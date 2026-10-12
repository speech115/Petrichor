//
// Queue policy crosses one platform seam. Swift keeps Track storage and publishes
// edits before notifying the playback engine; Rust computes macOS decisions.
//

import Foundation
#if os(macOS)
import PetrichorCore
#endif

enum QueuePolicy {
    struct Insertion {
        let replace: Bool
        let removeIndex: Int?
        let insertionIndex: Int
        let cursorAfterRemoval: Int
    }

    static func nextIndex(count: Int, cursor: Int, mode: RepeatMode) -> Int? {
        #if os(macOS)
        return answer(queueNextIndex(count: Int64(count), cursor: Int64(cursor), mode: rustMode(mode)))
        #else
        guard count > 0, cursor >= -1, cursor < count else { return nil }
        switch mode {
        case .one: return cursor >= 0 ? cursor : nil
        case .all: return cursor == count - 1 ? 0 : cursor + 1
        case .off: return cursor < count - 1 ? cursor + 1 : nil
        }
        #endif
    }

    static func previousIndex(count: Int, cursor: Int, mode: RepeatMode) -> Int? {
        #if os(macOS)
        return answer(queuePreviousIndex(count: Int64(count), cursor: Int64(cursor), mode: rustMode(mode)))
        #else
        guard count > 0, cursor >= -1, cursor < count else { return nil }
        switch mode {
        case .one: return cursor >= 0 ? cursor : nil
        case .all: return cursor > 0 ? cursor - 1 : count - 1
        case .off: return cursor > 0 ? cursor - 1 : nil
        }
        #endif
    }

    static func playableCandidates(count: Int, index: Int, mode: RepeatMode) -> [Int] {
        #if os(macOS)
        return queuePlayableCandidates(count: Int64(count), index: Int64(index), mode: rustMode(mode)).map(Int.init)
        #else
        guard index >= 0, index < count else { return [] }
        switch mode {
        case .one: return [index]
        case .all: return Array(index..<count) + Array(0..<index)
        case .off: return Array(index..<count)
        }
        #endif
    }

    static func playNextPlan(tracks: [Track], cursor: Int, track: Track) -> Insertion? {
        // Read identity positions from Swift-owned storage; Rust decides the edit.
        let existing = tracks.firstIndex(of: track)
        #if os(macOS)
        // Rust's code: none, -1 to replace the queue, or the cursor after removing `existing`.
        let code = queuePlayNextCursor(
            count: Int64(tracks.count), cursor: Int64(cursor), existingIndex: existing.map(Int64.init) ?? -1
        )
        guard let cursor = answer(code) else { return nil }
        if cursor == -1 {
            return Insertion(replace: true, removeIndex: nil, insertionIndex: 0, cursorAfterRemoval: 0)
        }
        return Insertion(replace: false, removeIndex: existing, insertionIndex: cursor + 1, cursorAfterRemoval: cursor)
        #else
        guard cursor >= -1, cursor < tracks.count else { return nil }
        if tracks.isEmpty || cursor == -1 {
            return Insertion(replace: true, removeIndex: nil, insertionIndex: 0, cursorAfterRemoval: 0)
        }
        guard existing != cursor else { return nil }
        let adjusted = cursor - ((existing.map { $0 < cursor } ?? false) ? 1 : 0)
        return Insertion(
            replace: false, removeIndex: existing, insertionIndex: adjusted + 1, cursorAfterRemoval: adjusted
        )
        #endif
    }

    static func shouldAppend(tracks: [Track], track: Track) -> Bool {
        let existing = tracks.firstIndex(of: track)
        #if os(macOS)
        return queueShouldAppend(count: Int64(tracks.count), existingIndex: existing.map(Int64.init) ?? -1)
        #else
        return existing == nil
        #endif
    }

    static func removalCursor(count: Int, cursor: Int, index: Int, allowCurrent: Bool) -> Int? {
        #if os(macOS)
        return answer(queueRemovalCursor(
            count: Int64(count), cursor: Int64(cursor), index: Int64(index), allowCurrent: allowCurrent
        ))
        #else
        guard index >= 0, index < count, cursor >= -1, cursor < count,
              allowCurrent || index != cursor else { return nil }
        if index < cursor { return cursor - 1 }
        if index == cursor { return min(cursor, count - 2) }
        return cursor
        #endif
    }

    static func moveCursor(count: Int, cursor: Int, source: Int, destination: Int) -> Int? {
        #if os(macOS)
        return answer(queueMoveCursor(
            count: Int64(count), cursor: Int64(cursor), source: Int64(source), destination: Int64(destination)
        ))
        #else
        guard cursor >= -1, cursor < count, source >= 0, source < count,
              destination >= 0, destination < count, source != destination else { return nil }
        if source == cursor { return destination }
        if source < cursor && destination >= cursor { return cursor - 1 }
        if source > cursor && destination <= cursor { return cursor + 1 }
        return cursor
        #endif
    }

    #if os(macOS)
    /// Rust returns `Int64.min` for "no answer" so the call needs no FFI buffer.
    private static func answer(_ value: Int64) -> Int? {
        value == .min ? nil : Int(value)
    }

    /// Rust's `QueueRepeat` codes.
    private static func rustMode(_ mode: RepeatMode) -> UInt8 {
        switch mode {
        case .off: return 0
        case .one: return 1
        case .all: return 2
        }
    }
    #endif
}
