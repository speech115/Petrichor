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
    let sectioner: @Sendable ([Track]) -> [IndexedSection<Track>]
    /// Live manager-owned rows, when available, remain authoritative for
    /// playlists whose membership can change without a library revision.
    var initialRows: [Track]? = nil
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

    @ObservedObject private var screenCache = LibraryScreenCache.shared

    @State private var snapshot: LibraryScreenCache.Tracks?
    @State private var snapshotIdentity: AnyHashable?

    private var presentation: LibraryScreenCache.Tracks? {
        if let initialRows {
            return LibraryScreenCache.Tracks(rows: initialRows, sections: sectioner(initialRows))
        }
        if snapshotIdentity == identity, let snapshot { return snapshot }
        return LibraryScreenCache.shared.trackList(identity, revision: libraryManager.libraryRevision)
    }

    private var tracks: [Track] { presentation?.rows ?? [] }
    private var sections: [IndexedSection<Track>] { presentation?.sections ?? [] }
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
            if presentation == nil, showsSpinner, sections.isEmpty, libraryManager.shouldShowMainUI {
                ProgressView()
                    .transition(.opacity)
            } else if !isLoading, showEmptyState, sections.isEmpty, libraryManager.shouldShowMainUI {
                ContentUnavailableView(emptyTitle, systemImage: emptyIcon)
                    .transition(.opacity)
            }
        }
        .task(id: ReloadKey(
            identity: identity,
            revision: libraryManager.libraryRevision,
            trackRevision: screenCache.trackRevision
        )) {
            await loadRows()
        }
        .onDisappear {
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
            if showsHeader, presentation != nil {
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

    private struct ReloadKey: Equatable {
        let identity: AnyHashable
        let revision: Int
        let trackRevision: Int
    }

    private func loadRows() async {
        isLoading = true
        scheduleSpinner()

        let revision = libraryManager.libraryRevision
        let trackRevision = screenCache.trackRevision
        let requestedIdentity = identity
        let prepared: LibraryScreenCache.Tracks
        if initialRows == nil, let cached = LibraryScreenCache.shared.trackList(identity, revision: revision) {
            prepared = cached
        } else {
            let loader = load
            let sectioner = sectioner
            prepared = await Task.detached(priority: .userInitiated) {
                let rows = await loader()
                return LibraryScreenCache.Tracks(rows: rows, sections: sectioner(rows))
            }.value
            await LibraryScreenCache.prepareArtwork(
                prepared.sections.flatMap(\.items), database: libraryManager.databaseManager
            )
        }
        guard !Task.isCancelled, libraryManager.libraryRevision == revision,
              screenCache.trackRevision == trackRevision else { return }
        spinnerTask?.cancel()
        if initialRows == nil {
            LibraryScreenCache.shared.store(prepared, identity: requestedIdentity, revision: revision)
        }
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            snapshot = prepared
            snapshotIdentity = requestedIdentity
            isLoading = false
            showsSpinner = false
        }
        onRowsChange?(prepared.rows)
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
