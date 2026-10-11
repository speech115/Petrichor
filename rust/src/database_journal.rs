use crate::database::{DbResult, LibraryDatabase, LibraryDatabaseError, timestamp};
use chrono::{NaiveDate, NaiveDateTime};
use rusqlite::{Connection, OptionalExtension, params, types::Value};
use unicode_normalization::UnicodeNormalization;

#[derive(Clone, uniffi::Record)]
pub struct DatabaseJournalEvent {
    pub path: String,
    pub timestamp: f64,
    pub favorite: Option<bool>,
}

#[derive(Debug, PartialEq, uniffi::Record)]
pub struct DatabaseJournalResult {
    pub applied: u64,
    pub skipped: u64,
    pub cursor: Option<f64>,
}

#[uniffi::export]
impl LibraryDatabase {
    pub fn apply_playback_journal(
        &self,
        events: Vec<DatabaseJournalEvent>,
        now: f64,
    ) -> DbResult<DatabaseJournalResult> {
        self.write(|db| apply(db, events, now))
    }
}

fn invalid(message: &str) -> LibraryDatabaseError {
    LibraryDatabaseError::Invalid {
        message: message.into(),
    }
}

fn date(value: &Value) -> DbResult<Option<f64>> {
    match value {
        Value::Null => Ok(None),
        Value::Integer(value) => Ok(Some(*value as f64)),
        Value::Real(value) if value.is_finite() => Ok(Some(*value)),
        Value::Text(value) => {
            let parsed = NaiveDateTime::parse_from_str(value, "%Y-%m-%d %H:%M:%S%.f")
                .or_else(|_| NaiveDateTime::parse_from_str(value, "%Y-%m-%dT%H:%M:%S%.f"))
                .or_else(|_| {
                    NaiveDate::parse_from_str(value, "%Y-%m-%d")
                        .map(|date| date.and_hms_opt(0, 0, 0).unwrap())
                })
                .map_err(|_| invalid("Invalid stored journal date"))?;
            Ok(Some(parsed.and_utc().timestamp_millis() as f64 / 1000.0))
        }
        _ => Err(invalid("Invalid stored journal date type")),
    }
}

