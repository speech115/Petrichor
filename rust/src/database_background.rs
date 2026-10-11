//! Background cursors and prepared image writes commit together; codecs remain in the Apple adapter.
use super::database::{
    DatabaseCell, DbResult, LibraryDatabase, invalid, query_rows, quote, timestamp,
};
use rusqlite::{Connection, OptionalExtension, params};

#[derive(Clone, Debug, uniffi::Record)]
pub struct BackgroundJob {
    pub identifier: String,
    pub progress: Option<String>,
}
#[derive(Clone, Debug, uniffi::Record)]
pub struct BackgroundArtwork {
    pub id: DatabaseCell,
    pub label: String,
    pub original: Vec<u8>,
    pub thumbnail: Option<Vec<u8>>,
}
#[derive(Clone, Debug, uniffi::Record)]
pub struct BackgroundArtworkBatch {
    pub table: String,
    pub items: Vec<BackgroundArtwork>,
    pub progress: String,
    pub done: bool,
    pub processed: u64,
    pub total: u64,
}
#[derive(Clone, Debug, uniffi::Record)]
pub struct BackgroundArtworkUpdate {
    pub id: DatabaseCell,
    pub original: Vec<u8>,
    pub data: Vec<u8>,
}
fn tables(job: &str) -> DbResult<&'static [&'static str]> {
    match job {
        "v8_background_convert_artwork_to_heic" => {
            Ok(&["albums", "artists", "tracks", "playlists"])
        }
        "v13_background_fill_artwork_thumbnail" | "v16_background_jpeg_thumbnails" => {
            Ok(&["albums", "artists"])
        }
        _ => Err(invalid("Unknown artwork migration")),
    }
}
fn columns(table: &str) -> DbResult<(&'static str, &'static str)> {
    match table {
        "albums" => Ok(("title", "artwork_data")),
        "artists" => Ok(("name", "artwork_data")),
        "tracks" => Ok(("title", "track_artwork_data")),
        "playlists" => Ok(("name", "cover_artwork_data")),
        _ => Err(invalid("Invalid artwork table")),
    }
}
#[uniffi::export(callback_interface)]
pub trait BackgroundMigrationProgress: Send + Sync {
    fn update(&self, processed: u64, total: u64);
}

