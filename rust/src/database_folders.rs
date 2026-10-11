//! Folder identity, guarded bookmarks, relocation and selection policy.
use crate::database::{DatabaseRows, DbResult, LibraryDatabase, invalid, query_rows, timestamp};
use rusqlite::{OptionalExtension, params};

#[derive(Clone, uniffi::Record)]
pub struct FolderObservation {
    pub path: String,
    pub name: String,
    pub bookmark: Option<Vec<u8>>,
    pub modified: Option<f64>,
}
#[derive(Clone, uniffi::Record)]
pub struct LibraryFileObservation {
    pub path: String,
    pub extension: String,
    pub basename: String,
    pub regular: bool,
    pub readable: bool,
    pub size: Option<i64>,
    pub modified: Option<f64>,
}
#[derive(uniffi::Record)]
pub struct LibraryManifest {
    pub audio_paths: Vec<String>,
    pub artwork_paths: Vec<String>,
    pub unsupported_paths: Vec<String>,
    pub failed_paths: Vec<String>,
}

pub(crate) fn rebased_path(path: &str, old: &str, new: &str) -> Option<String> {
    if path == old {
        return Some(new.into());
    }
    let prefix = format!("{}/", old.trim_end_matches('/'));
    path.strip_prefix(&prefix)
        .map(|tail| format!("{}/{}", new.trim_end_matches('/'), tail))
}
#[uniffi::export]
impl LibraryDatabase {
    pub fn add_folders(&self, folders: Vec<FolderObservation>, now: f64) -> DbResult<DatabaseRows> {
        self.write(|c|{let now=timestamp(now)?;let mut ids=Vec::new();
            for folder in folders {
                if let Some(id)=c.query_row("SELECT id FROM folders WHERE path=? ORDER BY id LIMIT 1",[&folder.path],|r|r.get::<_,i64>(0)).optional()? {
                    c.execute("UPDATE folders SET bookmark_data=? WHERE id=?",params![folder.bookmark,id])?;ids.push(id);
                }else {
                    let modified=folder.modified.map(timestamp).transpose()?.unwrap_or(now.clone());
                    c.execute("INSERT INTO folders(path,name,track_count,date_added,date_updated,bookmark_data) VALUES(?,?,0,?,?,?)",params![folder.path,folder.name,now,modified,folder.bookmark])?;ids.push(c.last_insert_rowid());
                }
            }
            let mut out=DatabaseRows{columns:Vec::new(),rows:Vec::new()};
            for id in ids {let rows=query_rows(c,"SELECT * FROM folders WHERE id=?",[id])?;out.columns=rows.columns;out.rows.extend(rows.rows);}
            if out.columns.is_empty(){out=query_rows(c,"SELECT * FROM folders WHERE 0",[])?;}
            Ok(out)
        })
    }
    pub fn all_folders(&self) -> DbResult<DatabaseRows> {
        self.read(|c| query_rows(c, "SELECT * FROM folders ORDER BY name", []))
    }
    pub fn folder(&self, id: i64) -> DbResult<DatabaseRows> {
        self.read(|c| query_rows(c, "SELECT * FROM folders WHERE id=?", [id]))
    }
    pub fn remove_folder(&self, id: i64) -> DbResult<()> {
        self.write(|c| {
            c.execute("DELETE FROM folders WHERE id=?", [id])?;
            crate::database_mutations::cleanup_orphaned_data(c)
        })
    }
    pub fn update_folder_bookmark(
        &self,
        id: i64,
        expected_path: String,
        bookmark: Vec<u8>,
    ) -> DbResult<()> {
        self.write(|c| {
            c.execute(
                "UPDATE folders SET bookmark_data=? WHERE id=? AND path=?",
                params![bookmark, id, expected_path],
            )?;
            Ok(())
        })
    }
    pub fn relocate_folder(
        &self,
        id: i64,
        old_path: String,
        new_path: String,
        new_name: String,
        bookmark: Vec<u8>,
    ) -> DbResult<DatabaseRows> {
        self.write(|c| {
            if old_path == new_path {
                return query_rows(c, "SELECT * FROM folders WHERE id=?", [id]);
            }
            let stored: String =
                c.query_row("SELECT path FROM folders WHERE id=?", [id], |r| r.get(0))?;
            if stored != old_path {
                return Err(invalid("Folder path changed during relocation"));
            }
            let watched: bool = c.query_row(
                "SELECT EXISTS(SELECT 1 FROM folders WHERE path=? AND id!=?)",
                params![new_path, id],
                |r| r.get(0),
            )?;
            if watched {
                return Err(invalid("Destination folder is already watched"));
            }
            let tracks = {
                let mut s =
                    c.prepare("SELECT id,path FROM tracks WHERE folder_id=? ORDER BY id")?;
                s.query_map([id], |r| Ok((r.get::<_, i64>(0)?, r.get::<_, String>(1)?)))?
                    .collect::<Result<Vec<_>, _>>()?
            };
            let mut updates = Vec::new();
            for (track, path) in tracks {
                let path = rebased_path(&path, &old_path, &new_path)
                    .ok_or_else(|| invalid("Track path is outside watched folder"))?;
                let conflict: bool = c.query_row(
                    "SELECT EXISTS(SELECT 1 FROM tracks WHERE path=? AND folder_id!=?)",
                    params![path, id],
                    |r| r.get(0),
                )?;
                if conflict {
                    return Err(invalid("Track path conflicts with another watched folder"));
                }
                updates.push((track, path));
            }
            for (track, path) in updates {
                c.execute("UPDATE tracks SET path=? WHERE id=?", params![path, track])?;
            }
            c.execute(
                "UPDATE folders SET path=?,name=?,bookmark_data=? WHERE id=?",
                params![new_path, new_name, bookmark, id],
            )?;
            query_rows(c, "SELECT * FROM folders WHERE id=?", [id])
        })
    }
    pub fn update_folder_metadata(
        &self,
        id: i64,
        modified: f64,
        hash: Option<String>,
        count_duplicates: bool,
    ) -> DbResult<()> {
        self.write(|c|{c.execute("UPDATE folders SET date_updated=?,shasum_hash=COALESCE(?,shasum_hash),track_count=(SELECT COUNT(*) FROM tracks WHERE folder_id=? AND (? OR is_duplicate=0)) WHERE id=?",params![timestamp(modified)?,hash,id,count_duplicates,id])?;Ok(())})
    }
    pub fn folder_needs_refresh(
        &self,
        id: i64,
        hard: bool,
        modified: Option<f64>,
        hash: Option<String>,
    ) -> DbResult<bool> {
        self.read(|c|{if hard{return Ok(true);}
            let state:Option<(Option<f64>,Option<String>)>=c.query_row("SELECT (julianday(date_updated)-2440587.5)*86400,shasum_hash FROM folders WHERE id=?",[id],|r|Ok((r.get(0)?,r.get(1)?))).optional()?;
            let Some((old_date,old_hash))=state else{return Ok(true);};
            if let (Some(disk),Some(stored))=(modified,old_date){if disk>stored{return Ok(true);}}
            Ok(hash.is_none() || old_hash.is_none() || hash!=old_hash)
        })
    }
    pub fn classify_library_files(
        &self,
        files: Vec<LibraryFileObservation>,
        supported: Vec<String>,
        unsupported: Vec<String>,
        art_extensions: Vec<String>,
        art_names: Vec<String>,
        root_available: bool,
    ) -> DbResult<LibraryManifest> {
        if !root_available {
            return Err(invalid("Folder is unavailable or unreadable"));
        }
        let mut out = LibraryManifest {
            audio_paths: vec![],
            artwork_paths: vec![],
            unsupported_paths: vec![],
            failed_paths: vec![],
        };
        let mut audio = std::collections::HashSet::new();
        let mut art_dirs = std::collections::HashSet::new();
        for file in files {
            if !file.regular {
                continue;
            }
            let ext = file.extension.to_lowercase();
            if supported.contains(&ext) {
                if !file.readable {
                    out.failed_paths.push(file.path.clone());
                    continue;
                }
                if audio.insert(file.path.clone()) {
                    out.audio_paths.push(file.path.clone());
                }
            } else if unsupported.contains(&ext) {
                out.unsupported_paths.push(file.path.clone());
            }
            if art_extensions.contains(&ext) && art_names.contains(&file.basename) {
                let parent = std::path::Path::new(&file.path)
                    .parent()
                    .map(|p| p.to_string_lossy().into_owned())
                    .unwrap_or_default();
                if art_dirs.insert(parent) {
                    out.artwork_paths.push(file.path);
                }
            }
        }
        Ok(out)
    }
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn relocation_component_boundary() {
        assert_eq!(rebased_path("/Music2/a", "/Music", "/Moved"), None);
        assert_eq!(
            rebased_path("/Music/a/b", "/Music", "/Moved"),
            Some("/Moved/a/b".into())
        );
        assert_eq!(
            rebased_path("/Music/a", "/Music/", "/Moved/"),
            Some("/Moved/a".into())
        );
    }
}
#[uniffi::export]
pub fn folder_refresh_needs_hash(
    hard_refresh: bool,
    timestamp_changed: bool,
    stored_hash: Option<String>,
) -> bool {
    !hard_refresh && !timestamp_changed && stored_hash.is_some()
}
#[uniffi::export]
pub fn folder_needs_refresh(
    hard_refresh: bool,
    timestamp_changed: bool,
    stored_hash: Option<String>,
    current_hash: Option<String>,
) -> bool {
    hard_refresh
        || timestamp_changed
        || stored_hash.is_none()
        || current_hash.is_none()
        || stored_hash != current_hash
}
