//! Closed library read operations. List projections deliberately exclude embedded metadata/art.
use crate::database::{DatabaseCell, DatabaseRows, DbResult, LibraryDatabase, query_rows};
use rusqlite::{Connection, OptionalExtension, params, params_from_iter};

pub(crate) const LIGHT_TRACK_COLUMNS: &str = "id,folder_id,path,title,artist,album,composer,genre,year,duration,format,lossless,codec,bitrate,sample_rate,channels,date_added,is_favorite,date_favorited,play_count,last_played_date,album_artist,track_number,disc_number,album_id,is_duplicate";
#[derive(Clone, Debug, uniffi::Record)]
pub struct DatabaseLightTrack {
    pub id: i64,
    pub folder_id: Option<i64>,
    pub path: String,
    pub title: Option<String>,
    pub artist: Option<String>,
    pub album: Option<String>,
    pub composer: Option<String>,
    pub genre: Option<String>,
    pub year: Option<String>,
    pub duration: Option<f64>,
    pub format: Option<String>,
    pub lossless: Option<bool>,
    pub codec: Option<String>,
    pub bitrate: Option<i64>,
    pub sample_rate: Option<i64>,
    pub channels: Option<i64>,
    pub date_added: DatabaseCell,
    pub is_favorite: bool,
    pub date_favorited: DatabaseCell,
    pub play_count: i64,
    pub last_played_date: DatabaseCell,
    pub album_artist: Option<String>,
    pub track_number: Option<i64>,
    pub disc_number: Option<i64>,
    pub album_id: Option<i64>,
    pub is_duplicate: bool,
    pub playlist_date_added: Option<DatabaseCell>,
}
#[derive(Clone, Debug, uniffi::Record)]
pub struct DatabaseTrackRows {
    pub tracks: Vec<DatabaseLightTrack>,
    pub artworks: DatabaseRows,
}
fn light_track(row: &[DatabaseCell], playlist_date: Option<usize>) -> DbResult<DatabaseLightTrack> {
    let string = |index: usize| -> DbResult<String> {
        match &row[index] {
            DatabaseCell::Text { value } => Ok(value.clone()),
            _ => Err(crate::database::invalid(format!(
                "Invalid track text at column {index}"
            ))),
        }
    };
    let optional_string = |index: usize| -> DbResult<Option<String>> {
        if matches!(row[index], DatabaseCell::Null) {
            Ok(None)
        } else {
            string(index).map(Some)
        }
    };
    let optional_integer = |index: usize| -> DbResult<Option<i64>> {
        match &row[index] {
            DatabaseCell::Null => Ok(None),
            DatabaseCell::Integer { value } => Ok(Some(*value)),
            DatabaseCell::Real { value }
                if value.is_finite()
                    && value.fract() == 0.0
                    && *value >= i64::MIN as f64
                    && *value < (i64::MAX as f64) =>
            {
                Ok(Some(*value as i64))
            }
            _ => Err(crate::database::invalid(format!(
                "Invalid track integer at column {index}"
            ))),
        }
    };
    let integer = |index: usize| -> DbResult<i64> {
        optional_integer(index)?.ok_or_else(|| {
            crate::database::invalid(format!("Null track integer at column {index}"))
        })
    };
    let duration = match row[9] {
        DatabaseCell::Integer { value } => Some(value as f64),
        DatabaseCell::Real { value } => Some(value),
        DatabaseCell::Null => None,
        _ => return Err(crate::database::invalid("Invalid track duration")),
    };
    Ok(DatabaseLightTrack {
        id: integer(0)?,
        folder_id: optional_integer(1)?,
        path: string(2)?,
        title: optional_string(3)?,
        artist: optional_string(4)?,
        album: optional_string(5)?,
        composer: optional_string(6)?,
        genre: optional_string(7)?,
        year: optional_string(8)?,
        duration: duration,
        format: optional_string(10)?,
        lossless: optional_integer(11)?.map(|value| value != 0),
        codec: optional_string(12)?,
        bitrate: optional_integer(13)?,
        sample_rate: optional_integer(14)?,
        channels: optional_integer(15)?,
        date_added: row[16].clone(),
        is_favorite: integer(17)? != 0,
        date_favorited: row[18].clone(),
        play_count: integer(19)?,
        last_played_date: row[20].clone(),
        album_artist: optional_string(21)?,
        track_number: optional_integer(22)?,
        disc_number: optional_integer(23)?,
        album_id: optional_integer(24)?,
        is_duplicate: optional_integer(25)?.unwrap_or(0) != 0,
        playlist_date_added: playlist_date.map(|index| row[index].clone()),
    })
}
pub(crate) fn track_projection(_artwork: bool) -> String {
    LIGHT_TRACK_COLUMNS
        .split(',')
        .map(|c| format!("t.{c}"))
        .collect::<Vec<_>>()
        .join(",")
}
pub(crate) fn decorate_tracks(
    conn: &Connection,
    rows: DatabaseRows,
    artwork: bool,
) -> DbResult<DatabaseTrackRows> {
    let mut artworks = DatabaseRows {
        columns: vec!["kind".into(), "id".into(), "artwork".into()],
        rows: vec![],
    };
    if artwork {
        let album_column = rows
            .columns
            .iter()
            .position(|c| c == "album_id")
            .expect("Track projection album ID");
        let id_column = rows
            .columns
            .iter()
            .position(|c| c == "id")
            .expect("Track projection ID");
        let mut album_ids = std::collections::BTreeSet::new();
        for row in &rows.rows {
            if let DatabaseCell::Integer { value } = row[album_column] {
                album_ids.insert(value);
            }
        }
        let albums = query_rows(
            conn,
            &format!(
                "SELECT 'album' AS kind,id,artwork_data AS artwork FROM albums WHERE id IN ({}) AND artwork_data IS NOT NULL",
                marks(album_ids.len())
            ),
            params_from_iter(album_ids),
        )?;
        let covered = albums
            .rows
            .iter()
            .filter_map(|r| {
                if let DatabaseCell::Integer { value } = r[1] {
                    Some(value)
                } else {
                    None
                }
            })
            .collect::<std::collections::HashSet<_>>();
        let track_ids=rows.rows.iter().filter(|r|!matches!(r[album_column],DatabaseCell::Integer{value} if covered.contains(&value))).map(|r|r[id_column].clone()).collect::<Vec<_>>();
        let fallback = query_rows(
            conn,
            &format!(
                "SELECT 'track' AS kind,id,track_artwork_data AS artwork FROM tracks WHERE id IN ({}) AND track_artwork_data IS NOT NULL",
                marks(track_ids.len())
            ),
            params_from_iter(track_ids),
        )?;
        artworks.rows = albums.rows;
        artworks.rows.extend(fallback.rows);
    }
    Ok(DatabaseTrackRows {
        tracks: rows
            .rows
            .iter()
            .map(|row| {
                light_track(
                    row,
                    rows.columns
                        .iter()
                        .position(|column| column == "playlist_date_added"),
                )
            })
            .collect::<DbResult<_>>()?,
        artworks,
    })
}
pub(crate) fn tracks(
    conn: &Connection,
    predicate: &str,
    tail: &str,
    args: Vec<DatabaseCell>,
    artwork: bool,
) -> DbResult<DatabaseTrackRows> {
    let rows = query_rows(
        conn,
        &format!(
            "SELECT {} FROM tracks t WHERE {predicate} {tail}",
            track_projection(false)
        ),
        params_from_iter(args),
    )?;
    decorate_tracks(conn, rows, artwork)
}
fn text(value: String) -> DatabaseCell {
    DatabaseCell::Text { value }
}
fn integer(value: i64) -> DatabaseCell {
    DatabaseCell::Integer { value }
}
pub(crate) fn marks(count: usize) -> String {
    vec!["?"; count].join(",")
}
fn duplicate(hide: bool) -> &'static str {
    if hide { "t.is_duplicate=0" } else { "1" }
}

