use crate::database::{DatabaseRows, DbResult, LibraryDatabase, query_rows, timestamp};
use rusqlite::{Connection, OptionalExtension, params};

pub(crate) fn cleanup_orphaned_data(conn: &Connection) -> DbResult<()> {
    for sql in [
        "DELETE FROM track_artists WHERE track_id NOT IN (SELECT id FROM tracks)",
        "DELETE FROM track_genres WHERE track_id NOT IN (SELECT id FROM tracks)",
        "DELETE FROM album_artists WHERE album_id NOT IN (SELECT id FROM albums)",
        "DELETE FROM playlist_tracks WHERE track_id NOT IN (SELECT id FROM tracks)",
        "DELETE FROM artists WHERE artwork_data IS NULL AND artwork_thumbnail IS NULL AND image_url IS NULL AND image_source IS NULL AND image_updated_at IS NULL AND bio IS NULL AND bio_source IS NULL AND bio_updated_at IS NULL AND discogs_id IS NULL AND musicbrainz_id IS NULL AND spotify_id IS NULL AND apple_music_id IS NULL AND country IS NULL AND formed_year IS NULL AND disbanded_year IS NULL AND genres IS NULL AND websites IS NULL AND members IS NULL AND NOT EXISTS (SELECT 1 FROM artist_aliases WHERE canonical_artist_id=artists.id) AND id NOT IN (SELECT artist_id FROM track_artists UNION SELECT artist_id FROM album_artists)",
        "DELETE FROM albums WHERE artwork_data IS NULL AND artwork_thumbnail IS NULL AND release_date IS NULL AND release_year IS NULL AND album_type IS NULL AND total_discs IS NULL AND description IS NULL AND review IS NULL AND review_source IS NULL AND cover_art_url IS NULL AND thumbnail_url IS NULL AND discogs_id IS NULL AND musicbrainz_id IS NULL AND spotify_id IS NULL AND apple_music_id IS NULL AND label IS NULL AND catalog_number IS NULL AND barcode IS NULL AND genres IS NULL AND NOT EXISTS (SELECT 1 FROM album_aliases WHERE canonical_album_id=albums.id) AND id NOT IN (SELECT album_id FROM tracks WHERE album_id IS NOT NULL)",
        "DELETE FROM genres WHERE id NOT IN (SELECT genre_id FROM track_genres)",
    ] {
        conn.execute(sql, [])?;
    }
    if conn.query_row("SELECT EXISTS(SELECT 1 FROM sqlite_master WHERE type='table' AND name='extended_metadata')", [], |r| r.get::<_,bool>(0))? {
        conn.execute("DELETE FROM extended_metadata WHERE track_id NOT IN (SELECT id FROM tracks)", [])?;
    }
    Ok(())
}

#[derive(uniffi::Record)]
pub struct ArtistInfoPatch {
    pub artist_id: i64,
    pub image_data: Option<Vec<u8>>,
    pub thumbnail: Option<Vec<u8>>,
    pub image_url: Option<String>,
    pub image_source: Option<String>,
    pub bio: Option<String>,
    pub bio_source: Option<String>,
    pub now: f64,
}

