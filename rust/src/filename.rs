//! Filename policy for the import, on the basename Swift extracted; no platform path handling.
use crate::lyrics::whitespace;
use crate::m3u::is_swift_number;
use unicode_segmentation::UnicodeSegmentation;

#[derive(Debug, PartialEq)]
pub struct FilenameMetadata {
    pub artist: Option<String>,
    pub title: String,
}

pub fn filename_metadata_fallback(base: &str) -> FilenameMetadata {
    let base = base.trim_matches(whitespace);
    let mut parts = base.split(" - ");
    let first = parts.next().unwrap_or("");
    let Some(second) = parts.next() else {
        return FilenameMetadata {
            artist: None,
            title: base.into(),
        };
    };
    let numeric = !first.is_empty() && first.graphemes(true).all(is_swift_number);
    if numeric && parts.next().is_some() {
        return FilenameMetadata {
            artist: Some(second.trim_matches(whitespace).into()),
            title: base.into(),
        };
    }
    if first.is_empty() || numeric {
        return FilenameMetadata {
            artist: None,
            title: base.into(),
        };
    }
    let title = base
        .get(first.len() + 3..)
        .unwrap_or("")
        .trim_matches(whitespace);
    FilenameMetadata {
        artist: Some(first.trim_matches(whitespace).into()),
        title: title.into(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn prefix_stays_in_title_and_unicode_numbers_are_prefixes() {
        for prefix in [
            "0012",
            "١٢",
            "²",
            "Ⅳ",
            "四",
            "万",
            "\u{11de0}",
            "\u{16ff4}",
            "1\u{301}",
            "1\u{fe0f}\u{20e3}",
        ] {
            let base = format!("{prefix} - Исполнитель - Название");
            assert_eq!(
                filename_metadata_fallback(&base),
                FilenameMetadata {
                    artist: Some("Исполнитель".into()),
                    title: base
                }
            );
        }
    }
    #[test]
    fn ordinary_and_missing_artist() {
        assert_eq!(
            filename_metadata_fallback(" Artist - Title - remix "),
            FilenameMetadata {
                artist: Some("Artist".into()),
                title: "Title - remix".into()
            }
        );
        assert_eq!(filename_metadata_fallback("123 - title").artist, None);
        assert_eq!(filename_metadata_fallback(" - title").artist, None);
        assert_eq!(filename_metadata_fallback("").title, "");
    }
}