#[derive(Clone, Copy, Debug, uniffi::Enum)]
pub enum DatabaseFilter {
    Artists,
    AlbumArtists,
    Composers,
    Albums,
    Genres,
    Years,
    Decades,
}
#[derive(Clone, Copy, Debug, uniffi::Enum)]
pub enum DatabaseStatistic {
    TrackCount,
    Duration,
    FileSize,
    ArtistCount,
    AlbumCount,
    Formats,
}

#[uniffi::export]
impl LibraryDatabase {
    pub fn all_tracks(&self, hide_duplicates: bool, artwork: bool) -> DbResult<DatabaseTrackRows> {
        self.read(|c| {
            tracks(
                c,
                duplicate(hide_duplicates),
                "ORDER BY t.title",
                vec![],
                artwork,
            )
        })
    }
    pub fn tracks_by_ids(&self, ids: Vec<i64>, artwork: bool) -> DbResult<DatabaseTrackRows> {
        self.read(|c| {
            tracks(
                c,
                &format!("t.id IN ({})", marks(ids.len())),
                "",
                ids.into_iter().map(integer).collect(),
                artwork,
            )
        })
    }
    pub fn recent_tracks(&self, limit: i64, hide_duplicates: bool) -> DbResult<DatabaseTrackRows> {
        self.read(|c| {
            tracks(
                c,
                &format!(
                    "{} AND t.last_played_date IS NOT NULL",
                    duplicate(hide_duplicates)
                ),
                "ORDER BY t.last_played_date DESC LIMIT ?",
                vec![integer(limit)],
                false,
            )
        })
    }
    pub fn discover_tracks(
        &self,
        limit: i64,
        excluded_ids: Vec<i64>,
        artwork: bool,
    ) -> DbResult<DatabaseTrackRows> {
        self.read(|c| {
            let predicate=format!("t.is_duplicate=0 AND t.is_favorite=0 AND t.id NOT IN ({})",marks(excluded_ids.len()));
            let mut args=excluded_ids.into_iter().map(integer).collect::<Vec<_>>(); args.push(integer(limit));
            let mut rows=query_rows(c,&format!("SELECT {} FROM tracks t WHERE {predicate} AND t.play_count=0 ORDER BY RANDOM() LIMIT ?",track_projection(false)),params_from_iter(args.clone()))?;
            if (rows.rows.len() as i64)<limit {args.pop(); let ids=rows.rows.iter().map(|row|row[0].clone()).collect::<Vec<_>>(); args.extend(ids.clone()); args.push(integer(limit-rows.rows.len() as i64));
                let more=query_rows(c,&format!("SELECT {} FROM tracks t WHERE {predicate} AND t.id NOT IN ({}) ORDER BY t.last_played_date,t.play_count LIMIT ?",track_projection(false),marks(ids.len())),params_from_iter(args))?;
                rows.rows.extend(more.rows);
            }
            decorate_tracks(c,rows,artwork)
        })
    }
    pub fn full_track(&self, id: i64) -> DbResult<DatabaseRows> {
        self.read(|c| query_rows(c, "SELECT * FROM tracks WHERE id=?", params![id]))
    }
    pub fn tracks_for_filter(
        &self,
        kind: DatabaseFilter,
        value: String,
        normalized_name: String,
        album_id: Option<i64>,
        hide_duplicates: bool,
        role_only: bool,
        artwork: bool,
    ) -> DbResult<DatabaseTrackRows> {
        self.read(|c| {
            let mut args = vec![];
            let predicate = match kind {
                DatabaseFilter::Artists | DatabaseFilter::AlbumArtists | DatabaseFilter::Composers => {
                    let (column,role,unknown) = match kind { DatabaseFilter::Artists => ("artist","artist","Unknown Artist"),DatabaseFilter::AlbumArtists => ("album_artist","album_artist","Unknown Album Artist"),_ => ("composer","composer","Unknown Composer") };
                    if !role_only && value==unknown { args.push(text(value)); format!("t.{column}=?") } else {
                        args.extend([text(value),text(normalized_name)]);
                        let role_clause = if role_only { args.push(text(role.into())); "AND role=?" } else { "" };
                        format!("t.id IN (SELECT track_id FROM track_artists WHERE artist_id=(SELECT id FROM artists WHERE name=? OR normalized_name=? LIMIT 1) {role_clause})")
                    }
                }
                DatabaseFilter::Albums => if let Some(id)=album_id {args.push(integer(id)); "t.album_id=?".into()} else {args.push(text(value)); "t.album=?".into()},
                DatabaseFilter::Genres | DatabaseFilter::Years => {
                    let column=if matches!(kind,DatabaseFilter::Genres) {"genre"} else {"year"};
                    let unknown=if matches!(kind,DatabaseFilter::Genres) {"Unknown Genre"} else {"Unknown Year"};
                    let is_unknown=value==unknown; args.push(text(value));
                    if is_unknown {format!("(t.{column} IS NULL OR t.{column}='' OR t.{column}=?)")} else {format!("t.{column}=?")}
                }
                DatabaseFilter::Decades => if value=="Unknown Decade" {"(t.year IS NULL OR t.year='' OR t.year='Unknown Year')".into()} else if let Ok(year)=value.replace('s',"").parse::<i64>() {args.extend([text(year.to_string()),text((year+9).to_string())]); "t.year>=? AND t.year<=?".into()} else {"0".into()},
            };
            tracks(c,&format!("({predicate}) AND {}",duplicate(hide_duplicates)),"",args,artwork)
        })
    }
    pub fn tracks_for_artist(
        &self,
        name: String,
        normalized_name: String,
        hide_duplicates: bool,
        artwork: bool,
    ) -> DbResult<DatabaseTrackRows> {
        self.read(|c| tracks(c,&format!("{} AND t.id IN (SELECT track_id FROM track_artists WHERE role='artist' AND artist_id=(SELECT id FROM artists WHERE name=? OR normalized_name=? LIMIT 1))",duplicate(hide_duplicates)),"ORDER BY t.album,IFNULL(t.disc_number,1),IFNULL(t.track_number,0)",vec![text(name),text(normalized_name)],artwork))
    }
    pub fn tracks_for_album(
        &self,
        id: Option<i64>,
        title: String,
        artist: Option<String>,
        hide_duplicates: bool,
        artwork: bool,
    ) -> DbResult<DatabaseTrackRows> {
        self.read(|c| {
            let mut args = vec![];
            let predicate = if let Some(id) = id {
                args.push(integer(id));
                "t.album_id=?".into()
            } else {
                args.push(text(title));
                if let Some(artist) = artist {
                    args.push(text(artist));
                    "t.album=? AND t.album_artist=?".to_string()
                } else {
                    "t.album=?".into()
                }
            };
            tracks(
                c,
                &format!("({predicate}) AND {}", duplicate(hide_duplicates)),
                "ORDER BY IFNULL(t.disc_number,1),IFNULL(t.track_number,0)",
                args,
                artwork,
            )
        })
    }
    pub fn search_tracks(
        &self,
        search_text: String,
        hide_duplicates: bool,
    ) -> DbResult<DatabaseTrackRows> {
        self.read(|c| {
            let mut stmt = c.prepare(
                "SELECT track_id FROM tracks_fts WHERE tracks_fts MATCH ? ORDER BY rank",
            )?;
            let ids = stmt
                .query_map([crate::query::library_fts_query(search_text)], |r| {
                    r.get::<_, i64>(0)
                })?
                .collect::<Result<Vec<_>, _>>()?;
            tracks(
                c,
                &format!(
                    "{} AND t.id IN ({})",
                    duplicate(hide_duplicates),
                    marks(ids.len())
                ),
                "",
                ids.into_iter().map(integer).collect(),
                false,
            )
        })
    }
    pub fn track_by_path(&self, path: String) -> DbResult<DatabaseTrackRows> {
        self.read(|c| {
            let exact = tracks(c, "t.path=?", "LIMIT 1", vec![text(path.clone())], false)?;
            if !exact.tracks.is_empty() {
                Ok(exact)
            } else {
                tracks(
                    c,
                    "t.path COLLATE NOCASE=?",
                    "LIMIT 1",
                    vec![text(path)],
                    false,
                )
            }
        })
    }
    pub fn tracks_by_filenames(&self, filenames: Vec<String>) -> DbResult<DatabaseTrackRows> {
        self.read(|c| {
            let wanted = filenames
                .into_iter()
                .collect::<std::collections::HashSet<_>>();
            let mut statement = c.prepare("SELECT id,filename FROM tracks")?;
            let stored =
                statement.query_map([], |r| Ok((r.get::<_, i64>(0)?, r.get::<_, String>(1)?)))?;
            let mut ids = Vec::new();
            for row in stored {
                let (id, name) = row?;
                if wanted.contains(&name.to_lowercase()) {
                    ids.push(integer(id));
                }
            }
            tracks(
                c,
                &format!("t.id IN ({})", marks(ids.len())),
                "",
                ids,
                false,
            )
        })
    }
    pub fn stored_filenames(&self) -> DbResult<Vec<String>> {
        self.read(|c| {
            let mut s = c.prepare("SELECT filename FROM tracks")?;
            Ok(s.query_map([], |r| r.get(0))?.collect::<Result<_, _>>()?)
        })
    }
    pub fn track_play_count(&self, id: i64) -> DbResult<Option<i64>> {
        self.read(|c| {
            Ok(
                c.query_row("SELECT play_count FROM tracks WHERE id=?", [id], |r| {
                    r.get(0)
                })
                .optional()?
                .flatten(),
            )
        })
    }
    pub fn track_exists(&self, id: i64) -> DbResult<bool> {
        self.read(|c| {
            Ok(
                c.query_row("SELECT COUNT(*)>0 FROM tracks WHERE id=?", [id], |r| {
                    r.get(0)
                })?,
            )
        })
    }
    pub fn folder_track_count(&self, id: i64) -> DbResult<i64> {
        self.read(|c| {
            Ok(
                c.query_row("SELECT COUNT(*) FROM tracks WHERE folder_id=?", [id], |r| {
                    r.get(0)
                })?,
            )
        })
    }
    pub fn library_statistic(
        &self,
        kind: DatabaseStatistic,
        hide_duplicates: bool,
    ) -> DbResult<DatabaseRows> {
        self.read(|c| {
            let sql=match kind {
                DatabaseStatistic::ArtistCount=>"SELECT COUNT(*) AS value FROM artists WHERE total_tracks>0".into(),
                DatabaseStatistic::AlbumCount=>"SELECT COUNT(*) AS value FROM albums WHERE total_tracks>0".into(),
                DatabaseStatistic::Formats=>format!("SELECT LOWER(format) AS fmt,COUNT(format) AS cnt FROM tracks t WHERE {} GROUP BY LOWER(format)",duplicate(hide_duplicates)),
                _=>format!("SELECT {} AS value FROM tracks t WHERE {}",match kind {DatabaseStatistic::TrackCount=>"COUNT(*)",DatabaseStatistic::Duration=>"COALESCE(SUM(duration),0.0)",_=>"COALESCE(SUM(file_size),0)"},duplicate(hide_duplicates)),
            }; query_rows(c,&sql,[])
        })
    }
    pub fn artist_names_by_role(&self) -> DbResult<DatabaseRows> {
        self.read(|c|query_rows(c,"SELECT DISTINCT ta.role AS role,a.normalized_name AS lookup,a.name AS canonical FROM artists a JOIN track_artists ta ON ta.artist_id=a.id UNION ALL SELECT DISTINCT ta.role,al.normalized_alias,a.name FROM artist_aliases al JOIN artists a ON a.id=al.canonical_artist_id JOIN track_artists ta ON ta.artist_id=a.id",[]))
    }
    pub fn artist_id(&self, name: String, normalized_name: String) -> DbResult<Option<i64>> {
        self.read(|c| {
            Ok(c.query_row(
                "SELECT id FROM artists WHERE name=? OR normalized_name=? LIMIT 1",
                params![name, normalized_name],
                |r| r.get(0),
            )
            .optional()?)
        })
    }
    pub fn artist_info(
        &self,
        name: String,
        normalized_name: String,
        requires_fetched_image: bool,
    ) -> DbResult<DatabaseRows> {
        self.read(|c|query_rows(c,"SELECT CASE WHEN ? AND image_source IS NULL THEN NULL ELSE artwork_data END AS artwork_data,bio FROM artists WHERE name=? OR normalized_name=? LIMIT 1",params![requires_fetched_image,name,normalized_name]))
    }
    pub fn artwork(
        &self,
        album_id: Option<i64>,
        track_id: Option<i64>,
    ) -> DbResult<Option<Vec<u8>>> {
        self.read(|c|Ok(c.query_row("SELECT COALESCE((SELECT artwork_data FROM albums WHERE id=?),(SELECT track_artwork_data FROM tracks WHERE id=?))",params![album_id,track_id],|r|r.get(0))?))
    }
    pub fn album_thumbnail(&self, id: i64) -> DbResult<Option<Vec<u8>>> {
        self.read(|c| {
            Ok(c.query_row(
                "SELECT artwork_thumbnail FROM albums WHERE id=?",
                [id],
                |r| r.get(0),
            )
            .optional()?
            .flatten())
        })
    }
    pub fn artist_thumbnail(
        &self,
        name: String,
        requires_fetched_image: bool,
    ) -> DbResult<Option<Vec<u8>>> {
        self.read(|c|Ok(c.query_row("SELECT CASE WHEN ? AND image_source IS NULL THEN NULL ELSE COALESCE(artwork_thumbnail,artwork_data) END FROM artists WHERE name=? LIMIT 1",params![requires_fetched_image,name],|r|r.get(0)).optional()?.flatten()))
    }
    pub fn artwork_batch(
        &self,
        album_ids: Vec<i64>,
        track_ids: Vec<i64>,
        track_album_ids: Vec<Option<i64>>,
    ) -> DbResult<DatabaseRows> {
        if track_ids.len() != track_album_ids.len() {
            return Err(crate::database::invalid(
                "Artwork IDs have different widths",
            ));
        }
        self.read(|c| {
            let requested=if track_ids.is_empty() {"SELECT NULL AS id,NULL AS album_id WHERE 0".to_string()} else {format!("VALUES {}",vec!["(?,?)";track_ids.len()].join(","))};
            let sql=format!("WITH requested(id,album_id) AS ({requested}) SELECT 'album' AS kind,id,artwork_data AS artwork FROM albums WHERE id IN ({}) UNION ALL SELECT 'track' AS kind,t.id,t.track_artwork_data AS artwork FROM tracks t JOIN requested r ON r.id=t.id WHERE t.track_artwork_data IS NOT NULL AND NOT EXISTS(SELECT 1 FROM albums WHERE albums.id=r.album_id AND albums.artwork_data IS NOT NULL)",marks(album_ids.len()));
            let mut args=Vec::new();
            for (id,album_id) in track_ids.into_iter().zip(track_album_ids) {args.push(integer(id));args.push(album_id.map(integer).unwrap_or(DatabaseCell::Null));}
            args.extend(album_ids.into_iter().map(integer));
            query_rows(c,&sql,params_from_iter(args))
        })
    }
    pub fn album_artworks(&self, ids: Vec<i64>, thumbnail: bool) -> DbResult<DatabaseRows> {
        self.read(|c| {
            query_rows(
                c,
                &format!(
                    "SELECT id,{} AS artwork FROM albums WHERE id IN ({})",
                    if thumbnail {
                        "artwork_thumbnail"
                    } else {
                        "artwork_data"
                    },
                    marks(ids.len())
                ),
                params_from_iter(ids),
            )
        })
    }
    pub fn track_artworks(&self, ids: Vec<i64>) -> DbResult<DatabaseRows> {
        self.read(|c|query_rows(c,&format!("SELECT id,track_artwork_data AS artwork FROM tracks WHERE id IN ({}) AND track_artwork_data IS NOT NULL",marks(ids.len())),params_from_iter(ids)))
    }
}

