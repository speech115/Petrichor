//! SQLite owns raw stored values; the writer is serialized while readers use independent WAL snapshots.
use rusqlite::{
    Connection, Transaction, TransactionBehavior,
    types::{ToSql, ToSqlOutput, ValueRef},
};
use std::{
    sync::{Arc, Mutex, RwLock},
    time::Duration,
};

/// Same UniFFI byte-array metadata and wire format, with a bulk byte copy.
/// UniFFI's generic Vec<T> lowering writes artwork one byte at a time.
#[derive(Clone, Debug, PartialEq)]
pub struct DatabaseBlob(pub Vec<u8>);
impl DatabaseBlob {
    pub fn as_slice(&self) -> &[u8] {
        &self.0
    }
}
impl From<Vec<u8>> for DatabaseBlob {
    fn from(value: Vec<u8>) -> Self {
        Self(value)
    }
}
// SAFETY: RustBuffer ownership and the i32 big-endian length + raw byte
// representation are exactly those of Vec<u8>. Every read checks its bounds.
unsafe impl uniffi::FfiConverter<crate::UniFfiTag> for DatabaseBlob {
    type FfiType = uniffi::RustBuffer;
    const TYPE_ID_META: uniffi::MetadataBuffer =
        <Vec<u8> as uniffi::TypeId<crate::UniFfiTag>>::TYPE_ID_META;
    fn lower(value: Self) -> Self::FfiType {
        let mut bytes = Vec::with_capacity(
            value
                .0
                .len()
                .checked_add(4)
                .expect("Byte buffer size overflow"),
        );
        Self::write(value, &mut bytes);
        uniffi::RustBuffer::from_vec(bytes)
    }
    fn try_lift(value: Self::FfiType) -> uniffi::Result<Self> {
        let bytes = value.destroy_into_vec();
        let mut cursor = bytes.as_slice();
        let result = Self::try_read(&mut cursor)?;
        uniffi::deps::anyhow::ensure!(cursor.is_empty(), "Trailing blob bytes");
        Ok(result)
    }
    fn write(value: Self, bytes: &mut Vec<u8>) {
        let length = i32::try_from(value.0.len()).expect("Byte buffer exceeds i32::MAX");
        bytes.extend_from_slice(&length.to_be_bytes());
        bytes.extend_from_slice(&value.0);
    }
    fn try_read(bytes: &mut &[u8]) -> uniffi::Result<Self> {
        uniffi::deps::anyhow::ensure!(bytes.len() >= 4, "Truncated blob length");
        let length = i32::from_be_bytes(bytes[..4].try_into()?);
        let length = usize::try_from(length)?;
        uniffi::deps::anyhow::ensure!(length <= bytes.len() - 4, "Truncated blob bytes");
        let value = Self(bytes[4..4 + length].to_vec());
        *bytes = &bytes[4 + length..];
        Ok(value)
    }
}
uniffi::derive_ffi_traits!(local DatabaseBlob);

