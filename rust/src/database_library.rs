//! File observations are decoded on Apple platforms; persistence decisions are transactional.
use crate::database::{DbResult, LibraryDatabase, invalid, timestamp};
use crate::database_normalization::*;
use rusqlite::{Connection, OptionalExtension, params};
use std::collections::HashMap;
use unicode_normalization::UnicodeNormalization;
fn duplicate_text(value: &str) -> String {
    let lower: String = value.chars().flat_map(char::to_lowercase).collect();
    lower
        .trim_matches(|c: char| c.is_whitespace() || c == '\u{200b}')
        .nfc()
        .collect()
}
#[derive(Clone, Default, uniffi::Record)]
pub struct TrackImport {
    pub path: String,
    pub filename: String,
    pub basename: String,
    pub format: String,
    pub folder_id: i64,
    pub modified: Option<f64>,
    pub size: Option<i64>,
    pub duration: f64,
    pub compilation: bool,
    pub lossless: Option<bool>,
    pub artwork: Option<Vec<u8>>,
    pub thumbnail: Option<Vec<u8>>,
    pub extended_json: Option<String>,
    pub title: Option<String>,
    pub artist: Option<String>,
    pub album: Option<String>,
    pub composer: Option<String>,
    pub genre: Option<String>,
    pub year: Option<String>,
    pub album_artist: Option<String>,
    pub release_date: Option<String>,
    pub original_release_date: Option<String>,
    pub media_type: Option<String>,
    pub codec: Option<String>,
    pub sort_title: Option<String>,
    pub sort_artist: Option<String>,
    pub sort_album: Option<String>,
    pub sort_album_artist: Option<String>,
    pub track_number: Option<i64>,
    pub total_tracks: Option<i64>,
    pub disc_number: Option<i64>,
    pub total_discs: Option<i64>,
    pub rating: Option<i64>,
    pub bpm: Option<i64>,
    pub bitrate: Option<i64>,
    pub sample_rate: Option<i64>,
    pub channels: Option<i64>,
    pub bit_depth: Option<i64>,
}
#[derive(uniffi::Record)]
pub struct TrackIngestResult {
    pub added: u64,
    pub updated: u64,
    pub skipped: u64,
    pub failed_paths: Vec<String>,
    pub errors: Vec<String>,
}
pub(crate) fn stored_seconds(value: rusqlite::types::Value) -> Option<f64> {
    match value {
        rusqlite::types::Value::Integer(v) => Some(v as f64),
        rusqlite::types::Value::Real(v) => Some(v),
        rusqlite::types::Value::Text(v) => {
            chrono::NaiveDateTime::parse_from_str(&v, "%Y-%m-%d %H:%M:%S%.f")
                .ok()
                .map(|d| d.and_utc().timestamp_millis() as f64 / 1000.0)
                .or_else(|| {
                    chrono::NaiveDate::parse_from_str(&v, "%Y-%m-%d")
                        .ok()
                        .and_then(|d| d.and_hms_opt(0, 0, 0))
                        .map(|d| d.and_utc().timestamp() as f64)
                })
        }
        _ => None,
    }
}
fn sanitized_duration(value: f64) -> f64 {
    if value.is_finite() && value >= 0.0 {
        value
    } else {
        0.0
    }
}
pub(crate) fn track_needs_ingest(
    conn: &Connection,
    path: &str,
    modified: Option<f64>,
    hard: bool,
) -> DbResult<bool> {
    let state: Option<Option<f64>> = conn
        .query_row(
            "SELECT date_modified FROM tracks WHERE path=? ORDER BY id LIMIT 1",
            [path],
            |r| Ok(stored_seconds(r.get(0)?)),
        )
        .optional()?;
    Ok(match state {
        None => true,
        Some(old) => hard || old.zip(modified).is_some_and(|(a, b)| (a - b).abs() > 1.0),
    })
}
fn ingest(
    conn: &Connection,
    input: &TrackImport,
    domain: &crate::artists::ArtistDomain,
    hard: bool,
    now: &str,
) -> DbResult<i32> {
    if !track_needs_ingest(conn, &input.path, input.modified, hard)? {
        return Ok(0);
    }
    let existing = conn
        .query_row(
            "SELECT id FROM tracks WHERE path=? ORDER BY id LIMIT 1",
            [&input.path],
            |r| r.get::<_, i64>(0),
        )
        .optional()?;
    let fallback = crate::filename::filename_metadata_fallback(&input.basename);
    let nonempty = |value: &Option<String>| value.as_ref().filter(|s| !s.is_empty()).cloned();
    let initial = |value: &Option<String>| {
        value
            .as_ref()
            .filter(|s| {
                !s.trim_matches(|c: char| c.is_whitespace() || c == '\u{200b}')
                    .is_empty()
            })
            .cloned()
    };
    let mut columns: Vec<&str> = Vec::new();
    let mut values: Vec<rusqlite::types::Value> = Vec::new();
    let mut put = |column: &'static str, value: rusqlite::types::Value| {
        columns.push(column);
        values.push(value);
    };
    if existing.is_none() {
        for (key, value) in [
            ("title", initial(&input.title).unwrap_or(fallback.title)),
            (
                "artist",
                initial(&input.artist)
                    .or(fallback.artist)
                    .unwrap_or("Unknown Artist".into()),
            ),
            (
                "album",
                initial(&input.album).unwrap_or("Unknown Album".into()),
            ),
            (
                "genre",
                initial(&input.genre).unwrap_or("Unknown Genre".into()),
            ),
            (
                "composer",
                initial(&input.composer).unwrap_or("Unknown Composer".into()),
            ),
            ("year", initial(&input.year).unwrap_or_default()),
        ] {
            put(key, value.into());
        }
        put("path", input.path.clone().into());
        put("filename", input.filename.clone().into());
        put("format", input.format.clone().into());
        put("folder_id", input.folder_id.into());
        put("date_added", now.to_owned().into());
        put("duration", sanitized_duration(input.duration).into());
    }
    if existing.is_some() {
        if let Some(value) = nonempty(&input.title) {
            put("title", value.into());
        }
    }
    if existing.is_some() {
        if let Some(value) = nonempty(&input.artist) {
            put("artist", value.into());
        }
    }
    if existing.is_some() {
        if let Some(value) = nonempty(&input.album) {
            put("album", value.into());
        }
    }
    if existing.is_some() {
        if let Some(value) = nonempty(&input.composer) {
            put("composer", value.into());
        }
    }
    if existing.is_some() {
        if let Some(value) = nonempty(&input.genre) {
            put("genre", value.into());
        }
    }
    if existing.is_some() {
        if let Some(value) = nonempty(&input.year) {
            put("year", value.into());
        }
    }
    if let Some(value) = if existing.is_none() {
        input.album_artist.clone()
    } else {
        nonempty(&input.album_artist)
    } {
        put("album_artist", value.into());
    }
    if let Some(value) = if existing.is_none() {
        input.release_date.clone()
    } else {
        nonempty(&input.release_date)
    } {
        put("release_date", value.into());
    }
    if let Some(value) = if existing.is_none() {
        input.original_release_date.clone()
    } else {
        nonempty(&input.original_release_date)
    } {
        put("original_release_date", value.into());
    }
    if let Some(value) = if existing.is_none() {
        input.media_type.clone()
    } else {
        nonempty(&input.media_type)
    } {
        put("media_type", value.into());
    }
    if let Some(value) = if existing.is_none() {
        input.codec.clone()
    } else {
        nonempty(&input.codec)
    } {
        put("codec", value.into());
    }
    if let Some(value) = if existing.is_none() {
        input.sort_title.clone()
    } else {
        nonempty(&input.sort_title)
    } {
        put("sort_title", value.into());
    }
    if let Some(value) = if existing.is_none() {
        input.sort_artist.clone()
    } else {
        nonempty(&input.sort_artist)
    } {
        put("sort_artist", value.into());
    }
    if let Some(value) = if existing.is_none() {
        input.sort_album.clone()
    } else {
        nonempty(&input.sort_album)
    } {
        put("sort_album", value.into());
    }
    if let Some(value) = if existing.is_none() {
        input.sort_album_artist.clone()
    } else {
        nonempty(&input.sort_album_artist)
    } {
        put("sort_album_artist", value.into());
    }
    if let Some(value) = input.track_number {
        put("track_number", value.into());
    }
    if let Some(value) = input.total_tracks {
        put("total_tracks", value.into());
    }
    if let Some(value) = input.disc_number {
        put("disc_number", value.into());
    }
    if let Some(value) = input.total_discs {
        put("total_discs", value.into());
    }
    if let Some(value) = input.rating {
        put("rating", value.into());
    }
    if let Some(value) = input.bpm {
        put("bpm", value.into());
    }
    if let Some(value) = input.bitrate {
        put("bitrate", value.into());
    }
    if let Some(value) = input.sample_rate {
        put("sample_rate", value.into());
    }
    if let Some(value) = input.channels {
        put("channels", value.into());
    }
    if let Some(value) = input.bit_depth {
        put("bit_depth", value.into());
    }
    if let Some(value) = input.modified {
        put("date_modified", timestamp(value)?.into());
    }
    if let Some(value) = input.size {
        put("file_size", value.into());
    }
    if let Some(value) = input.lossless {
        put("lossless", (value as i64).into());
    }
    put("compilation", (input.compilation as i64).into());
    if let Some(id) = existing {
        let old: f64 = conn.query_row(
            "SELECT COALESCE(duration,0) FROM tracks WHERE id=?",
            [id],
            |r| r.get(0),
        )?;
        let duration = sanitized_duration(input.duration);
        if duration > 0.0 && (old - duration).abs() > 0.1 {
            put("duration", duration.into());
        }
    }
    // Preserve database-only/unknown JSON fields and user lyrics when fresh file tags omit them.
    if let Some(json) = &input.extended_json {
        let mut fresh: serde_json::Value = serde_json::from_str(json)
            .map_err(|e| invalid(format!("Invalid metadata JSON: {e}")))?;
        if !fresh.is_object() {
            return Err(invalid("Extended metadata must be an object"));
        }
        if let Some(id) = existing {
            let old: Option<String> = conn.query_row(
                "SELECT extended_metadata FROM tracks WHERE id=?",
                [id],
                |r| r.get(0),
            )?;
            if let Some(old) = old {
                if let Ok(mut previous) = serde_json::from_str::<serde_json::Value>(&old) {
                    if let (Some(previous), Some(fresh_fields)) =
                        (previous.as_object_mut(), fresh.as_object())
                    {
                        for (key, value) in fresh_fields {
                            if !value.is_null() && !(key == "lyrics" && value.as_str() == Some(""))
                            {
                                previous.insert(key.clone(), value.clone());
                            }
                        }
                        fresh = previous.clone().into();
                    }
                } else {
                    return Err(invalid(
                        "Existing extended metadata is invalid JSON; preserved without overwrite",
                    ));
                }
            }
        }
        put("extended_metadata", fresh.to_string().into());
    }
    let is_new = existing.is_none();
    let id = if let Some(id) = existing {
        let sql = format!(
            "UPDATE tracks SET {} WHERE id=?",
            columns
                .iter()
                .map(|s| format!("{s}=?"))
                .collect::<Vec<_>>()
                .join(",")
        );
        values.push(id.into());
        conn.execute(&sql, rusqlite::params_from_iter(values))?;
        id
    } else {
        let sql = format!(
            "INSERT INTO tracks({}) VALUES({})",
            columns.join(","),
            vec!["?"; columns.len()].join(",")
        );
        conn.execute(&sql, rusqlite::params_from_iter(values))?;
        conn.last_insert_rowid()
    };
    rebuild_track_associations_with_domain(conn, domain, id, now)?;
    rebuild_track_genres(conn, id)?;
    if let Some(art) = input.artwork.as_ref().filter(|s| !s.is_empty()) {
        let (album_id, album): (Option<i64>, String) = conn.query_row(
            "SELECT album_id,COALESCE(album,'Unknown Album') FROM tracks WHERE id=?",
            [id],
            |r| Ok((r.get(0)?, r.get(1)?)),
        )?;
        if album.is_empty() || album == "Unknown Album" {
            conn.execute(
                "UPDATE tracks SET track_artwork_data=? WHERE id=?",
                params![art, id],
            )?;
        }
        // Keep repaired per-track art on known albums: metadata refresh is not an art deletion.
        conn.execute("UPDATE artists SET artwork_data=?,artwork_thumbnail=?,updated_at=? WHERE artwork_data IS NULL AND id IN(SELECT artist_id FROM track_artists WHERE track_id=?)",params![art,input.thumbnail,now,id])?;
        if let Some(album) = album_id {
            conn.execute("UPDATE albums SET artwork_data=?,artwork_thumbnail=?,updated_at=? WHERE id=? AND (artwork_data IS NULL OR (? AND artwork_data!=?))",params![art,input.thumbnail,now,album,!is_new,art])?;
        }
    }
    Ok(if is_new { 1 } else { 2 })
}
#[uniffi::export]
impl LibraryDatabase {
    pub fn track_needs_ingest(
        &self,
        path: String,
        modified: Option<f64>,
        hard: bool,
    ) -> DbResult<bool> {
        self.read(|c| track_needs_ingest(c, &path, modified, hard))
    }
    pub fn ingest_tracks(
        &self,
        tracks: Vec<TrackImport>,
        hard: bool,
        now: f64,
    ) -> DbResult<TrackIngestResult> {
        self.write(|c| {
            let now = timestamp(now)?;
            let domain = artist_domain(c)?;
            let mut out = TrackIngestResult {
                added: 0,
                updated: 0,
                skipped: 0,
                failed_paths: vec![],
                errors: vec![],
            };
            for track in tracks {
                c.execute_batch("SAVEPOINT ingest_item")?;
                match ingest(c, &track, &domain, hard, &now) {
                    Ok(result) => {
                        c.execute_batch("RELEASE ingest_item")?;
                        match result {
                            1 => out.added += 1,
                            2 => out.updated += 1,
                            _ => out.skipped += 1,
                        }
                    }
                    Err(error) => {
                        c.execute_batch("ROLLBACK TO ingest_item; RELEASE ingest_item")?;
                        out.failed_paths.push(track.path);
                        out.errors.push(error.to_string());
                    }
                }
            }
            Ok(out)
        })
    }
    pub fn detect_and_mark_duplicates(&self) -> DbResult<u64> {
        self.write(|c| detect_and_mark_duplicates(c))
    }
    pub fn finalize_library_scan(&self, now: f64) -> DbResult<()> {
        self.write(|c| {
            let now = timestamp(now)?;
            normalize_compilation_albums(c, &now)?;
            detect_and_mark_duplicates(c)?;
            update_artist_stats(c, &now)?;
            update_album_stats(c, &now)?;
            crate::database_mutations::cleanup_orphaned_data(c)
        })
    }
    pub fn library_contents_differ(
        &self,
        files: Vec<crate::database_folders::LibraryFileObservation>,
        tolerance: f64,
    ) -> DbResult<bool> {
        self.read(|c| {
            for file in files {
                if !file.regular || !file.readable {
                    continue;
                }
                let stored: Option<Option<f64>> = c
                    .query_row(
                        "SELECT date_modified FROM tracks WHERE path=? ORDER BY id LIMIT 1",
                        [file.path],
                        |r| Ok(stored_seconds(r.get(0)?)),
                    )
                    .optional()?;
                match (stored, file.modified) {
                    (Some(Some(old)), Some(new)) if (old - new).abs() <= tolerance => (),
                    _ => return Ok(true),
                }
            }
            Ok(false)
        })
    }
}
#[derive(Clone, Debug, PartialEq, Default)]
struct Marking {
    duplicate: bool,
    primary: Option<i64>,
    group: Option<String>,
}
pub(crate) fn detect_and_mark_duplicates(conn: &Connection) -> DbResult<u64> {
    let mut groups: HashMap<String, Vec<(i64, i64, Marking)>> = HashMap::new();
    let mut stmt = conn.prepare(
        "SELECT t.*,t.track_artwork_data IS NOT NULL AS has_art FROM tracks t ORDER BY t.id",
    )?;
    for row in stmt.query_map([], |r| {
        let text = |key: &str, unknown: &str| -> rusqlite::Result<String> {
            Ok(r.get::<_, Option<String>>(key)?.unwrap_or(unknown.into()))
        };
        let title = text("title", "Unknown Title")?;
        let artist = text("artist", "Unknown Artist")?;
        let album = text("album", "Unknown Album")?;
        let year = text("year", "Unknown Year")?;
        let duration = sanitized_duration(r.get::<_, Option<f64>>("duration")?.unwrap_or_default());
        let key = format!(
            "{}|{}|{}|{}|{}",
            duplicate_text(&title),
            duplicate_text(&artist),
            duplicate_text(&album),
            year.trim_matches(|c: char| c.is_whitespace() || c == '\u{200b}')
                .nfc()
                .collect::<String>(),
            ((duration / 2.0).round() as i64).saturating_mul(2)
        );
        let format = text("format", "")?.to_lowercase();
        let bitrate = r.get::<_, Option<i64>>("bitrate")?.unwrap_or_default();
        let codec = text("codec", "")?.to_lowercase();
        let lossless = r.get::<_, Option<bool>>("lossless")?.unwrap_or_else(|| {
            if !codec.is_empty() {
                if [
                    "flac",
                    "alac",
                    "apple lossless",
                    "aiff",
                    "wav",
                    "wave",
                    "pcm",
                    "ape",
                    "wavpack",
                    "tta",
                    "dsf",
                    "dsdiff",
                ]
                .iter()
                .any(|s| codec.contains(s))
                {
                    return true;
                }
                if [
                    "mp3", "mpeg", "aac", "vorbis", "ogg", "opus", "musepack", "mpc", "wma",
                ]
                .iter()
                .any(|s| codec.contains(s))
                {
                    return false;
                }
            }
            matches!(
                format.as_str(),
                "flac"
                    | "ape"
                    | "wv"
                    | "tta"
                    | "wav"
                    | "wave"
                    | "w64"
                    | "aiff"
                    | "aif"
                    | "aifc"
                    | "alac"
                    | "dsf"
                    | "dff"
                    | "tak"
                    | "shn"
                    | "thd"
                    | "mlp"
                    | "au"
            )
        });
        let mut score = if lossless {
            if matches!(format.as_str(), "dsf" | "dff") {
                1200
            } else {
                1000
            }
        } else {
            match format.as_str() {
                "mp3" => {
                    if bitrate >= 320 {
                        800
                    } else if bitrate >= 256 {
                        600
                    } else if bitrate >= 192 {
                        400
                    } else {
                        200
                    }
                }
                "aac" | "m4a" => {
                    if bitrate >= 256 {
                        700
                    } else if bitrate >= 192 {
                        500
                    } else {
                        300
                    }
                }
                "ogg" | "mpc" => {
                    if bitrate >= 192 {
                        600
                    } else {
                        400
                    }
                }
                "opus" | "oga" => {
                    if bitrate >= 128 {
                        650
                    } else {
                        450
                    }
                }
                "spx" => 300,
                _ => 100,
            }
        };
        for (value, unknown) in [
            (&title, "Unknown Title"),
            (&artist, "Unknown Artist"),
            (&album, "Unknown Album"),
        ] {
            if !value.is_empty() && value != unknown {
                score += 50;
            }
        }
        if r.get::<_, Option<String>>("album_artist")?.is_some() {
            score += 25;
        }
        if r.get::<_, Option<i64>>("track_number")?.is_some() {
            score += 25;
        }
        if year != "Unknown Year" {
            score += 25;
        }
        if r.get::<_, bool>("has_art")? {
            score += 100;
        }
        let rate = r.get::<_, Option<i64>>("sample_rate")?.unwrap_or_default();
        if rate >= 96000 {
            score += 100;
        } else if rate >= 48000 {
            score += 50;
        }
        if r.get::<_, Option<i64>>("bit_depth")?.unwrap_or_default() >= 24 {
            score += 50;
        }
        Ok((
            key,
            r.get::<_, i64>("id")?,
            score,
            Marking {
                duplicate: r.get("is_duplicate")?,
                primary: r.get("primary_track_id")?,
                group: r.get("duplicate_group_id")?,
            },
        ))
    })? {
        let (key, id, score, current) = row?;
        groups.entry(key).or_default().push((id, score, current));
    }
    let mut changed = 0;
    for group in groups.values_mut() {
        group.sort_by(|a, b| b.1.cmp(&a.1).then(a.0.cmp(&b.0)));
        let primary = group[0].0;
        let duplicate = group.len() > 1;
        for (id, _, current) in group {
            let desired = if duplicate {
                Marking {
                    duplicate: *id != primary,
                    primary: (*id != primary).then_some(primary),
                    group: Some(primary.to_string()),
                }
            } else {
                Marking::default()
            };
            if *current != desired {
                conn.execute("UPDATE tracks SET is_duplicate=?,primary_track_id=?,duplicate_group_id=? WHERE id=?",params![desired.duplicate,desired.primary,desired.group,*id])?;
                changed += 1;
            }
        }
    }
    Ok(changed)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::database_folders::{FolderObservation, LibraryFileObservation};
    fn fixture() -> std::sync::Arc<LibraryDatabase> {
        let path =
            std::env::temp_dir().join(format!("petrichor-library-{}.sqlite", uuid::Uuid::new_v4()));
        let db = LibraryDatabase::open(path.to_string_lossy().into_owned()).unwrap();
        db.add_folders(
            vec![FolderObservation {
                path: "/Music".into(),
                name: "Music".into(),
                bookmark: Some(vec![8, 9]),
                modified: Some(100.0),
            }],
            100.0,
        )
        .unwrap();
        db
    }
    fn input(path: &str) -> TrackImport {
        TrackImport {
            path: path.into(),
            filename: path.rsplit('/').next().unwrap().into(),
            basename: "Singer - Song".into(),
            format: "mp3".into(),
            folder_id: 1,
            modified: Some(100.0),
            duration: 120.0,
            artist: Some("Singer".into()),
            album: Some("Album".into()),
            extended_json: Some(r#"{"lyrics":"original","private":"keep"}"#.into()),
            ..Default::default()
        }
    }
    #[test]
    fn ingest_preserves_user_edits_and_database_only_art() {
        let db = fixture();
        let first = input("/Music/a.mp3");
        assert_eq!(
            db.ingest_tracks(vec![first.clone()], false, 100.0)
                .unwrap()
                .added,
            1
        );
        db.write(|c|{c.execute("UPDATE tracks SET is_favorite=1,date_favorited='2001-01-01 00:00:00.000',play_count=42,last_played_date='2002-01-01 00:00:00.000',track_artwork_data=X'0102' WHERE id=1",[])?;Ok(())}).unwrap();
        let mut changed = first;
        changed.title = Some("Changed".into());
        changed.extended_json = Some(r#"{"label":"New"}"#.into());
        changed.modified = Some(102.0);
        assert_eq!(
            db.ingest_tracks(vec![changed], false, 200.0)
                .unwrap()
                .updated,
            1
        );
        db.read(|c|{let state:(String,i64,i64,Vec<u8>,String,String)=c.query_row("SELECT title,is_favorite,play_count,track_artwork_data,extended_metadata,date_added FROM tracks WHERE id=1",[],|r|Ok((r.get(0)?,r.get(1)?,r.get(2)?,r.get(3)?,r.get(4)?,r.get(5)?)))?;
            assert_eq!(state.0,"Changed");assert_eq!(state.1,1);assert_eq!(state.2,42);assert_eq!(state.3,vec![1,2]);let json:serde_json::Value=serde_json::from_str(&state.4).unwrap();assert_eq!(json["lyrics"],"original");assert_eq!(json["private"],"keep");assert_eq!(json["label"],"New");assert_eq!(state.5,timestamp(100.0)?);Ok(())}).unwrap();
    }
    #[test]
    fn mtime_threshold_null_and_hard_refresh() {
        let db = fixture();
        db.ingest_tracks(vec![input("/Music/a.mp3")], false, 100.0)
            .unwrap();
        for delta in [0.0, 0.999, 1.0] {
            assert!(
                !db.track_needs_ingest("/Music/a.mp3".into(), Some(100.0 + delta), false)
                    .unwrap()
            );
        }
        assert!(
            db.track_needs_ingest("/Music/a.mp3".into(), Some(101.001), false)
                .unwrap()
        );
        assert!(
            !db.track_needs_ingest("/Music/a.mp3".into(), None, false)
                .unwrap()
        );
        assert!(
            db.track_needs_ingest("/Music/a.mp3".into(), None, true)
                .unwrap()
        );
        db.write(|c| {
            c.execute("UPDATE tracks SET date_modified=NULL WHERE id=1", [])?;
            Ok(())
        })
        .unwrap();
        assert!(
            !db.track_needs_ingest("/Music/a.mp3".into(), Some(500.0), false)
                .unwrap()
        );
    }
    #[test]
    fn per_item_savepoint_rolls_back_normalization_and_continues() {
        let db = fixture();
        db.write(|c|{c.execute_batch("CREATE TRIGGER reject_failed_artist BEFORE INSERT ON artists WHEN NEW.name='Failed artist' BEGIN SELECT RAISE(ABORT,'fixture artist failure'); END;")?;Ok(())}).unwrap();
        let mut bad = input("/Music/bad.mp3");
        bad.artist = Some("Failed artist".into());
        let result = db
            .ingest_tracks(vec![bad, input("/Music/good.mp3")], false, 100.0)
            .unwrap();
        assert_eq!(result.added, 1);
        assert_eq!(result.failed_paths, vec!["/Music/bad.mp3"]);
        db.read(|c| {
            let count: i64 = c.query_row("SELECT COUNT(*) FROM tracks", [], |r| r.get(0))?;
            assert_eq!(count, 1);
            let bad: i64 = c.query_row(
                "SELECT COUNT(*) FROM artists WHERE name='Failed artist'",
                [],
                |r| r.get(0),
            )?;
            assert_eq!(bad, 0);
            Ok(())
        })
        .unwrap();
    }
    #[test]
    fn duplicate_winner_stable_and_changed_only() {
        let db = fixture();
        let mut better = input("/Music/b.mp3");
        better.bitrate = Some(320);
        let mut lower = input("/Music/a.mp3");
        lower.bitrate = Some(128);
        db.ingest_tracks(vec![lower, better], false, 100.0).unwrap();
        assert_eq!(db.detect_and_mark_duplicates().unwrap(), 2);
        assert_eq!(db.detect_and_mark_duplicates().unwrap(), 0);
        db.read(|c| {
            let state: (bool, Option<i64>, String) = c.query_row(
                "SELECT is_duplicate,primary_track_id,duplicate_group_id FROM tracks WHERE id=1",
                [],
                |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?)),
            )?;
            assert_eq!(state, (true, Some(2), "2".into()));
            Ok(())
        })
        .unwrap();
    }
    #[test]
    fn compilation_preserves_database_only_donor_art_and_missing_tracks() {
        let db = fixture();
        let mut a = input("/Music/one.mp3");
        a.artist = Some("One".into());
        let mut b = input("/Music/two.mp3");
        b.artist = Some("Two".into());
        db.ingest_tracks(vec![a, b], false, 100.0).unwrap();
        db.write(|c| {
            c.execute(
                "UPDATE albums SET artwork_data=X'010203',artwork_thumbnail=X'0405' WHERE id=2",
                [],
            )?;
            Ok(())
        })
        .unwrap();
        db.finalize_library_scan(200.0).unwrap();
        db.read(|c| {
            let count: i64 = c.query_row("SELECT COUNT(*) FROM tracks", [], |r| r.get(0))?;
            assert_eq!(count, 2);
            let art: Vec<u8> =
                c.query_row("SELECT artwork_data FROM albums WHERE id=1", [], |r| {
                    r.get(0)
                })?;
            assert_eq!(art, vec![1, 2, 3]);
            let thumb: Vec<u8> =
                c.query_row("SELECT artwork_thumbnail FROM albums WHERE id=1", [], |r| {
                    r.get(0)
                })?;
            assert_eq!(thumb, vec![4, 5]);
            let fk: i64 =
                c.query_row("SELECT COUNT(*) FROM pragma_foreign_key_check", [], |r| {
                    r.get(0)
                })?;
            assert_eq!(fk, 0);
            Ok(())
        })
        .unwrap();
    }
    #[test]
    fn relocation_is_atomic_and_retains_identity() {
        let db = fixture();
        db.ingest_tracks(vec![input("/Music/a.mp3")], false, 100.0)
            .unwrap();
        let rows = db
            .relocate_folder(1, "/Music".into(), "/Moved".into(), "Moved".into(), vec![7])
            .unwrap();
        assert_eq!(rows.rows.len(), 1);
        db.read(|c| {
            let state: (i64, String) = c.query_row("SELECT id,path FROM tracks", [], |r| {
                Ok((r.get(0)?, r.get(1)?))
            })?;
            assert_eq!(state, (1, "/Moved/a.mp3".into()));
            Ok(())
        })
        .unwrap();
        db.write(|c| {
            c.execute("UPDATE tracks SET path='/Elsewhere/a.mp3' WHERE id=1", [])?;
            Ok(())
        })
        .unwrap();
        assert!(
            db.relocate_folder(1, "/Moved".into(), "/Final".into(), "Final".into(), vec![6])
                .is_err()
        );
        db.read(|c| {
            let path: String =
                c.query_row("SELECT path FROM folders WHERE id=1", [], |r| r.get(0))?;
            assert_eq!(path, "/Moved");
            Ok(())
        })
        .unwrap();
    }
    #[test]
    fn classification_deduplicates_and_keeps_first_art_per_directory() {
        let db = fixture();
        let observe = |path: &str, ext: &str, name: &str, readable: bool| LibraryFileObservation {
            path: path.into(),
            extension: ext.into(),
            basename: name.into(),
            regular: true,
            readable,
            size: Some(10),
            modified: None,
        };
        let files = vec![
            observe("/Music/a.mp3", "mp3", "a", true),
            observe("/Music/a.mp3", "mp3", "a", true),
            observe("/Music/b.mp3", "mp3", "b", false),
            observe("/Music/cover.jpg", "jpg", "cover", true),
            observe("/Music/folder.jpg", "jpg", "folder", true),
        ];
        let result = db
            .classify_library_files(
                files,
                vec!["mp3".into()],
                vec![],
                vec!["jpg".into()],
                vec!["cover".into(), "folder".into()],
                true,
            )
            .unwrap();
        assert_eq!(result.audio_paths, vec!["/Music/a.mp3"]);
        assert_eq!(result.failed_paths, vec!["/Music/b.mp3"]);
        assert_eq!(result.artwork_paths, vec!["/Music/cover.jpg"]);
        assert!(
            db.classify_library_files(vec![], vec![], vec![], vec![], vec![], false)
                .is_err()
        );
    }
}