#[uniffi::export]
impl LibraryDatabase {
    pub fn cleanup_orphaned_data(&self) -> DbResult<()> {
        self.write(|tx| cleanup_orphaned_data(tx))
    }
    pub fn update_track_favorite(&self, track_id: i64, favorite: bool, now: f64) -> DbResult<()> {
        let date = if favorite {
            Some(timestamp(now)?)
        } else {
            None
        };
        self.write(|tx| {
            tx.execute(
                "UPDATE tracks SET is_favorite=?,date_favorited=? WHERE id=?",
                params![favorite, date, track_id],
            )?;
            Ok(())
        })
    }
    pub fn update_track_playback(
        &self,
        track_id: i64,
        play_count: i64,
        last_played: f64,
    ) -> DbResult<()> {
        let date = timestamp(last_played)?;
        self.write(|tx| {
            tx.execute(
                "UPDATE tracks SET play_count=?,last_played_date=? WHERE id=?",
                params![play_count, date, track_id],
            )?;
            Ok(())
        })
    }
    pub fn update_track_lyrics(&self, track_id: i64, lyrics: String) -> DbResult<()> {
        self.write(|tx| {
            let raw:Option<Option<String>>=tx.query_row("SELECT extended_metadata FROM tracks WHERE id=?",[track_id],|r|r.get(0)).optional()?;
            if raw.is_none() { return Err(crate::database::invalid(format!("Missing persisted track #{track_id}"))); }
            if let Some(raw)=raw {
                // SQLite patches the stored object, retaining fields unknown to Swift models.
                let valid:bool=tx.query_row("SELECT CASE WHEN json_valid(?) THEN json_type(?)='object' ELSE 0 END",params![raw,raw],|r|r.get(0))?;
                if raw.is_some() && !valid {
                    return Err(rusqlite::Error::InvalidParameterName("extended_metadata must be a JSON object; original retained".into()).into());
                }
                tx.execute("UPDATE tracks SET extended_metadata=json_set(COALESCE(extended_metadata,'{}'),'$.lyrics',?) WHERE id=?",params![lyrics,track_id])?;
            }
            Ok(())
        })
    }
    pub fn update_artist_info(&self, p: ArtistInfoPatch) -> DbResult<()> {
        let now = timestamp(p.now)?;
        self.write(|tx| {
            if p.image_data.is_none() && p.image_url.is_none() && p.image_source.is_none() && p.bio.is_none() && p.bio_source.is_none() { return Ok(()); }
            tx.execute("UPDATE artists SET artwork_data=CASE WHEN ? THEN ? ELSE artwork_data END, artwork_thumbnail=CASE WHEN ? THEN ? ELSE artwork_thumbnail END, image_url=COALESCE(?,image_url),image_source=COALESCE(?,image_source),image_updated_at=CASE WHEN ? THEN ? ELSE image_updated_at END,bio=COALESCE(?,bio),bio_source=COALESCE(?,bio_source),bio_updated_at=CASE WHEN ? THEN ? ELSE bio_updated_at END,updated_at=? WHERE id=?",params![p.image_data.is_some(),p.image_data,p.image_data.is_some(),p.thumbnail,p.image_url,p.image_source,p.image_source.is_some(),now,p.bio,p.bio_source,p.bio_source.is_some(),now,now,p.artist_id])?;
            Ok(())
        })
    }
    pub fn delete_artist_image(&self, artist_id: i64, now: f64) -> DbResult<()> {
        let now = timestamp(now)?;
        self.write(|tx|{tx.execute("UPDATE artists SET artwork_data=NULL,artwork_thumbnail=NULL,image_url=NULL,image_source='deleted',image_updated_at=?,updated_at=? WHERE id=?",params![now,now,artist_id])?;Ok(())})
    }
    pub fn mark_artist_fetch_failed(&self, artist_id: i64, image: bool, now: f64) -> DbResult<()> {
        let now = timestamp(now)?;
        self.write(|tx| {
            tx.execute(
                if image {
                    "UPDATE artists SET image_updated_at=?,updated_at=? WHERE id=?"
                } else {
                    "UPDATE artists SET bio_updated_at=?,updated_at=? WHERE id=?"
                },
                params![now, now, artist_id],
            )?;
            Ok(())
        })
    }
    pub fn artists_needing_image_or_bio(&self, cutoff: f64) -> DbResult<DatabaseRows> {
        let cutoff = timestamp(cutoff)?;
        self.read(|c|query_rows(c,"SELECT DISTINCT a.id,a.name,a.image_source,a.bio FROM artists a JOIN track_artists ta ON ta.artist_id=a.id WHERE (a.image_source IS NULL AND (a.image_updated_at IS NULL OR a.image_updated_at<?)) OR (a.bio IS NULL AND (a.bio_updated_at IS NULL OR a.bio_updated_at<?)) ORDER BY a.total_tracks DESC",params![cutoff,cutoff]))
    }
}

