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

extension IndexedSection: Sendable where Item: Sendable {}

enum IndexedListSectionFactory {
    /// Clearance so the last row sits above ContentView's floating tab bar.
    /// Owned by the host chrome, not IndexedList itself.
    static func floatingTabBarClearance(for dynamicTypeSize: DynamicTypeSize) -> CGFloat {
        dynamicTypeSize.isAccessibilitySize ? 100 : 80
    }

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
    /// Host-owned inset so rows clear floating chrome (tab bar).
    var bottomClearance: CGFloat = 0

    init(
        sections: [IndexedSection<Item>],
        bottomClearance: CGFloat = 0,
        @ViewBuilder row: @escaping (Item) -> Row
    ) {
        self.sections = sections
        self.bottomClearance = bottomClearance
        self.row = row
    }

    // The index bar is the system one (iOS 26 `sectionIndexLabel`), the same
    // control Contacts and Music use: haptic ticks while scrubbing, the
    // magnified letter, VoiceOver's adjustable index and the letter sampling
    // on short screens all come with it.
    var body: some View {
        List {
            ForEach(sections) { section in
                Section {
                    // Native section headers cap Dynamic Type. A heading row
                    // keeps the letters scalable without weakening the audit.
                    Text(section.key)
                        .font(.subheadline.weight(.semibold))
                        .foregroundColor(.secondaryText)
                        .accessibilityAddTraits(.isHeader)
                        .listRowSeparator(.hidden)
                    ForEach(section.items) { item in
                        row(item)
                    }
                }
                .sectionIndexLabel(section.key)
            }
        }
        .listStyle(.plain)
        .listSectionIndexVisibility(sections.count > 1 ? .visible : .hidden)
        .padding(.bottom, bottomClearance)
    }
}
