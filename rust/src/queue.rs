//! Deterministic queue edits; Swift owns track storage and engine event ordering.

#[derive(Clone, Copy, uniffi::Enum)]
pub enum QueueRepeat {
    Off,
    One,
    All,
}

#[derive(Debug, PartialEq, uniffi::Record)]
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

#[uniffi::export]
pub fn queue_next_index(count: i64, cursor: i64, mode: QueueRepeat) -> Option<i64> {
    if !valid_cursor(count, cursor) || count == 0 {
        return None;
    }
    match mode {
        QueueRepeat::One => valid(count, cursor).then_some(cursor),
        QueueRepeat::All => Some(if cursor == count - 1 { 0 } else { cursor + 1 }),
        QueueRepeat::Off => (cursor < count - 1).then_some(cursor + 1),
    }
}

#[uniffi::export]
pub fn queue_previous_index(count: i64, cursor: i64, mode: QueueRepeat) -> Option<i64> {
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
pub fn queue_playable_candidates(count: i64, index: i64, mode: QueueRepeat) -> Vec<i64> {
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

#[uniffi::export]
pub fn queue_play_next_plan(
    count: i64,
    cursor: i64,
    existing_index: i64,
) -> Option<QueueInsertion> {
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

#[uniffi::export]
pub fn queue_removal_cursor(
    count: i64,
    cursor: i64,
    index: i64,
    allow_current: bool,
) -> Option<i64> {
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

#[uniffi::export]
pub fn queue_move_cursor(count: i64, cursor: i64, source: i64, destination: i64) -> Option<i64> {
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

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn navigation_and_candidate_order() {
        assert_eq!(queue_next_index(3, 2, QueueRepeat::All), Some(0));
        assert_eq!(queue_next_index(3, 2, QueueRepeat::Off), None);
        assert_eq!(queue_next_index(3, 2, QueueRepeat::One), Some(2));
        assert_eq!(queue_previous_index(3, 0, QueueRepeat::All), Some(2));
        assert_eq!(queue_previous_index(3, 0, QueueRepeat::Off), None);
        assert_eq!(queue_next_index(3, -1, QueueRepeat::Off), Some(0));
        assert_eq!(
            queue_playable_candidates(4, 2, QueueRepeat::All),
            vec![2, 3, 0, 1]
        );
        assert_eq!(queue_playable_candidates(4, 2, QueueRepeat::One), vec![2]);
        assert_eq!(
            queue_playable_candidates(4, 2, QueueRepeat::Off),
            vec![2, 3]
        );
    }
    #[test]
    fn edits_preserve_playing_identity() {
        let plan = queue_play_next_plan(3, 1, 0).unwrap();
        assert_eq!(
            plan,
            QueueInsertion {
                replace: false,
                remove_index: Some(0),
                insertion_index: 1,
                cursor_after_removal: 0
            }
        );
        assert!(queue_play_next_plan(3, 1, 1).is_none());
        assert!(!queue_should_append(3, 2));
        // Duplicate rows are legal in imported playlist contexts: match the first,
        // preserving the original playing entry when that first match precedes it.
        let duplicate = queue_play_next_plan(3, 2, 0).unwrap();
        assert_eq!(duplicate.remove_index, Some(0));
        assert_eq!(duplicate.cursor_after_removal, 1);
        assert_eq!(duplicate.insertion_index, 2);
        assert_eq!(queue_removal_cursor(3, 1, 1, false), None);
        assert_eq!(queue_removal_cursor(1, 0, 0, true), Some(-1));
        assert_eq!(queue_removal_cursor(3, 2, 2, true), Some(1));
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
                        queue_move_cursor(4, cursor as i64, source as i64, destination as i64)
                            .unwrap();
                    assert_eq!(identities[new_cursor as usize], playing);
                }
            }
        }
    }
    #[test]
    fn malformed_indices_do_not_panic_or_produce_mutations() {
        for count in [-1, 0, 3, i64::MAX] {
            for index in [i64::MIN, -2, -1, 3, i64::MAX] {
                if valid(count, index) {
                    continue;
                }
                assert!(queue_playable_candidates(count, index, QueueRepeat::All).is_empty());
                assert_eq!(queue_removal_cursor(count, 0, index, true), None);
                assert_eq!(queue_move_cursor(count, 0, index, 0), None);
            }
        }
        for index in [i64::MIN, -2, 3, i64::MAX] {
            assert_eq!(queue_next_index(3, index, QueueRepeat::All), None);
            assert_eq!(queue_previous_index(3, index, QueueRepeat::All), None);
            assert_eq!(queue_play_next_plan(1, index, -1), None);
        }
        for index in [i64::MIN, -2, 3, i64::MAX] {
            assert!(queue_play_next_plan(3, 0, index).is_none());
        }
        assert!(!queue_should_append(-1, -1));
        assert!(queue_should_append(0, -1));
        assert!(queue_should_append(3, -1));
        assert_eq!(
            queue_next_index(i64::MAX, i64::MAX - 1, QueueRepeat::All),
            Some(0)
        );
        assert!(queue_playable_candidates(i64::MAX, 0, QueueRepeat::All).is_empty());
    }
}