#[uniffi::export]
impl LibraryDatabase {
    pub fn artist_entities(&self, hide_duplicates: bool) -> DbResult<DatabaseRows> {
        self.read(|c| { let duplicate_clause=if hide_duplicates {"AND tracks.is_duplicate = 0"} else {""};
 let sql = r#"SELECT artists.name, COUNT(DISTINCT track_artists.track_id) as trackCount FROM artists JOIN track_artists ON track_artists.artist_id = artists.id AND track_artists.role = 'artist' JOIN tracks ON tracks.id = track_artists.track_id {duplicate_clause} GROUP BY artists.id HAVING trackCount > 0 ORDER BY artists.sort_name"#.replace("{duplicate_clause}",duplicate_clause);
query_rows(c,&sql,[]) })
    }
    pub fn album_entities(&self, hide_duplicates: bool) -> DbResult<DatabaseRows> {
        self.read(|c| { let duplicate_clause=if hide_duplicates {"AND tracks.is_duplicate = 0"} else {""};
 let sql = r#"SELECT albums.id, albums.title, COUNT(tracks.id) as trackCount, albums.release_year, COALESCE( (SELECT artists.name FROM album_artists JOIN artists ON artists.id = album_artists.artist_id WHERE album_artists.album_id = albums.id AND album_artists.role = 'primary' ORDER BY album_artists.position LIMIT 1), NULLIF(MAX(tracks.album_artist), ''), MAX(tracks.artist) ) as artistName FROM albums LEFT JOIN tracks ON albums.id = tracks.album_id {duplicate_clause} GROUP BY albums.id HAVING trackCount > 0 ORDER BY albums.sort_title"#.replace("{duplicate_clause}",duplicate_clause);
query_rows(c,&sql,[]) })
    }
    pub fn artist_filter_items(&self, hide_duplicates: bool) -> DbResult<DatabaseRows> {
        self.read(|c| { let duplicate_clause=if hide_duplicates {"AND t.is_duplicate = 0"} else {""};
 let sql = r#"SELECT a.name, a.sort_name, COUNT(DISTINCT ta.track_id) as track_count FROM artists a INNER JOIN track_artists ta ON a.id = ta.artist_id INNER JOIN tracks t ON ta.track_id = t.id WHERE ta.role = 'artist' {duplicate_clause} GROUP BY a.id, a.name, a.sort_name HAVING track_count > 0 UNION ALL SELECT 'Unknown Artist' as name, 'Unknown Artist' as sort_name, COUNT(*) as track_count FROM tracks t WHERE t.artist = 'Unknown Artist' {duplicate_clause} HAVING COUNT(*) > 0 ORDER BY sort_name COLLATE NOCASE"#.replace("{duplicate_clause}",duplicate_clause);
query_rows(c,&sql,[]) })
    }
    pub fn album_filter_items(&self, hide_duplicates: bool) -> DbResult<DatabaseRows> {
        self.read(|c| { let duplicate_clause=if hide_duplicates {"AND t.is_duplicate = 0"} else {""};
 let albums = if hide_duplicates { r#"SELECT a.title as name, a.sort_title, COUNT(DISTINCT CASE WHEN t.is_duplicate = 0 THEN t.id END) as track_count, a.id as id FROM albums a LEFT JOIN tracks t ON a.id = t.album_id GROUP BY a.id, a.title, a.sort_title HAVING track_count > 0"# } else { r#"SELECT title as name, sort_title, total_tracks as track_count, id FROM albums WHERE total_tracks > 0"# };
let unknown = r#"SELECT 'Unknown Album' as name, 'Unknown Album' as sort_title, COUNT(*) as track_count, NULL as id FROM tracks t WHERE t.album = 'Unknown Album' {duplicate_clause} GROUP BY t.album"#;
let sql = format!("{albums} UNION ALL {} ORDER BY sort_title COLLATE NOCASE",unknown.replace("{duplicate_clause}",duplicate_clause));
query_rows(c,&sql,[]) })
    }
    pub fn album_artist_filter_items(&self, hide_duplicates: bool) -> DbResult<DatabaseRows> {
        self.read(|c| { let duplicate_clause=if hide_duplicates {"AND t.is_duplicate = 0"} else {""};
 let sql = r#"SELECT a.name, a.sort_name, COUNT(DISTINCT ta.track_id) as track_count FROM artists a INNER JOIN track_artists ta ON a.id = ta.artist_id INNER JOIN tracks t ON ta.track_id = t.id WHERE ta.role = 'album_artist' {duplicate_clause} GROUP BY a.id, a.name, a.sort_name HAVING track_count > 0 UNION ALL SELECT 'Unknown Album Artist' as name, 'Unknown Album Artist' as sort_name, COUNT(*) as track_count FROM tracks t WHERE t.album_artist = 'Unknown Album Artist' {duplicate_clause} HAVING COUNT(*) > 0 ORDER BY sort_name COLLATE NOCASE"#.replace("{duplicate_clause}",duplicate_clause);
query_rows(c,&sql,[]) })
    }
    pub fn composer_filter_items(&self, hide_duplicates: bool) -> DbResult<DatabaseRows> {
        self.read(|c| { let duplicate_clause=if hide_duplicates {"AND t.is_duplicate = 0"} else {""};
 let sql = r#"SELECT a.name, a.sort_name, COUNT(DISTINCT ta.track_id) as track_count FROM artists a INNER JOIN track_artists ta ON a.id = ta.artist_id INNER JOIN tracks t ON ta.track_id = t.id WHERE ta.role = 'composer' {duplicate_clause} GROUP BY a.id, a.name, a.sort_name HAVING track_count > 0 UNION ALL SELECT 'Unknown Composer' as name, 'Unknown Composer' as sort_name, COUNT(*) as track_count FROM tracks t WHERE t.composer = 'Unknown Composer' {duplicate_clause} HAVING COUNT(*) > 0 ORDER BY sort_name COLLATE NOCASE"#.replace("{duplicate_clause}",duplicate_clause);
query_rows(c,&sql,[]) })
    }
    pub fn genre_filter_items(&self, hide_duplicates: bool) -> DbResult<DatabaseRows> {
        self.read(|c| { let duplicate_clause=if hide_duplicates {"AND is_duplicate = 0"} else {""};
 let sql = r#"SELECT genre as name, COUNT(*) as track_count FROM tracks WHERE genre IS NOT NULL AND genre != '' AND genre != 'Unknown Genre' {duplicate_clause} GROUP BY genre UNION ALL SELECT 'Unknown Genre' as name, COUNT(*) as track_count FROM tracks WHERE (genre IS NULL OR genre = '' OR genre = 'Unknown Genre') {duplicate_clause} HAVING COUNT(*) > 0 ORDER BY name COLLATE NOCASE"#.replace("{duplicate_clause}",duplicate_clause);
query_rows(c,&sql,[]) })
    }
    pub fn decade_filter_items(&self, hide_duplicates: bool) -> DbResult<DatabaseRows> {
        self.read(|c| { let duplicate_clause=if hide_duplicates {"AND is_duplicate = 0"} else {""};
 let sql = r#"SELECT CASE WHEN year IS NULL OR year = '' OR year = 'Unknown Year' THEN 'Unknown Decade' ELSE SUBSTR(year, 1, 3) || '0s' END as decade, COUNT(*) as track_count FROM tracks WHERE 1=1 {duplicate_clause} GROUP BY decade HAVING track_count > 0 ORDER BY CASE WHEN decade = 'Unknown Decade' THEN '9999' ELSE decade END DESC"#.replace("{duplicate_clause}",duplicate_clause);
query_rows(c,&sql,[]) })
    }
    pub fn year_filter_items(&self, hide_duplicates: bool) -> DbResult<DatabaseRows> {
        self.read(|c| { let duplicate_clause=if hide_duplicates {"AND is_duplicate = 0"} else {""};
 let sql = r#"SELECT year as name, COUNT(*) as track_count FROM tracks WHERE year IS NOT NULL AND year != '' AND year != 'Unknown Year' {duplicate_clause} GROUP BY year UNION ALL SELECT 'Unknown Year' as name, COUNT(*) as track_count FROM tracks WHERE (year IS NULL OR year = '' OR year = 'Unknown Year') {duplicate_clause} HAVING COUNT(*) > 0 ORDER BY name DESC"#.replace("{duplicate_clause}",duplicate_clause);
query_rows(c,&sql,[]) })
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    fn fixture() -> std::sync::Arc<LibraryDatabase> {
        let path =
            std::env::temp_dir().join(format!("petrichor-read-{}.sqlite", uuid::Uuid::new_v4()));
        let db = LibraryDatabase::open(path.to_string_lossy().into()).unwrap();
        db.write(|c| {
            c.execute_batch("INSERT INTO folders(id,name,path,date_added,date_updated) VALUES(1,'Fixture','/fixture','2026-01-01 00:00:00.000','2026-01-01 00:00:00.000'); INSERT INTO albums(id,title,normalized_title,sort_title,artwork_data,artwork_thumbnail,total_tracks,created_at,updated_at) VALUES(1,'Shared','shared','Shared',X'0102',X'03',9,'2026-01-01 00:00:00.000','2026-01-01 00:00:00.000'),(2,'Shared','shared2','Shared',NULL,NULL,1,'2026-01-01 00:00:00.000','2026-01-01 00:00:00.000');
                INSERT INTO artists(id,name,normalized_name,sort_name,total_tracks,created_at,updated_at) VALUES(1,'Artist','artist','Artist',10,'2026-01-01 00:00:00.000','2026-01-01 00:00:00.000');
                INSERT INTO tracks(folder_id,date_added,id,path,filename,title,artist,album,composer,genre,year,duration,format,is_favorite,is_duplicate,play_count,album_id,album_artist,track_artwork_data) VALUES
                  (1,'2026-01-01 00:00:00.000',1,'/a/one.mp3','one.mp3','Zed','Artist','Shared','Unknown Composer',NULL,NULL,61.9,'MP3',0,0,0,1,'Artist',X'09'),
                  (1,'2026-01-01 00:00:00.000',2,'/b/two.mp3','two.mp3','Alpha','Artist','Shared','Unknown Composer','','',62.0,'mp3',1,1,2,1,'Artist',X'08'),
                  (1,'2026-01-01 00:00:00.000',3,'/c/Three.mp3','Три.mp3','Beta','Other','Shared','Unknown Composer','Rock','1990',1.0,'MP3',0,0,1,2,'Other',X'07');
                INSERT INTO track_artists(track_id,artist_id,role,position) VALUES(1,1,'artist',0),(2,1,'artist',0),(3,1,'composer',0);")?;
            Ok(())
        }).unwrap();
        db
    }
    fn ids(rows: DatabaseTrackRows) -> Vec<i64> {
        rows.tracks.iter().map(|track| track.id).collect()
    }
    #[test]
    fn projections_artwork_identity_and_duplicates() {
        let db = fixture();
        let light = db.all_tracks(true, false).unwrap();
        assert_eq!(LIGHT_TRACK_COLUMNS.split(',').count(), 26);
        assert!(light.artworks.rows.is_empty());
        assert_eq!(ids(light), vec![3, 1]);
        let stale = db.artwork_batch(vec![], vec![1], vec![None]).unwrap();
        assert_eq!(
            stale.rows[0][2],
            DatabaseCell::Blob {
                value: vec![9].into()
            }
        );
        let batch = db
            .artwork_batch(vec![1], vec![1, 3], vec![Some(1), Some(2)])
            .unwrap();
        assert_eq!(batch.rows.len(), 2);
        assert!(db.artwork_batch(vec![], vec![1], vec![]).is_err());
        assert_eq!(ids(db.tracks_by_ids(vec![2], false).unwrap()), vec![2]);
        assert_eq!(
            db.tracks_by_ids(vec![1, 2], true)
                .unwrap()
                .artworks
                .rows
                .len(),
            1
        );
        let artwork = db.tracks_by_ids(vec![1, 3], true).unwrap();
        assert_eq!(
            artwork.artworks.rows[0].last(),
            Some(&DatabaseCell::Blob {
                value: vec![1, 2].into()
            })
        );
        assert_eq!(
            artwork.artworks.rows[1].last(),
            Some(&DatabaseCell::Blob {
                value: vec![7].into()
            })
        );
        assert_eq!(
            ids(db
                .tracks_for_album(
                    Some(2),
                    "Shared".into(),
                    Some("Artist".into()),
                    false,
                    false
                )
                .unwrap()),
            vec![3]
        );
        assert_eq!(
            ids(db
                .tracks_for_filter(
                    DatabaseFilter::Artists,
                    "Artist".into(),
                    "artist".into(),
                    None,
                    false,
                    false,
                    false
                )
                .unwrap()),
            vec![1, 2, 3]
        );
        assert_eq!(
            ids(db
                .tracks_for_filter(
                    DatabaseFilter::Artists,
                    "Artist".into(),
                    "artist".into(),
                    None,
                    false,
                    true,
                    false
                )
                .unwrap()),
            vec![1, 2]
        );
        assert_eq!(
            ids(db
                .tracks_for_filter(
                    DatabaseFilter::Genres,
                    "Unknown Genre".into(),
                    "".into(),
                    None,
                    false,
                    false,
                    false
                )
                .unwrap()),
            vec![1, 2]
        );
        assert_eq!(
            ids(db.track_by_path("/C/three.MP3".into()).unwrap()),
            vec![3]
        );
        assert_eq!(
            ids(db.tracks_by_filenames(vec!["три.mp3".into()]).unwrap()),
            vec![3]
        );
    }
    #[test]
    fn categories_and_discover_preserve_special_counts() {
        let db = fixture();
        assert_eq!(db.artist_entities(true).unwrap().rows.len(), 1);
        let artist = db.artist_entities(true).unwrap();
        assert_eq!(artist.rows[0][1], DatabaseCell::Integer { value: 1 });
        let albums = db.album_filter_items(false).unwrap();
        assert_eq!(albums.rows[0][2], DatabaseCell::Integer { value: 9 });
        let live = db.album_filter_items(true).unwrap();
        assert_eq!(live.rows[0][2], DatabaseCell::Integer { value: 1 });
        assert_eq!(
            ids(db.discover_tracks(10, vec![3], false).unwrap()),
            vec![1]
        );
        assert!(db.search_tracks("".into(), false).is_err());
    }
}