#[cfg(test)]
pub(crate) mod tests {
    use super::*;
    use std::sync::Arc;
    pub(crate) fn fixture(label: &str) -> Arc<LibraryDatabase> {
        let path = std::env::temp_dir().join(format!(
            "petrichor-mutation-{label}-{}-{}.sqlite",
            std::process::id(),
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        let db = LibraryDatabase::open(path.to_string_lossy().into_owned()).unwrap();
        db.write(|c| {c.execute_batch("INSERT INTO folders(id,path,name,date_added,date_updated) VALUES(1,'/fixture','fixture','2026-01-01','2026-01-01'); INSERT INTO tracks(id,folder_id,path,filename,title,artist,album,date_added,extended_metadata) VALUES(1,1,'/fixture/1.mp3','1.mp3','One','Raw artist','Raw album','2026-01-01','{\"future\":{\"huge\":9223372036854775807},\"lyrics\":\"old\"}'),(2,1,'/fixture/2.mp3','2.mp3','Two','Raw artist','Raw album','2026-01-01',NULL); INSERT INTO artists(id,name,normalized_name,created_at,updated_at) VALUES(1,'Winner','winner','2026-01-01','2026-01-01'),(2,'Loser','loser','2026-01-01','2026-01-01'); INSERT INTO albums(id,title,normalized_title,created_at,updated_at) VALUES(1,'Winner album','winner album','2026-01-01','2026-01-01'),(2,'Loser album','loser album','2026-01-01','2026-01-01'); INSERT INTO track_artists(track_id,artist_id,role,position) VALUES(1,1,'artist',0),(1,2,'artist',1),(2,2,'composer',0); INSERT INTO album_artists(album_id,artist_id,role,position) VALUES(1,1,'primary',0),(2,2,'primary',0); UPDATE tracks SET album_id=id;")?;Ok(())}).unwrap();
        db
    }
    #[test]
    fn lyrics_patch_preserves_concurrent_state_unknown_json_and_art() {
        let db = fixture("lyrics");
        db.write(|c| {
            c.execute(
                "UPDATE tracks SET track_artwork_data=x'010203' WHERE id=1",
                [],
            )?;
            Ok(())
        })
        .unwrap();
        db.update_track_favorite(1, true, 1000.).unwrap();
        db.update_track_playback(1, 77, 2000.).unwrap();
        db.update_track_lyrics(1, "new lyrics".into()).unwrap();
        db.read(|c|{let row:(bool,i64,String,String,Vec<u8>)=c.query_row("SELECT is_favorite,play_count,json_extract(extended_metadata,'$.lyrics'),CAST(json_extract(extended_metadata,'$.future.huge') AS TEXT),track_artwork_data FROM tracks WHERE id=1",[],|r|Ok((r.get(0)?,r.get(1)?,r.get(2)?,r.get(3)?,r.get(4)?)))?;assert_eq!(row,(true,77,"new lyrics".into(),"9223372036854775807".into(),vec![1,2,3]));Ok(())}).unwrap();
        db.write(|c| {
            c.execute(
                "UPDATE tracks SET extended_metadata='malformed' WHERE id=1",
                [],
            )?;
            Ok(())
        })
        .unwrap();
        assert!(db.update_track_lyrics(1, "do not erase".into()).is_err());
        db.read(|c| {
            assert_eq!(
                c.query_row("SELECT extended_metadata FROM tracks WHERE id=1", [], |r| r
                    .get::<_, String>(0))?,
                "malformed"
            );
            Ok(())
        })
        .unwrap();
    }
    #[test]
    fn artist_patch_retry_sentinel_and_cleanup_preserve_db_only_assets() {
        let db = fixture("artist");
        db.update_artist_info(ArtistInfoPatch {
            artist_id: 2,
            image_data: Some(vec![9, 8, 7]),
            thumbnail: Some(vec![6]),
            image_url: Some("url".into()),
            image_source: Some("source".into()),
            bio: Some("bio".into()),
            bio_source: Some("source".into()),
            now: 1000.,
        })
        .unwrap();
        db.delete_artist_image(2, 2000.).unwrap();
        db.read(|c| {
            assert_eq!(
                c.query_row("SELECT image_source FROM artists WHERE id=2", [], |r| {
                    r.get::<_, String>(0)
                })?,
                "deleted"
            );
            assert_eq!(
                c.query_row("SELECT bio FROM artists WHERE id=2", [], |r| r
                    .get::<_, String>(0))?,
                "bio"
            );
            Ok(())
        })
        .unwrap();
        db.write(|c|{c.execute_batch("INSERT INTO artists(id,name,normalized_name,bio,created_at,updated_at) VALUES(3,'Protected','protected','DB only bio','2026-01-01','2026-01-01'),(4,'Orphan','orphan',NULL,'2026-01-01','2026-01-01'); INSERT INTO albums(id,title,normalized_title,artwork_data,created_at,updated_at) VALUES(3,'Protected','protected',x'0102','2026-01-01','2026-01-01'),(4,'Orphan','orphan',NULL,'2026-01-01','2026-01-01');")?;Ok(())}).unwrap();
        db.cleanup_orphaned_data().unwrap();
        db.read(|c| {
            for table in ["artists", "albums"] {
                assert_eq!(
                    c.query_row(
                        &format!("SELECT COUNT(*) FROM {table} WHERE id=3"),
                        [],
                        |r| r.get::<_, i64>(0)
                    )?,
                    1
                );
                assert_eq!(
                    c.query_row(
                        &format!("SELECT COUNT(*) FROM {table} WHERE id=4"),
                        [],
                        |r| r.get::<_, i64>(0)
                    )?,
                    0
                );
            }
            Ok(())
        })
        .unwrap();
    }
}
#[cfg(test)]
mod evaluations {
    use super::*;
    #[test]
    fn copied_fixture_before_after_reference_eval() {
        let source = super::tests::fixture("eval");
        let root = std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
            .parent()
            .unwrap()
            .join(".scratch/rust-library-database/evals/mutations");
        std::fs::create_dir_all(&root).unwrap();
        let stamp = format!(
            "{}",
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        );
        let baseline_path = root.join(format!("baseline-{stamp}.sqlite"));
        let candidate_path = root.join(format!("candidate-{stamp}.sqlite"));
        for path in [&baseline_path, &candidate_path] {
            source
                .exclusive(|c| {
                    c.execute("VACUUM INTO ?", [path.to_string_lossy().as_ref()])?;
                    Ok(())
                })
                .unwrap();
        }
        let baseline = LibraryDatabase::open(baseline_path.to_string_lossy().into_owned()).unwrap();
        let candidate =
            LibraryDatabase::open(candidate_path.to_string_lossy().into_owned()).unwrap();
        let before = candidate
            .read(|c| query_rows(c, "SELECT * FROM tracks ORDER BY id", []))
            .unwrap();
        baseline.write(|c|{c.execute("UPDATE tracks SET is_favorite=1,date_favorited=? WHERE id=1",[timestamp(1000.)?])?;c.execute("UPDATE tracks SET play_count=77,last_played_date=? WHERE id=1",[timestamp(2000.)?])?;c.execute("UPDATE tracks SET extended_metadata=json_set(extended_metadata,'$.lyrics','new lyrics') WHERE id=1",[])?;Ok(())}).unwrap();
        candidate.update_track_favorite(1, true, 1000.).unwrap();
        candidate.update_track_playback(1, 77, 2000.).unwrap();
        candidate
            .update_track_lyrics(1, "new lyrics".into())
            .unwrap();
        let expected = baseline
            .read(|c| query_rows(c, "SELECT * FROM tracks ORDER BY id", []))
            .unwrap();
        let after = candidate
            .read(|c| query_rows(c, "SELECT * FROM tracks ORDER BY id", []))
            .unwrap();
        assert_eq!(expected, after);
        for db in [&baseline, &candidate] {
            db.read(|c| {
                assert_eq!(
                    c.query_row("PRAGMA integrity_check", [], |r| r.get::<_, String>(0))?,
                    "ok"
                );
                assert!(
                    query_rows(c, "PRAGMA foreign_key_check", [])?
                        .rows
                        .is_empty()
                );
                Ok(())
            })
            .unwrap();
            db.checkpoint().unwrap();
        }
        std::fs::write(root.join("before-after-reference.txt"),format!("Reference: exact targeted SQL matching original favorite/playback; intentional JSON lyrics patch.\nNot an original Swift facade execution.\nBefore: {before:#?}\nExpected: {expected:#?}\nAfter: {after:#?}\nExact row equality PASS; integrity_check ok; foreign_key_check empty.\n")).unwrap();
    }
}
#[cfg(test)]
mod regression_tests {
    use super::*;
    #[test]
    fn missing_lyrics_track_returns_error() {
        let db = super::tests::fixture("missing-track");
        assert!(db.update_track_lyrics(999, "lyrics".into()).is_err());
        db.update_track_favorite(999, true, 1000.).unwrap();
        db.update_track_playback(999, 1, 1000.).unwrap();
    }
    #[test]
    fn cleanup_keeps_metadata_only_orphan_album_and_its_alias() {
        let db = super::tests::fixture("metadata-album");
        db.write(|c|{c.execute_batch("INSERT INTO albums(id,title,normalized_title,description,review,review_source,catalog_number,created_at,updated_at) VALUES(3,'Protected','protected','User notes','Review','User','CAT-3','2026-01-01','2026-01-01'); INSERT INTO album_aliases(normalized_key,display_title,canonical_album_id,created_at) VALUES('protected|','Protected',3,'2026-01-01');")?;Ok(())}).unwrap();
        let before = db
            .read(|c| query_rows(c, "SELECT * FROM albums WHERE id=3", []))
            .unwrap();
        db.cleanup_orphaned_data().unwrap();
        assert_eq!(
            before,
            db.read(|c| query_rows(c, "SELECT * FROM albums WHERE id=3", []))
                .unwrap()
        );
        db.read(|c|{assert_eq!(c.query_row("SELECT canonical_album_id FROM album_aliases WHERE normalized_key='protected|'",[],|r|r.get::<_,i64>(0))?,3);Ok(())}).unwrap();
    }
}