#[derive(Clone, Debug, PartialEq, uniffi::Enum)]
pub enum DatabaseCell {
    Null,
    Integer { value: i64 },
    Real { value: f64 },
    Text { value: String },
    Blob { value: DatabaseBlob },
}
impl ToSql for DatabaseCell {
    fn to_sql(&self) -> rusqlite::Result<ToSqlOutput<'_>> {
        Ok(match self {
            Self::Null => ToSqlOutput::Borrowed(ValueRef::Null),
            Self::Integer { value } => (*value).into(),
            Self::Real { value } => (*value).into(),
            Self::Text { value } => value.as_str().into(),
            Self::Blob { value } => value.as_slice().into(),
        })
    }
}
#[derive(Clone, Debug, PartialEq, uniffi::Record)]
pub struct DatabaseRows {
    pub columns: Vec<String>,
    pub rows: Vec<Vec<DatabaseCell>>,
}
#[derive(Debug, thiserror::Error, uniffi::Error)]
pub enum LibraryDatabaseError {
    #[error("Could not find the entity to merge: {name}")]
    EntityNotFound { name: String },
    #[error("{message}")]
    Storage { message: String },
    #[error("{message}")]
    Invalid { message: String },
}
pub type DbResult<T> = Result<T, LibraryDatabaseError>;
impl From<rusqlite::Error> for LibraryDatabaseError {
    fn from(e: rusqlite::Error) -> Self {
        Self::Storage {
            message: e.to_string(),
        }
    }
}
pub(crate) fn invalid(message: impl Into<String>) -> LibraryDatabaseError {
    LibraryDatabaseError::Storage {
        message: message.into(),
    }
}
#[derive(uniffi::Object)]
pub struct LibraryDatabase {
    path: String,
    pub(crate) writer: Mutex<Connection>,
    readers: Mutex<Vec<Connection>>,
    pub(crate) operation_gate: RwLock<()>,
}
fn connect(path: &str) -> DbResult<Connection> {
    let conn = Connection::open(path)?;
    conn.busy_timeout(Duration::from_secs(5))?;
    conn.execute_batch("PRAGMA foreign_keys=ON; PRAGMA synchronous=NORMAL;")?;
    Ok(conn)
}
#[uniffi::export]
impl LibraryDatabase {
    #[uniffi::constructor]
    pub fn open(path: String) -> DbResult<Arc<Self>> {
        if path.is_empty() || path == ":memory:" {
            return Err(invalid(
                "A file path is required for concurrent WAL readers",
            ));
        }
        let mut conn = connect(&path)?;
        // Check FTS before migrations can change the existing library.
        conn.execute_batch("CREATE VIRTUAL TABLE temp.fts_capability USING fts5(value, tokenize='unicode61'); DROP TABLE temp.fts_capability;")?;
        conn.pragma_update(None, "journal_mode", "WAL")?;
        super::database_schema::migrate(&mut conn)?;
        Ok(Arc::new(Self {
            path,
            writer: Mutex::new(conn),
            readers: Mutex::new(Vec::new()),
            operation_gate: RwLock::new(()),
        }))
    }
    pub fn checkpoint(&self) -> DbResult<()> {
        self.exclusive(|conn| {
            conn.execute_batch("PRAGMA wal_checkpoint(TRUNCATE)")?;
            Ok(())
        })
    }
    pub fn vacuum(&self) -> DbResult<()> {
        self.exclusive(|conn| {
            conn.execute_batch("VACUUM")?;
            Ok(())
        })
    }
    pub fn analyze(&self) -> DbResult<()> {
        self.exclusive(|conn| {
            conn.execute_batch("ANALYZE")?;
            Ok(())
        })
    }
    pub fn reset(&self, now: f64) -> DbResult<()> {
        let _guard = self
            .operation_gate
            .write()
            .map_err(|_| invalid("Database operation lock poisoned"))?;
        self.exclusive(|conn| {
            conn.pragma_update(None,"foreign_keys",false)?;
            let outcome = (|| {
                let tx=conn.transaction_with_behavior(TransactionBehavior::Immediate)?;
                let names:Vec<String>={let mut s=tx.prepare("SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%' AND name NOT LIKE 'tracks_fts_%'")?; s.query_map([],|r|r.get(0))?.collect::<Result<_,_>>()?};
                for name in names { tx.execute_batch(&format!("DROP TABLE {}",quote(&name)))?; }
                super::database_schema::reset_schema(&tx)?;
                tx.execute("UPDATE background_migrations SET completed_at=?,progress=NULL WHERE completed_at IS NULL",[timestamp(now)?])?;
                tx.commit()?;
                Ok(())
            })();
            conn.pragma_update(None,"foreign_keys",true)?; outcome
        })
    }
}
impl LibraryDatabase {
    pub(crate) fn read<T>(&self, f: impl FnOnce(&Connection) -> DbResult<T>) -> DbResult<T> {
        let _guard = self
            .operation_gate
            .read()
            .map_err(|_| invalid("Database operation lock poisoned"))?;
        let pooled = self
            .readers
            .lock()
            .map_err(|_| invalid("SQLite reader lock poisoned"))?
            .pop();
        let mut conn = match pooled {
            Some(conn) => conn,
            None => connect(&self.path)?,
        };
        let result = (|| {
            let tx = conn.transaction_with_behavior(TransactionBehavior::Deferred)?;
            let value = f(&tx)?;
            tx.commit()?;
            Ok(value)
        })();
        let mut readers = self
            .readers
            .lock()
            .map_err(|_| invalid("SQLite reader lock poisoned"))?;
        if readers.len() < 4 {
            readers.push(conn);
        }
        result
    }
    pub(crate) fn write<T>(&self, f: impl FnOnce(&Transaction) -> DbResult<T>) -> DbResult<T> {
        let _guard = self
            .operation_gate
            .read()
            .map_err(|_| invalid("Database operation lock poisoned"))?;
        self.exclusive(|conn| {
            let tx = conn.transaction_with_behavior(TransactionBehavior::Immediate)?;
            let value = f(&tx)?;
            tx.commit()?;
            Ok(value)
        })
    }
    pub(crate) fn exclusive<T>(
        &self,
        f: impl FnOnce(&mut Connection) -> DbResult<T>,
    ) -> DbResult<T> {
        let mut conn = self
            .writer
            .lock()
            .map_err(|_| invalid("SQLite writer lock poisoned"))?;
        f(&mut conn)
    }
}
pub(crate) fn quote(name: &str) -> String {
    format!("\"{}\"", name.replace('"', "\"\""))
}
pub(crate) fn query_rows(
    conn: &Connection,
    sql: &str,
    params: impl rusqlite::Params,
) -> DbResult<DatabaseRows> {
    let mut statement = conn.prepare(sql)?;
    let columns = statement
        .column_names()
        .iter()
        .map(|s| s.to_string())
        .collect::<Vec<_>>();
    let count = columns.len();
    let rows = statement
        .query_map(params, |row| {
            (0..count)
                .map(|i| {
                    Ok(match row.get_ref(i)? {
                        ValueRef::Null => DatabaseCell::Null,
                        ValueRef::Integer(value) => DatabaseCell::Integer { value },
                        ValueRef::Real(value) => DatabaseCell::Real { value },
                        ValueRef::Text(value) => DatabaseCell::Text {
                            value: std::str::from_utf8(value)
                                .map_err(|e| {
                                    rusqlite::Error::FromSqlConversionFailure(
                                        i,
                                        rusqlite::types::Type::Text,
                                        Box::new(e),
                                    )
                                })?
                                .into(),
                        },
                        ValueRef::Blob(value) => DatabaseCell::Blob {
                            value: value.to_vec().into(),
                        },
                    })
                })
                .collect::<rusqlite::Result<Vec<_>>>()
        })?
        .collect::<rusqlite::Result<Vec<_>>>()?;
    Ok(DatabaseRows { columns, rows })
}
pub(crate) fn timestamp(seconds: f64) -> DbResult<String> {
    if !seconds.is_finite() {
        return Err(invalid("Invalid date"));
    }
    chrono::DateTime::from_timestamp_millis((seconds * 1000.0).round() as i64)
        .map(|d| d.format("%Y-%m-%d %H:%M:%S%.3f").to_string())
        .ok_or_else(|| invalid("Date out of range"))
}

