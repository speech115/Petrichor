//! Normalized library identities and relationships share the originating transaction.
use crate::artists::ArtistDomain;
use crate::database::{DbResult, LibraryDatabase, timestamp};
use rusqlite::{Connection, OptionalExtension, params};
use std::collections::{HashMap, HashSet};

static DOMAIN: std::sync::LazyLock<std::sync::Arc<ArtistDomain>> =
    std::sync::LazyLock::new(ArtistDomain::new);
pub(crate) fn normalize_artist_name(name: &str) -> String {
    DOMAIN.normalize_artist_name(name.into())
}
pub(crate) fn normalize_album_title(title: &str) -> String {
    title
        .chars()
        .flat_map(char::to_lowercase)
        .collect::<String>()
        .replace(" - ", " ")
        .replace("  ", " ")
        .replace("the ", "")
        .trim_matches(|c: char| c.is_whitespace() || c == '\u{200b}')
        .into()
}
pub(crate) fn artist_domain(conn: &Connection) -> DbResult<std::sync::Arc<ArtistDomain>> {
    let domain = DOMAIN.database_snapshot();
    let mut roles: HashMap<String, HashMap<String, String>> = HashMap::new();
    let mut stmt=conn.prepare("SELECT DISTINCT ta.role,a.normalized_name,a.name FROM artists a JOIN track_artists ta ON ta.artist_id=a.id UNION SELECT DISTINCT ta.role,aa.normalized_alias,a.name FROM artist_aliases aa JOIN artists a ON a.id=aa.canonical_artist_id JOIN track_artists ta ON ta.artist_id=a.id UNION SELECT roles.role,aa.normalized_alias,a.name FROM artist_aliases aa JOIN artists a ON a.id=aa.canonical_artist_id CROSS JOIN (SELECT 'artist' AS role UNION SELECT 'composer' UNION SELECT 'album_artist') roles WHERE NOT EXISTS (SELECT 1 FROM track_artists ta WHERE ta.artist_id=a.id)")?;
    for row in stmt.query_map([], |r| {
        Ok((
            r.get::<_, String>(0)?,
            r.get::<_, String>(1)?,
            r.get::<_, String>(2)?,
        ))
    })? {
        let (role, key, name) = row?;
        roles.entry(role).or_default().insert(key, name);
    }
    domain.set_library_artists(roles);
    Ok(domain)
}
pub(crate) fn find_or_create_artist(conn: &Connection, name: &str, now: &str) -> DbResult<i64> {
    let normalized = normalize_artist_name(name);
    let id = conn
        .query_row(
            "SELECT id FROM artists WHERE normalized_name=? ORDER BY id LIMIT 1",
            [&normalized],
            |r| r.get(0),
        )
        .optional()?;
    if let Some(id) = id {
        return Ok(id);
    }
    let id=conn.query_row("SELECT a.id FROM artist_aliases aa JOIN artists a ON a.id=aa.canonical_artist_id WHERE normalized_alias=?",[&normalized],|r|r.get(0)).optional()?;
    if let Some(id) = id {
        return Ok(id);
    }
    conn.execute("INSERT INTO artists(name,normalized_name,sort_name,total_tracks,total_albums,created_at,updated_at) VALUES(?,?,?,0,0,?,?)",params![name,normalized,name,now,now])?;
    Ok(conn.last_insert_rowid())
}
pub(crate) fn process_artists_for_field(
    conn: &Connection,
    domain: &ArtistDomain,
    field: &str,
    id: i64,
    role: &str,
    now: &str,
) -> DbResult<()> {
    for (position, name) in domain
        .parse(field.into(), "Unknown Artist".into(), Some(role.into()))
        .iter()
        .enumerate()
    {
        let artist = find_or_create_artist(conn, name, now)?;
        conn.execute(
            "INSERT OR IGNORE INTO track_artists(track_id,artist_id,role,position) VALUES(?,?,?,?)",
            params![id, artist, role, position as i64],
        )?;
    }
    Ok(())
}
pub(crate) fn find_or_create_album(
    conn: &Connection,
    title: &str,
    owner: Option<&str>,
    now: &str,
) -> DbResult<i64> {
    let normalized = normalize_album_title(title);
    let owner = owner.filter(|s| !s.is_empty() && *s != "Unknown Artist");
    let key = format!(
        "{}|{}",
        normalized,
        owner.map(normalize_artist_name).unwrap_or_default()
    );
    if let Some(id)=conn.query_row("SELECT a.id FROM album_aliases aa JOIN albums a ON a.id=aa.canonical_album_id WHERE normalized_key=?",[key],|r|r.get(0)).optional()?{return Ok(id);}
    let id = if let Some(owner) = owner {
        conn.query_row("SELECT al.id FROM albums al JOIN album_artists aa ON aa.album_id=al.id JOIN artists a ON a.id=aa.artist_id WHERE al.normalized_title=? AND aa.role='primary' AND aa.position=0 AND (a.name=? OR a.normalized_name=?) ORDER BY al.id LIMIT 1",params![normalized,owner,normalize_artist_name(owner)],|r|r.get(0)).optional()?
    } else {
        conn.query_row("SELECT id FROM albums WHERE normalized_title=? AND NOT EXISTS(SELECT 1 FROM album_artists aa WHERE aa.album_id=albums.id AND aa.role='primary') ORDER BY id LIMIT 1",[&normalized],|r|r.get(0)).optional()?
    };
    if let Some(id) = id {
        return Ok(id);
    }
    conn.execute("INSERT INTO albums(title,normalized_title,sort_title,created_at,updated_at) VALUES(?,?,?,?,?)",params![title,normalized,title,now,now])?;
    let id = conn.last_insert_rowid();
    if let Some(owner) = owner {
        let artist = find_or_create_artist(conn, owner, now)?;
        conn.execute(
            "INSERT INTO album_artists(album_id,artist_id,role,position) VALUES(?,?,'primary',0)",
            params![id, artist],
        )?;
    }
    Ok(id)
}
pub(crate) fn backfill_track_album_artists(conn: &Connection, id: i64, now: &str) -> DbResult<()> {
    let exists: bool = conn.query_row(
        "SELECT EXISTS(SELECT 1 FROM track_artists WHERE track_id=? AND role='album_artist')",
        [id],
        |r| r.get(0),
    )?;
    if exists {
        return Ok(());
    }
    let (artist, album_artist): (String, Option<String>) = conn.query_row(
        "SELECT COALESCE(artist,'Unknown Artist'),album_artist FROM tracks WHERE id=?",
        [id],
        |r| Ok((r.get(0)?, r.get(1)?)),
    )?;
    let field = album_artist
        .filter(|s| !s.is_empty())
        .or_else(|| (!artist.is_empty() && artist != "Unknown Artist").then_some(artist));
    if let Some(field) = field {
        let domain = artist_domain(conn)?;
        process_artists_for_field(conn, &domain, &field, id, "album_artist", now)?;
    }
    Ok(())
}
pub(crate) fn rebuild_track_associations(conn: &Connection, id: i64, now: &str) -> DbResult<()> {
    let domain = artist_domain(conn)?;
    rebuild_track_associations_with_domain(conn, &domain, id, now)
}
pub(crate) fn rebuild_track_associations_with_domain(
    conn: &Connection,
    domain: &ArtistDomain,
    id: i64,
    now: &str,
) -> DbResult<()> {
    let (artist,composer):(String,String)=conn.query_row("SELECT COALESCE(artist,'Unknown Artist'),COALESCE(composer,'Unknown Composer') FROM tracks WHERE id=?",[id],|r|Ok((r.get(0)?,r.get(1)?)))?;
    conn.execute("DELETE FROM track_artists WHERE track_id=?", [id])?;

    for (field, role, unknown) in [
        (&artist, "artist", "Unknown Artist"),
        (&composer, "composer", "Unknown Composer"),
    ] {
        if !field.is_empty() && field != unknown {
            process_artists_for_field(conn, &domain, field, id, role, now)?;
        }
    }
    let album_artist: Option<String> =
        conn.query_row("SELECT album_artist FROM tracks WHERE id=?", [id], |r| {
            r.get(0)
        })?;
    let field = album_artist
        .filter(|s| !s.is_empty())
        .or_else(|| (!artist.is_empty() && artist != "Unknown Artist").then_some(artist.clone()));
    if let Some(field) = field {
        process_artists_for_field(conn, domain, &field, id, "album_artist", now)?;
    }
    process_track_album(conn, &domain, id, now)?;
    Ok(())
}
pub(crate) fn rebuild_track_genres(conn: &Connection, id: i64) -> DbResult<()> {
    let genre: String = conn.query_row(
        "SELECT COALESCE(genre,'Unknown Genre') FROM tracks WHERE id=?",
        [id],
        |r| r.get(0),
    )?;
    conn.execute("DELETE FROM track_genres WHERE track_id=?", [id])?;
    if !genre.is_empty() && genre != "Unknown Genre" {
        for name in genre
            .split([';', '/'])
            .map(|s| s.trim_matches(|c: char| c.is_whitespace() || c == '\u{200b}'))
            .filter(|s| !s.is_empty())
        {
            let genre = conn
                .query_row(
                    "SELECT id FROM genres WHERE name=? ORDER BY id LIMIT 1",
                    [name],
                    |r| r.get::<_, i64>(0),
                )
                .optional()?;
            let genre = match genre {
                Some(id) => id,
                None => {
                    conn.execute("INSERT INTO genres(name) VALUES(?)", [name])?;
                    conn.last_insert_rowid()
                }
            };
            conn.execute(
                "INSERT OR IGNORE INTO track_genres(track_id,genre_id) VALUES(?,?)",
                params![id, genre],
            )?;
        }
    }
    Ok(())
}
pub(crate) fn process_track_album(
    conn: &Connection,
    domain: &ArtistDomain,
    id: i64,
    now: &str,
) -> DbResult<()> {
    let (album,artist,owner,compilation):(String,String,Option<String>,bool)=conn.query_row("SELECT COALESCE(album,'Unknown Album'),COALESCE(artist,'Unknown Artist'),album_artist,COALESCE(compilation,0) FROM tracks WHERE id=?",[id],|r|Ok((r.get(0)?,r.get(1)?,r.get(2)?,r.get(3)?)))?;
    if album.is_empty() || album == "Unknown Album" {
        return Ok(());
    }
    let names = domain.parse(
        artist.clone(),
        "Unknown Artist".into(),
        Some("artist".into()),
    );
    let owner = owner
        .filter(|s| !s.is_empty())
        .or_else(|| compilation.then(|| "Various Artists".into()))
        .or_else(|| {
            (!artist.is_empty() && artist != "Unknown Artist")
                .then(|| names.first().cloned())
                .flatten()
        });
    let album_id = find_or_create_album(conn, &album, owner.as_deref(), now)?;
    conn.execute(
        "UPDATE tracks SET album_id=? WHERE id=?",
        params![album_id, id],
    )?;
    let year: Option<String> =
        conn.query_row("SELECT year FROM tracks WHERE id=?", [id], |r| r.get(0))?;
    let release_year = year
        .and_then(|year| year.parse::<i64>().ok())
        .filter(|year| (1900..=2100).contains(year));
    conn.execute("UPDATE albums SET release_year=COALESCE(release_year,?),release_date=COALESCE(release_date,(SELECT release_date FROM tracks WHERE id=?)),total_tracks=CASE WHEN total_tracks IS NOT NULL THEN MAX(total_tracks,COALESCE((SELECT total_tracks FROM tracks WHERE id=?),total_tracks)) END,total_discs=CASE WHEN total_discs IS NOT NULL THEN MAX(total_discs,COALESCE((SELECT total_discs FROM tracks WHERE id=?),total_discs)) END,label=COALESCE(label,(SELECT CASE WHEN json_valid(extended_metadata) THEN json_extract(extended_metadata,'$.label') END FROM tracks WHERE id=?)),updated_at=? WHERE id=?",params![release_year,id,id,id,id,now,album_id])?;
    if !artist.is_empty() && artist != "Unknown Artist" {
        let count: i64 = conn.query_row(
            "SELECT COUNT(*) FROM album_artists WHERE album_id=?",
            [album_id],
            |r| r.get(0),
        )?;
        for (index, name) in names.iter().enumerate() {
            let artist = find_or_create_artist(conn, name, now)?;
            let exists: bool = conn.query_row(
                "SELECT EXISTS(SELECT 1 FROM album_artists WHERE album_id=? AND artist_id=?)",
                params![album_id, artist],
                |r| r.get(0),
            )?;
            if !exists {
                conn.execute(
                    "INSERT INTO album_artists(album_id,artist_id,role,position) VALUES(?,?,?,?)",
                    params![
                        album_id,
                        artist,
                        if count == 0 && index == 0 {
                            "primary"
                        } else {
                            "featured"
                        },
                        count + index as i64
                    ],
                )?;
            }
        }
    }
    Ok(())
}
pub(crate) fn update_artist_stats(conn: &Connection, now: &str) -> DbResult<()> {
    conn.execute("UPDATE artists SET total_tracks=(SELECT COUNT(DISTINCT ta.track_id) FROM track_artists ta JOIN tracks t ON t.id=ta.track_id WHERE ta.artist_id=artists.id AND ta.role='artist' AND t.is_duplicate=0),total_albums=(SELECT COUNT(DISTINCT album_id) FROM album_artists WHERE artist_id=artists.id),updated_at=?",[now])?;
    Ok(())
}
pub(crate) fn update_album_stats(conn: &Connection, now: &str) -> DbResult<()> {
    conn.execute("UPDATE albums SET total_tracks=(SELECT COUNT(*) FROM tracks WHERE album_id=albums.id AND is_duplicate=0),updated_at=?",[now])?;
    Ok(())
}
pub(crate) fn normalize_compilation_albums(conn: &Connection, now: &str) -> DbResult<()> {
    let domain = artist_domain(conn)?;
    let mut buckets: HashMap<(String, String), Vec<(i64, i64, String)>> = HashMap::new();
    let mut stmt=conn.prepare("SELECT id,path,album,album_id,COALESCE(artist,'Unknown Artist') FROM tracks WHERE is_duplicate=0 AND album_id IS NOT NULL ORDER BY id")?;
    for row in stmt.query_map([], |r| {
        Ok((
            r.get::<_, i64>(0)?,
            r.get::<_, String>(1)?,
            r.get::<_, String>(2)?,
            r.get::<_, i64>(3)?,
            r.get::<_, String>(4)?,
        ))
    })? {
        let (id, path, title, album, artist) = row?;
        let title = normalize_album_title(&title);
        if title.is_empty() {
            continue;
        }
        let parent = std::path::Path::new(&path)
            .parent()
            .map(|s| s.to_string_lossy().into_owned())
            .unwrap_or_default();
        buckets
            .entry((parent, title))
            .or_default()
            .push((id, album, artist));
    }
    for tracks in buckets.values() {
        let mut counts: HashMap<i64, usize> = HashMap::new();
        for (_, album, _) in tracks {
            *counts.entry(*album).or_default() += 1;
        }
        if counts.len() < 2 {
            continue;
        }
        let canonical = *counts
            .iter()
            .max_by(|(a, ac), (b, bc)| ac.cmp(bc).then_with(|| b.cmp(a)))
            .unwrap()
            .0;
        // Database-only donor artwork must survive deletion of the empty donor album.
        for (_, album, _) in tracks {
            if *album == canonical {
                continue;
            }
            conn.execute("UPDATE albums SET artwork_data=(SELECT artwork_data FROM albums WHERE id=?),artwork_thumbnail=(SELECT artwork_thumbnail FROM albums WHERE id=?) WHERE id=? AND artwork_data IS NULL",params![album,album,canonical])?;
        }
        for (id, _, _) in tracks {
            conn.execute(
                "UPDATE tracks SET album_id=? WHERE id=? AND album_id!=?",
                params![canonical, id, canonical],
            )?;
        }
        let mut names = Vec::new();
        let mut seen = HashSet::new();
        for (_, _, artist) in tracks {
            if !artist.is_empty() && artist != "Unknown Artist" {
                if let Some(name) = domain
                    .parse(
                        artist.clone(),
                        "Unknown Artist".into(),
                        Some("artist".into()),
                    )
                    .first()
                {
                    if seen.insert(normalize_artist_name(name)) {
                        names.push(name.clone());
                    }
                }
            }
        }
        if names.len() > 1 {
            names.insert(0, "Various Artists".into());
        }
        conn.execute("DELETE FROM album_artists WHERE album_id=?", [canonical])?;
        for (position, name) in names.iter().enumerate() {
            let artist = find_or_create_artist(conn, name, now)?;
            conn.execute("INSERT OR IGNORE INTO album_artists(album_id,artist_id,role,position) VALUES(?,?,?,?)",params![canonical,artist,if position==0 {"primary"}else{"featured"},position as i64])?;
        }
    }
    Ok(())
}
#[uniffi::export]
impl LibraryDatabase {
    pub fn load_scan_artists(&self, content: Option<String>) {
        DOMAIN.load_known_artists(content);
    }
    pub fn unload_scan_artists(&self) {
        DOMAIN.unload_known_artists();
    }
    pub fn normalize_compilation_albums(&self, now: f64) -> DbResult<()> {
        self.write(|c| normalize_compilation_albums(c, &timestamp(now)?))
    }
    pub fn update_entity_stats(&self, now: f64) -> DbResult<()> {
        self.write(|c| {
            let now = timestamp(now)?;
            update_artist_stats(c, &now)?;
            update_album_stats(c, &now)
        })
    }
}
