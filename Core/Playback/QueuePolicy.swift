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
        return queueNextIndex(count: Int64(count), cursor: Int64(cursor), mode: rustMode(mode)).map(Int.init)
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
        return queuePreviousIndex(count: Int64(count), cursor: Int64(cursor), mode: rustMode(mode)).map(Int.init)
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

    static func playNextPlan(ids: [String], cursor: Int, id: String) -> Insertion? {
        #if os(macOS)
        guard let plan = queuePlayNextPlan(ids: ids, cursor: Int64(cursor), id: id) else { return nil }
        return Insertion(
            replace: plan.replace,
            removeIndex: plan.removeIndex.map(Int.init),
            insertionIndex: Int(plan.insertionIndex),
            cursorAfterRemoval: Int(plan.cursorAfterRemoval)
        )
        #else
        guard cursor >= -1, cursor < ids.count else { return nil }
        if ids.isEmpty || cursor == -1 {
            return Insertion(replace: true, removeIndex: nil, insertionIndex: 0, cursorAfterRemoval: 0)
        }
        let existing = ids.firstIndex(of: id)
        guard existing != cursor else { return nil }
        let adjusted = cursor - ((existing.map { $0 < cursor } ?? false) ? 1 : 0)
        return Insertion(
            replace: false, removeIndex: existing, insertionIndex: adjusted + 1, cursorAfterRemoval: adjusted
        )
        #endif
    }

    static func shouldAppend(ids: [String], id: String) -> Bool {
        #if os(macOS)
        return queueShouldAppend(ids: ids, id: id)
        #else
        return !ids.contains(id)
        #endif
    }

    static func removalCursor(count: Int, cursor: Int, index: Int, allowCurrent: Bool) -> Int? {
        #if os(macOS)
        return queueRemovalCursor(
            count: Int64(count), cursor: Int64(cursor), index: Int64(index), allowCurrent: allowCurrent
        ).map(Int.init)
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
        return queueMoveCursor(
            count: Int64(count), cursor: Int64(cursor), source: Int64(source), destination: Int64(destination)
        ).map(Int.init)
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
    private static func rustMode(_ mode: RepeatMode) -> QueueRepeat {
        switch mode {
        case .off: return .off
        case .one: return .one
        case .all: return .all
        }
    }
    #endif
}
