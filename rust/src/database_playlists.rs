use crate::database::{DatabaseRows, DbResult, LibraryDatabase, query_rows, timestamp};
use crate::database_reads::{DatabaseTrackRows, decorate_tracks};
use rusqlite::{Connection, params};
use std::collections::{HashMap, HashSet};
#[derive(uniffi::Record)]
pub struct PlaylistWrite {
    pub id: String,
    pub name: String,
    pub kind: String,
    pub user_editable: bool,
    pub content_editable: bool,
    pub created: f64,
    pub modified: f64,
    pub artwork: Option<Vec<u8>>,
    pub sort_order: i64,
    pub criteria: Option<String>,
    pub track_ids: Vec<Option<i64>>,
    pub now: f64,
}
fn replace_tracks(
    c: &Connection,
    id: &str,
    ids: &[Option<i64>],
    now: f64,
    retain_dates: bool,
) -> DbResult<()> {
    let mut old = HashMap::<i64, String>::new();
    if retain_dates {
        let mut s =
            c.prepare("SELECT track_id,date_added FROM playlist_tracks WHERE playlist_id=?")?;
        for r in s.query_map([id], |r| Ok((r.get(0)?, r.get(1)?)))? {
            let (k, v) = r?;
            old.insert(k, v);
        }
    }
    c.execute("DELETE FROM playlist_tracks WHERE playlist_id=?", [id])?;
    let mut seen = HashSet::new();
    for (pos, id_track) in ids.iter().enumerate() {
        if let Some(t) = id_track {
            if seen.insert(*t) {
                let date = match old.get(t) {
                    Some(d) => d.clone(),
                    None => timestamp(now + pos as f64)?,
                };
                c.execute("INSERT INTO playlist_tracks(playlist_id,track_id,position,date_added) VALUES(?,?,?,?)",params![id,t,pos as i64,date])?;
            }
        }
    }
    Ok(())
}
#[uniffi::export]
impl LibraryDatabase {
    pub fn playlist_smart_counts(
        &self,
        criteria: Vec<crate::database_smart::DatabaseSmartCriteria>,
        hide_duplicates: bool,
    ) -> DbResult<Vec<i64>> {
        self.read(|c| {
            criteria
                .into_iter()
                .map(|p| crate::database_smart::smart_count(c, p, hide_duplicates, true))
                .collect()
        })
    }
    pub fn save_playlist(&self, p: PlaylistWrite) -> DbResult<()> {
        let created = timestamp(p.created)?;
        let modified = timestamp(p.modified)?;
        self.write(|tx|{tx.execute("INSERT INTO playlists(id,name,type,is_user_editable,is_content_editable,date_created,date_modified,cover_artwork_data,sort_order,smart_criteria) VALUES(?,?,?,?,?,?,?,?,?,?) ON CONFLICT(id) DO UPDATE SET name=excluded.name,type=excluded.type,is_user_editable=excluded.is_user_editable,is_content_editable=excluded.is_content_editable,date_created=excluded.date_created,date_modified=excluded.date_modified,cover_artwork_data=excluded.cover_artwork_data,sort_order=excluded.sort_order,smart_criteria=COALESCE(excluded.smart_criteria,playlists.smart_criteria)",params![p.id,p.name,p.kind,p.user_editable,p.content_editable,created,modified,p.artwork,p.sort_order,p.criteria])?;
 replace_tracks(tx,&p.id,if p.kind=="regular" {&p.track_ids}else{&[]},p.now,true)})
    }
    pub fn save_smart_playlist_snapshot(
        &self,
        id: String,
        track_ids: Vec<Option<i64>>,
        now: f64,
    ) -> DbResult<()> {
        self.write(|tx| replace_tracks(tx, &id, &track_ids, now, false))
    }
    pub fn update_playlist_metadata(
        &self,
        id: String,
        name: String,
        modified: f64,
    ) -> DbResult<()> {
        let d = timestamp(modified)?;
        self.write(|tx| {
            let changed = tx.execute(
                "UPDATE playlists SET name=?,date_modified=? WHERE id=?",
                params![name, d, id],
            )?;
            if changed == 0 {
                return Err(crate::database::invalid(format!(
                    "Missing persisted playlist {id}"
                )));
            }
            Ok(())
        })
    }
    pub fn update_playlists_order(&self, ids: Vec<String>) -> DbResult<()> {
        self.write(|tx| {
            for (i, id) in ids.iter().enumerate() {
                let changed = tx.execute(
                    "UPDATE playlists SET sort_order=? WHERE id=?",
                    params![i as i64, id],
                )?;
                if changed == 0 {
                    return Err(crate::database::invalid(format!(
                        "Missing persisted playlist {id}"
                    )));
                }
            }
            Ok(())
        })
    }
    pub fn all_playlists(&self) -> DbResult<DatabaseRows> {
        self.read(|c|query_rows(c,"SELECT p.*,(SELECT COUNT(*) FROM playlist_tracks pt WHERE pt.playlist_id=p.id) AS __track_count FROM playlists p ORDER BY sort_order",[]))
    }
    pub fn playlist_track_ids(&self, id: String) -> DbResult<Vec<i64>> {
        self.read(|c| {
            let mut s = c.prepare("SELECT track_id FROM playlist_tracks WHERE playlist_id=?")?;
            Ok(s.query_map([id], |r| r.get(0))?
                .collect::<Result<Vec<_>, _>>()?)
        })
    }
    pub fn append_playlist_tracks(
        &self,
        id: String,
        ids: Vec<Option<i64>>,
        now: f64,
    ) -> DbResult<i64> {
        self.write(|tx|{
 let mut s=tx.prepare("SELECT track_id FROM playlist_tracks WHERE playlist_id=?")?;let mut seen=s.query_map([&id],|r|r.get::<_,i64>(0))?.collect::<Result<HashSet<_>,_>>()?;
 let max:i64=tx.query_row("SELECT COALESCE(MAX(position),-1) FROM playlist_tracks WHERE playlist_id=?",[&id],|r|r.get(0))?;let mut n=0;
 for t in ids.into_iter().flatten(){if seen.insert(t){tx.execute("INSERT INTO playlist_tracks(playlist_id,track_id,position,date_added) VALUES(?,?,?,?)",params![id,t,max+1+n,timestamp(now+n as f64)?])?;n+=1;}}
 if n>0{tx.execute("UPDATE playlists SET date_modified=? WHERE id=?",params![timestamp(now)?,id])?;}Ok(n)})
    }
    pub fn add_playlist_track(&self, id: String, track_id: i64, now: f64) -> DbResult<()> {
        self.write(|tx|{tx.execute("INSERT INTO playlist_tracks(playlist_id,track_id,position,date_added) SELECT ?,?,COALESCE(MAX(position),-1)+1,? FROM playlist_tracks WHERE playlist_id=?",params![id,track_id,timestamp(now)?,id])?;Ok(())})
    }
    pub fn remove_playlist_tracks(&self, id: String, ids: Vec<i64>, now: f64) -> DbResult<()> {
        if ids.is_empty() {
            return Ok(());
        }
        self.write(|tx|{for t in ids {tx.execute("DELETE FROM playlist_tracks WHERE playlist_id=? AND track_id=?",params![id,t])?;}
 let mut s=tx.prepare("SELECT track_id,position FROM playlist_tracks WHERE playlist_id=? ORDER BY position")?;let rows=s.query_map([&id],|r|Ok((r.get::<_,i64>(0)?,r.get::<_,i64>(1)?)))?.collect::<Result<Vec<_>,_>>()?;
 for (i,(t,pos)) in rows.iter().enumerate(){if *pos!=i as i64{tx.execute("UPDATE playlist_tracks SET position=? WHERE playlist_id=? AND track_id=?",params![i as i64,id,t])?;}}
 tx.execute("UPDATE playlists SET date_modified=? WHERE id=?",params![timestamp(now)?,id])?;Ok(())})
    }
    pub fn set_playlist_track_order(&self, id: String, ids: Vec<i64>, now: f64) -> DbResult<()> {
        self.write(|tx|{for (i,t) in ids.iter().enumerate(){tx.execute("UPDATE playlist_tracks SET position=? WHERE playlist_id=? AND track_id=? AND position!=?",params![i as i64,id,t,i as i64])?;}tx.execute("UPDATE playlists SET date_modified=? WHERE id=?",params![timestamp(now)?,id])?;Ok(())})
    }
    pub fn delete_playlist(&self, id: String) -> DbResult<()> {
        self.write(|tx| {
            tx.execute("DELETE FROM playlists WHERE id=?", [id])?;
            Ok(())
        })
    }
    pub fn playlist_tracks(&self, id: String, artwork: bool) -> DbResult<DatabaseTrackRows> {
        self.read(|c| {
            let rows=query_rows(c,&format!("SELECT {},pt.date_added AS playlist_date_added FROM playlist_tracks pt JOIN tracks t ON t.id=pt.track_id WHERE pt.playlist_id=? AND (t.duplicate_group_id IS NULL OR NOT EXISTS(SELECT 1 FROM playlist_tracks earlier JOIN tracks et ON et.id=earlier.track_id WHERE earlier.playlist_id=pt.playlist_id AND et.duplicate_group_id=t.duplicate_group_id AND (earlier.position<pt.position OR (earlier.position=pt.position AND earlier.track_id<pt.track_id)))) ORDER BY pt.position,pt.track_id",crate::database_reads::track_projection(false)),[id])?;
            decorate_tracks(c,rows,artwork)
        })
    }
    pub fn playlist_preview(&self, id: String, limit: i64) -> DbResult<DatabaseTrackRows> {
        self.read(|c| {
            let rows=query_rows(c,&format!("SELECT {} FROM playlist_tracks pt JOIN tracks t ON t.id=pt.track_id WHERE pt.playlist_id=? ORDER BY pt.position LIMIT ?",crate::database_reads::track_projection(false)),params![id,limit])?;
            decorate_tracks(c,rows,false)
        })
    }
}
#[cfg(test)]
mod tests {
    use super::*;
    use crate::database_mutations::tests::fixture;
    #[test]
    fn playlist_order_dates_raw_metadata_and_failed_replace_rollback() {
        let db = fixture("playlist");
        db.write(|c|{c.execute("INSERT INTO playlists(id,name,type,is_user_editable,is_content_editable,date_created,date_modified,sort_order,smart_criteria) VALUES('P','Original','regular',1,1,'2026-01-01','2026-01-01',0,'unknown raw')",[])?;Ok(())}).unwrap();
        assert_eq!(
            db.append_playlist_tracks("P".into(), vec![Some(2), Some(1), Some(2), None], 1000.)
                .unwrap(),
            2
        );
        db.save_playlist(PlaylistWrite {
            id: "P".into(),
            name: "Original".into(),
            kind: "regular".into(),
            user_editable: true,
            content_editable: true,
            created: 1000.,
            modified: 1000.,
            artwork: None,
            sort_order: 0,
            criteria: None,
            track_ids: vec![Some(2), Some(1), Some(2), None],
            now: 2000.,
        })
        .unwrap();
        let before = db
            .read(|c| query_rows(c, "SELECT * FROM playlist_tracks ORDER BY position", []))
            .unwrap();
        db.set_playlist_track_order("P".into(), vec![1, 2], 2000.)
            .unwrap();
        db.update_playlists_order(vec!["P".into()]).unwrap();
        db.read(|c| {
            assert_eq!(
                c.query_row(
                    "SELECT smart_criteria FROM playlists WHERE id='P'",
                    [],
                    |r| r.get::<_, String>(0)
                )?,
                "unknown raw"
            );
            assert_eq!(
                c.query_row(
                    "SELECT date_added FROM playlist_tracks WHERE track_id=2",
                    [],
                    |r| r.get::<_, String>(0)
                )?,
                timestamp(1000.)?
            );
            Ok(())
        })
        .unwrap();
        let stable = db
            .read(|c| query_rows(c, "SELECT * FROM playlist_tracks ORDER BY position", []))
            .unwrap();
        assert!(
            db.save_smart_playlist_snapshot("P".into(), vec![Some(1), Some(999999)], 3000.)
                .is_err()
        );
        assert_eq!(
            stable,
            db.read(|c| query_rows(c, "SELECT * FROM playlist_tracks ORDER BY position", []))
                .unwrap()
        );
        db.remove_playlist_tracks("P".into(), vec![1], 4000.)
            .unwrap();
        db.read(|c| {
            assert_eq!(
                c.query_row(
                    "SELECT position FROM playlist_tracks WHERE track_id=2",
                    [],
                    |r| r.get::<_, i64>(0)
                )?,
                0
            );
            Ok(())
        })
        .unwrap();
        assert_ne!(before, stable);
    }
}
#[cfg(test)]
mod regression_tests {
    use crate::database_mutations::tests::fixture;
    #[test]
    fn missing_playlist_model_errors_and_sort_batch_rolls_back() {
        let db = fixture("missing-playlist");
        db.write(|c|{c.execute("INSERT INTO playlists(id,name,type,is_user_editable,is_content_editable,date_created,date_modified,sort_order) VALUES('P','Original','regular',1,1,'2026-01-01','2026-01-01',7)",[])?;Ok(())}).unwrap();
        assert!(
            db.update_playlist_metadata("missing".into(), "name".into(), 1000.)
                .is_err()
        );
        assert!(
            db.update_playlists_order(vec!["P".into(), "missing".into()])
                .is_err()
        );
        db.read(|c| {
            assert_eq!(
                c.query_row("SELECT sort_order FROM playlists WHERE id='P'", [], |r| r
                    .get::<_, i64>(
                    0
                ))?,
                7
            );
            Ok(())
        })
        .unwrap();
    }
    #[test]
    fn tied_playlist_positions_keep_one_copy_of_duplicate_group() {
        let db = fixture("tied-position");
        db.write(|c|{c.execute_batch("INSERT INTO playlists(id,name,type,is_user_editable,is_content_editable,date_created,date_modified,sort_order) VALUES('P','Original','regular',1,1,'2026-01-01','2026-01-01',0); INSERT INTO playlist_tracks(playlist_id,track_id,position,date_added) VALUES('P',1,0,'2026-01-01'),('P',2,0,'2026-01-01'); UPDATE tracks SET duplicate_group_id='same' WHERE id IN (1,2);")?;Ok(())}).unwrap();
        let rows = db.playlist_tracks("P".into(), false).unwrap();
        assert_eq!(rows.tracks.len(), 1);
        assert_eq!(rows.tracks[0].id, 1);
        assert_eq!(db.playlist_track_ids("P".into()).unwrap().len(), 2);
    }
}
