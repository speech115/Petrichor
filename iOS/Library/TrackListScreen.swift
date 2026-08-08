//
// TrackListScreen (iOS)
//
// The shared track-list skeleton: off-main loading with the
// reload-on-library-change plumbing, section building, the empty state and
// the optional header slot all live here once. Hosts supply the loader, a
// sectioner (alphabet letters, album discs, a single playlist blob), the row
// builder and their own header; the screen keeps TrackRow rows lazy and
// cancels stale loads on disappear.
//

import SwiftUI

struct TrackListScreen<Header: View, Row: View>: View {
    /// Identity for the loader: `load` re-runs when it changes.
    let identity: AnyHashable
    /// Loads the rows for the current identity, off the main thread.
    let load: () async -> [Track]
    /// Groups loaded rows into list sections (index letters, discs, one blob).
    let sectioner: ([Track]) -> [IndexedSection<Track>]
    /// Whether the alphabet index bar is shown (multi-section lists only).
    var isIndexed = false
    /// `.plain` for single-section lists, `.insetGrouped` otherwise.
    var usesPlainStyle = false
    /// Optional title of the header section (e.g. "Folders").
    var headerTitle: String? = nil
    /// Whether the header section can appear; hosts with conditional headers
    /// (a folder with no subfolders) pass a computed flag.
    var showsHeader = true
    /// Whether the empty state can appear; hosts with their own empty logic
    /// (a folder that still has subfolders) pass `false`.
    var showEmptyState = true
    var emptyTitle: String = String(localized: "No Tracks")
    var emptyIcon: String = Icons.musicNote
    /// Called with the loaded rows after every (re)load, so hosts can derive
    /// state from rows without re-querying (e.g. a toolbar action's
    /// disabled flag).
    var onRowsChange: (([Track]) -> Void)? = nil

    @ViewBuilder var header: ([Track]) -> Header?
    @ViewBuilder var row: (Track, [Track]) -> Row

    @EnvironmentObject private var libraryManager: LibraryManager

    @State private var tracks: [Track] = []
    @State private var sections: [IndexedSection<Track>] = []
    @State private var loadTask: Task<Void, Never>?

    var body: some View {
        Group {
            if isIndexed {
                IndexedList(sections: sections) { item in
                    row(item, tracks)
                }
            } else {
                plainList
            }
        }
        .overlay {
            if showEmptyState, sections.isEmpty, libraryManager.shouldShowMainUI {
                ContentUnavailableView(emptyTitle, systemImage: emptyIcon)
            }
        }
        .task(id: identity) {
            await loadRows()
        }
        .onChange(of: libraryManager.tracks) { _, _ in
            scheduleLoad()
        }
        .onDisappear {
            loadTask?.cancel()
        }
    }

    private var plainList: some View {
        Group {
            if usesPlainStyle {
                listBody.listStyle(.plain)
            } else {
                listBody.listStyle(.insetGrouped)
            }
        }
    }

    private var listBody: some View {
        List {
            if showsHeader {
                Section {
                    header(tracks)
                } header: {
                    if let headerTitle, !headerTitle.isEmpty {
                        Text(headerTitle)
                    }
                }
            }

            ForEach(sections) { section in
                Section {
                    ForEach(section.items) { item in
                        row(item, tracks)
                    }
                } header: {
                    if !section.key.isEmpty {
                        Text(section.key)
                    }
                }
            }
        }
    }

    private func scheduleLoad() {
        loadTask?.cancel()
        loadTask = Task {
            await loadRows()
        }
    }

    private func loadRows() async {
        let loaded = await Task.detached(priority: .userInitiated) {
            await load()
        }.value

        guard !Task.isCancelled else { return }
        tracks = loaded
        sections = sectioner(loaded)
        onRowsChange?(loaded)
    }
}