#[cfg(test)]
mod review_regressions {
    use super::*;
    fn fixture() -> std::sync::Arc<LibraryDatabase> {
        let path = std::env::temp_dir().join(format!(
            "petrichor-library-review-{}.sqlite",
            uuid::Uuid::new_v4()
        ));
        let db = LibraryDatabase::open(path.to_string_lossy().into_owned()).unwrap();
        db.add_folders(
            vec![crate::database_folders::FolderObservation {
                path: "/Music".into(),
                name: "Music".into(),
                bookmark: None,
                modified: None,
            }],
            100.0,
        )
        .unwrap();
        db
    }
    fn track(path: &str) -> TrackImport {
        TrackImport {
            path: path.into(),
            filename: "a.mp3".into(),
            basename: "a".into(),
            format: "mp3".into(),
            folder_id: 1,
            modified: Some(100.0),
            duration: 120.0,
            title: Some("Song".into()),
            artist: Some("Artist".into()),
            album: Some("Album".into()),
            ..Default::default()
        }
    }
    #[test]
    fn repaired_track_art_beats_album_art_for_duplicate_primary() {
        let db = fixture();
        db.ingest_tracks(
            vec![track("/Music/a.mp3"), track("/Music/b.mp3")],
            false,
            100.0,
        )
        .unwrap();
        db.write(|c| {
            c.execute("UPDATE albums SET artwork_data=X'0102'", [])?;
            c.execute(
                "UPDATE tracks SET track_artwork_data=X'0304' WHERE id=2",
                [],
            )?;
            Ok(())
        })
        .unwrap();
        db.detect_and_mark_duplicates().unwrap();
        db.read(|c| {
            let primary: Option<i64> =
                c.query_row("SELECT primary_track_id FROM tracks WHERE id=1", [], |r| {
                    r.get(0)
                })?;
            assert_eq!(primary, Some(2));
            Ok(())
        })
        .unwrap();
        assert_eq!(db.detect_and_mark_duplicates().unwrap(), 0);
    }
    #[test]
    fn aliases_keep_orphan_canonical_owners_through_compilation_and_cleanup() {
        let db = fixture();
        let a = track("/Music/a.mp3");
        let mut b = track("/Music/b.mp3");
        b.artist = Some("Other".into());
        db.ingest_tracks(vec![a, b], false, 100.0).unwrap();
        db.write(|c|{c.execute("INSERT INTO album_aliases(normalized_key,display_title,canonical_album_id,created_at) VALUES('old|other','Old',2,?)",[timestamp(100.0)?])?;let artist=find_or_create_artist(c,"Saved Owner",&timestamp(100.0)?)?;c.execute("INSERT INTO artist_aliases(normalized_alias,display_name,canonical_artist_id,created_at) VALUES('old saved','Old Saved',?,?)",params![artist,timestamp(100.0)?])?;Ok(())}).unwrap();
        db.finalize_library_scan(200.0).unwrap();
        db.cleanup_orphaned_data().unwrap();
        db.read(|c|{let albums:i64=c.query_row("SELECT COUNT(*) FROM album_aliases WHERE canonical_album_id=2",[],|r|r.get(0))?;let artists:i64=c.query_row("SELECT COUNT(*) FROM artists a JOIN artist_aliases aa ON aa.canonical_artist_id=a.id WHERE aa.normalized_alias='old saved'",[],|r|r.get(0))?;assert_eq!(albums,1);assert_eq!(artists,1);assert_eq!(find_or_create_album(c,"Old",Some("Other"),&timestamp(200.0)?)?,2);let checks:i64=c.query_row("SELECT COUNT(*) FROM pragma_foreign_key_check",[],|r|r.get(0))?;assert_eq!(checks,0);Ok(())}).unwrap();
    }
    #[test]
    fn orphan_alias_with_separator_reimports_to_saved_owner_without_weakening_known_roles() {
        let db = fixture();
        let canonical=db.write(|c|{let artist=find_or_create_artist(c,"Saved Canonical",&timestamp(100.0)?)?;c.execute("INSERT INTO artist_aliases(normalized_alias,display_name,canonical_artist_id,created_at) VALUES(?,?,?,?)",params![normalize_artist_name("Old & Saved"),"Old & Saved",artist,timestamp(100.0)?])?;Ok(artist)}).unwrap();
        db.cleanup_orphaned_data().unwrap();
        let mut input = track("/Music/a.mp3");
        input.artist = Some("Old & Saved".into());
        input.album = Some("Unknown Album".into());
        db.ingest_tracks(vec![input], false, 100.0).unwrap();
        db.read(|c| {
            let count: i64 = c.query_row("SELECT COUNT(*) FROM artists", [], |r| r.get(0))?;
            assert_eq!(count, 1);
            let owner: i64 = c.query_row(
                "SELECT artist_id FROM track_artists WHERE track_id=1 AND role='artist'",
                [],
                |r| r.get(0),
            )?;
            assert_eq!(owner, canonical);
            let domain = artist_domain(c)?;
            assert_eq!(
                domain.parse(
                    "Old & Saved".into(),
                    "Unknown Artist".into(),
                    Some("artist".into())
                ),
                vec!["Saved Canonical"]
            );
            assert_ne!(
                domain.parse(
                    "Old & Saved".into(),
                    "Unknown Artist".into(),
                    Some("composer".into())
                ),
                vec!["Saved Canonical"]
            );
            Ok(())
        })
        .unwrap();
    }
    #[test]
    fn release_year_is_strict_and_new_genres_link_idempotently() {
        let db = fixture();
        let mut input = track("/Music/a.mp3");
        input.year = Some("2001 remaster".into());
        input.genre = Some("Rock; Pop/Jazz".into());
        db.ingest_tracks(vec![input.clone()], false, 100.0).unwrap();
        db.read(|c| {
            let year: Option<i64> =
                c.query_row("SELECT release_year FROM albums WHERE id=1", [], |r| {
                    r.get(0)
                })?;
            assert_eq!(year, None);
            let count: i64 = c.query_row(
                "SELECT COUNT(*) FROM track_genres WHERE track_id=1",
                [],
                |r| r.get(0),
            )?;
            assert_eq!(count, 3);
            Ok(())
        })
        .unwrap();
        input.year = Some("2001".into());
        db.ingest_tracks(vec![input], true, 200.0).unwrap();
        db.read(|c| {
            let year: Option<i64> =
                c.query_row("SELECT release_year FROM albums WHERE id=1", [], |r| {
                    r.get(0)
                })?;
            assert_eq!(year, Some(2001));
            let count: i64 = c.query_row(
                "SELECT COUNT(*) FROM track_genres WHERE track_id=1",
                [],
                |r| r.get(0),
            )?;
            assert_eq!(count, 3);
            Ok(())
        })
        .unwrap();
    }
}
