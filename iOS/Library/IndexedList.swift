//
// IndexedList (iOS)
//
// Lazy list with an alphabet index: rows are grouped into sections by a key
// and the trailing index bar jumps to a section. Built on `List`, so rows stay
// lazy at 2829 tracks and swipe actions (ticket 05) keep working on top.
//

import SwiftUI

struct IndexedSection<Item: Identifiable>: Identifiable {
    let key: String
    let items: [Item]

    var id: String { key }
}

enum IndexedListSectionFactory {
    /// Groups `items` into sections by `key`, preserving each item's relative
    /// order within a section. Sections are sorted ascending by key; callers
    /// needing another order re-sort the result.
    static func sections<Item>(
        from items: [Item],
        key: @escaping (Item) -> String
    ) -> [IndexedSection<Item>] where Item: Identifiable {
        let grouped = Dictionary(grouping: items, by: key)
        return grouped.keys
            .sorted()
            .map { IndexedSection(key: $0, items: grouped[$0] ?? []) }
    }

    /// Section key for a display name: first character uppercased for letters,
    /// digits kept as-is (release years), everything else collapses to "#".
    static func sectionKey(for name: String) -> String {
        guard let first = name.first else { return "#" }
        if first.isLetter {
            return first.uppercased()
        }
        if first.isNumber {
            return String(first)
        }
        return "#"
    }
}

struct IndexedList<Item: Identifiable, Row: View>: View {
    let sections: [IndexedSection<Item>]
    let row: (Item) -> Row
    /// The section the index bar is currently on, for VoiceOver's value and
    /// adjustable action. Touch updates it as the finger drags; the adjustable
    /// action moves it one section at a time; plain scrolling syncs it with
    /// the section actually at the top of the list.
    @State private var indexSelection: String?
    /// Each mounted section header reports its top edge in the list's own
    /// coordinate space; as the list scrolls, the topmost visible section is
    /// the one whose top has just crossed the list's top edge.
    @State private var sectionTops: [String: CGFloat] = [:]
    /// The bar is a fixed 24pt-wide column pinned to the trailing edge, with
    /// no room to its right to grow into. A real text style is required —
    /// the audit flags a capped/raw size as "Dynamic Type font sizes are
    /// unsupported" even though the letters aren't individual VoiceOver
    /// elements — but at the largest accessibility sizes that same style
    /// renders wide enough to push letters off the screen's trailing edge.
    /// Apple's own apps resolve this by dropping the index at accessibility
    /// sizes (Contacts, Music); VoiceOver users still reach every section by
    /// swiping through the list, just in more steps.
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    init(
        sections: [IndexedSection<Item>],
        @ViewBuilder row: @escaping (Item) -> Row
    ) {
        self.sections = sections
        self.row = row
    }

    var body: some View {
        ScrollViewReader { proxy in
            List {
                ForEach(sections) { section in
                    Section {
                        ForEach(section.items) { item in
                            row(item)
                        }
                    } header: {
                        // The system header gray sits at ~3.3:1 in light
                        // mode; the shared secondary text color clears 4.5:1.
                        Text(section.key)
                            .foregroundColor(.secondaryText)
                            .background {
                                GeometryReader { geometry in
                                    Color.clear.preference(
                                        key: SectionTopPreferenceKey.self,
                                        value: [
                                            section.key: geometry.frame(
                                                in: .named(Self.scrollCoordinateSpace)
                                            ).minY
                                        ]
                                    )
                                }
                            }
                    }
                    .id(section.key)
                }
            }
            .listStyle(.plain)
            .coordinateSpace(name: Self.scrollCoordinateSpace)
            .onPreferenceChange(SectionTopPreferenceKey.self) { tops in
                sectionTops = tops
                syncIndexSelection()
            }
            .onScrollGeometryChange(for: CGFloat.self) { geometry in
                geometry.contentOffset.y
            } action: { _, _ in
                syncIndexSelection()
            }
            .overlay(alignment: .trailing) {
                // Visual alphabet letters stay below accessibility Dynamic Type
                // sizes: a fixed 24pt column cannot absorb `.body` growth, and
                // Contacts/Music drop their own letter column the same way.
                // At accessibility sizes VoiceOver still gets the Index
                // adjustable (label + value + swipe up/down) so jump-by-letter
                // survives AX5 without overflowing the trailing edge.
                if sections.count > 1 {
                    if dynamicTypeSize.isAccessibilitySize {
                        voiceOverIndex(proxy: proxy)
                    } else {
                        indexBar(proxy: proxy)
                    }
                }
            }
        }
    }

