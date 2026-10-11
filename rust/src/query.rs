//! Parameterized library queries; Swift owns calendar boundaries and GRDB encoding.
use unicode_segmentation::UnicodeSegmentation;
#[derive(Clone, Debug, PartialEq, uniffi::Enum)]
pub enum QueryArgument {
    Text { value: String },
    Number { value: f64 },
    Integer { value: i64 },
    Date { timestamp: f64 },
}
#[derive(Clone, Debug, Default, uniffi::Record)]
pub struct QueryFragment {
    pub sql: String,
    pub arguments: Vec<QueryArgument>,
}
#[derive(Clone, Debug, uniffi::Record)]
pub struct QueryRule {
    pub field: String,
    pub condition: String,
    pub value: String,
    pub date_start: Option<f64>,
    pub date_end: Option<f64>,
    pub relative_date: bool,
    pub numeric_value: Option<f64>,
    pub integer_value: Option<i64>,
}
#[uniffi::export]
pub fn library_fts_query(text: String) -> String {
    let graphemes: Vec<&str> = text.graphemes(true).collect();
    graphemes
        .split(|g| *g == " ")
        .filter(|s| !s.is_empty())
        .map(|parts| parts.concat())
        .map(|token| {
            let escaped = token.replace('"', "\"\"");
            if token.contains(['"', '*', '^', ':', '(', ')', '[', ']', '{', '}', '~', '-']) {
                format!("\"{escaped}\"")
            } else if token.contains('.') {
                format!("\"{escaped}\" OR \"{escaped}\"*")
            } else {
                format!("{token}*")
            }
        })
        .collect::<Vec<_>>()
        .join(" AND ")
}
fn column(field: &str) -> Option<&'static str> {
    Some(match field {
        "isFavorite" => "is_favorite",
        "playCount" => "play_count",
        "lastPlayedDate" => "last_played_date",
        "dateAdded" => "date_added",
        "dateFavorited" => "date_favorited",
        "albumArtist" => "album_artist",
        "trackNumber" => "track_number",
        "discNumber" => "disc_number",
        "filename" => "path",
        "title" => "title",
        "artist" => "artist",
        "album" => "album",
        "genre" => "genre",
        "year" => "year",
        "composer" => "composer",
        "duration" => "duration",
        _ => return None,
    })
}
fn rule_fragment(rule: QueryRule) -> Option<QueryFragment> {
    if rule.field == "dateFavorited" {
        return None;
    }
    let column = column(&rule.field)?;
    let (condition, negative) = match rule.condition.as_str() {
        "notEquals" => ("equals", true),
        "notContains" => ("contains", true),
        "notStartsWith" => ("startsWith", true),
        "notEndsWith" => ("endsWith", true),
        c => (c, false),
    };
    let mut args = Vec::new();
    let sql = match rule.field.as_str() {
        "isFavorite" => {
            if condition != "equals" {
                return None;
            }
            args.push(QueryArgument::Integer {
                value: i64::from(rule.value.to_lowercase() == "true"),
            });
            format!("{column} = ?")
        }
        "playCount" | "duration" | "trackNumber" | "discNumber" => {
            let value = rule.numeric_value?;
            args.push(QueryArgument::Number { value });
            match condition {
                "equals" => {
                    args.push(QueryArgument::Number { value: value + 1.0 });
                    format!("{column} >= ? AND {column} < ?")
                }
                c => format!("{column} {} ?", operator(c)?),
            }
        }
        "lastPlayedDate" | "dateAdded" => {
            let start = rule.date_start.filter(|n| n.is_finite())?;
            let timestamp = if !rule.relative_date && condition == "greaterThan" {
                rule.date_end.filter(|n| n.is_finite())?
            } else {
                start
            };
            args.push(QueryArgument::Date { timestamp });
            let comparison = if rule.relative_date {
                operator(condition)?
            } else {
                match condition {
                    "equals" => {
                        args.push(QueryArgument::Date {
                            timestamp: rule.date_end.filter(|n| n.is_finite())?,
                        });
                        return Some(negate(
                            QueryFragment {
                                sql: format!(
                                    "{column} IS NOT NULL AND {column} >= ? AND {column} < ?"
                                ),
                                arguments: args,
                            },
                            negative,
                        ));
                    }
                    "greaterThan" => ">=",
                    "lessThan" => "<",
                    _ => return None,
                }
            };
            if rule.relative_date && !matches!(condition, "greaterThan" | "lessThan") {
                return None;
            }
            format!("{column} IS NOT NULL AND {column} {comparison} ?")
        }
        "year" if matches!(condition, "greaterThan" | "lessThan") => {
            args.push(QueryArgument::Integer {
                value: rule.integer_value?,
            });
            if condition == "lessThan" {
                format!("CAST({column} AS INTEGER) > 0 AND CAST({column} AS INTEGER) < ?")
            } else {
                format!("CAST({column} AS INTEGER) > ?")
            }
        }
        _ => {
            let (sql, value) = match condition {
                "equals" => (
                    format!(
                        "{column}{} = ?",
                        if rule.field == "year" {
                            ""
                        } else {
                            " COLLATE NOCASE"
                        }
                    ),
                    rule.value,
                ),
                "contains" => (
                    format!("{column} COLLATE NOCASE LIKE ?"),
                    format!("%{}%", rule.value),
                ),
                "startsWith" => (
                    format!("{column} COLLATE NOCASE LIKE ?"),
                    format!("{}%", rule.value),
                ),
                "endsWith" => (
                    format!("{column} COLLATE NOCASE LIKE ?"),
                    format!("%{}", rule.value),
                ),
                "regex" => (format!("{column} REGEXP ?"), rule.value),
                _ => return None,
            };
            args.push(QueryArgument::Text { value });
            sql
        }
    };
    Some(negate(
        QueryFragment {
            sql,
            arguments: args,
        },
        negative,
    ))
}
fn operator(condition: &str) -> Option<&'static str> {
    match condition {
        "greaterThan" => Some(">"),
        "greaterThanOrEqual" => Some(">="),
        "lessThan" => Some("<"),
        "lessThanOrEqual" => Some("<="),
        _ => None,
    }
}
fn negate(mut fragment: QueryFragment, negative: bool) -> QueryFragment {
    if negative {
        fragment.sql = format!("({}) IS NOT 1", fragment.sql);
    }
    fragment
}
#[uniffi::export]
pub fn library_smart_filter(rules: Vec<QueryRule>, match_all: bool) -> QueryFragment {
    let mut result = QueryFragment::default();
    let mut fragments = Vec::new();
    for rule in rules {
        if let Some(fragment) = rule_fragment(rule) {
            fragments.push(format!("({})", fragment.sql));
            result.arguments.extend(fragment.arguments);
        }
    }
    result.sql = fragments.join(if match_all { " AND " } else { " OR " });
    result
}
#[uniffi::export]
pub fn library_smart_sort(
    field: String,
    ascending: bool,
    distant_past: f64,
    distant_future: f64,
) -> QueryFragment {
    let mut result = QueryFragment::default();
    if !matches!(
        field.as_str(),
        "title"
            | "artist"
            | "album"
            | "playCount"
            | "dateAdded"
            | "duration"
            | "year"
            | "genre"
            | "trackNumber"
            | "discNumber"
            | "filename"
            | "lastPlayedDate"
            | "dateFavorited"
    ) {
        return result;
    }
    let Some(column) = column(&field) else {
        return result;
    };
    let expression = if matches!(field.as_str(), "lastPlayedDate" | "dateFavorited") {
        result.arguments.push(QueryArgument::Date {
            timestamp: if field == "lastPlayedDate" && !ascending {
                distant_future
            } else {
                distant_past
            },
        });
        format!("IFNULL({column}, ?)")
    } else {
        column.into()
    };
    result.sql = format!("{expression} {}", if ascending { "ASC" } else { "DESC" });
    result
}
#[cfg(test)]
mod tests {
    use super::*;
    fn rule(field: &str, condition: &str, value: &str) -> QueryRule {
        QueryRule {
            field: field.into(),
            condition: condition.into(),
            value: value.into(),
            date_start: None,
            date_end: None,
            relative_date: false,
            numeric_value: value.parse::<f64>().ok(),
            integer_value: value.parse::<i64>().ok(),
        }
    }
    #[test]
    fn values_cannot_change_sql() {
        let f = library_smart_filter(
            vec![
                rule("title", "equals", "'; DROP TABLE tracks;--"),
                rule("title; DROP", "equals", "x"),
            ],
            true,
        );
        assert_eq!(f.sql, "(title COLLATE NOCASE = ?)");
        assert_eq!(f.arguments.len(), 1);
    }
    #[test]
    fn negatives_include_null_and_duration_is_range() {
        let f = library_smart_filter(vec![rule("duration", "notEquals", "61")], true);
        assert_eq!(f.sql, "((duration >= ? AND duration < ?) IS NOT 1)");
        assert_eq!(
            f.arguments,
            vec![
                QueryArgument::Number { value: 61.0 },
                QueryArgument::Number { value: 62.0 }
            ]
        );
    }
    #[test]
    fn date_bounds_and_sort_sentinels() {
        let mut r = rule("dateAdded", "equals", "2026-10-11");
        r.date_start = Some(10.0);
        r.date_end = Some(20.0);
        let f = library_smart_filter(vec![r], true);
        assert_eq!(
            f.arguments,
            vec![
                QueryArgument::Date { timestamp: 10.0 },
                QueryArgument::Date { timestamp: 20.0 }
            ]
        );
        assert_eq!(
            library_smart_sort("dateFavorited".into(), false, -100.0, 100.0).arguments,
            vec![QueryArgument::Date { timestamp: -100.0 }]
        );
    }
    #[test]
    fn fts_preserves_space_combining_graphemes() {
        assert_eq!(
            library_fts_query("a \u{301}b c".into()),
            "a \u{301}b* AND c*"
        );
    }
    #[test]
    fn fts_preserves_original_special_character_strategy() {
        assert_eq!(
            library_fts_query("a  b.mp3 x-y \"q\"".into()),
            "a* AND \"b.mp3\" OR \"b.mp3\"* AND \"x-y\" AND \"\"\"q\"\"\""
        );
    }
}