#[cfg(test)]
mod tests {
    use super::*;
    fn path() -> String {
        std::env::temp_dir()
            .join(format!(
                "petrichor-foundation-{}.sqlite",
                uuid::Uuid::new_v4()
            ))
            .to_string_lossy()
            .into()
    }
    fn scalar(db: &LibraryDatabase, sql: &str) -> i64 {
        db.read(|c| Ok(c.query_row(sql, [], |r| r.get(0))?))
            .unwrap()
    }
    #[test]
    fn fresh_storage_and_fts_transactions() {
        let db = LibraryDatabase::open(path()).unwrap();
        assert_eq!(scalar(&db, "SELECT COUNT(*) FROM grdb_migrations"), 17);
        assert_eq!(scalar(&db, "SELECT COUNT(*) FROM playlists"), 3);
        db.write(|c|{c.execute_batch("INSERT INTO folders(name,path,date_added,date_updated) VALUES ('test','/test','2026-01-01','2026-01-01'); INSERT INTO tracks(folder_id,path,filename,title,date_added) VALUES (1,'/test/song.mp3','song.mp3','Señor, музыка','2026-01-01');")?;Ok(())}).unwrap();
        assert_eq!(
            scalar(
                &db,
                "SELECT COUNT(*) FROM tracks_fts WHERE tracks_fts MATCH 'музыка'"
            ),
            1
        );
        let failed: DbResult<()> = db.write(|c| {
            c.execute_batch(
                "UPDATE tracks SET title='Lost';UPDATE background_migrations SET progress='lost';",
            )?;
            Err(invalid("forced failure"))
        });
        assert!(failed.is_err());
        assert_eq!(
            scalar(
                &db,
                "SELECT COUNT(*) FROM tracks_fts WHERE tracks_fts MATCH 'музыка'"
            ),
            1
        );
        assert_eq!(
            scalar(
                &db,
                "SELECT COUNT(*) FROM background_migrations WHERE progress IS NOT NULL"
            ),
            0
        );
        db.write(|c| {
            c.execute_batch("UPDATE tracks SET title='New';")?;
            Ok(())
        })
        .unwrap();
        assert_eq!(
            scalar(
                &db,
                "SELECT COUNT(*) FROM tracks_fts WHERE tracks_fts MATCH 'New'"
            ),
            1
        );
        db.write(|c| {
            c.execute_batch("DELETE FROM tracks;")?;
            Ok(())
        })
        .unwrap();
        assert_eq!(scalar(&db, "SELECT COUNT(*) FROM tracks_fts"), 0);
    }
    #[test]
    fn readers_keep_snapshot_while_writer_runs() {
        let db = LibraryDatabase::open(path()).unwrap();
        db.read(|reader| {
            let before:i64=reader.query_row("SELECT COUNT(*) FROM folders",[],|r|r.get(0))?;
            db.write(|c|{c.execute_batch("INSERT INTO folders(name,path,date_added,date_updated) VALUES ('test','/test','2026-01-01','2026-01-01')")?;Ok(())})?;
            let after:i64=reader.query_row("SELECT COUNT(*) FROM folders",[],|r|r.get(0))?;
            assert_eq!(before,after);Ok(())
        }).unwrap();
        assert_eq!(scalar(&db, "SELECT COUNT(*) FROM folders"), 1);
    }
    #[test]
    fn current_schema_open_preserves_raw_values() {
        let name = path();
        let db = LibraryDatabase::open(name.clone()).unwrap();
        db.write(|c|{c.execute_batch("INSERT INTO artists(id,name,normalized_name,bio,genres,artwork_data,created_at,updated_at) VALUES (9007199254740993,'Raw','raw','bio','invalid unknown JSON',X'0001FF','2020-01-01','2020-01-01'); INSERT INTO folders(id,name,path,date_added,date_updated,bookmark_data) VALUES (50,'folder','/folder','2020-01-01','2020-01-01',X'00FF'); INSERT INTO folders(id,name,path,date_added,date_updated) VALUES (999,'deleted','/deleted','2020-01-01','2020-01-01');DELETE FROM folders WHERE id=999;UPDATE background_migrations SET progress='{\"table\":\"albums\",\"offset\":50}';")?;Ok(())}).unwrap();
        let before = db
            .read(|c| query_rows(c, "SELECT * FROM artists", []))
            .unwrap();
        let jobs = db.pending_background_migrations().unwrap();
        drop(db);
        let reopened = LibraryDatabase::open(name).unwrap();
        assert_eq!(
            before,
            reopened
                .read(|c| query_rows(c, "SELECT * FROM artists", []))
                .unwrap()
        );
        assert_eq!(
            scalar(
                &reopened,
                "SELECT seq FROM sqlite_sequence WHERE name='folders'"
            ),
            999
        );
        assert_eq!(
            jobs[0].progress,
            reopened.pending_background_migrations().unwrap()[0].progress
        );
    }
    #[test]
    fn failed_historical_migration_keeps_ledger_and_data() {
        let name = path();
        let db = LibraryDatabase::open(name.clone()).unwrap();
        db.write(|c|{c.execute_batch("DELETE FROM grdb_migrations WHERE identifier='v2_add_folder_content_hash';INSERT INTO folders(name,path,date_added,date_updated) VALUES ('keep','/keep','2020-01-01','2020-01-01')")?;Ok(())}).unwrap();
        drop(db);
        assert!(LibraryDatabase::open(name.clone()).is_err());
        let c = Connection::open(name).unwrap();
        assert_eq!(
            c.query_row("SELECT COUNT(*) FROM folders", [], |r| r.get::<_, i64>(0))
                .unwrap(),
            1
        );
        assert_eq!(
            c.query_row("SELECT COUNT(*) FROM grdb_migrations", [], |r| r
                .get::<_, i64>(0))
                .unwrap(),
            16
        );
    }
    #[test]
    fn populated_old_schema_migrates_without_reserializing() {
        let name = path();
        let mut c = Connection::open(&name).unwrap();
        // Reconstruct the v1 shape: old libraries did not contain the later conditional columns.
        let ddl = super::super::database_schema::fresh_schema_for_test();
        c.execute_batch(&ddl).unwrap();
        c.execute_batch("ALTER TABLE tracks DROP COLUMN date_favorited;ALTER TABLE albums DROP COLUMN artwork_thumbnail;ALTER TABLE artists DROP COLUMN artwork_thumbnail;CREATE TABLE grdb_migrations(identifier TEXT NOT NULL PRIMARY KEY);INSERT INTO grdb_migrations VALUES ('v1_initial_schema');INSERT INTO folders(id,name,path,date_added,date_updated,bookmark_data) VALUES (42,'old','/old','2020-01-01','2020-01-01',X'00FF');INSERT INTO tracks(id,folder_id,path,filename,date_added,is_favorite,track_artwork_data,extended_metadata) VALUES (101,42,'/old/song','song','2020-01-02 03:04:05.006',1,X'AA00FF','raw unknown JSON');").unwrap();
        super::super::database_schema::migrate(&mut c).unwrap();
        assert_eq!(
            c.query_row("SELECT date_favorited FROM tracks WHERE id=101", [], |r| {
                r.get::<_, String>(0)
            })
            .unwrap(),
            "2020-01-02 03:04:05.006"
        );
        assert_eq!(
            c.query_row(
                "SELECT track_artwork_data FROM tracks WHERE id=101",
                [],
                |r| r.get::<_, Vec<u8>>(0)
            )
            .unwrap(),
            vec![170, 0, 255]
        );
        assert_eq!(
            c.query_row(
                "SELECT extended_metadata FROM tracks WHERE id=101",
                [],
                |r| r.get::<_, String>(0)
            )
            .unwrap(),
            "raw unknown JSON"
        );
        assert!(
            !c.prepare("PRAGMA foreign_key_check")
                .unwrap()
                .exists([])
                .unwrap()
        );
    }
    #[test]
    fn utc_date_matches_grdb_milliseconds() {
        assert_eq!(timestamp(0.0).unwrap(), "1970-01-01 00:00:00.000");
        assert_eq!(timestamp(1.125).unwrap(), "1970-01-01 00:00:01.125");
        assert!(timestamp(f64::NAN).is_err());
    }
}

