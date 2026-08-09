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
    /// action moves it one section at a time.
    @State private var indexSelection: String?
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
                        Text(section.key)
                    }
                    .id(section.key)
                }
            }
            .listStyle(.plain)
            .overlay(alignment: .trailing) {
                // Hidden at accessibility Dynamic Type sizes: the bar is a
                // fixed 24pt column with no room to grow into, and a real
                // text style there would push letters off the screen's
                // trailing edge. Matches Contacts/Music, which drop their
                // own alphabet index at the same sizes; the list itself
                // stays fully reachable by scrolling or VoiceOver swipes.
                if sections.count > 1, !dynamicTypeSize.isAccessibilitySize {
                    indexBar(proxy: proxy)
                }
            }
        }
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
                // empty space (ratio 1:1, "Contrast failed"). A real text
                // style, not a capped one — this view only renders below
                // accessibility Dynamic Type sizes (see the overlay above),
                // so it never needs to absorb their growth.
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
            // `.accessibilityAdjustableAction` itself adds the adjustable trait.
            .accessibilityAdjustableAction { direction in
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
        }
        .frame(width: 24)
        .padding(.trailing, 2)
    }

    /// Moves the list to `key`'s section and records it as the current one.
    private func selectSection(_ key: String, in keys: [String], proxy: ScrollViewProxy) {
        indexSelection = key
        proxy.scrollTo(key, anchor: .top)
    }
}
