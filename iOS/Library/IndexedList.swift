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

    /// Current section for VoiceOver's value / adjustable action. Updated by
    /// drag and adjustable steps — not by mirroring plain scroll position.
    @State private var indexSelection: String?
    /// Visual letters stay below accessibility Dynamic Type: a fixed 24pt
    /// column cannot absorb `.body` growth (Contacts/Music drop theirs too).
    /// VoiceOver still gets Index (label/value/adjustable) at AX sizes.
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    init(
        sections: [IndexedSection<Item>],
        bottomClearance: CGFloat = 0,
        @ViewBuilder row: @escaping (Item) -> Row
    ) {
        self.sections = sections
        self.bottomClearance = bottomClearance
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
                            .foregroundColor(.secondaryText)
                    }
                    .id(section.key)
                }
            }
            .listStyle(.plain)
            .overlay(alignment: .trailing) {
                if sections.count > 1 {
                    indexControl(proxy: proxy)
                }
            }
        }
        .padding(.bottom, bottomClearance)
    }

    /// One control: AX traits always; letter glyphs only when they fit.
    private func indexControl(proxy: ScrollViewProxy) -> some View {
        let keys = sections.map(\.key)
        let showLetters = !dynamicTypeSize.isAccessibilitySize
        let width: CGFloat = showLetters ? 24 : 44

        return GeometryReader { geometry in
            ZStack {
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
                                selectSection(keys[index], proxy: proxy)
                            }
                    )

                if showLetters {
                    // Letters at slot centers, natural size — stretching them
                    // into the slot makes the contrast audit sample empty space.
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
            }
            .frame(width: width)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(String(localized: "Index"))
            .accessibilityValue(indexSelection ?? keys.first ?? "")
            .accessibilityAdjustableAction { direction in
                adjustIndex(direction: direction, keys: keys, proxy: proxy)
            }
        }
        .frame(width: width)
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
                selectSection(keys[currentIndex + 1], proxy: proxy)
            }
        case .decrement:
            if currentIndex > 0 {
                selectSection(keys[currentIndex - 1], proxy: proxy)
            }
        @unknown default:
            break
        }
    }

    private func selectSection(_ key: String, proxy: ScrollViewProxy) {
        indexSelection = key
        proxy.scrollTo(key, anchor: .top)
    }
}