#[cfg(test)]
mod baseline_test {
    use super::*;
    #[test]
    #[ignore = "requires explicitly supplied disposable evaluation paths"]
    fn opens_real_backup_without_data_migration() {
        let source = std::env::var("PETRICHOR_BASELINE").expect("baseline backup path");
        let copy = std::env::var("PETRICHOR_FOUNDATION_COPY").expect("disposable path");
        assert_ne!(source, copy);
        assert!(!std::path::Path::new(&copy).exists());
        std::fs::copy(source, &copy).unwrap();
        let db = LibraryDatabase::open(copy).unwrap();
        db.read(|c| {
            assert_eq!(
                c.query_row("PRAGMA integrity_check", [], |r| r.get::<_, String>(0))?,
                "ok"
            );
            assert!(!c.prepare("PRAGMA foreign_key_check")?.exists([])?);
            Ok(())
        })
        .unwrap();
        db.checkpoint().unwrap();
    }
}

#[cfg(test)]
mod reset_tests {
    use super::*;
    #[test]
    fn deliberate_reset_failure_rolls_back_existing_library() {
        let path = std::env::temp_dir()
            .join(format!("petrichor-reset-{}.sqlite", uuid::Uuid::new_v4()))
            .to_string_lossy()
            .into();
        let db = LibraryDatabase::open(path).unwrap();
        db.write(|c|{c.execute_batch("INSERT INTO folders(name,path,date_added,date_updated) VALUES ('keep','/keep','2020-01-01','2020-01-01')")?;Ok(())}).unwrap();
        assert!(db.reset(f64::NAN).is_err());
        db.read(|c| {
            assert_eq!(
                c.query_row("SELECT COUNT(*) FROM folders", [], |r| r.get::<_, i64>(0))?,
                1
            );
            Ok(())
        })
        .unwrap();
        db.reset(0.0).unwrap();
        db.read(|c| {
            assert_eq!(
                c.query_row("SELECT COUNT(*) FROM folders", [], |r| r.get::<_, i64>(0))?,
                0
            );
            assert_eq!(
                c.query_row("SELECT COUNT(*) FROM playlists", [], |r| r.get::<_, i64>(0))?,
                3
            );
            assert!(
                !c.prepare("SELECT 1 FROM background_migrations WHERE completed_at IS NULL")?
                    .exists([])?
            );
            Ok(())
        })
        .unwrap();
    }
}