    /// VoiceOver-only index control for accessibility Dynamic Type sizes.
    private func voiceOverIndex(proxy: ScrollViewProxy) -> some View {
        let keys = sections.map(\.key)
        return Color.clear
            .frame(width: 44)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(String(localized: "Index"))
            .accessibilityValue(indexSelection ?? keys.first ?? "")
            .accessibilityAdjustableAction { direction in
                adjustIndex(direction: direction, keys: keys, proxy: proxy)
            }
            .padding(.trailing, 2)
    }

    private func indexBar(proxy: ScrollViewProxy) -> some View {
        let keys = sections.map(\.key)
        return GeometryReader { geometry in
            ZStack {
                // Full-height drag surface: any touch on the bar selects the
                // section under the finger. `minimumDistance: 0` makes the
                // same gesture cover plain taps, so the letters themselves
                // need no tap target.
                Color.clear
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { value in
                                let index = Int(
                                    (value.location.y / max(geometry.size.height, 1))
                                        * CGFloat(keys.count)
                                )
                                guard keys.indices.contains(index) else { return }
                                let key = keys[index]
                                indexSelection = key
                                proxy.scrollTo(key, anchor: .top)
                            }
                    )
                // The letters sit at their slot centers at their natural
                // size. They must not be stretched into their slots: the
                // accessibility audit samples an element's text pixels at
                // its frame center, and a slot-sized letter element reads as
                // empty space (ratio 1:1, "Contrast failed").
                ForEach(Array(keys.enumerated()), id: \.offset) { index, key in
                    Text(key)
                        .font(.body)
                        .foregroundColor(.secondaryText)
                        .frame(width: 24)
                        .position(
                            x: geometry.size.width / 2,
                            y: geometry.size.height * (CGFloat(index) + 0.5)
                                / CGFloat(keys.count)
                        )
                }
            }
            .frame(width: 24)
            // One element: the letters are touch targets, not separate
            // VoiceOver elements. Value carries the current section; the
            // adjustable action moves through sections the way the drag does.
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(String(localized: "Index"))
            .accessibilityValue(indexSelection ?? keys.first ?? "")
            .accessibilityAdjustableAction { direction in
                adjustIndex(direction: direction, keys: keys, proxy: proxy)
            }
        }
        .frame(width: 24)
        .padding(.trailing, 2)
    }

    private func adjustIndex(
        direction: AccessibilityAdjustmentDirection,
        keys: [String],
        proxy: ScrollViewProxy
    ) {
        guard let current = indexSelection ?? keys.first,
              let currentIndex = keys.firstIndex(of: current) else { return }
        switch direction {
        case .increment:
            if currentIndex + 1 < keys.count {
                selectSection(keys[currentIndex + 1], in: keys, proxy: proxy)
            }
        case .decrement:
            if currentIndex > 0 {
                selectSection(keys[currentIndex - 1], in: keys, proxy: proxy)
            }
        @unknown default:
            break
        }
    }

    /// Moves the list to `key`'s section and records it as the current one.
    private func selectSection(_ key: String, in keys: [String], proxy: ScrollViewProxy) {
        indexSelection = key
        proxy.scrollTo(key, anchor: .top)
    }

    /// Mirrors the section actually at the top of the list into the index
    /// bar's value, so VoiceOver announces the current letter after a plain
    /// scroll, not only after an index-bar drag or an adjustable step.
    private func syncIndexSelection() {
        // Topmost visible = the header with the largest top edge that has
        // already crossed the list's top edge. No header crossed it yet (the
        // list sits at the very top, or no header is mounted): first section.
        let topmost = sectionTops
            .filter { $0.value <= 0 }
            .max { $0.value < $1.value }?
            .key
        indexSelection = topmost ?? sections.first?.key
    }

    private static var scrollCoordinateSpace: String { "indexedList" }
}

/// Tops of mounted section headers in the list's coordinate space, keyed by
/// section key. Lazy sections join and leave the dictionary as they mount.
private struct SectionTopPreferenceKey: PreferenceKey {
    static var defaultValue: [String: CGFloat] = [:]

    static func reduce(value: inout [String: CGFloat], nextValue: () -> [String: CGFloat]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}
