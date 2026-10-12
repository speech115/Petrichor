//! Artist policy and caches. A single mutex makes lookup replacement and parse atomic.
use regex::Regex;
use std::collections::{HashMap, HashSet};
use std::sync::{Arc, LazyLock, Mutex};
use unicode_normalization::UnicodeNormalization;
use unicode_segmentation::UnicodeSegmentation;

const HIGH: &[&str] = &[
    " feat. ",
    " feat ",
    " featuring ",
    " ft. ",
    " ft ",
    ";",
    "、",
];
const AMBIGUOUS: &[&str] = &[
    " & ", " and ", " x ", " X ", " vs. ", " vs ", ", ", " with ", " / ", "/", "／",
];
static INITIALS: LazyLock<Regex> =
    LazyLock::new(|| Regex::new(r"(\b[a-z]\.?\s*)+").expect("constant regex"));
static SPACES: LazyLock<Regex> = LazyLock::new(|| Regex::new(r"\s+").expect("constant regex"));
static SEPARATORS: LazyLock<Vec<Regex>> = LazyLock::new(|| {
    HIGH.iter()
        .chain(AMBIGUOUS)
        .map(|s| Regex::new(&format!("(?i:{})", regex::escape(s))).expect("escaped separator"))
        .collect()
});

#[derive(Default)]
struct State {
    known: HashSet<String>,
    retains: u64,
    library: HashMap<String, Arc<HashMap<String, String>>>,
    normalize: HashMap<String, String>,
    parse: HashMap<(String, String, Option<String>), Vec<String>>,
}
#[derive(uniffi::Object, Default)]
pub struct ArtistDomain {
    state: Mutex<State>,
}
#[uniffi::export]
impl ArtistDomain {
    #[uniffi::constructor]
    pub fn new() -> Arc<Self> {
        Arc::new(Self::default())
    }
    pub fn normalize_artist_name(&self, name: String) -> String {
        let mut state = self.state.lock().unwrap_or_else(|e| e.into_inner());
        normalize(&mut state, &name)
    }
    /// Retain even when the resource is missing, matching balanced scan load/unload calls.
    pub fn load_known_artists(&self, content: Option<String>) -> u64 {
        let mut state = self.state.lock().unwrap_or_else(|e| e.into_inner());
        state.retains = state.retains.saturating_add(1);
        if !state.known.is_empty() {
            return 0;
        }
        let Some(content) = content else {
            return 0;
        };
        state.known = content
            .split([
                '\n', '\r', '\u{000b}', '\u{000c}', '\u{0085}', '\u{2028}', '\u{2029}',
            ])
            .map(trim)
            .filter(|s| !s.is_empty() && !s.starts_with('#'))
            .map(|name| name.nfc().collect())
            .collect();
        state.parse.clear();
        state.known.len() as u64
    }
    pub fn unload_known_artists(&self) -> u64 {
        let mut state = self.state.lock().unwrap_or_else(|e| e.into_inner());
        state.retains = state.retains.saturating_sub(1);
        if state.retains != 0 {
            return 0;
        }
        let count = state.known.len();
        state.known.clear();
        if count > 0 {
            state.parse.clear();
        }
        count as u64
    }
    pub fn set_library_artists(
        &self,
        names_by_role: HashMap<String, HashMap<String, String>>,
    ) -> bool {
        let mut state = self.state.lock().unwrap_or_else(|e| e.into_inner());
        let names_by_role = names_by_role
            .into_iter()
            .map(|(role, names)| {
                (
                    role.nfc().collect(),
                    Arc::new(
                        names
                            .into_iter()
                            .map(|(key, value)| (key.nfc().collect(), value))
                            .collect(),
                    ),
                )
            })
            .collect();
        if same_library(&state.library, &names_by_role) {
            return false;
        }
        state.library = names_by_role;
        state.parse.clear();
        true
    }
    pub fn parse(
        &self,
        artist_string: String,
        unknown_placeholder: String,
        role: Option<String>,
    ) -> Vec<String> {
        let mut state = self.state.lock().unwrap_or_else(|e| e.into_inner());
        let key = (
            artist_string.nfc().collect(),
            unknown_placeholder.nfc().collect(),
            role.as_ref().map(|value| value.nfc().collect()),
        );
        if let Some(result) = state.parse.get(&key) {
            return result.clone();
        }
        let role = role.as_ref().map(|value| value.nfc().collect::<String>());
        let library = role
            .as_ref()
            .and_then(|r| state.library.get(r))
            .cloned()
            .unwrap_or_default();
        let has_lookup = !state.known.is_empty() || !library.is_empty();
        let resolve = |candidate: &str, state: &mut State| -> Option<String> {
            let normalized: String = normalize(state, candidate).nfc().collect();
            if normalized.is_empty() {
                return None;
            }
            library.get(&normalized).cloned().or_else(|| {
                state
                    .known
                    .contains(&normalized)
                    .then(|| trim(candidate).to_owned())
            })
        };
        let active = SEPARATORS
            .iter()
            .enumerate()
            .filter(|(i, _)| has_lookup || HIGH.len() + 9 != *i)
            .map(|(_, r)| r)
            .collect::<Vec<_>>();
        let result = if artist_string.is_empty() {
            vec![unknown_placeholder.clone()]
        } else if !active.iter().any(|r| r.is_match(&artist_string)) {
            let name = trim(&artist_string);
            vec![if name.is_empty() {
                unknown_placeholder.clone()
            } else {
                resolve(name, &mut state).unwrap_or_else(|| name.to_owned())
            }]
        } else {
            let artists = if !has_lookup {
                split(vec![artist_string.clone()], active.into_iter())
            } else if let Some(name) = resolve(&artist_string, &mut state) {
                vec![name]
            } else {
                let mut result = Vec::new();
                for segment in split(vec![artist_string.clone()], SEPARATORS[..HIGH.len()].iter()) {
                    let segment = trim(&segment);
                    if segment.is_empty() {
                        continue;
                    }
                    let mut matches = Vec::new();
                    for regex in &SEPARATORS[HIGH.len()..] {
                        for m in regex.find_iter(segment) {
                            matches.push((m.start(), m.end()));
                        }
                    }
                    matches.sort_by_key(|m| m.0);
                    let mut filtered = Vec::new();
                    for m in matches {
                        if filtered
                            .last()
                            .is_some_and(|last: &(usize, usize)| m.0 < last.1)
                        {
                            continue;
                        }
                        filtered.push(m);
                    }
                    if filtered.is_empty() {
                        result.push(segment.to_owned());
                        continue;
                    }
                    let mut atoms = Vec::new();
                    let mut start = 0;
                    for &(a, b) in &filtered {
                        atoms.push((start, a));
                        start = b;
                    }
                    atoms.push((start, segment.len()));
                    let mut i = 0;
                    while i < atoms.len() {
                        let mut found = None;
                        for j in ((i + 1)..atoms.len()).rev() {
                            if let Some(name) =
                                resolve(&segment[atoms[i].0..atoms[j].1], &mut state)
                            {
                                found = Some((j, name));
                                break;
                            }
                        }
                        if let Some((j, name)) = found {
                            result.push(name);
                            i = j + 1;
                        } else {
                            let atom = trim(&segment[atoms[i].0..atoms[i].1]);
                            if !atom.is_empty() {
                                result.push(
                                    resolve(atom, &mut state).unwrap_or_else(|| atom.to_owned()),
                                );
                            }
                            i += 1;
                        }
                    }
                }
                result
            };
            let mut unique: HashMap<String, String> = HashMap::new();
            for artist in artists {
                let artist = trim(&artist);
                if artist.is_empty() || artist.nfc().eq(unknown_placeholder.nfc()) {
                    continue;
                }
                let normalized: String = normalize(&mut state, artist).nfc().collect();
                let entry = unique
                    .entry(normalized)
                    .or_insert_with(|| artist.to_owned());
                if artist.graphemes(true).count() > entry.graphemes(true).count() {
                    *entry = artist.to_owned();
                }
            }
            if unique.is_empty() {
                vec![unknown_placeholder.clone()]
            } else {
                unique.into_values().collect()
            }
        };
        state.parse.insert(key, result.clone());
        result
    }
}
fn same_library(
    before: &HashMap<String, Arc<HashMap<String, String>>>,
    after: &HashMap<String, Arc<HashMap<String, String>>>,
) -> bool {
    before.len() == after.len()
        && before.iter().all(|(role, names)| {
            after.get(role).is_some_and(|next| {
                names.len() == next.len()
                    && names.iter().all(|(key, value)| {
                        next.get(key)
                            .is_some_and(|other| value.nfc().eq(other.nfc()))
                    })
            })
        })
}
fn trim(value: &str) -> &str {
    value.trim_matches(|c: char| c.is_whitespace() || c == '\u{200b}')
}
fn normalize(state: &mut State, name: &str) -> String {
    let key: String = name.nfc().collect();
    if let Some(result) = state.normalize.get(&key) {
        return result.clone();
    }
    // Swift String.lowercased uses simple scalar lowercase, including non-final sigma.
    let lower: String = name.chars().flat_map(char::to_lowercase).collect();
    let initials = INITIALS.replace_all(&lower, |caps: &regex::Captures| {
        caps[0].replace(['.', ' '], "")
    });
    let hyphens = initials
        .replace(" - ", "-")
        .replace(" -", "-")
        .replace("- ", "-");
    let result = trim(&SPACES.replace_all(&hyphens, " ")).to_owned();
    state.normalize.insert(key, result.clone());
    result
}
fn split<'a>(mut input: Vec<String>, separators: impl Iterator<Item = &'a Regex>) -> Vec<String> {
    for separator in separators {
        input = input
            .into_iter()
            .flat_map(|s| {
                if !separator.is_match(&s) {
                    return vec![s];
                }
                let mut parts = separator.split(&s).map(str::to_owned).collect::<Vec<_>>();
                if parts.last().is_some_and(String::is_empty) {
                    parts.pop();
                }
                parts
            })
            .collect();
    }
    input
}
#[cfg(test)]
mod tests {
    use super::*;
    fn sorted(mut names: Vec<String>) -> Vec<String> {
        names.sort();
        names
    }
    fn parse(domain: &ArtistDomain, s: &str, role: Option<&str>) -> Vec<String> {
        sorted(domain.parse(s.into(), "Unknown Artist".into(), role.map(str::to_owned)))
    }
    #[test]
    fn mixed_separators_and_known_names() {
        let d = ArtistDomain::new();
        assert_eq!(
            parse(&d, "AC/DC; A X B、C feat. D", None),
            ["A", "AC/DC", "B", "C", "D"]
        );
        d.load_known_artists(Some("mumford & sons\nearth, wind & fire\nac/dc".into()));
        assert_eq!(
            parse(&d, "Mumford & Sons feat. Earth, Wind & Fire / AC/DC", None),
            ["AC/DC", "Earth, Wind & Fire", "Mumford & Sons"]
        );
    }
    #[test]
    fn aliases_roles_and_invalidation() {
        let d = ArtistDomain::new();
        let map = HashMap::from([(
            "artist".into(),
            HashMap::from([("p!nk".into(), "Pink".into())]),
        )]);
        assert_eq!(parse(&d, "P!nk", Some("artist")), ["P!nk"]);
        d.set_library_artists(map);
        assert_eq!(parse(&d, "P!nk", Some("artist")), ["Pink"]);
        assert_eq!(parse(&d, "P!nk", Some("composer")), ["P!nk"]);
        d.set_library_artists(HashMap::new());
        assert_eq!(parse(&d, "P!nk", Some("artist")), ["P!nk"]);
    }
    #[test]
    fn normalization_and_retains() {
        let d = ArtistDomain::new();
        assert_eq!(d.normalize_artist_name("ΟΣ".into()), "οσ");
        assert_eq!(d.normalize_artist_name("J. S. Bach".into()), "jsbach");
        assert_eq!(
            d.normalize_artist_name("А. С. Пушкин".into()),
            "а. с. пушкин"
        );
        assert_eq!(
            d.normalize_artist_name("Jean - Michel".into()),
            "jean-michel"
        );
        assert_eq!(d.load_known_artists(Some("ac/dc".into())), 1);
        d.load_known_artists(None);
        assert_eq!(d.unload_known_artists(), 0);
        assert_eq!(d.unload_known_artists(), 1);
    }
    #[test]
    fn canonical_equivalence_and_bundled_alias_priority() {
        let d = ArtistDomain::new();
        let decomposed = "Beyonce\u{0301}";
        let first = d.normalize_artist_name(decomposed.into());
        assert_eq!(d.normalize_artist_name("Beyoncé".into()), first);
        d.load_known_artists(Some("beyoncé\np!nk".into()));
        d.set_library_artists(HashMap::from([(
            "artist".into(),
            HashMap::from([
                ("p!nk".into(), "Pink".into()),
                ("beyoncé".into(), "Beyoncé".into()),
            ]),
        )]));
        assert_eq!(parse(&d, decomposed, Some("artist")), ["Beyoncé"]);
        assert_eq!(parse(&d, "P!nk", Some("artist")), ["Pink"]);
        assert!(!d.set_library_artists(HashMap::from([(
            "artist".into(),
            HashMap::from([
                ("p!nk".into(), "Pink".into()),
                ("beyoncé".into(), decomposed.into()),
            ])
        )])));
        assert_eq!(
            d.parse(format!("{decomposed}; Beyoncé"), "Beyoncé".into(), None),
            ["Beyoncé"]
        );
    }
    #[test]
    fn concurrent_lookup_changes() {
        let d = ArtistDomain::new();
        let threads = (0..8)
            .map(|_| {
                let d = d.clone();
                std::thread::spawn(move || {
                    for _ in 0..100 {
                        d.set_library_artists(HashMap::from([(
                            "artist".into(),
                            HashMap::from([("p!nk".into(), "Pink".into())]),
                        )]));
                        let names = parse(&d, "P!nk", Some("artist"));
                        assert!(names == ["Pink"] || names == ["P!nk"]);
                        d.set_library_artists(HashMap::new());
                    }
                })
            })
            .collect::<Vec<_>>();
        for thread in threads {
            thread.join().unwrap();
        }
    }
}