fn apply(
    db: &Connection,
    mut events: Vec<DatabaseJournalEvent>,
    now: f64,
) -> DbResult<DatabaseJournalResult> {
    let favorite_date = timestamp(now)?;
    for event in &events {
        if event.path.is_empty() || !event.timestamp.is_finite() {
            return Err(invalid("Invalid playback journal event"));
        }
        timestamp(event.timestamp)?;
    }
    let cursor_value: Value = db
        .query_row(
            "SELECT applied_through FROM playback_journal_cursor WHERE singleton = 1",
            [],
            |row| row.get(0),
        )
        .optional()?
        .unwrap_or(Value::Null);
    let cursor = date(&cursor_value)?;
    events.retain(|event| cursor.is_none_or(|cursor| event.timestamp > cursor));
    events.sort_by(|left, right| left.timestamp.total_cmp(&right.timestamp));
    let mut statement =
        db.prepare("SELECT id, path, play_count, is_favorite, last_played_date FROM tracks")?;
    let originals = statement
        .query_map([], |row| {
            Ok((
                row.get::<_, i64>(0)?,
                row.get::<_, String>(1)?,
                row.get::<_, i64>(2)?,
                row.get::<_, bool>(3)?,
                row.get::<_, Value>(4)?,
            ))
        })?
        .collect::<Result<Vec<_>, _>>()?;
    let paths: Vec<String> = originals.iter().map(|row| row.1.nfc().collect()).collect();
    let mut states = originals
        .iter()
        .map(|row| Ok((row.2, row.3, date(&row.4)?)))
        .collect::<DbResult<Vec<_>>>()?;
    let old_states = states.clone();
    let mut result = DatabaseJournalResult {
        applied: 0,
        skipped: 0,
        cursor,
    };
    for event in events {
        let path: String = event.path.nfc().collect();
        let suffix = format!("/{path}");
        let mut matches = paths
            .iter()
            .enumerate()
            .filter(|(_, stored)| **stored == path || stored.ends_with(&suffix));
        let Some((index, _)) = matches.next() else {
            result.skipped += 1;
            continue;
        };
        if matches.next().is_some() {
            result.skipped += 1;
            continue;
        }
        let state = &mut states[index];
        if let Some(favorite) = event.favorite {
            state.1 = favorite;
        } else {
            state.0 = state
                .0
                .checked_add(1)
                .ok_or_else(|| invalid("Play count overflow"))?;
            state.2 = Some(
                state
                    .2
                    .map_or(event.timestamp, |previous| previous.max(event.timestamp)),
            );
        }
        result.applied += 1;
        result.cursor = Some(event.timestamp);
    }
    for (index, state) in states.iter().enumerate() {
        let previous = old_states[index];
        if *state == previous {
            continue;
        }
        let last_played = state.2.map(timestamp).transpose()?;
        db.execute(
            "UPDATE tracks SET play_count = ?, is_favorite = ?, last_played_date = ?, date_favorited = CASE WHEN ? THEN ? ELSE date_favorited END WHERE id = ?",
            params![state.0, state.1, last_played, state.1 != previous.1, state.1.then_some(&favorite_date), originals[index].0]
        )?;
    }
    if let Some(cursor) = result.cursor {
        db.execute(
            "INSERT INTO playback_journal_cursor(singleton, applied_through) VALUES(1, ?) ON CONFLICT(singleton) DO UPDATE SET applied_through=excluded.applied_through",
            [timestamp(cursor)?]
        )?;
    }
    Ok(result)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn replay_ambiguity_order_and_favorite_timestamp() -> DbResult<()> {
        let mut db = Connection::open_in_memory()?;
        db.execute_batch("CREATE TABLE tracks(id INTEGER PRIMARY KEY,path TEXT,play_count INTEGER,is_favorite INTEGER,last_played_date DATETIME,date_favorited DATETIME); CREATE TABLE playback_journal_cursor(singleton INTEGER PRIMARY KEY,applied_through DATETIME); INSERT INTO tracks VALUES(1,'/Music/a.mp3',2,0,NULL,NULL),(2,'/Music/x.mp3',0,0,NULL,NULL),(3,'/Other/x.mp3',0,0,NULL,NULL);")?;
        let events = vec![
            DatabaseJournalEvent {
                path: "a.mp3".into(),
                timestamp: 102.0,
                favorite: Some(true),
            },
            DatabaseJournalEvent {
                path: "a.mp3".into(),
                timestamp: 101.0,
                favorite: None,
            },
            DatabaseJournalEvent {
                path: "x.mp3".into(),
                timestamp: 103.0,
                favorite: None,
            },
        ];
        let transaction = db.transaction()?;
        let result = apply(&transaction, events.clone(), 200.0)?;
        transaction.commit()?;
        assert_eq!(
            result,
            DatabaseJournalResult {
                applied: 2,
                skipped: 1,
                cursor: Some(102.0)
            }
        );
        let state: (i64, bool, String) = db.query_row(
            "SELECT play_count,is_favorite,date_favorited FROM tracks WHERE id=1",
            [],
            |row| Ok((row.get(0)?, row.get(1)?, row.get(2)?)),
        )?;
        assert_eq!(state, (3, true, timestamp(200.0)?));
        let transaction = db.transaction()?;
        assert_eq!(
            apply(&transaction, events, 300.0)?,
            DatabaseJournalResult {
                applied: 0,
                skipped: 1,
                cursor: Some(102.0)
            }
        );
        transaction.commit()?;
        let transaction = db.transaction()?;
        apply(
            &transaction,
            vec![DatabaseJournalEvent {
                path: "a.mp3".into(),
                timestamp: 104.0,
                favorite: Some(false),
            }],
            400.0,
        )?;
        drop(transaction);
        assert!(
            db.query_row("SELECT is_favorite FROM tracks WHERE id=1", [], |row| row
                .get::<_, bool>(
                0
            ))?
        );
        let cursor: String = db.query_row(
            "SELECT applied_through FROM playback_journal_cursor",
            [],
            |row| row.get(0),
        )?;
        assert_eq!(cursor, timestamp(102.0)?);
        Ok(())
    }
}
