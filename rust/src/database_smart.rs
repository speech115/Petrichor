//! Smart rules remain closed domain data; only Rust executes their SQL fragments.
use crate::database::{DatabaseCell, DbResult, LibraryDatabase, timestamp};
use crate::database_reads::{DatabaseTrackRows, tracks};
use crate::query::{QueryArgument, QueryRule, library_smart_filter, library_smart_sort};
use rusqlite::{Connection, params_from_iter};

#[derive(Clone, Debug, uniffi::Record)]
pub struct DatabaseSmartCriteria {
    pub rules: Vec<QueryRule>,
    pub match_all: bool,
    pub sort_by: Option<String>,
    pub ascending: bool,
    pub limit: Option<i64>,
    pub distant_past: f64,
    pub distant_future: f64,
}
fn arguments(args: Vec<QueryArgument>) -> DbResult<Vec<DatabaseCell>> {
    args.into_iter()
        .map(|a| {
            Ok(match a {
                QueryArgument::Text { value } => DatabaseCell::Text { value },
                QueryArgument::Number { value } => DatabaseCell::Real { value },
                QueryArgument::Integer { value } => DatabaseCell::Integer { value },
                QueryArgument::Date { timestamp: seconds } => DatabaseCell::Text {
                    value: timestamp(seconds)?,
                },
            })
        })
        .collect()
}
fn predicate(
    criteria: &DatabaseSmartCriteria,
    hide_duplicates: bool,
) -> DbResult<(String, Vec<DatabaseCell>)> {
    let filter = library_smart_filter(criteria.rules.clone(), criteria.match_all);
    let mut sql = if hide_duplicates {
        "(is_duplicate=0 OR is_favorite=1)"
    } else {
        "1"
    }
    .to_string();
    if !filter.sql.is_empty() {
        sql.push_str(&format!(" AND ({})", filter.sql));
    }
    Ok((sql, arguments(filter.arguments)?))
}
pub(crate) fn smart_count(
    conn: &Connection,
    criteria: DatabaseSmartCriteria,
    hide_duplicates: bool,
    honor_limit: bool,
) -> DbResult<i64> {
    let (predicate, mut args) = predicate(&criteria, hide_duplicates)?;
    let tail = if honor_limit {
        if let Some(limit) = criteria.limit {
            args.push(DatabaseCell::Integer { value: limit });
            " LIMIT ?"
        } else {
            ""
        }
    } else {
        ""
    };
    Ok(conn.query_row(
        &format!("SELECT COUNT(*) FROM (SELECT id FROM tracks WHERE {predicate}{tail})"),
        params_from_iter(args),
        |r| r.get(0),
    )?)
}
#[uniffi::export]
impl LibraryDatabase {
    pub fn smart_count(
        &self,
        criteria: DatabaseSmartCriteria,
        hide_duplicates: bool,
        honor_limit: bool,
    ) -> DbResult<i64> {
        self.read(|c| smart_count(c, criteria, hide_duplicates, honor_limit))
    }
    pub fn smart_tracks(
        &self,
        criteria: DatabaseSmartCriteria,
        hide_duplicates: bool,
        artwork: bool,
    ) -> DbResult<DatabaseTrackRows> {
        self.read(|c| {
            let (predicate, mut args) = predicate(&criteria, hide_duplicates)?;
            let mut tail = String::new();
            if let Some(field) = criteria.sort_by {
                let sort = library_smart_sort(
                    field,
                    criteria.ascending,
                    criteria.distant_past,
                    criteria.distant_future,
                );
                if !sort.sql.is_empty() {
                    tail = format!("ORDER BY {}", sort.sql);
                    args.extend(arguments(sort.arguments)?);
                }
            }
            if let Some(limit) = criteria.limit {
                tail.push_str(" LIMIT ?");
                args.push(DatabaseCell::Integer { value: limit });
            }
            tracks(c, &predicate, &tail, args, artwork)
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn executes_date_text_null_negatives_and_limit() {
        let c = Connection::open_in_memory().unwrap();
        c.execute_batch("CREATE TABLE tracks(id INTEGER,title TEXT,duration REAL,date_added TEXT,is_duplicate INTEGER,is_favorite INTEGER); INSERT INTO tracks VALUES(1,NULL,61.9,'2026-10-11 00:00:00.000',0,0),(2,'no',62,'2026-10-10 23:59:59.999',1,1),(3,'yes',61,'2026-10-11 23:59:59.999',1,0);").unwrap();
        let mut criteria = DatabaseSmartCriteria {
            rules: vec![QueryRule {
                field: "title".into(),
                condition: "notEquals".into(),
                value: "yes".into(),
                date_start: None,
                date_end: None,
                relative_date: false,
                numeric_value: None,
                integer_value: None,
            }],
            match_all: true,
            sort_by: None,
            ascending: true,
            limit: Some(1),
            distant_past: 0.0,
            distant_future: 0.0,
        };
        assert_eq!(smart_count(&c, criteria.clone(), true, false).unwrap(), 2);
        assert_eq!(smart_count(&c, criteria.clone(), true, true).unwrap(), 1);
        criteria.rules = vec![QueryRule {
            field: "dateAdded".into(),
            condition: "equals".into(),
            value: "2026-10-11".into(),
            date_start: Some(1791676800.0),
            date_end: Some(1791763200.0),
            relative_date: false,
            numeric_value: None,
            integer_value: None,
        }];
        assert_eq!(smart_count(&c, criteria.clone(), false, false).unwrap(), 2);
        assert_eq!(smart_count(&c, criteria, true, false).unwrap(), 1);
    }
}
