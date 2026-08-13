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
    let load: @Sendable () async -> [Track]
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
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    @State private var tracks: [Track] = []
    @State private var sections: [IndexedSection<Track>] = []
    @State private var loadTask: Task<Void, Never>?
    @State private var isLoading = true
    @State private var showsSpinner = false
    @State private var spinnerTask: Task<Void, Never>?

    /// A list that arrives in 30 ms feels slower behind a spinner than with no
    /// spinner at all: the eye reads the flash as the wait. Most of these loads
    /// are that fast, so the spinner waits this long before claiming there is
    /// something to wait for.
    private var spinnerDelay: Duration { .milliseconds(200) }

    var body: some View {
        Group {
            if isIndexed {
                IndexedList(
                    sections: sections,
                    bottomClearance: IndexedListSectionFactory.floatingTabBarClearance(for: dynamicTypeSize)
                ) { item in
                    row(item, tracks)
                }
            } else {
                plainList
            }
        }
        .overlay {
            if showsSpinner, sections.isEmpty, libraryManager.shouldShowMainUI {
                ProgressView()
                    .transition(.opacity)
            } else if !isLoading, showEmptyState, sections.isEmpty, libraryManager.shouldShowMainUI {
                ContentUnavailableView(emptyTitle, systemImage: emptyIcon)
                    .transition(.opacity)
            }
        }
        .task(id: identity) {
            await loadRows()
        }
        .onChange(of: libraryManager.libraryRevision) { _, _ in
            scheduleLoad()
        }
        .onDisappear {
            loadTask?.cancel()
            spinnerTask?.cancel()
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
                        // The system header gray sits at ~3.3:1 in light
                        // mode; the shared secondary text color clears 4.5:1.
                        Text(section.key)
                            .foregroundColor(.secondaryText)
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
        isLoading = true
        scheduleSpinner()

        let loader = load
        let loaded = await Task.detached(priority: .userInitiated) {
            await loader()
        }.value

        spinnerTask?.cancel()
        guard !Task.isCancelled else { return }
        tracks = loaded
        sections = sectioner(loaded)
        isLoading = false
        withAnimation(.easeOut(duration: AnimationDuration.standardDuration)) {
            showsSpinner = false
        }
        onRowsChange?(loaded)
    }

    private func scheduleSpinner() {
        spinnerTask?.cancel()
        spinnerTask = Task { @MainActor in
            try? await Task.sleep(for: spinnerDelay)
            guard !Task.isCancelled, isLoading else { return }
            withAnimation(.easeOut(duration: AnimationDuration.standardDuration)) {
                showsSpinner = true
            }
        }
    }
}
