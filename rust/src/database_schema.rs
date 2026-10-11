//! Historical GRDB migration identifiers remain the authority; current databases are never reserialized.
use super::database::{DbResult, invalid, timestamp};
use rusqlite::{Connection, OptionalExtension};
const FRESH: &str = r#"CREATE TABLE IF NOT EXISTS "folders" ("id" INTEGER PRIMARY KEY AUTOINCREMENT, "name" TEXT NOT NULL, "path" TEXT NOT NULL UNIQUE, "track_count" INTEGER NOT NULL DEFAULT 0, "date_added" DATETIME NOT NULL, "date_updated" DATETIME NOT NULL, "bookmark_data" BLOB);
CREATE TABLE IF NOT EXISTS "artists" ("id" INTEGER PRIMARY KEY AUTOINCREMENT, "name" TEXT NOT NULL, "normalized_name" TEXT NOT NULL, "sort_name" TEXT, "artwork_data" BLOB, "artwork_thumbnail" BLOB, "bio" TEXT, "bio_source" TEXT, "bio_updated_at" DATETIME, "image_url" TEXT, "image_source" TEXT, "image_updated_at" DATETIME, "discogs_id" TEXT, "musicbrainz_id" TEXT, "spotify_id" TEXT, "apple_music_id" TEXT, "country" TEXT, "formed_year" INTEGER, "disbanded_year" INTEGER, "genres" TEXT, "websites" TEXT, "members" TEXT, "total_tracks" INTEGER NOT NULL DEFAULT 0 CHECK ("total_tracks" >= 0), "total_albums" INTEGER NOT NULL DEFAULT 0 CHECK ("total_albums" >= 0), "created_at" DATETIME NOT NULL, "updated_at" DATETIME NOT NULL);
CREATE TABLE IF NOT EXISTS "albums" ("id" INTEGER PRIMARY KEY AUTOINCREMENT, "title" TEXT NOT NULL, "normalized_title" TEXT NOT NULL, "sort_title" TEXT, "artwork_data" BLOB, "artwork_thumbnail" BLOB, "release_date" TEXT, "release_year" INTEGER CHECK ("release_year" IS NULL OR ("release_year" >= 1900 AND "release_year" <= 2100)), "album_type" TEXT, "total_tracks" INTEGER CHECK ("total_tracks" IS NULL OR "total_tracks" >= 0), "total_discs" INTEGER CHECK ("total_discs" IS NULL OR "total_discs" >= 0), "description" TEXT, "review" TEXT, "review_source" TEXT, "cover_art_url" TEXT, "thumbnail_url" TEXT, "discogs_id" TEXT, "musicbrainz_id" TEXT, "spotify_id" TEXT, "apple_music_id" TEXT, "label" TEXT, "catalog_number" TEXT, "barcode" TEXT, "genres" TEXT, "created_at" DATETIME NOT NULL, "updated_at" DATETIME NOT NULL);
CREATE TABLE IF NOT EXISTS "album_artists" ("album_id" INTEGER NOT NULL REFERENCES "albums"("id") ON DELETE CASCADE, "artist_id" INTEGER NOT NULL REFERENCES "artists"("id") ON DELETE CASCADE, "role" TEXT NOT NULL DEFAULT "primary", "position" INTEGER NOT NULL DEFAULT 0, PRIMARY KEY ("album_id", "artist_id", "role"));
CREATE TABLE IF NOT EXISTS "genres" ("id" INTEGER PRIMARY KEY AUTOINCREMENT, "name" TEXT NOT NULL UNIQUE);
CREATE TABLE IF NOT EXISTS "tracks" ("id" INTEGER PRIMARY KEY AUTOINCREMENT, "folder_id" INTEGER NOT NULL REFERENCES "folders"("id") ON DELETE CASCADE, "album_id" INTEGER REFERENCES "albums"("id") ON DELETE SET NULL, "path" TEXT NOT NULL UNIQUE, "filename" TEXT NOT NULL, "title" TEXT, "artist" TEXT, "album" TEXT, "composer" TEXT, "genre" TEXT, "year" TEXT, "duration" DOUBLE CHECK ("duration" >= 0), "format" TEXT, "file_size" INTEGER, "date_added" DATETIME NOT NULL, "date_modified" DATETIME, "track_artwork_data" BLOB, "is_favorite" BOOLEAN NOT NULL DEFAULT 0, "date_favorited" DATETIME, "play_count" INTEGER NOT NULL DEFAULT 0, "last_played_date" DATETIME, "is_duplicate" BOOLEAN NOT NULL DEFAULT 0, "primary_track_id" INTEGER REFERENCES "tracks"("id") ON DELETE SET NULL, "duplicate_group_id" TEXT, "album_artist" TEXT, "track_number" INTEGER, "total_tracks" INTEGER, "disc_number" INTEGER, "total_discs" INTEGER, "rating" INTEGER CHECK ("rating" IS NULL OR ("rating" >= 0 AND "rating" <= 5)), "compilation" BOOLEAN DEFAULT 0, "release_date" TEXT, "original_release_date" TEXT, "bpm" INTEGER, "media_type" TEXT, "bitrate" INTEGER CHECK ("bitrate" IS NULL OR "bitrate" > 0), "sample_rate" INTEGER, "channels" INTEGER, "codec" TEXT, "bit_depth" INTEGER, "sort_title" TEXT, "sort_artist" TEXT, "sort_album" TEXT, "sort_album_artist" TEXT, "extended_metadata" TEXT);
CREATE TABLE IF NOT EXISTS "playlists" ("id" TEXT PRIMARY KEY, "name" TEXT NOT NULL, "type" TEXT NOT NULL, "is_user_editable" BOOLEAN NOT NULL, "is_content_editable" BOOLEAN NOT NULL, "date_created" DATETIME NOT NULL, "date_modified" DATETIME NOT NULL, "cover_artwork_data" BLOB, "smart_criteria" TEXT, "sort_order" INTEGER NOT NULL DEFAULT 0);
CREATE TABLE IF NOT EXISTS "playlist_tracks" ("playlist_id" TEXT NOT NULL REFERENCES "playlists"("id") ON DELETE CASCADE, "track_id" INTEGER NOT NULL REFERENCES "tracks"("id") ON DELETE CASCADE, "position" INTEGER NOT NULL, "date_added" DATETIME NOT NULL, PRIMARY KEY ("playlist_id", "track_id"));
CREATE TABLE IF NOT EXISTS "track_artists" ("track_id" INTEGER NOT NULL REFERENCES "tracks"("id") ON DELETE CASCADE, "artist_id" INTEGER NOT NULL REFERENCES "artists"("id") ON DELETE CASCADE, "role" TEXT NOT NULL DEFAULT "artist", "position" INTEGER NOT NULL DEFAULT 0, PRIMARY KEY ("track_id", "artist_id", "role"));
CREATE TABLE IF NOT EXISTS "track_genres" ("track_id" INTEGER NOT NULL REFERENCES "tracks"("id") ON DELETE CASCADE, "genre_id" INTEGER NOT NULL REFERENCES "genres"("id") ON DELETE CASCADE, PRIMARY KEY ("track_id", "genre_id"));
CREATE TABLE IF NOT EXISTS "artist_aliases" ("normalized_alias" TEXT PRIMARY KEY, "display_name" TEXT NOT NULL, "canonical_artist_id" INTEGER NOT NULL REFERENCES "artists"("id") ON DELETE CASCADE, "created_at" DATETIME NOT NULL);
CREATE TABLE IF NOT EXISTS "album_aliases" ("normalized_key" TEXT PRIMARY KEY, "display_title" TEXT NOT NULL, "canonical_album_id" INTEGER NOT NULL REFERENCES "albums"("id") ON DELETE CASCADE, "created_at" DATETIME NOT NULL);
CREATE TABLE IF NOT EXISTS "internet_radio" ("id" INTEGER PRIMARY KEY AUTOINCREMENT, "name" TEXT NOT NULL, "stream_url" TEXT NOT NULL, "description" TEXT, "artwork_data" BLOB, "station_uuid" TEXT, "favicon_url" TEXT, "homepage_url" TEXT, "tags" TEXT, "country" TEXT, "country_code" TEXT, "language" TEXT, "codec" TEXT, "bitrate" INTEGER, "votes" INTEGER, "play_count" INTEGER NOT NULL DEFAULT 0, "last_played" DATETIME, "date_added" DATETIME NOT NULL, "date_modified" DATETIME NOT NULL);
CREATE TABLE IF NOT EXISTS "playlist_stations" ("playlist_id" TEXT NOT NULL REFERENCES "playlists"("id") ON DELETE CASCADE, "station_id" INTEGER NOT NULL REFERENCES "internet_radio"("id") ON DELETE CASCADE, "position" INTEGER NOT NULL, "date_added" DATETIME NOT NULL, PRIMARY KEY ("playlist_id", "station_id"));
CREATE INDEX IF NOT EXISTS "idx_tracks_folder_id" ON "tracks" ("folder_id");
CREATE INDEX IF NOT EXISTS "idx_tracks_album_id" ON "tracks" ("album_id");
CREATE INDEX IF NOT EXISTS "idx_tracks_artist" ON "tracks" ("artist");
CREATE INDEX IF NOT EXISTS "idx_tracks_album" ON "tracks" ("album");
CREATE INDEX IF NOT EXISTS "idx_tracks_composer" ON "tracks" ("composer");
CREATE INDEX IF NOT EXISTS "idx_tracks_genre" ON "tracks" ("genre");
CREATE INDEX IF NOT EXISTS "idx_tracks_year" ON "tracks" ("year");
CREATE INDEX IF NOT EXISTS "idx_tracks_album_artist" ON "tracks" ("album_artist");
CREATE INDEX IF NOT EXISTS "idx_tracks_is_favorite" ON "tracks" ("is_favorite");
CREATE INDEX IF NOT EXISTS "idx_tracks_rating" ON "tracks" ("rating");
CREATE INDEX IF NOT EXISTS "idx_tracks_compilation" ON "tracks" ("compilation");
CREATE INDEX IF NOT EXISTS "idx_tracks_media_type" ON "tracks" ("media_type");
CREATE INDEX IF NOT EXISTS "idx_tracks_primary_track_id" ON "tracks" ("primary_track_id");
CREATE INDEX IF NOT EXISTS "idx_tracks_is_duplicate" ON "tracks" ("is_duplicate");
CREATE INDEX IF NOT EXISTS "idx_tracks_duplicate_group_id" ON "tracks" ("duplicate_group_id");
CREATE INDEX IF NOT EXISTS "idx_tracks_duplicate_artist" ON "tracks" ("is_duplicate", "artist");
CREATE INDEX IF NOT EXISTS "idx_tracks_duplicate_album_artist" ON "tracks" ("is_duplicate", "album_artist");
CREATE INDEX IF NOT EXISTS "idx_tracks_duplicate_composer" ON "tracks" ("is_duplicate", "composer");
CREATE INDEX IF NOT EXISTS "idx_tracks_duplicate_genre" ON "tracks" ("is_duplicate", "genre");
CREATE INDEX IF NOT EXISTS "idx_tracks_last_played_date" ON "tracks" ("last_played_date");
CREATE INDEX IF NOT EXISTS "idx_tracks_duplicate_last_played" ON "tracks" ("is_duplicate", "last_played_date");
CREATE INDEX IF NOT EXISTS "idx_tracks_duplicate_play_count" ON "tracks" ("is_duplicate", "play_count");
CREATE INDEX IF NOT EXISTS "idx_tracks_duplicate_year" ON "tracks" ("is_duplicate", "year");
CREATE INDEX IF NOT EXISTS "idx_tracks_album_id_duplicate" ON "tracks" ("album_id", "is_duplicate", "disc_number", "track_number");
CREATE INDEX IF NOT EXISTS "idx_tracks_album_name_artist" ON "tracks" ("album", "album_artist", "is_duplicate", "disc_number", "track_number");
CREATE UNIQUE INDEX IF NOT EXISTS "idx_artists_normalized_name_unique" ON "artists" ("normalized_name");
CREATE INDEX IF NOT EXISTS "idx_artists_name_normalized" ON "artists" ("name", "normalized_name");
CREATE INDEX IF NOT EXISTS "idx_albums_title_year" ON "albums" ("normalized_title", "release_year");
CREATE INDEX IF NOT EXISTS "idx_albums_normalized_title" ON "albums" ("normalized_title");
CREATE INDEX IF NOT EXISTS "idx_albums_release_year" ON "albums" ("release_year");
CREATE INDEX IF NOT EXISTS "idx_album_artists_album_id" ON "album_artists" ("album_id");
CREATE INDEX IF NOT EXISTS "idx_album_artists_artist_id" ON "album_artists" ("artist_id");
CREATE INDEX IF NOT EXISTS "idx_album_artists_primary" ON "album_artists" ("role", "position", "album_id", "artist_id");
CREATE INDEX IF NOT EXISTS "idx_playlist_tracks_playlist_id" ON "playlist_tracks" ("playlist_id");
CREATE INDEX IF NOT EXISTS "idx_playlist_tracks_track_id" ON "playlist_tracks" ("track_id");
CREATE INDEX IF NOT EXISTS "idx_track_artists_artist_id" ON "track_artists" ("artist_id");
CREATE INDEX IF NOT EXISTS "idx_track_artists_track_id" ON "track_artists" ("track_id");
CREATE INDEX IF NOT EXISTS "idx_track_artists_role_artist" ON "track_artists" ("role", "artist_id", "track_id");
CREATE INDEX IF NOT EXISTS "idx_track_genres_genre_id" ON "track_genres" ("genre_id");
CREATE INDEX IF NOT EXISTS "idx_artist_aliases_canonical" ON "artist_aliases" ("canonical_artist_id");
CREATE INDEX IF NOT EXISTS "idx_album_aliases_canonical" ON "album_aliases" ("canonical_album_id");
CREATE INDEX IF NOT EXISTS "idx_internet_radio_name" ON "internet_radio" ("name");
CREATE INDEX IF NOT EXISTS "idx_internet_radio_station_uuid" ON "internet_radio" ("station_uuid");
CREATE INDEX IF NOT EXISTS "idx_internet_radio_last_played" ON "internet_radio" ("last_played");
CREATE INDEX IF NOT EXISTS "idx_playlist_stations_playlist_position" ON "playlist_stations" ("playlist_id", "position");
CREATE INDEX IF NOT EXISTS "idx_playlist_stations_station_id" ON "playlist_stations" ("station_id");
CREATE INDEX IF NOT EXISTS idx_tracks_filename_lower ON tracks(LOWER(filename));"#;
const FTS: &str = r#"CREATE VIRTUAL TABLE IF NOT EXISTS tracks_fts USING fts5(track_id UNINDEXED,title,artist,album,album_artist,composer,genre,year,tokenize='unicode61');
            CREATE TRIGGER IF NOT EXISTS tracks_fts_insert
            AFTER INSERT ON tracks
            BEGIN
                INSERT INTO tracks_fts(
                    rowid, track_id, title, artist, album, album_artist, composer, genre, year
                ) VALUES (
                    NEW.id, NEW.id, NEW.title, NEW.artist, NEW.album, NEW.album_artist, NEW.composer, NEW.genre, NEW.year
                );
            END;
            CREATE TRIGGER IF NOT EXISTS tracks_fts_update
            AFTER UPDATE ON tracks
            BEGIN
                UPDATE tracks_fts SET
                    title = NEW.title,
                    artist = NEW.artist,
                    album = NEW.album,
                    album_artist = NEW.album_artist,
                    composer = NEW.composer,
                    genre = NEW.genre,
                    year = NEW.year
                WHERE rowid = NEW.id;
            END;
            CREATE TRIGGER IF NOT EXISTS tracks_fts_delete
            AFTER DELETE ON tracks
            BEGIN
                DELETE FROM tracks_fts WHERE rowid = OLD.id;
            END;
            INSERT INTO tracks_fts(
                rowid, track_id, title, artist, album, album_artist, composer, genre, year
            )
            SELECT
                id, id, title, artist, album, album_artist, composer, genre, year
            FROM tracks"#;
