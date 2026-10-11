use crate::database::{DatabaseRows, DbResult, LibraryDatabase, query_rows, timestamp};
use crate::database_normalization::{
    normalize_album_title, normalize_artist_name, update_album_stats, update_artist_stats,
};
use rusqlite::{Connection, OptionalExtension, params};
use std::collections::HashSet;
#[derive(uniffi::Record)]
pub struct EntityMergeResult {
    pub merged_count: i64,
    pub canonical_name: String,
}
#[derive(uniffi::Record)]
pub struct MergeThumbnail {
    pub entity_id: i64,
    pub artwork: Vec<u8>,
    pub thumbnail: Option<Vec<u8>>,
}
fn not_found(name: &str) -> crate::database::LibraryDatabaseError {
    crate::database::LibraryDatabaseError::EntityNotFound {
        name: name.to_owned(),
    }
}

fn artist(c: &Connection, name: &str) -> DbResult<Option<(i64, String, String)>> {
    Ok(c.query_row(
        "SELECT id,name,normalized_name FROM artists WHERE name=? OR normalized_name=? LIMIT 1",
        params![name, normalize_artist_name(name)],
        |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?)),
    )
    .optional()?)
}
fn primary(c: &Connection, id: i64) -> DbResult<String> {
    Ok(c.query_row("SELECT a.normalized_name FROM album_artists aa JOIN artists a ON a.id=aa.artist_id WHERE aa.album_id=? AND aa.role='primary' ORDER BY aa.position LIMIT 1",[id],|r|r.get(0)).optional()?.unwrap_or_default())
}
fn alias_artist(c: &Connection, n: &str, name: &str, id: i64, date: &str) -> DbResult<()> {
    c.execute("INSERT OR REPLACE INTO artist_aliases(normalized_alias,display_name,canonical_artist_id,created_at) VALUES(?,?,?,?)",params![n,name,id,date])?;
    Ok(())
}
fn alias_album(c: &Connection, key: &str, title: &str, id: i64, date: &str) -> DbResult<()> {
    c.execute("INSERT OR REPLACE INTO album_aliases(normalized_key,display_title,canonical_album_id,created_at) VALUES(?,?,?,?)",params![key,title,id,date])?;
    Ok(())
}
fn donor_thumbnail(
    c: &Connection,
    table: &str,
    id: i64,
    prepared: &[MergeThumbnail],
) -> DbResult<Option<Vec<u8>>> {
    let pair: (Option<Vec<u8>>, Option<Vec<u8>>) = c.query_row(
        &format!("SELECT artwork_data,artwork_thumbnail FROM {table} WHERE id=?"),
        [id],
        |r| Ok((r.get(0)?, r.get(1)?)),
    )?;
    if let Some(thumbnail) = pair.1 {
        return Ok(Some(thumbnail));
    }
    let Some(artwork) = pair.0 else {
        return Ok(None);
    };
    let prepared = prepared
        .iter()
        .find(|p| p.entity_id == id && p.artwork == artwork)
        .ok_or_else(|| crate::database::LibraryDatabaseError::Invalid {
            message: "Merge artwork changed or was not prepared; retry the merge".into(),
        })?;
    Ok(prepared.thumbnail.clone())
}
#[uniffi::export]
impl LibraryDatabase {
    pub fn merge_artists(
        &self,
        winner_name: String,
        loser_names: Vec<String>,
        new_name: Option<String>,
        now: f64,
        thumbnails: Vec<MergeThumbnail>,
    ) -> DbResult<EntityMergeResult> {
        let date = timestamp(now)?;
        self.write(|tx|{
 let (winner,name,norm)=artist(tx,&winner_name)?.ok_or_else(||not_found(&winner_name))?;
 let rename=new_name.as_deref().map(str::trim).filter(|s|!s.is_empty()&&*s!=name).map(str::to_owned);
 let mut seen=HashSet::from([winner]);let mut losers=Vec::new();
 for n in loser_names {if ["Unknown Artist","Unknown Album Artist","Unknown Composer"].contains(&n.as_str()){continue;}if let Some(row)=artist(tx,&n)?{if seen.insert(row.0){losers.push(row);}}}
 if let Some(new)=&rename {let normalized=normalize_artist_name(new);if normalized!=norm {if let Some(row)=artist(tx,&normalized)?{if seen.insert(row.0){losers.push(row);}}}}
 if losers.is_empty()&&rename.is_none(){return Ok(EntityMergeResult{merged_count:0,canonical_name:name});}
 // Donors use database row order, matching the original unordered fetch.
 let mut donors=losers.iter().map(|r|r.0).collect::<Vec<_>>();donors.sort_unstable();
 for id in &donors {
 for table in ["track_artists","album_artists"] {tx.execute(&format!("UPDATE OR IGNORE {table} SET artist_id=? WHERE artist_id=?"),params![winner,id])?;tx.execute(&format!("DELETE FROM {table} WHERE artist_id=?"),[id])?;}
 let fills:bool=tx.query_row("SELECT (w.artwork_data IS NULL AND d.artwork_data IS NOT NULL) OR (w.image_url IS NULL AND d.image_url IS NOT NULL) OR (w.bio IS NULL AND d.bio IS NOT NULL) FROM artists w,artists d WHERE w.id=? AND d.id=?",params![winner,id],|r|r.get(0))?;
 let needs_art:bool=tx.query_row("SELECT w.artwork_data IS NULL AND d.artwork_data IS NOT NULL FROM artists w,artists d WHERE w.id=? AND d.id=?",params![winner,id],|r|r.get(0))?;
 let thumb=if needs_art {donor_thumbnail(tx,"artists",*id,&thumbnails)?}else{None};
 tx.execute("UPDATE artists SET artwork_thumbnail=CASE WHEN artwork_data IS NULL AND (SELECT artwork_data FROM artists WHERE id=?) IS NOT NULL THEN ? ELSE artwork_thumbnail END,artwork_data=COALESCE(artwork_data,(SELECT artwork_data FROM artists WHERE id=?)),image_source=CASE WHEN image_url IS NULL AND (SELECT image_url FROM artists WHERE id=?) IS NOT NULL THEN (SELECT image_source FROM artists WHERE id=?) ELSE image_source END,image_updated_at=CASE WHEN image_url IS NULL AND (SELECT image_url FROM artists WHERE id=?) IS NOT NULL THEN (SELECT image_updated_at FROM artists WHERE id=?) ELSE image_updated_at END,image_url=COALESCE(image_url,(SELECT image_url FROM artists WHERE id=?)),bio_source=CASE WHEN bio IS NULL AND (SELECT bio FROM artists WHERE id=?) IS NOT NULL THEN (SELECT bio_source FROM artists WHERE id=?) ELSE bio_source END,bio_updated_at=CASE WHEN bio IS NULL AND (SELECT bio FROM artists WHERE id=?) IS NOT NULL THEN (SELECT bio_updated_at FROM artists WHERE id=?) ELSE bio_updated_at END,bio=COALESCE(bio,(SELECT bio FROM artists WHERE id=?)) WHERE id=?",params![id,thumb,id,id,id,id,id,id,id,id,id,id,id,winner])?;
 if fills {tx.execute("UPDATE artists SET updated_at=? WHERE id=?",params![date,winner])?;}
 tx.execute("UPDATE artist_aliases SET canonical_artist_id=? WHERE canonical_artist_id=?",params![winner,id])?;
 }
 for (id,display,n) in &losers {alias_artist(tx,n,display,winner,&date)?;tx.execute("DELETE FROM artists WHERE id=?",[id])?;}
 if let Some(new)=&rename {let n=normalize_artist_name(new);if n!=norm {alias_artist(tx,&norm,&name,winner,&date)?;tx.execute("DELETE FROM artist_aliases WHERE normalized_alias=?",[&n])?;}tx.execute("UPDATE artists SET name=?,normalized_name=?,sort_name=?,updated_at=? WHERE id=?",params![new,n,new,date,winner])?;}
 update_artist_stats(tx,&date)?;Ok(EntityMergeResult{merged_count:losers.len() as i64,canonical_name:rename.unwrap_or(name)})})
    }
    pub fn merge_albums(
        &self,
        winner_id: i64,
        loser_ids: Vec<i64>,
        new_title: Option<String>,
        now: f64,
        thumbnails: Vec<MergeThumbnail>,
    ) -> DbResult<EntityMergeResult> {
        let date = timestamp(now)?;
        self.write(|tx|{
 let (title,norm):(String,String)=tx.query_row("SELECT title,normalized_title FROM albums WHERE id=?",[winner_id],|r|Ok((r.get(0)?,r.get(1)?))).optional()?.ok_or_else(||not_found(&format!("album #{winner_id}")))?;
 let rename=new_title.as_deref().map(str::trim).filter(|s|!s.is_empty()&&*s!=title).map(str::to_owned);let canonical=rename.as_ref().unwrap_or(&title).clone();
 let mut ids=loser_ids.into_iter().filter(|id|*id!=winner_id).collect::<HashSet<_>>().into_iter().collect::<Vec<_>>();ids.sort_unstable();
 if ids.is_empty()&&rename.is_none(){return Ok(EntityMergeResult{merged_count:0,canonical_name:title});}
 for id in &ids {let loser:Option<(String,String)>=tx.query_row("SELECT title,normalized_title FROM albums WHERE id=?",[id],|r|Ok((r.get(0)?,r.get(1)?))).optional()?;let Some((lt,ln))=loser else{continue;};let key=format!("{}|{}",ln,primary(tx,*id)?);
 tx.execute("UPDATE tracks SET album_id=? WHERE album_id=?",params![winner_id,id])?;tx.execute("UPDATE OR IGNORE album_artists SET album_id=? WHERE album_id=?",params![winner_id,id])?;tx.execute("DELETE FROM album_artists WHERE album_id=?",[id])?;
 let fills:bool=tx.query_row("SELECT w.artwork_data IS NULL AND d.artwork_data IS NOT NULL FROM albums w,albums d WHERE w.id=? AND d.id=?",params![winner_id,id],|r|r.get(0))?;let thumb=if fills {donor_thumbnail(tx,"albums",*id,&thumbnails)?}else{None};tx.execute("UPDATE albums SET artwork_thumbnail=CASE WHEN artwork_data IS NULL AND (SELECT artwork_data FROM albums WHERE id=?) IS NOT NULL THEN ? ELSE artwork_thumbnail END,artwork_data=COALESCE(artwork_data,(SELECT artwork_data FROM albums WHERE id=?)) WHERE id=?",params![id,thumb,id,winner_id])?;
 if fills {tx.execute("UPDATE albums SET updated_at=? WHERE id=?",params![date,winner_id])?;}tx.execute("UPDATE album_aliases SET canonical_album_id=? WHERE canonical_album_id=?",params![winner_id,id])?;alias_album(tx,&key,&lt,winner_id,&date)?;tx.execute("DELETE FROM albums WHERE id=?",[id])?;
 }
 tx.execute("UPDATE tracks SET album=? WHERE album_id=?",params![canonical,winner_id])?;
 if let Some(new)=&rename {let n=normalize_album_title(new);let p=primary(tx,winner_id)?;alias_album(tx,&format!("{norm}|{p}"),&title,winner_id,&date)?;tx.execute("DELETE FROM album_aliases WHERE normalized_key=?",[format!("{n}|{p}")])?;tx.execute("UPDATE albums SET title=?,normalized_title=?,sort_title=?,updated_at=? WHERE id=?",params![new,n,new,date,winner_id])?;}
 update_album_stats(tx,&date)?;Ok(EntityMergeResult{merged_count:ids.len() as i64,canonical_name:canonical})})
    }
    pub fn album_merge_candidates(&self) -> DbResult<DatabaseRows> {
        self.read(|c|query_rows(c,"SELECT albums.id,albums.title,albums.total_tracks AS track_count,(SELECT artists.name FROM album_artists JOIN artists ON artists.id=album_artists.artist_id WHERE album_artists.album_id=albums.id AND album_artists.role='primary' ORDER BY album_artists.position LIMIT 1) AS artist_name FROM albums WHERE total_tracks>0 ORDER BY sort_title COLLATE NOCASE",[]))
    }
    pub fn merge_artwork_candidates(
        &self,
        albums: bool,
        names: Vec<String>,
        ids: Vec<i64>,
    ) -> DbResult<DatabaseRows> {
        self.read(|c|{
 let mut ids=ids;
 if !albums {for name in names {if let Some(row)=artist(c,&name)?{ids.push(row.0);}}}
 let mut result=DatabaseRows{columns:vec!["id".into(),"artwork_data".into()],rows:vec![]};let mut seen=HashSet::new();
 for id in ids {if seen.insert(id){let rows=query_rows(c,if albums {"SELECT id,artwork_data FROM albums WHERE id=? AND artwork_data IS NOT NULL AND artwork_thumbnail IS NULL"}else{"SELECT id,artwork_data FROM artists WHERE id=? AND artwork_data IS NOT NULL AND artwork_thumbnail IS NULL"},[id])?;result.rows.extend(rows.rows);}}
 Ok(result)
 })
    }
}
#[cfg(test)]
mod tests {
    use super::*;
    use crate::database_mutations::tests::fixture;
    #[test]
    fn artist_merge_keeps_raw_tags_roles_alias_chains_metadata_and_rolls_back() {
        let db = fixture("merge");
        db.write(|c|{c.execute_batch("UPDATE artists SET bio='DB only bio',artwork_data=x'0102',artwork_thumbnail=x'03' WHERE id=2; INSERT INTO artist_aliases(normalized_alias,display_name,canonical_artist_id,created_at) VALUES('older','Older',2,'2026-01-01');")?;Ok(())}).unwrap();
        let before = db
            .read(|c| query_rows(c, "SELECT * FROM artists ORDER BY id", []))
            .unwrap();
        db.write(|c|{c.execute_batch("CREATE TRIGGER fail_merge BEFORE DELETE ON artists BEGIN SELECT RAISE(ABORT,'forced rollback'); END;")?;Ok(())}).unwrap();
        assert!(
            db.merge_artists(
                "Winner".into(),
                vec!["Loser".into()],
                Some("Renamed".into()),
                1000.,
                vec![]
            )
            .is_err()
        );
        assert_eq!(
            before,
            db.read(|c| query_rows(c, "SELECT * FROM artists ORDER BY id", []))
                .unwrap()
        );
        db.write(|c| {
            c.execute_batch("DROP TRIGGER fail_merge;")?;
            Ok(())
        })
        .unwrap();
        let result = db
            .merge_artists(
                "Winner".into(),
                vec![
                    "Loser".into(),
                    "Loser".into(),
                    "Winner".into(),
                    "Unknown Artist".into(),
                ],
                Some("Renamed".into()),
                1000.,
                vec![],
            )
            .unwrap();
        assert_eq!(result.merged_count, 1);
        db.read(|c| {
            assert_eq!(
                c.query_row("SELECT artist FROM tracks WHERE id=1", [], |r| r
                    .get::<_, String>(0))?,
                "Raw artist"
            );
            assert_eq!(
                c.query_row("SELECT bio FROM artists WHERE id=1", [], |r| r
                    .get::<_, String>(0))?,
                "DB only bio"
            );
            assert_eq!(
                c.query_row(
                    "SELECT COUNT(*) FROM track_artists WHERE artist_id=1",
                    [],
                    |r| r.get::<_, i64>(0)
                )?,
                2
            );
            assert_eq!(
                c.query_row(
                    "SELECT COUNT(*) FROM artist_aliases WHERE canonical_artist_id=1",
                    [],
                    |r| r.get::<_, i64>(0)
                )?,
                3
            );
            Ok(())
        })
        .unwrap();
    }
    #[test]
    fn album_merge_preserves_membership_ids_art_and_alias() {
        let db = fixture("album");
        db.write(|c| {
            c.execute(
                "UPDATE albums SET artwork_data=x'0102',artwork_thumbnail=x'03' WHERE id=2",
                [],
            )?;
            Ok(())
        })
        .unwrap();
        let result = db
            .merge_albums(1, vec![1, 2, 2], Some("Canonical".into()), 1000., vec![])
            .unwrap();
        assert_eq!(result.merged_count, 1);
        db.read(|c|{assert_eq!(c.query_row("SELECT COUNT(*) FROM tracks WHERE album_id=1 AND album='Canonical'",[],|r|r.get::<_,i64>(0))?,2);assert_eq!(c.query_row("SELECT artwork_data FROM albums WHERE id=1",[],|r|r.get::<_,Vec<u8>>(0))?,vec![1,2]);assert_eq!(c.query_row("SELECT canonical_album_id FROM album_aliases WHERE normalized_key='loser album|loser'",[],|r|r.get::<_,i64>(0))?,1);Ok(())}).unwrap();
    }
}
#[cfg(test)]
mod regression_tests {
    #[test]
    fn missing_merge_winner_is_distinct_domain_error() {
        let db = crate::database_mutations::tests::fixture("missing-merge");
        assert!(
            matches!(db.merge_artists("Missing".into(),vec![],None,1000.,vec![]),Err(crate::database::LibraryDatabaseError::EntityNotFound{name}) if name=="Missing")
        );
        assert!(
            matches!(db.merge_albums(999,vec![],None,1000.,vec![]),Err(crate::database::LibraryDatabaseError::EntityNotFound{name}) if name=="album #999")
        );
    }
}
#[cfg(test)]
mod artwork_guard_tests {
    use super::*;
    #[test]
    fn changed_donor_art_rolls_back_winner_roles_and_aliases() {
        let db = crate::database_mutations::tests::fixture("art-cas");
        db.write(|c|{c.execute_batch("UPDATE artists SET artwork_data=x'0102',artwork_thumbnail=NULL WHERE id=2; UPDATE albums SET artwork_data=x'0102',artwork_thumbnail=NULL WHERE id=2; INSERT INTO artist_aliases(normalized_alias,display_name,canonical_artist_id,created_at) VALUES('older','Older',2,'2026-01-01'); INSERT INTO album_aliases(normalized_key,display_title,canonical_album_id,created_at) VALUES('older|','Older',2,'2026-01-01');")?;Ok(())}).unwrap();
        let tables = [
            "artists",
            "albums",
            "tracks",
            "track_artists",
            "album_artists",
            "artist_aliases",
            "album_aliases",
        ];
        let before = tables
            .iter()
            .map(|t| {
                db.read(|c| query_rows(c, &format!("SELECT * FROM {t} ORDER BY 1,2"), []))
                    .unwrap()
            })
            .collect::<Vec<_>>();
        let stale = || {
            vec![MergeThumbnail {
                entity_id: 2,
                artwork: vec![9],
                thumbnail: Some(vec![8]),
            }]
        };
        assert!(
            matches!(db.merge_artists("Winner".into(),vec!["Loser".into()],Some("Rename".into()),1000.,stale()),Err(crate::database::LibraryDatabaseError::Invalid{message}) if message.contains("retry"))
        );
        assert!(
            matches!(db.merge_albums(1,vec![2],Some("Rename".into()),1000.,stale()),Err(crate::database::LibraryDatabaseError::Invalid{message}) if message.contains("retry"))
        );
        for (t, old) in tables.iter().zip(before) {
            assert_eq!(
                old,
                db.read(|c| query_rows(c, &format!("SELECT * FROM {t} ORDER BY 1,2"), []))
                    .unwrap()
            );
        }
        // A failed image decode may produce nil; matching current source bytes still permits it.
        db.merge_artists(
            "Winner".into(),
            vec!["Loser".into()],
            None,
            1000.,
            vec![MergeThumbnail {
                entity_id: 2,
                artwork: vec![1, 2],
                thumbnail: None,
            }],
        )
        .unwrap();
    }
}