#[uniffi::export]
impl LibraryDatabase {
    pub fn pending_background_migrations(&self) -> DbResult<Vec<BackgroundJob>> {
        self.read(|c| {
    let mut s=c.prepare("SELECT identifier,progress FROM background_migrations WHERE completed_at IS NULL ORDER BY identifier")?;
    Ok(s.query_map([],|r|Ok(BackgroundJob{identifier:r.get(0)?,progress:r.get(1)?}))?.collect::<Result<_,_>>()?)
 })
    }
    pub fn has_pending_background_migrations(&self) -> DbResult<bool> {
        self.read(|c| {
            Ok(
                c.prepare(
                    "SELECT 1 FROM background_migrations WHERE completed_at IS NULL LIMIT 1",
                )?
                .exists([])?,
            )
        })
    }
    pub fn is_pending_migration_resumable(&self) -> DbResult<bool> {
        self.read(|c|Ok(c.query_row("SELECT resumable FROM background_migrations WHERE completed_at IS NULL ORDER BY identifier LIMIT 1",[],|r|r.get(0)).optional()?.unwrap_or(true)))
    }
    pub fn complete_background_migration(&self, identifier: String, now: f64) -> DbResult<()> {
        self.write(|c| complete(c, &identifier, now))
    }
    pub fn update_migration_progress(&self, identifier: String, progress: String) -> DbResult<()> {
        self.write(|c| {
            c.execute(
                "UPDATE background_migrations SET progress=? WHERE identifier=?",
                params![progress, identifier],
            )?;
            Ok(())
        })
    }
    pub fn background_artwork_batch(&self, identifier: String) -> DbResult<BackgroundArtworkBatch> {
        self.read(|c|{
    let names=tables(&identifier)?;
    let progress:Option<String>=c.query_row("SELECT progress FROM background_migrations WHERE identifier=? AND completed_at IS NULL",[&identifier],|r|r.get(0)).optional()?.flatten();
    let state=progress.as_deref().and_then(|s|serde_json::from_str::<serde_json::Value>(s).ok()).unwrap_or_default();
    let table=state.get("table").and_then(|v|v.as_str()).unwrap_or(names[0]);
    let index=names.iter().position(|n|*n==table).ok_or_else(||invalid("Invalid migration cursor table"))?;
    let jpeg=identifier=="v16_background_jpeg_thumbnails";
    let thumbnail=identifier!="v8_background_convert_artwork_to_heic";
    let counts=names.iter().map(|table| {let (_,art)=columns(table)?;let filter=if jpeg {"artwork_thumbnail"} else {art};Ok(c.query_row(&format!("SELECT COUNT(*) FROM {table} WHERE {filter} IS NOT NULL"),[],|r|r.get::<_,i64>(0).map(|value|value as u64))?)}).collect::<DbResult<Vec<_>>>()?;
    let total=counts.iter().sum();
    for (i,table) in names.iter().enumerate().skip(index) {
        let (label,art)=columns(table)?;
        let source=if jpeg {"COALESCE(artwork_data,artwork_thumbnail)"} else {art};
        let filter=if jpeg {"artwork_thumbnail"} else {art};
        let thumb=if thumbnail {"artwork_thumbnail"} else {"NULL"};
        let last=if i==index {state.get("lastID").cloned()} else {None};
        let mut cursor=last.map(|v|match v {serde_json::Value::String(value)=>DatabaseCell::Text{value},serde_json::Value::Number(n)=>DatabaseCell::Integer{value:n.as_i64().unwrap_or(0)},_=>DatabaseCell::Integer{value:0}}).unwrap_or(DatabaseCell::Integer{value:0});
        // Integer IDs follow legacy rowid order; UUID playlists restart because old OFFSET had no ID ordering.
        if i==index && *table!="playlists" && state.get("lastID").is_none() {if let Some(offset)=state.get("offset").and_then(|v|v.as_i64()).filter(|n|*n>0) {
            let r=query_rows(c,&format!("SELECT id FROM {table} WHERE {filter} IS NOT NULL ORDER BY id LIMIT 1 OFFSET ?"),[offset-1])?;
            if let Some(row)=r.rows.first(){cursor=row[0].clone();}
        }}
        let r=query_rows(c,&format!("SELECT id,COALESCE({label},''),{source},{thumb} FROM {table} WHERE id>? AND {filter} IS NOT NULL ORDER BY id LIMIT 50"),[cursor])?;
        if r.rows.is_empty(){continue;}
        let last=r.rows.last().ok_or_else(||invalid("Empty artwork batch"))?[0].clone();
        let processed=counts[..i].iter().sum::<u64>()+c.query_row(&format!("SELECT COUNT(*) FROM {table} WHERE id<=? AND {filter} IS NOT NULL"),[last.clone()],|r|r.get::<_,i64>(0).map(|value|value as u64))?;
        let last=match last {DatabaseCell::Integer{value}=>serde_json::json!(value),DatabaseCell::Text{value}=>serde_json::json!(value),_=>return Err(invalid("Invalid artwork identity"))};
        let items=r.rows.into_iter().map(|row| {
            let original=match &row[2]{DatabaseCell::Blob{value}=>value.clone(),_=>Vec::new()};
            let thumbnail=match &row[3]{DatabaseCell::Blob{value}=>Some(value.clone()),_=>None};
            let label=match &row[1]{DatabaseCell::Text{value}=>value.clone(),_=>String::new()};
            BackgroundArtwork{id:row[0].clone(),label,original,thumbnail}
        }).collect();
        return Ok(BackgroundArtworkBatch{table:table.to_string(),items,progress:serde_json::json!({"table":table,"lastID":last}).to_string(),done:false,processed,total});
    }
    Ok(BackgroundArtworkBatch{table:names[names.len()-1].into(),items:Vec::new(),progress:String::new(),done:true,processed:total,total})
 })
    }
    pub fn commit_background_artwork(
        &self,
        identifier: String,
        table: String,
        updates: Vec<BackgroundArtworkUpdate>,
        progress: String,
    ) -> DbResult<()> {
        if !tables(&identifier)?.contains(&table.as_str()) {
            return Err(invalid("Artwork table does not belong to migration"));
        }
        let (_, art) = columns(&table)?;
        let heic = identifier == "v8_background_convert_artwork_to_heic";
        let target = if heic { art } else { "artwork_thumbnail" };
        let jpeg = identifier == "v16_background_jpeg_thumbnails";
        let source = if jpeg {
            "COALESCE(artwork_data,artwork_thumbnail)"
        } else {
            art
        };
        self.write(|c| {
        for update in updates {if heic && update.data.len()>=update.original.len(){continue;}
            c.execute(&format!("UPDATE {table} SET {target}=? WHERE id=? AND {source}=?"),params![update.data,update.id,update.original])?;
        }
        c.execute("UPDATE background_migrations SET progress=? WHERE identifier=? AND completed_at IS NULL",params![progress,identifier])?;Ok(())
    })
    }
    pub fn run_background_associations(
        &self,
        identifier: String,
        now: f64,
        progress: Box<dyn BackgroundMigrationProgress>,
    ) -> DbResult<()> {
        if ![
            "v9_background_rebuild_artist_associations",
            "v12_background_backfill_album_artists",
        ]
        .contains(&identifier.as_str())
        {
            return Err(invalid("Unknown association migration"));
        }
        self.write(|c| {
        if !c.prepare("SELECT 1 FROM background_migrations WHERE identifier=? AND completed_at IS NULL")?.exists([&identifier])?{return Ok(());}
        let now_text=timestamp(now)?;
        let rebuild=identifier.starts_with("v9_");
        let ids:Vec<i64>={let mut s=c.prepare(if rebuild {"SELECT id FROM tracks WHERE is_duplicate=0 ORDER BY id"} else {"SELECT id FROM tracks ORDER BY id"})?;s.query_map([],|r|r.get(0))?.collect::<Result<_,_>>()?};
        let total=ids.len() as u64;
        for (index,id) in ids.into_iter().enumerate() {
            if rebuild {super::database_normalization::rebuild_track_associations(c,id,&now_text)?;}
            else {super::database_normalization::backfill_track_album_artists(c,id,&now_text)?;}
            let processed=index as u64+1;
            if processed%500==0 || processed==total {progress.update(processed,total);}
        }
        if rebuild {super::database_normalization::update_artist_stats(c,&now_text)?;super::database_normalization::update_album_stats(c,&now_text)?;super::database_mutations::cleanup_orphaned_data(c)?;}
        complete(c,&identifier,now)
    })
    }
    pub fn move_artwork_columns_last(&self, now: f64) -> DbResult<()> {
        let _guard = self
            .operation_gate
            .write()
            .map_err(|_| invalid("Database operation lock poisoned"))?;
        self.exclusive(|c| {
            c.pragma_update(None, "foreign_keys", false)?;
            let result = (|| {
                for (table, cols) in [
                    ("albums", vec!["artwork_thumbnail", "artwork_data"]),
                    ("artists", vec!["artwork_thumbnail", "artwork_data"]),
                    ("tracks", vec!["track_artwork_data"]),
                ] {
                    let tx = c.transaction()?;
                    reorder(&tx, table, &cols)?;
                    if tx.prepare("PRAGMA foreign_key_check")?.exists([])? {
                        return Err(invalid("Column reorder failed foreign key check"));
                    }
                    tx.commit()?;
                }
                complete(c, "v16_background_move_artwork_columns_last", now)
            })();
            c.pragma_update(None, "foreign_keys", true)?;
            result
        })?;
        self.checkpoint()
    }
}
fn complete(c: &Connection, id: &str, now: f64) -> DbResult<()> {
    c.execute("UPDATE background_migrations SET completed_at=?,progress=NULL WHERE identifier=? AND completed_at IS NULL",params![timestamp(now)?,id])?;
    Ok(())
}
fn definitions(body: &str) -> DbResult<Vec<String>> {
    let mut out = Vec::new();
    let mut start = 0;
    let mut depth = 0;
    let mut quote = None;
    let mut iter = body.char_indices().peekable();
    while let Some((i, ch)) = iter.next() {
        if let Some(q) = quote {
            if ch == q {
                if iter.peek().is_some_and(|(_, next)| *next == q) {
                    iter.next();
                } else {
                    quote = None;
                }
            }
        } else {
            match ch {
                '\'' | '"' | '`' => quote = Some(ch),
                '[' => quote = Some(']'),
                '(' => depth += 1,
                ')' => depth -= 1,
                ',' if depth == 0 => {
                    out.push(body[start..i].trim().into());
                    start = i + 1;
                }
                _ => {}
            }
        }
    }
    if quote.is_some() || depth != 0 {
        return Err(invalid("Unsupported table definition"));
    }
    out.push(body[start..].trim().into());
    Ok(out)
}
fn reorder(c: &Connection, table: &str, moved: &[&str]) -> DbResult<()> {
    let current: Vec<String> = {
        let mut s = c.prepare(&format!("PRAGMA table_info({})", quote(table)))?;
        s.query_map([], |r| r.get(1))?.collect::<Result<_, _>>()?
    };
    if current
        .iter()
        .rev()
        .take(moved.len())
        .map(String::as_str)
        .eq(moved.iter().rev().copied())
    {
        return Ok(());
    }
    let ddl: String = c.query_row(
        "SELECT sql FROM sqlite_master WHERE type='table' AND name=?",
        [table],
        |r| r.get(0),
    )?;
    let open = ddl
        .find('(')
        .ok_or_else(|| invalid("Missing table definition"))?;
    let close = ddl
        .rfind(')')
        .ok_or_else(|| invalid("Missing table definition"))?;
    let mut defs = definitions(&ddl[open + 1..close])?;
    let mut moved_defs = Vec::new();
    for name in moved {
        let prefix = quote(name);
        let index = defs
            .iter()
            .position(|d| {
                d.starts_with(&prefix) && d[prefix.len()..].starts_with(char::is_whitespace)
            })
            .ok_or_else(|| invalid(format!("Unsupported column definition: {table}.{name}")))?;
        moved_defs.push(defs.remove(index));
    }
    defs.extend(moved_defs);
    let dependents: Vec<(String, String, String)> = {
        let mut s=c.prepare("SELECT type,name,sql FROM sqlite_master WHERE tbl_name=? AND type IN ('index','trigger') AND sql IS NOT NULL")?;
        s.query_map([table], |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?)))?
            .collect::<Result<_, _>>()?
    };
    let seq: Option<i64> = c
        .query_row(
            "SELECT seq FROM sqlite_sequence WHERE name=?",
            [table],
            |r| r.get(0),
        )
        .optional()?;
    let count: i64 = c.query_row(&format!("SELECT COUNT(*) FROM {}", quote(table)), [], |r| {
        r.get(0)
    })?;
    for (typ, name, _) in &dependents {
        if typ == "trigger" {
            c.execute_batch(&format!("DROP TRIGGER {}", quote(name)))?;
        }
    }
    let staging = format!("{table}_reordered");
    c.execute_batch(&format!(
        "CREATE TABLE {} ({}){}",
        quote(&staging),
        defs.join(","),
        &ddl[close + 1..]
    ))?;
    let mut names = current
        .iter()
        .filter(|n| !moved.contains(&n.as_str()))
        .map(|n| quote(n))
        .collect::<Vec<_>>();
    names.extend(moved.iter().map(|n| quote(n)));
    let list = names.join(",");
    let mut last = i64::MIN;
    loop {
        let upper:Option<i64>=c.query_row(&format!("SELECT MAX(rowid) FROM (SELECT rowid FROM {} WHERE rowid>? ORDER BY rowid LIMIT 100)",quote(table)),[last],|r|r.get(0))?;
        let Some(upper) = upper else {
            break;
        };
        c.execute(
            &format!(
                "INSERT INTO {} ({list}) SELECT {list} FROM {} WHERE rowid>? AND rowid<=?",
                quote(&staging),
                quote(table)
            ),
            params![last, upper],
        )?;
        c.execute(
            &format!("DELETE FROM {} WHERE rowid>? AND rowid<=?", quote(table)),
            params![last, upper],
        )?;
        last = upper;
    }
    let after: i64 = c.query_row(
        &format!("SELECT COUNT(*) FROM {}", quote(&staging)),
        [],
        |r| r.get(0),
    )?;
    if after != count {
        return Err(invalid("Column reorder changed row count"));
    }
    c.execute_batch(&format!(
        "DROP TABLE {};ALTER TABLE {} RENAME TO {}",
        quote(table),
        quote(&staging),
        quote(table)
    ))?;
    for (_, _, sql) in dependents {
        c.execute_batch(&sql)?;
    }
    if let Some(seq) = seq {
        let changed = c.execute(
            "UPDATE sqlite_sequence SET seq=MAX(seq,?) WHERE name=?",
            params![seq, table],
        )?;
        if changed == 0 {
            c.execute(
                "INSERT INTO sqlite_sequence(name,seq) VALUES (?,?)",
                params![table, seq],
            )?;
        }
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    fn database() -> std::sync::Arc<LibraryDatabase> {
        LibraryDatabase::open(
            std::env::temp_dir()
                .join(format!(
                    "petrichor-background-{}.sqlite",
                    uuid::Uuid::new_v4()
                ))
                .to_string_lossy()
                .into(),
        )
        .unwrap()
    }
    #[test]
    fn artwork_progress_and_blob_write_roll_back_together() {
        let db = database();
        db.write(|c|{c.execute_batch("INSERT INTO albums(title,normalized_title,artwork_data,created_at,updated_at) VALUES ('cover','cover',X'00010203','2020-01-01','2020-01-01')")?;Ok(())}).unwrap();
        let job = "v13_background_fill_artwork_thumbnail".to_string();
        let batch = db.background_artwork_batch(job.clone()).unwrap();
        assert_eq!(batch.items.len(), 1);
        assert_eq!((batch.processed, batch.total), (1, 1));
        db.write(|c|{c.execute_batch("CREATE TRIGGER fail_cursor BEFORE UPDATE OF progress ON background_migrations BEGIN SELECT RAISE(ABORT,'interrupt');END")?;Ok(())}).unwrap();
        let item = &batch.items[0];
        let update = BackgroundArtworkUpdate {
            id: item.id.clone(),
            original: item.original.clone(),
            data: vec![9],
        };
        assert!(
            db.commit_background_artwork(
                job.clone(),
                batch.table.clone(),
                vec![update.clone()],
                batch.progress.clone()
            )
            .is_err()
        );
        assert_eq!(
            db.read(|c| query_rows(c, "SELECT artwork_thumbnail FROM albums", []))
                .unwrap()
                .rows[0][0],
            DatabaseCell::Null
        );
        db.write(|c| {
            c.execute_batch("DROP TRIGGER fail_cursor")?;
            Ok(())
        })
        .unwrap();
        db.commit_background_artwork(job.clone(), batch.table, vec![update], batch.progress)
            .unwrap();
        assert!(db.background_artwork_batch(job).unwrap().done);
    }
    #[test]
    fn reorder_preserves_junctions_fts_sequence_and_unknown_columns() {
        let db = database();
        db.write(|c|{c.execute_batch("INSERT INTO folders(name,path,date_added,date_updated) VALUES ('folder','/folder','2020-01-01','2020-01-01'); INSERT INTO artists(id,name,normalized_name,created_at,updated_at) VALUES (99,'artist','artist','2020-01-01','2020-01-01');DELETE FROM artists WHERE id=99;INSERT INTO artists(id,name,normalized_name,artwork_data,created_at,updated_at) VALUES (1,'artist','artist',X'AA00FF','2020-01-01','2020-01-01');INSERT INTO tracks(id,folder_id,path,filename,title,date_added,track_artwork_data) VALUES (1,1,'/folder/song','song','Test music','2020-01-01',X'0011FF');INSERT INTO track_artists VALUES(1,1,'artist',0);ALTER TABLE tracks ADD COLUMN \"future_value\" TEXT;UPDATE tracks SET future_value='unchanged';")?;Ok(())}).unwrap();
        db.move_artwork_columns_last(0.0).unwrap();
        db.read(|c| {
            assert_eq!(
                c.query_row(
                    "SELECT seq FROM sqlite_sequence WHERE name='artists'",
                    [],
                    |r| r.get::<_, i64>(0)
                )?,
                99
            );
            assert_eq!(
                c.query_row("SELECT COUNT(*) FROM track_artists", [], |r| r
                    .get::<_, i64>(0))?,
                1
            );
            assert_eq!(
                c.query_row("SELECT future_value FROM tracks", [], |r| r
                    .get::<_, String>(0))?,
                "unchanged"
            );
            assert_eq!(
                c.query_row(
                    "SELECT COUNT(*) FROM tracks_fts WHERE tracks_fts MATCH 'music'",
                    [],
                    |r| r.get::<_, i64>(0)
                )?,
                1
            );
            assert_eq!(
                c.query_row("SELECT artwork_data FROM artists", [], |r| r
                    .get::<_, Vec<u8>>(0))?,
                vec![170, 0, 255]
            );
            assert!(!c.prepare("PRAGMA foreign_key_check")?.exists([])?);
            Ok(())
        })
        .unwrap();
    }
}