pub(crate) const MIGRATIONS: [&str; 17] = [
    "v1_initial_schema",
    "v2_add_folder_content_hash",
    "v3_add_category_query_indices",
    "v4_rebuild_fts_with_unicode61_tokenizer",
    "v5_add_lossless_column",
    "v6_update_most_played_criteria",
    "v7_create_background_migrations_table",
    "v8_convert_artwork_to_heic",
    "v9_rebuild_artist_associations",
    "v10_add_filename_index_and_drop_pinned_icon_name",
    "v11_add_merge_support",
    "v12_backfill_album_artists",
    "v13_add_artwork_thumbnail",
    "v14_playback_journal_cursor",
    "v15_date_favorited",
    "v16_artwork_read_performance",
    "v17_drop_pinned_items",
];
pub(crate) fn migrate(conn: &mut Connection) -> DbResult<()> {
    conn.execute_batch(
        "CREATE TABLE IF NOT EXISTS grdb_migrations (identifier TEXT NOT NULL PRIMARY KEY)",
    )?;
    for (index, id) in MIGRATIONS.iter().enumerate() {
        if conn
            .query_row(
                "SELECT 1 FROM grdb_migrations WHERE identifier=?",
                [id],
                |r| r.get::<_, i64>(0),
            )
            .optional()?
            .is_some()
        {
            continue;
        }
        // GRDB defers FK validation until the migration has finished.
        let tx = conn.transaction()?;
        tx.execute_batch("PRAGMA defer_foreign_keys=ON")?;
        apply(&tx, index)?;
        if tx.prepare("PRAGMA foreign_key_check")?.exists([])? {
            return Err(invalid(format!("Foreign key failure in {id}")));
        }
        tx.execute("INSERT INTO grdb_migrations VALUES (?)", [id])?;
        tx.commit()?;
    }
    Ok(())
}
fn enqueue(conn: &Connection, id: &str) -> DbResult<()> {
    conn.execute(
        "INSERT INTO background_migrations(identifier,resumable) VALUES (?,1)",
        [id],
    )?;
    Ok(())
}
fn add_column(conn: &Connection, table: &str, column: &str, typ: &str) -> DbResult<()> {
    let mut stmt = conn.prepare(&format!("PRAGMA table_info({table})"))?;
    let names = stmt
        .query_map([], |r| r.get::<_, String>(1))?
        .collect::<Result<Vec<_>, _>>()?;
    if !names.iter().any(|n| n == column) {
        conn.execute_batch(&format!("ALTER TABLE {table} ADD COLUMN {column} {typ}"))?;
    }
    Ok(())
}
fn apply(conn: &Connection, index: usize) -> DbResult<()> {
    match index {
    0=>{
        let exists:bool=conn.query_row("SELECT EXISTS(SELECT 1 FROM sqlite_master WHERE type='table' AND name IN ('tracks','folders','artists'))",[],|r|r.get(0))?;
        if !exists {conn.execute_batch(FRESH)?;conn.execute_batch(FTS)?;seed(conn)?;}
    },
    1=>conn.execute_batch("ALTER TABLE folders ADD COLUMN shasum_hash TEXT")?,
    2=>{
        // All category indices already occur in fresh setup; only use this subset on old libraries.
        for sql in FRESH.split(';').filter(|s|s.contains("CREATE INDEX") && ["idx_track_artists_role_artist","idx_tracks_duplicate_artist","idx_tracks_duplicate_album_artist","idx_tracks_duplicate_composer","idx_tracks_duplicate_genre","idx_tracks_duplicate_year","idx_album_artists_primary","idx_artists_name_normalized","idx_tracks_album_id_duplicate","idx_tracks_album_name_artist"].iter().any(|n|s.contains(n))) {conn.execute_batch(sql)?;}
        conn.execute_batch("UPDATE artists SET total_tracks=(SELECT COUNT(DISTINCT ta.track_id) FROM track_artists ta JOIN tracks t ON t.id=ta.track_id WHERE ta.artist_id=artists.id AND ta.role='artist' AND t.is_duplicate=0)")?;
    },
    3=>{conn.execute_batch("DROP TRIGGER IF EXISTS tracks_fts_insert;DROP TRIGGER IF EXISTS tracks_fts_update;DROP TRIGGER IF EXISTS tracks_fts_delete;DROP TABLE IF EXISTS tracks_fts;")?;conn.execute_batch(FTS)?;},
    4=>conn.execute_batch("ALTER TABLE tracks ADD COLUMN lossless BOOLEAN")?,
    5=>{conn.execute("UPDATE playlists SET smart_criteria=REPLACE(smart_criteria,'\"condition\":\"greaterThan\"','\"condition\":\"greaterThanOrEqual\"') WHERE name=? AND type='smart'",["Top 25 Most Played"])?;},
    6=>conn.execute_batch("CREATE TABLE background_migrations (identifier TEXT PRIMARY KEY,completed_at DATETIME,progress TEXT,resumable BOOLEAN DEFAULT 1)")?,
    7=>enqueue(conn,"v8_background_convert_artwork_to_heic")?,
    8=>enqueue(conn,"v9_background_rebuild_artist_associations")?,
    9=>conn.execute_batch("CREATE INDEX IF NOT EXISTS idx_tracks_filename ON tracks(filename)")?,
    10=>{for sql in FRESH.split(';').filter(|s|s.contains("artist_aliases")||s.contains("album_aliases")){conn.execute_batch(sql)?;}},
    11=>enqueue(conn,"v12_background_backfill_album_artists")?,
    12=>{add_column(conn,"albums","artwork_thumbnail","BLOB")?;add_column(conn,"artists","artwork_thumbnail","BLOB")?;enqueue(conn,"v13_background_fill_artwork_thumbnail")?;},
    13=>conn.execute_batch("CREATE TABLE playback_journal_cursor (singleton INTEGER PRIMARY KEY,applied_through DATETIME)")?,
    14=>{
        add_column(conn,"tracks","date_favorited","DATETIME")?;
        conn.execute_batch("UPDATE tracks SET date_favorited=date_added WHERE is_favorite=1 AND date_favorited IS NULL")?;
        let rows:Vec<(String,String)>={let mut stmt=conn.prepare("SELECT id,smart_criteria FROM playlists WHERE name='Favorites' AND type='smart' AND smart_criteria IS NOT NULL")?;stmt.query_map([],|r|Ok((r.get(0)?,r.get(1)?)))?.collect::<Result<_,_>>()?};
        for (id,json) in rows {if let Ok(mut value)=serde_json::from_str::<serde_json::Value>(&json) {if value.get("matchType").is_some()&&value.get("rules").is_some()&&value.is_object(){value["sortBy"]="dateFavorited".into();value["sortAscending"]=false.into();conn.execute("UPDATE playlists SET smart_criteria=? WHERE id=?",rusqlite::params![value.to_string(),id])?;}}}
    },
    15=>{enqueue(conn,"v16_background_jpeg_thumbnails")?;enqueue(conn,"v16_background_move_artwork_columns_last")?;},
    16=>conn.execute_batch("DROP TABLE IF EXISTS pinned_items")?,
    _=>unreachable!(),
    }
    Ok(())
}
fn seed(conn: &Connection) -> DbResult<()> {
    let now = timestamp(chrono::Utc::now().timestamp_millis() as f64 / 1000.0)?;
    for (name, field, condition, value, sort, limit) in [
        (
            "Favorites",
            "isFavorite",
            "equals",
            "true",
            "dateFavorited",
            None,
        ),
        (
            "Top 25 Most Played",
            "playCount",
            "greaterThanOrEqual",
            "5",
            "playCount",
            Some(25),
        ),
        (
            "Top 25 Recently Played",
            "lastPlayedDate",
            "greaterThan",
            "7days",
            "lastPlayedDate",
            Some(25),
        ),
    ] {
        let mut criteria = serde_json::json!({"matchType":"all","rules":[{"field":field,"condition":condition,"value":value}],"sortBy":sort,"sortAscending":false,"autoUpdate":true});
        if let Some(limit) = limit {
            criteria["limit"] = limit.into();
        }
        conn.execute("INSERT INTO playlists(id,name,type,is_user_editable,is_content_editable,date_created,date_modified,smart_criteria,sort_order) VALUES (?,?,'smart',0,0,?,?,?,0)",rusqlite::params![uuid::Uuid::new_v4().to_string().to_uppercase(),name,now,now,criteria.to_string()])?;
    }
    Ok(())
}
#[cfg(test)]
pub(crate) fn fresh_schema_for_test() -> String {
    FRESH.into()
}

// Deliberate reset drops and creates everything inside its caller's single transaction.
pub(crate) fn reset_schema(conn: &Connection) -> DbResult<()> {
    conn.execute_batch("CREATE TABLE grdb_migrations(identifier TEXT NOT NULL PRIMARY KEY)")?;
    for (index, id) in MIGRATIONS.iter().enumerate() {
        apply(conn, index)?;
        conn.execute("INSERT INTO grdb_migrations VALUES (?)", [id])?;
    }
    if conn.prepare("PRAGMA foreign_key_check")?.exists([])? {
        return Err(invalid("Reset failed foreign key check"));
    }
    Ok(())
}
