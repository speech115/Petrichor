//! M3U domain policy. Database and file-system access stay in Swift.
use std::collections::{HashMap, HashSet};
use unicode_general_category::{GeneralCategory, get_general_category};
use unicode_normalization::UnicodeNormalization;
use unicode_segmentation::UnicodeSegmentation;

fn lowercase(value: &str) -> String {
    value.chars().flat_map(char::to_lowercase).collect()
}

fn key(value: &str) -> String {
    lowercase(value).nfc().collect()
}

fn newline(c: char) -> bool {
    matches!(
        c,
        '\n' | '\r' | '\u{b}' | '\u{c}' | '\u{85}' | '\u{2028}' | '\u{2029}'
    )
}
fn whitespace(c: char) -> bool {
    matches!(
        c,
        '\t' | ' ' | '\u{a0}' | '\u{1680}' | '\u{2000}'
            ..='\u{200b}' | '\u{202f}' | '\u{205f}' | '\u{3000}'
    )
}
// Swift Character.isNumber uses Numeric_Type, including numeric letters and newer numeric scalars absent from the category crate.
// shortcut: macOS 26 Unicode supplementary numeric table; regenerate when system Unicode changes.
const NUMERIC_LETTERS: &[u32] = &[
    0x3405, 0x3483, 0x382A, 0x3B4D, 0x4E00, 0x4E03, 0x4E07, 0x4E09, 0x4E24, 0x4E5D, 0x4E8C, 0x4E94,
    0x4E96, 0x4EAC, 0x4EBF, 0x4EC0, 0x4EDF, 0x4EE8, 0x4F0D, 0x4F70, 0x4FE9, 0x5006, 0x5104, 0x5146,
    0x5169, 0x516B, 0x516D, 0x5341, 0x5343, 0x5344, 0x5345, 0x534C, 0x53C1, 0x53C2, 0x53C3, 0x53C4,
    0x56DB, 0x58F1, 0x58F9, 0x5E7A, 0x5EFE, 0x5EFF, 0x5F0C, 0x5F0D, 0x5F0E, 0x5F10, 0x62D0, 0x62FE,
    0x634C, 0x67D2, 0x6D1E, 0x6F06, 0x7396, 0x767E, 0x7695, 0x79ED, 0x8086, 0x842C, 0x8CAE, 0x8CB3,
    0x8D30, 0x920E, 0x94A9, 0x9621, 0x9646, 0x964C, 0x9678, 0x96F6, 0xF96B, 0xF973, 0xF978, 0xF9B2,
    0xF9D1, 0xF9D3, 0xF9FD, 0x11DE0, 0x11DE1, 0x11DE2, 0x11DE3, 0x11DE4, 0x11DE5, 0x11DE6, 0x11DE7,
    0x11DE8, 0x11DE9, 0x12038, 0x12039, 0x12079, 0x12226, 0x1222B, 0x1230B, 0x1230D, 0x12399,
    0x16ff4, 0x16ff5, 0x16ff6, 0x20001, 0x20064, 0x200E2, 0x20121, 0x2092A, 0x20983, 0x2098C,
    0x2099C, 0x20AEA, 0x20AFD, 0x20B19, 0x22390, 0x22998, 0x23B1B, 0x2626D, 0x2F890,
];

pub(crate) fn is_swift_number(grapheme: &str) -> bool {
    grapheme.chars().next().is_some_and(|c| {
        NUMERIC_LETTERS.binary_search(&(c as u32)).is_ok()
            || matches!(
                get_general_category(c),
                GeneralCategory::DecimalNumber
                    | GeneralCategory::LetterNumber
                    | GeneralCategory::OtherNumber
            )
    })
}
#[uniffi::export]
pub fn m3u_normalize_filename(filename: String) -> String {
    let mut offset = 0;
    for grapheme in filename.graphemes(true) {
        if !is_swift_number(grapheme) {
            break;
        }
        offset += grapheme.len();
    }
    let name = if offset > 0 && filename[offset..].starts_with(" - ") {
        &filename[offset + 3..]
    } else {
        &filename
    };
    let normalized = name
        .replace(';', ",")
        .replace(", ", ",")
        .replace(" ,", ",")
        .split(|c| whitespace(c) || newline(c))
        .filter(|s| !s.is_empty())
        .collect::<Vec<_>>()
        .join(" ");
    lowercase(&normalized)
}