#[cfg(test)]
mod progress_tests {
    use super::*;
    struct Progress(std::sync::Arc<std::sync::Mutex<Vec<(u64, u64)>>>);
    impl BackgroundMigrationProgress for Progress {
        fn update(&self, processed: u64, total: u64) {
            self.0.lock().unwrap().push((processed, total));
        }
    }
    #[test]
    fn association_progress_reports_work_without_owning_database_state() {
        let db = LibraryDatabase::open(
            std::env::temp_dir()
                .join(format!(
                    "petrichor-progress-{}.sqlite",
                    uuid::Uuid::new_v4()
                ))
                .to_string_lossy()
                .into(),
        )
        .unwrap();
        db.write(|c|{c.execute_batch("INSERT INTO folders(name,path,date_added,date_updated) VALUES ('folder','/folder','2020-01-01','2020-01-01');INSERT INTO tracks(folder_id,path,filename,artist,date_added) VALUES (1,'/folder/song','song','Artist','2020-01-01')")?;Ok(())}).unwrap();
        let updates = std::sync::Arc::new(std::sync::Mutex::new(Vec::new()));
        db.run_background_associations(
            "v12_background_backfill_album_artists".into(),
            0.0,
            Box::new(Progress(updates.clone())),
        )
        .unwrap();
        assert_eq!(*updates.lock().unwrap(), vec![(1, 1)]);
        db.read(|c|{assert_eq!(c.query_row("SELECT COUNT(*) FROM track_artists WHERE role='album_artist'",[],|r|r.get::<_,i64>(0))?,1);assert!(!c.prepare("SELECT 1 FROM background_migrations WHERE identifier='v12_background_backfill_album_artists' AND completed_at IS NULL")?.exists([])?);Ok(())}).unwrap();
    }
}

