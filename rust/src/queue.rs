//! Deterministic queue edits; Swift owns track storage and engine event ordering.

/// Crosses FFI as its `u8` code: a UniFFI enum would cost a RustBuffer per call.
#[derive(Clone, Copy)]
#[repr(u8)]
pub enum QueueRepeat {
    Off = 0,
    One = 1,
    All = 2,
}
impl QueueRepeat {
    fn from_code(code: u8) -> Option<Self> {
        [Self::Off, Self::One, Self::All]
            .get(usize::from(code))
            .copied()
    }
}

#[derive(Debug, PartialEq)]
pub struct QueueInsertion {
    pub replace: bool,
    pub remove_index: Option<i64>,
    pub insertion_index: i64,
    pub cursor_after_removal: i64,
}

fn valid(count: i64, index: i64) -> bool {
    count > 0 && index >= 0 && index < count
}
fn valid_cursor(count: i64, cursor: i64) -> bool {
    count >= 0 && cursor >= -1 && cursor < count
}

fn next_index(count: i64, cursor: i64, mode: QueueRepeat) -> Option<i64> {
    if !valid_cursor(count, cursor) || count == 0 {
        return None;
    }
    match mode {
        QueueRepeat::One => valid(count, cursor).then_some(cursor),
        QueueRepeat::All => Some(if cursor == count - 1 { 0 } else { cursor + 1 }),
        QueueRepeat::Off => (cursor < count - 1).then_some(cursor + 1),
    }
}

fn previous_index(count: i64, cursor: i64, mode: QueueRepeat) -> Option<i64> {
    if !valid_cursor(count, cursor) || count == 0 {
        return None;
    }
    match mode {
        QueueRepeat::One => valid(count, cursor).then_some(cursor),
        QueueRepeat::All => Some(if cursor > 0 { cursor - 1 } else { count - 1 }),
        QueueRepeat::Off => (cursor > 0).then_some(cursor - 1),
    }
}

#[uniffi::export]
pub fn queue_playable_candidates(count: i64, index: i64, mode: u8) -> Vec<i64> {
    let Some(mode) = QueueRepeat::from_code(mode) else {
        return vec![];
    };
    if !valid(count, index) {
        return vec![];
    }
    let length = match mode {
        QueueRepeat::One => 1,
        QueueRepeat::All => count,
        QueueRepeat::Off => count - index,
    };
    let Ok(length) = usize::try_from(length) else {
        return vec![];
    };
    let mut candidates = Vec::new();
    if candidates.try_reserve_exact(length).is_err() {
        return candidates;
    }
    match mode {
        QueueRepeat::One => candidates.push(index),
        QueueRepeat::All => candidates.extend((index..count).chain(0..index)),
        QueueRepeat::Off => candidates.extend(index..count),
    }
    candidates
}

fn play_next_plan(count: i64, cursor: i64, existing_index: i64) -> Option<QueueInsertion> {
    // -1 means absent, matching the unseated cursor convention without an FFI buffer.
    if !valid_cursor(count, cursor) || (existing_index != -1 && !valid(count, existing_index)) {
        return None;
    }
    if count == 0 || cursor == -1 {
        return Some(QueueInsertion {
            replace: true,
            remove_index: None,
            insertion_index: 0,
            cursor_after_removal: 0,
        });
    }
    let existing = (existing_index != -1).then_some(existing_index);
    if existing == Some(cursor) {
        return None;
    }
    let adjusted = cursor - i64::from(existing.is_some_and(|index| index < cursor));
    Some(QueueInsertion {
        replace: false,
        remove_index: existing,
        insertion_index: adjusted + 1,
        cursor_after_removal: adjusted,
    })
}

#[uniffi::export]
pub fn queue_should_append(count: i64, existing_index: i64) -> bool {
    count >= 0 && existing_index == -1
}