fn percent_decode(path: &str) -> Option<String> {
    let bytes = path.as_bytes();
    let mut decoded = Vec::with_capacity(bytes.len());
    let mut i = 0;
    while i < bytes.len() {
        if bytes[i] == b'%' {
            let high = (*bytes.get(i + 1)? as char).to_digit(16)?;
            let low = (*bytes.get(i + 2)? as char).to_digit(16)?;
            decoded.push((high * 16 + low) as u8);
            i += 3;
        } else {
            decoded.push(bytes[i]);
            i += 1;
        }
    }
    String::from_utf8(decoded).ok()
}
#[uniffi::export]
pub fn m3u_path_variations(path: String) -> Vec<String> {
    let mut normalized = path;
    for scheme in ["file://", "smb://", "afp://", "nfs://"] {
        if lowercase(&normalized).starts_with(scheme) {
            normalized = normalized[scheme.len()..].to_string();
            break;
        }
    }
    if normalized.starts_with("//") {
        normalized = format!("/Volumes{}", &normalized[1..]);
    }
    normalized = normalized.replace('\\', "/");
    normalized = percent_decode(&normalized).unwrap_or(normalized);
    let mut result = vec![normalized.clone()];
    if normalized.starts_with("/Volumes/") {
        result.push(normalized[8..].to_string());
    } else if normalized.starts_with('/') && !normalized.starts_with("/Users/") {
        result.push(format!("/Volumes{normalized}"));
    }
    result
}

