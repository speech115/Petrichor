//! Deterministic subtitle parsing; Swift supplies UUID identities after the FFI call.
//! Digit classes supplement regex Unicode 16 with Foundation Unicode 17 decimals.
use regex::Regex;
use std::sync::OnceLock;

#[derive(Debug, PartialEq, uniffi::Record)]
pub struct ParsedLyricLine {
    pub text: String,
    pub start_time: f64,
    pub end_time: Option<f64>,
}

pub(crate) fn whitespace(c: char) -> bool {
    matches!(
        c,
        '\t' | ' ' | '\u{a0}' | '\u{1680}' | '\u{2000}'
            ..='\u{200b}' | '\u{202f}' | '\u{205f}' | '\u{3000}'
    )
}
fn number(s: &str) -> f64 {
    s.parse().unwrap_or(0.0)
}
fn normalized(s: &str) -> String {
    s.replace("\r\n", "\n").replace('\r', "\n")
}

fn compare_times(a: f64, b: f64) -> std::cmp::Ordering {
    // Overflow can produce either NaN sign depending on the architecture.
    match (a.is_nan(), b.is_nan()) {
        (true, true) => std::cmp::Ordering::Equal,
        (true, false) => std::cmp::Ordering::Greater,
        (false, true) => std::cmp::Ordering::Less,
        (false, false) => a.total_cmp(&b),
    }
}

#[uniffi::export]
pub fn parse_lrc(input: String) -> Vec<ParsedLyricLine> {
    static TIME: OnceLock<Result<Regex, regex::Error>> = OnceLock::new();
    static WORD: OnceLock<Result<Regex, regex::Error>> = OnceLock::new();
    let (Ok(time), Ok(word)) = (
        TIME.get_or_init(|| Regex::new(r"\[([\d\u{11de0}-\u{11de9}]+):([\d\u{11de0}-\u{11de9}]+)(?:\.([\d\u{11de0}-\u{11de9}]+))?\]")),
        WORD.get_or_init(|| Regex::new(r"<[\d\u{11de0}-\u{11de9}]+:[\d\u{11de0}-\u{11de9}]+(?:\.[\d\u{11de0}-\u{11de9}]+)?>")),
    ) else {
        return Vec::new();
    };
    let mut result = Vec::new();
    for line in normalized(&input).split('\n') {
        let without_time = time.replace_all(line, "");
        let without_word = word.replace_all(&without_time, "");
        let text = without_word.trim_matches(whitespace);
        for captures in time.captures_iter(line) {
            let minutes = captures.get(1).map_or(0.0, |v| number(v.as_str()));
            let seconds = captures.get(2).map_or(0.0, |v| number(v.as_str()));
            let fraction = captures.get(3).map_or(0.0, |v| {
                number(v.as_str()) / 10_f64.powf(v.as_str().chars().count() as f64)
            });
            result.push(ParsedLyricLine {
                text: text.into(),
                start_time: minutes * 60.0 + seconds + fraction,
                end_time: None,
            });
        }
    }
    // Stable sorting retains translations; overflowing (NaN) decimals sort after valid timestamps.
    result.sort_by(|a, b| compare_times(a.start_time, b.start_time));
    for i in (0..result.len().saturating_sub(1)).rev() {
        result[i].end_time = if result[i].start_time == result[i + 1].start_time {
            result[i + 1].end_time
        } else {
            Some(result[i + 1].start_time)
        };
    }
    result
}