fn removal_cursor(count: i64, cursor: i64, index: i64, allow_current: bool) -> Option<i64> {
    if !valid(count, index) || !valid_cursor(count, cursor) || (!allow_current && index == cursor) {
        return None;
    }
    Some(if index < cursor {
        cursor - 1
    } else if index == cursor {
        cursor.min(count - 2)
    } else {
        cursor
    })
}

fn move_cursor(count: i64, cursor: i64, source: i64, destination: i64) -> Option<i64> {
    if !valid_cursor(count, cursor)
        || !valid(count, source)
        || !valid(count, destination)
        || source == destination
    {
        return None;
    }
    Some(if source == cursor {
        destination
    } else if source < cursor && destination >= cursor {
        cursor - 1
    } else if source > cursor && destination <= cursor {
        cursor + 1
    } else {
        cursor
    })
}

/// Absent answers cross FFI as `QUEUE_NONE`: an `Option<i64>` return costs a heap
/// RustBuffer per call, about 50 times the decision itself. Real answers are >= -1.
const QUEUE_NONE: i64 = i64::MIN;

#[uniffi::export]
pub fn queue_next_index(count: i64, cursor: i64, mode: u8) -> i64 {
    QueueRepeat::from_code(mode)
        .and_then(|mode| next_index(count, cursor, mode))
        .unwrap_or(QUEUE_NONE)
}

#[uniffi::export]
pub fn queue_previous_index(count: i64, cursor: i64, mode: u8) -> i64 {
    QueueRepeat::from_code(mode)
        .and_then(|mode| previous_index(count, cursor, mode))
        .unwrap_or(QUEUE_NONE)
}

/// `QUEUE_NONE`: no change; -1: replace the queue with the track; n >= 0: remove
/// `existing_index` when present, insert at n + 1 and seat the cursor at n.
#[uniffi::export]
pub fn queue_play_next_cursor(count: i64, cursor: i64, existing_index: i64) -> i64 {
    match play_next_plan(count, cursor, existing_index) {
        None => QUEUE_NONE,
        Some(plan) if plan.replace => -1,
        Some(plan) => plan.cursor_after_removal,
    }
}

#[uniffi::export]
pub fn queue_removal_cursor(count: i64, cursor: i64, index: i64, allow_current: bool) -> i64 {
    removal_cursor(count, cursor, index, allow_current).unwrap_or(QUEUE_NONE)
}