#[uniffi::export]
pub fn m3u_unique_filename_indices(filenames: Vec<String>) -> HashMap<String, u64> {
    let mut indices = HashMap::new();
    let mut blocked = HashSet::new();
    for (index, filename) in filenames.iter().enumerate() {
        let key = key(filename);
        if blocked.contains(&key) {
            continue;
        }
        if indices.contains_key(&key) {
            indices.remove(&key);
            blocked.insert(key);
        } else {
            indices.insert(key, index as u64);
        }
    }
    indices
}
#[uniffi::export]
pub fn m3u_resolve_normalized_filenames(
    filenames: Vec<String>,
    candidates: Vec<String>,
) -> HashMap<String, String> {
    let mut names = HashMap::new();
    let mut blocked = HashSet::new();
    for candidate in candidates {
        let key = key(&m3u_normalize_filename(candidate.clone()));
        if blocked.contains(&key) {
            continue;
        }
        if names.contains_key(&key) {
            names.remove(&key);
            blocked.insert(key);
        } else {
            names.insert(key, candidate);
        }
    }
    filenames
        .into_iter()
        .filter_map(|filename| {
            names
                .get(&key(&m3u_normalize_filename(filename.clone())))
                .map(|candidate| (filename, candidate.clone()))
        })
        .collect()
}
#[uniffi::export]
pub fn m3u_parse(content: String) -> Vec<String> {
    content
        .split(newline)
        .map(|s| s.trim_matches(whitespace))
        .filter(|s| !s.is_empty() && !s.starts_with('#'))
        .map(str::to_owned)
        .collect()
}
#[uniffi::export]
pub fn m3u_unique_playlist_name(base_name: String, existing_names: Vec<String>) -> String {
    let lower = key(&base_name);
    let existing_names: Vec<String> = existing_names.iter().map(|s| s.nfc().collect()).collect();
    if !existing_names.contains(&lower) {
        return base_name;
    }
    let prefix = format!("{lower} ");
    let highest = existing_names
        .iter()
        .filter_map(|s| s.strip_prefix(&prefix))
        .filter_map(|s| s.parse::<i64>().ok())
        .fold(1, i64::max);
    format!("{base_name} {}", highest.saturating_add(1))
}
#[uniffi::export]
pub fn m3u_export_filename(name: String) -> String {
    let sanitized: String = name
        .chars()
        .map(|c| if ":/\\?%*|\"<>".contains(c) { '_' } else { c })
        .collect();
    let trimmed = sanitized.trim_matches(|c| whitespace(c) || newline(c));
    let filename = if trimmed.is_empty() {
        "Untitled".to_string()
    } else {
        trimmed.graphemes(true).take(255).collect()
    };
    format!("{filename}.m3u")
}
#[derive(uniffi::Record)]
pub struct M3uExportEntry {
    pub duration_seconds: i64,
    pub artist: String,
    pub title: String,
    pub path: String,
}
#[uniffi::export]
pub fn m3u_generate(entries: Vec<M3uExportEntry>) -> String {
    let mut lines = vec!["#EXTM3U".to_string()];
    for entry in entries {
        lines.push(format!(
            "#EXTINF:{},{} - {}",
            entry.duration_seconds, entry.artist, entry.title
        ));
        lines.push(entry.path);
    }
    lines.join("\r\n")
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn order_duplicates_and_unicode_lines() {
        assert_eq!(NUMERIC_LETTERS.len(), 112);
        assert!(NUMERIC_LETTERS.windows(2).all(|pair| pair[0] < pair[1]));
        assert_eq!(
            m3u_normalize_filename("\u{11de0} - New number.mp3".into()),
            "new number.mp3"
        );
        assert_eq!(
            m3u_normalize_filename("\u{16ff4} - New number.mp3".into()),
            "new number.mp3"
        );
        assert_eq!(m3u_normalize_filename("四 - Han.mp3".into()), "han.mp3");
        assert_eq!(
            m3u_normalize_filename("𒈫 - Numeral.mp3".into()),
            "numeral.mp3"
        );
        assert_eq!(
            m3u_parse(
                "#EXTM3U\r\n a.mp3\u{2028}a.mp3\u{85}# comment\n\u{200b}b.mp3\u{200b}".into()
            ),
            ["a.mp3", "a.mp3", "b.mp3"]
        );
        assert_eq!(
            m3u_normalize_filename("Ⅻ - ДО  ОБЕДА; X.mp3".into()),
            "до обеда,x.mp3"
        );
    }
    #[test]
    fn ambiguity_stays_blocked() {
        assert!(
            m3u_resolve_normalized_filenames(
                vec!["Foo ; Bar.mp3".into()],
                vec![
                    "Foo;Bar.mp3".into(),
                    "Foo, Bar.mp3".into(),
                    "Foo , Bar.mp3".into()
                ]
            )
            .is_empty()
        );
        assert!(
            m3u_unique_filename_indices(vec!["A.mp3".into(), "a.mp3".into(), "A.mp3".into()])
                .is_empty()
        );
    }
    #[test]
    fn canonical_equivalence_refuses_collisions() {
        assert!(
            m3u_unique_filename_indices(vec!["é.mp3".into(), "e\u{301}.mp3".into()]).is_empty()
        );
        assert_eq!(
            m3u_unique_playlist_name("Cafe\u{301}".into(), vec!["café".into(), "café 3".into()]),
            "Cafe\u{301} 4"
        );
        let family = "👨‍👩‍👧‍👦";
        assert_eq!(
            m3u_export_filename(family.repeat(256)),
            format!("{}.m3u", family.repeat(255))
        );
    }
    #[test]
    fn lowercase_matches_swift_scalar_mapping() {
        assert_eq!(m3u_normalize_filename("ΟΣ".into()), "οσ");
        assert_eq!(
            m3u_unique_playlist_name("ΟΣ".into(), vec!["οσ".into()]),
            "ΟΣ 2"
        );
        assert!(m3u_unique_filename_indices(vec!["ΟΣ".into(), "οσ".into()]).is_empty());
    }
    #[test]
    fn paths_decode_atomically() {
        assert_eq!(
            m3u_path_variations("FILE:///Music/a%20b.mp3".into()),
            ["/Music/a b.mp3", "/Volumes/Music/a b.mp3"]
        );
        assert_eq!(m3u_path_variations("a%20%zz.mp3".into()), ["a%20%zz.mp3"]);
        assert_eq!(m3u_path_variations("a%FF.mp3".into()), ["a%FF.mp3"]);
        assert_eq!(
            m3u_path_variations("//server/share/a.mp3".into()),
            ["/Volumes/server/share/a.mp3", "/server/share/a.mp3"]
        );
    }
    #[test]
    fn export_and_naming() {
        assert_eq!(m3u_export_filename("  A:/B  ".into()), "A__B.m3u");
        assert_eq!(
            m3u_unique_playlist_name(
                "Mix".into(),
                vec!["mix".into(), "mix 4".into(), "mix rubbish".into()]
            ),
            "Mix 5"
        );
        assert_eq!(
            m3u_generate(vec![M3uExportEntry {
                duration_seconds: 12,
                artist: "A".into(),
                title: "T".into(),
                path: "x.mp3".into()
            }]),
            "#EXTM3U\r\n#EXTINF:12,A - T\r\nx.mp3"
        );
    }
}
