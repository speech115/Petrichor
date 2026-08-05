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
                if sections.count > 1 {
                    indexBar(proxy: proxy)
                }
            }
        }
    }

    private func indexBar(proxy: ScrollViewProxy) -> some View {
        let keys = sections.map(\.key)
        return GeometryReader { geometry in
            VStack(spacing: 0) {
                ForEach(keys, id: \.self) { key in
                    Text(key)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            proxy.scrollTo(key, anchor: .top)
                        }
                }
            }
            .frame(width: 24)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        let index = Int(
                            (value.location.y / max(geometry.size.height, 1))
                                * CGFloat(keys.count)
                        )
                        guard keys.indices.contains(index) else { return }
                        proxy.scrollTo(keys[index], anchor: .top)
                    }
            )
        }
        .frame(width: 24)
        .padding(.trailing, 2)
        .accessibilityLabel(String(localized: "Index"))
    }
}