#[uniffi::export]
pub fn queue_move_cursor(count: i64, cursor: i64, source: i64, destination: i64) -> i64 {
    move_cursor(count, cursor, source, destination).unwrap_or(QUEUE_NONE)
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn navigation_and_candidate_order() {
        assert_eq!(next_index(3, 2, QueueRepeat::All), Some(0));
        assert_eq!(next_index(3, 2, QueueRepeat::Off), None);
        assert_eq!(next_index(3, 2, QueueRepeat::One), Some(2));
        assert_eq!(previous_index(3, 0, QueueRepeat::All), Some(2));
        assert_eq!(previous_index(3, 0, QueueRepeat::Off), None);
        assert_eq!(next_index(3, -1, QueueRepeat::Off), Some(0));
        assert_eq!(
            queue_playable_candidates(4, 2, QueueRepeat::All as u8),
            vec![2, 3, 0, 1]
        );
        assert_eq!(
            queue_playable_candidates(4, 2, QueueRepeat::One as u8),
            vec![2]
        );
        assert_eq!(
            queue_playable_candidates(4, 2, QueueRepeat::Off as u8),
            vec![2, 3]
        );
    }
    #[test]
    fn edits_preserve_playing_identity() {
        let plan = play_next_plan(3, 1, 0).unwrap();
        assert_eq!(
            plan,
            QueueInsertion {
                replace: false,
                remove_index: Some(0),
                insertion_index: 1,
                cursor_after_removal: 0
            }
        );
        assert!(play_next_plan(3, 1, 1).is_none());
        assert!(!queue_should_append(3, 2));
        // Duplicate rows are legal in imported playlist contexts: match the first,
        // preserving the original playing entry when that first match precedes it.
        let duplicate = play_next_plan(3, 2, 0).unwrap();
        assert_eq!(duplicate.remove_index, Some(0));
        assert_eq!(duplicate.cursor_after_removal, 1);
        assert_eq!(duplicate.insertion_index, 2);
        assert_eq!(removal_cursor(3, 1, 1, false), None);
        assert_eq!(removal_cursor(1, 0, 0, true), Some(-1));
        assert_eq!(removal_cursor(3, 2, 2, true), Some(1));
        for cursor in 0..4 {
            for source in 0..4 {
                for destination in 0..4 {
                    if source == destination {
                        continue;
                    }
                    let mut identities = vec![0, 1, 2, 3];
                    let playing = identities[cursor];
                    let moved = identities.remove(source);
                    identities.insert(destination, moved);
                    let new_cursor =
                        move_cursor(4, cursor as i64, source as i64, destination as i64).unwrap();
                    assert_eq!(identities[new_cursor as usize], playing);
                }
            }
        }
    }
    #[test]
    fn play_next_code_carries_the_whole_plan() {
        for count in 0..6 {
            for cursor in -1..count {
                for existing in -1..count {
                    let code = queue_play_next_cursor(count, cursor, existing);
                    match play_next_plan(count, cursor, existing) {
                        None => assert_eq!(code, QUEUE_NONE),
                        Some(plan) if plan.replace => {
                            assert_eq!(code, -1);
                            assert_eq!(
                                (
                                    plan.remove_index,
                                    plan.insertion_index,
                                    plan.cursor_after_removal
                                ),
                                (None, 0, 0)
                            );
                        }
                        Some(plan) => {
                            assert!(code >= 0);
                            assert_eq!(plan.cursor_after_removal, code);
                            assert_eq!(plan.insertion_index, code + 1);
                            assert_eq!(plan.remove_index, (existing != -1).then_some(existing));
                        }
                    }
                }
            }
        }
        assert_eq!(queue_removal_cursor(1, 0, 0, true), -1);
        assert_eq!(queue_removal_cursor(3, 1, 1, false), QUEUE_NONE);
        assert_eq!(queue_next_index(3, 2, QueueRepeat::Off as u8), QUEUE_NONE);
        assert_eq!(queue_next_index(3, 0, 3), QUEUE_NONE);
        assert!(queue_playable_candidates(3, 0, 3).is_empty());
    }
    #[test]
    fn malformed_indices_do_not_panic_or_produce_mutations() {
        for count in [-1, 0, 3, i64::MAX] {
            for index in [i64::MIN, -2, -1, 3, i64::MAX] {
                if valid(count, index) {
                    continue;
                }
                assert!(queue_playable_candidates(count, index, QueueRepeat::All as u8).is_empty());
                assert_eq!(removal_cursor(count, 0, index, true), None);
                assert_eq!(move_cursor(count, 0, index, 0), None);
            }
        }
        for index in [i64::MIN, -2, 3, i64::MAX] {
            assert_eq!(next_index(3, index, QueueRepeat::All), None);
            assert_eq!(previous_index(3, index, QueueRepeat::All), None);
            assert_eq!(play_next_plan(1, index, -1), None);
        }
        for index in [i64::MIN, -2, 3, i64::MAX] {
            assert!(play_next_plan(3, 0, index).is_none());
        }
        assert!(!queue_should_append(-1, -1));
        assert!(queue_should_append(0, -1));
        assert!(queue_should_append(3, -1));
        assert_eq!(
            next_index(i64::MAX, i64::MAX - 1, QueueRepeat::All),
            Some(0)
        );
        assert!(queue_playable_candidates(i64::MAX, 0, QueueRepeat::All as u8).is_empty());
    }
}