#[uniffi::export]
pub fn parse_srt(input: String) -> Vec<ParsedLyricLine> {
    static TIME: OnceLock<Result<Regex, regex::Error>> = OnceLock::new();
    let Ok(time) = TIME.get_or_init(|| {
        Regex::new(r"(?:^|[\n\r\u{85}\u{2028}\u{2029}])([\d\u{11de0}-\u{11de9}]{2}):([\d\u{11de0}-\u{11de9}]{2}):([\d\u{11de0}-\u{11de9}]{2}),([\d\u{11de0}-\u{11de9}]{3}) --> ([\d\u{11de0}-\u{11de9}]{2}):([\d\u{11de0}-\u{11de9}]{2}):([\d\u{11de0}-\u{11de9}]{2}),([\d\u{11de0}-\u{11de9}]{3})(?:$|[\n\r\u{85}\u{2028}\u{2029}])")
    }) else {
        return Vec::new();
    };
    let normalized = normalized(&input);
    let mut result = Vec::new();
    for block in normalized
        .trim_matches(|c: char| whitespace(c) || c.is_whitespace())
        .split("\n\n")
    {
        let mut lines = block.split('\n').map(|line| line.trim_matches(whitespace));
        let (Some(_), Some(timestamp), Some(first_text)) =
            (lines.next(), lines.next(), lines.next())
        else {
            continue;
        };
        let Some(captures) = time.captures(timestamp) else {
            continue;
        };
        let at = |i| captures.get(i).map_or(0.0, |v| number(v.as_str()));
        let start_time = at(1) * 3600.0 + at(2) * 60.0 + at(3) + at(4) / 1000.0;
        let end_time = at(5) * 3600.0 + at(6) * 60.0 + at(7) + at(8) / 1000.0;
        let mut text = String::from(first_text);
        for line in lines {
            text.push('\n');
            text.push_str(line);
        }
        result.push(ParsedLyricLine {
            text,
            start_time,
            end_time: Some(end_time),
        });
    }
    result.sort_by(|a, b| compare_times(a.start_time, b.start_time));
    result
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn both_nan_signs_sort_last_and_preserve_authored_order() {
        let mut times = [
            (-f64::NAN, "negative"),
            (2.0, "two"),
            (f64::NAN, "positive"),
            (1.0, "one"),
        ];
        times.sort_by(|a, b| compare_times(a.0, b.0));
        assert_eq!(
            times.map(|entry| entry.1),
            ["one", "two", "negative", "positive"]
        );
    }

    #[test]
    fn translations_share_next_distinct_window_and_newlines_normalize() {
        let rows = parse_lrc(
            "[00:03.125]later\r\n[00:01][00:03.125] <00:01.2>Привет\r[00:01]translation".into(),
        );
        assert_eq!(rows.len(), 4);
        assert_eq!(rows[0].text, "Привет");
        assert_eq!(rows[1].text, "translation");
        assert_eq!(rows[0].end_time, Some(3.125));
        assert_eq!(rows[1].end_time, Some(3.125));
        assert_eq!(rows[2].end_time, None);
    }
    #[test]
    fn srt_preserves_multiline_and_reversed_end_time() {
        let rows =
            parse_srt("1\r00:00:03,125 --> 00:00:01,000\r Привет \rworld\r\r2\rbad\rx".into());
        assert_eq!(
            rows,
            vec![ParsedLyricLine {
                text: "Привет\nworld".into(),
                start_time: 3.125,
                end_time: Some(1.0)
            }]
        );
    }
    #[test]
    fn malformed_and_unicode_digits_follow_foundation_number_conversion() {
        assert!(parse_lrc("[bad]ignored".into()).is_empty());
        assert_eq!(parse_lrc("[٠١:٠٢]unicode".into())[0].start_time, 0.0);
        assert_eq!(
            parse_lrc("[\u{11de0}:\u{11de1}]new decimal".into())[0].start_time,
            0.0
        );
        assert!(parse_srt("1\n00:00:00.000 --> 00:00:01.000\nx".into()).is_empty());
        let overflowing = format!("[0:0.{}]overflow\n[0:1]finite", "9".repeat(400));
        let rows = parse_lrc(overflowing);
        assert_eq!(rows.len(), 2);
        assert_eq!(rows[0].text, "finite");
        assert!(rows[1].start_time.is_nan());
        for length in [0, 1, 1000, 100000] {
            let _ = parse_lrc("[".repeat(length));
        }
    }
}