#[cfg(test)]
mod review_regressions {
    use super::*;
    fn database() -> std::sync::Arc<LibraryDatabase> {
        LibraryDatabase::open(
            std::env::temp_dir()
                .join(format!("petrichor-cursor-{}.sqlite", uuid::Uuid::new_v4()))
                .to_string_lossy()
                .into(),
        )
        .unwrap()
    }
    #[test]
    fn legacy_uuid_playlist_offset_revisits_every_cover() {
        let db = database();
        let job = "v8_background_convert_artwork_to_heic".to_string();
        db.write(|c| {
            for number in (1..=100).rev() {
                let id=format!("{:08X}-0000-0000-0000-000000000000",number);
                c.execute("INSERT INTO playlists(id,name,type,is_user_editable,is_content_editable,date_created,date_modified,cover_artwork_data) VALUES (?,'cover','regular',1,1,'2020-01-01','2020-01-01',X'00010203')",[id])?;
            }
            c.execute("UPDATE background_migrations SET progress=? WHERE identifier=?",params!["{\"table\":\"playlists\",\"offset\":50}",job])?;Ok(())
        }).unwrap();
        let mut seen = std::collections::HashSet::new();
        loop {
            let batch = db.background_artwork_batch(job.clone()).unwrap();
            if batch.done {
                break;
            }
            let updates = batch
                .items
                .into_iter()
                .map(|item| {
                    if let DatabaseCell::Text { value } = &item.id {
                        seen.insert(value.clone());
                    }
                    BackgroundArtworkUpdate {
                        id: item.id,
                        original: item.original,
                        data: vec![9],
                    }
                })
                .collect();
            db.commit_background_artwork(job.clone(), batch.table, updates, batch.progress)
                .unwrap();
        }
        assert_eq!(seen.len(), 100);
        db.read(|c| {
            assert_eq!(
                c.query_row(
                    "SELECT COUNT(*) FROM playlists WHERE cover_artwork_data=X'09'",
                    [],
                    |r| r.get::<_, i64>(0)
                )?,
                100
            );
            Ok(())
        })
        .unwrap();
    }
    #[test]
    fn failed_later_artwork_batch_preserves_prior_committed_work() {
        let db = database();
        let job = "v13_background_fill_artwork_thumbnail".to_string();
        db.write(|c|{for i in 0..51 {c.execute("INSERT INTO albums(title,normalized_title,artwork_data,created_at,updated_at) VALUES (?, ?, X'00010203','2020-01-01','2020-01-01')",params![format!("cover{i}"),format!("cover{i}")])?;}Ok(())}).unwrap();
        let first = db.background_artwork_batch(job.clone()).unwrap();
        assert_eq!(first.items.len(), 50);
        let updates = first
            .items
            .into_iter()
            .map(|item| BackgroundArtworkUpdate {
                id: item.id,
                original: item.original,
                data: vec![9],
            })
            .collect();
        db.commit_background_artwork(job.clone(), first.table, updates, first.progress.clone())
            .unwrap();
        let second = db.background_artwork_batch(job.clone()).unwrap();
        assert_eq!(second.items.len(), 1);
        db.write(|c|{c.execute_batch("CREATE TRIGGER fail_cursor BEFORE UPDATE OF progress ON background_migrations BEGIN SELECT RAISE(ABORT,'second batch failure');END")?;Ok(())}).unwrap();
        let updates = second
            .items
            .into_iter()
            .map(|item| BackgroundArtworkUpdate {
                id: item.id,
                original: item.original,
                data: vec![8],
            })
            .collect();
        assert!(
            db.commit_background_artwork(job.clone(), second.table, updates, second.progress)
                .is_err()
        );
        db.read(|c| {
            assert_eq!(
                c.query_row(
                    "SELECT COUNT(*) FROM albums WHERE artwork_thumbnail=X'09'",
                    [],
                    |r| r.get::<_, i64>(0)
                )?,
                50
            );
            assert_eq!(
                c.query_row(
                    "SELECT progress FROM background_migrations WHERE identifier=?",
                    [job],
                    |r| r.get::<_, String>(0)
                )?,
                first.progress
            );
            Ok(())
        })
        .unwrap();
    }
}