#[cfg(test)]
mod database_blob_tests {
    use super::DatabaseBlob;
    use uniffi::{FfiConverter, Lower};
    #[test]
    fn bulk_converter_has_identical_byte_wire_and_checked_reads() {
        for payload in [
            vec![],
            vec![0, 128, 255, 195, 169],
            vec![42; 2 * 1024 * 1024],
        ] {
            let mut bulk = Vec::new();
            <DatabaseBlob as FfiConverter<crate::UniFfiTag>>::write(
                DatabaseBlob(payload.clone()),
                &mut bulk,
            );
            let mut generic = Vec::new();
            <Vec<u8> as Lower<crate::UniFfiTag>>::write(payload.clone(), &mut generic);
            assert_eq!(bulk, generic);
            let mut cursor = bulk.as_slice();
            let decoded =
                <DatabaseBlob as FfiConverter<crate::UniFfiTag>>::try_read(&mut cursor).unwrap();
            assert_eq!(decoded.0, payload);
            assert!(cursor.is_empty());
            let buffer = <DatabaseBlob as FfiConverter<crate::UniFfiTag>>::lower(decoded);
            assert_eq!(
                <DatabaseBlob as FfiConverter<crate::UniFfiTag>>::try_lift(buffer)
                    .unwrap()
                    .0,
                payload
            );
        }
        for invalid in [vec![], vec![0, 0, 0], vec![255; 4], vec![0, 0, 0, 2, 1]] {
            let mut cursor = invalid.as_slice();
            assert!(
                <DatabaseBlob as FfiConverter<crate::UniFfiTag>>::try_read(&mut cursor).is_err()
            );
            assert_eq!(cursor, invalid.as_slice());
        }
        let mut trailing = vec![0, 0, 0, 0, 1];
        assert!(
            <DatabaseBlob as FfiConverter<crate::UniFfiTag>>::try_lift(
                uniffi::RustBuffer::from_vec(std::mem::take(&mut trailing))
            )
            .is_err()
        );
    }
}
