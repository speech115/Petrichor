import SwiftUI

struct EntityDetailView: View {
    let entity: any Entity
    let onBack: (() -> Void)?

    @EnvironmentObject var playlistManager: PlaylistManager
    @EnvironmentObject var libraryManager: LibraryManager
    @State private var tracks: [Track] = []
    @State private var selectedTrackID: String?
    @State private var isLoading = true
    @State private var isBackButtonHovered = false
    @State private var isArtworkHovered = false
    @State private var showingImagePicker = false
    @State private var overrideArtworkData: Data?
    @State private var artworkDeleted = false
    @State private var artistBio: String?
    @State private var gradientColors: [Color] = []
    @State private var gradientRevision: UInt64 = 0
    @State private var gradientTask: Task<Void, Never>?

    init(entity: any Entity, onBack: (() -> Void)? = nil) {
        self.entity = entity
        self.onBack = onBack
    }

    @AppStorage("useArtworkColors")
    private var useArtworkColors = true

    @AppStorage("trackTableRowSize")
    private var trackTableRowSize: TableRowSize = .expanded

    @Environment(\.colorScheme)
    var colorScheme

    @State private var trackTableSortOrder = [KeyPathComparator(\Track.title)]

    var body: some View {
        VStack(spacing: 0) {
            // Header with back button
            entityHeader

            // Track list
            if isLoading {
                loadingView
            } else if tracks.isEmpty {
                emptyView
            } else {
                TrackView(
                    tracks: tracks,
                    selectedTrackID: $selectedTrackID,
                    playlistID: nil,
                    entityID: entity.id,
                    queueSource: queueSource,
                    layout: entity is AlbumEntity ? .album : .standard,
                    sortOrder: $trackTableSortOrder,
                    onPlayTrack: { track in
                        playTrack(track)
                    },
                    contextMenuItems: { track, _ in
                        TrackContextMenu.createMenuItems(
                            for: track,
                            playlistManager: playlistManager,
                            currentContext: .library
                        )
                    }
                )
            }
        }
        .background {
            ZStack {
                Color(platformColor: .windowBackgroundColor)
                // The cover's colors wash the whole page and fade out downward,
                // as on the iPhone album page.
                if !gradientColors.isEmpty {
                    GradientBackground(colors: gradientColors)
                        .mask(LinearGradient(colors: [.black, .black.opacity(0.35), .clear], startPoint: .top, endPoint: .bottom))
                        .transaction { $0.animation = nil }
                }
            }
        }
        .onAppear {
            loadTracks()
            updateGradientColors()
        }
        .onChange(of: entity.id) { oldValue, newValue in
            if oldValue != newValue {
                loadTracks()
                updateGradientColors()
            }
        }
        .onChange(of: displayedArtworkData) {
            // Same entity IDs can receive replacement artwork. Advancing the
            // retained revision here invalidates extraction started by the old
            // view value before it can publish into the shared @State slot.
            updateGradientColors()
        }
        .onChange(of: colorScheme) {
            updateGradientColors()
        }
        .onChange(of: useArtworkColors) {
            updateGradientColors()
        }
    }

    // MARK: - Header

    private var entityHeader: some View {
        EntityHeader {
            HStack(alignment: .bottom, spacing: 24) {
                // Back button
                if let onBack = onBack {
                    backButton(onBack)
                        .frame(maxHeight: .infinity, alignment: .top)
                }

                // Artwork
                entityArtwork
                // Info and controls
                VStack(alignment: .leading, spacing: 16) {
                    if entity is AlbumEntity {
                        albumEntityInfo
                    } else {
                        artistEntityInfo
                    }

                    entityControls
                }

                Spacer()
            }
            .fixedSize(horizontal: false, vertical: true)
        }
        .overlay(alignment: .bottomTrailing) {
            HStack(spacing: 12) {
                TrackTableOptionsDropdown(
                    sortOrder: $trackTableSortOrder,
                    tableRowSize: $trackTableRowSize
                )
            }
            .padding([.bottom, .trailing], 12)
        }
    }

    @ViewBuilder
    private func backButton(_ onBack: @escaping () -> Void) -> some View {
        if #available(macOS 26.0, *) {
            Button(action: onBack) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.glass)
            .buttonBorderShape(.circle)
            .controlSize(.small)
            .help("Back")
        } else {
            #if os(macOS)
            Button {
                onBack()
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.primary)
                    .frame(width: 28, height: 28)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(isBackButtonHovered ? Color(platformColor: .controlAccentColor).opacity(0.15) : Color.clear)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .strokeBorder(
                                isBackButtonHovered ? Color(platformColor: .controlAccentColor).opacity(0.3) : Color.clear,
                                lineWidth: 1
                            )
                    )
            }
            .buttonStyle(.plain)
            .onHover { hovering in
                isBackButtonHovered = hovering
            }
            .help("Back")
            #endif
        }
    }

    private var displayedArtworkData: Data? {
        if artworkDeleted { return nil }
        return overrideArtworkData ?? entity.artworkData
    }

    private var isPersonEntity: Bool {
        entity is ArtistEntity
    }

    /// Cover size in the header: large, as on the iPhone album page.
    private static let artworkSize: CGFloat = 200

    private var entityArtwork: some View {
        Group {
            if let artworkData = displayedArtworkData,
               let platformImage = PlatformImage(data: artworkData) {
                Image(platformImage: platformImage)
                    .resizable()
                    .scaledToFill()
                    .frame(width: Self.artworkSize, height: Self.artworkSize)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .shadow(color: .black.opacity(0.25), radius: 16, x: 0, y: 6)
            } else {
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color.secondary.opacity(0.2))
                    .frame(width: Self.artworkSize, height: Self.artworkSize)
                    .overlay(
                        Group {
                            if isPersonEntity {
                                Text(entity.name.artistInitials)
                                    .font(.system(size: 64, weight: .medium, design: .rounded))
                                    .foregroundColor(.secondary)
                            } else if entity is CategoryEntity {
                                Text(entity.name)
                                    .font(.system(size: entity.name.count <= 5 ? 28 : 16, weight: .medium, design: .rounded))
                                    .foregroundColor(.secondary)
                                    .multilineTextAlignment(.center)
                                    .padding(8)
                            } else {
                                Image(systemName: Icons.opticalDiscFill)
                                    .font(.system(size: 64))
                                    .foregroundColor(.secondary)
                            }
                        }
                    )
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            if isPersonEntity {
                showingImagePicker = true
            }
        }
        .overlay {
            if isPersonEntity {
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color.black.opacity(0.4))
                    .frame(width: Self.artworkSize, height: Self.artworkSize)
                    .overlay(
                        VStack(spacing: 4) {
                            Image(systemName: "pencil")
                                .font(.system(size: 24, weight: .medium))
                            Text("Update image")
                                .font(.system(size: 12, weight: .medium))
                        }
                        .foregroundStyle(.white)
                    )
                    .opacity(isArtworkHovered ? 1 : 0)
                    .animation(.easeInOut(duration: 0.15), value: isArtworkHovered)
                    .allowsHitTesting(false)
            }
        }
        .onHover { hovering in
            isArtworkHovered = hovering
        }
        .sheet(isPresented: $showingImagePicker) {
            ArtistImageSheet(
                artistName: entity.name,
                artistId: libraryManager.getArtistId(for: entity.name),
                isPresented: $showingImagePicker
            ) { newImageData in
                if let newImageData {
                    overrideArtworkData = newImageData
                    artworkDeleted = false
                } else {
                    overrideArtworkData = nil
                    artworkDeleted = true
                }
            }
        }
    }

    private var entityTypeLabel: String {
        if entity is FolderEntity {
            return String(localized: "Folder")
        }
        if let category = entity as? CategoryEntity {
            return category.filterType.singularDisplayName
        }
        return String(localized: "Artist")
    }

    private var artistEntityInfo: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(entityTypeLabel)
                .font(.caption)
                .foregroundColor(.secondary)
                .fontWeight(.medium)

            Text(entity.name)
                .font(.system(size: 28, weight: .bold))
                .lineLimit(2)

            if let bio = artistBio, !bio.isEmpty {
                Text(bio)
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .lineLimit(2)
                    .help(bio)
            }

            trackStats()
        }
    }

    private var albumEntityInfo: some View {
        let albumEntity = entity as? AlbumEntity

        return VStack(alignment: .leading, spacing: 4) {
            Text(entity.name)
                .font(.system(size: 28, weight: .bold))
                .lineLimit(2)

            if let artistName = albumEntity?.artistName, !artistName.isEmpty {
                Text(artistName)
                    .font(.title3)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }

            trackStats {
                if let year = albumEntity?.year {
                    statText(year)
                    statDot
                }
            } trailing: {
                if isAlbumFullyLossless {
                    statDot
                    HStack(spacing: 4) {
                        Image(Icons.customLossless)
                            .renderingMode(.template)
                            .resizable()
                            .scaledToFit()
                            .frame(width: 15, height: 15)
                        Text("Lossless")
                    }
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                }
            }
        }
    }

    // Shared track count + duration stats line
    private func trackStats<Leading: View, Trailing: View>(
        @ViewBuilder leading: () -> Leading = { EmptyView() },
        @ViewBuilder trailing: () -> Trailing = { EmptyView() }
    ) -> some View {
        HStack {
            leading()
            statText(String(localized: "\(tracks.count) songs"))
            if !tracks.isEmpty {
                statDot
                statText(HelperUtils.formattedDurationSummary(totalTrackDuration))
                trailing()
            }
        }
    }

    private func statText(_ text: String) -> some View {
        Text(text).font(.subheadline).foregroundColor(.secondary)
    }

    private var statDot: some View {
        Text("•").font(.subheadline).foregroundColor(.secondary)
    }

    /// Play and Shuffle as equal capsules, as on the iPhone: on a long
    /// artist people press Shuffle, so it must not read as secondary.
    private var entityControls: some View {
        HStack(spacing: 12) {
            Button { playEntity() } label: {
                Label("Play", systemImage: Icons.playFill)
                    .frame(width: 110)
            }
            .disabled(tracks.isEmpty)

            Button { playEntity(shuffle: true) } label: {
                Label("Shuffle", systemImage: Icons.shuffleFill)
                    .frame(width: 110)
            }
            .disabled(tracks.isEmpty)
        }
        .font(.system(size: 13, weight: .semibold))
        .foregroundStyle(.tint)
        .buttonStyle(.bordered)
        .buttonBorderShape(.capsule)
        .tint(.accentColor)
        .controlSize(.large)
    }

    // MARK: - Views

    private var loadingView: some View {
        VStack {
            ProgressView()
                .scaleEffect(0.8)
            Text("Loading tracks...")
                .font(.caption)
                .foregroundColor(.secondary)
                .padding(.top, 8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyViewIcon: String {
        if entity is ArtistEntity { return "person.slash" }
        if entity is CategoryEntity { return "music.note.slash" }
        if entity is FolderEntity { return Icons.folderFill }
        return "opticaldisc.slash"
    }

    private var emptyView: some View {
        VStack(spacing: 20) {
            Image(systemName: emptyViewIcon)
                .font(.system(size: 60))
                .foregroundColor(.gray)

            Text("No tracks found")
                .font(.headline)

            Text("No tracks were found for \(entity.name)")
                .font(.subheadline)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    // MARK: - Computed Properties

    private var totalTrackDuration: Double {
        tracks.reduce(0) { $0 + HelperUtils.sanitizedDuration($1.duration) }
    }

    private var isAlbumFullyLossless: Bool {
        guard entity is AlbumEntity, !tracks.isEmpty else { return false }
        return tracks.allSatisfy { $0.lossless == true }
    }
}

// MARK: - Methods

extension EntityDetailView {
    private func updateGradientColors() {
        gradientTask?.cancel()
        gradientRevision &+= 1
        let revision = gradientRevision
        guard useArtworkColors else {
            gradientColors = []
            return
        }

        let entity = entity
        let artworkInput = displayedArtworkData
        let isDark = colorScheme == .dark
        gradientTask = Task { @MainActor in
            let resolved = if let artworkInput {
                await ImageUtils.cachedBackgroundGradientColors(
                    id: entity.id.uuidString,
                    imageData: artworkInput,
                    isDark: isDark
                )
            } else { [Color]() }
            guard !Task.isCancelled,
                  gradientRevision == revision,
                  self.entity.id == entity.id,
                  useArtworkColors,
                  displayedArtworkData == artworkInput,
                  (colorScheme == .dark) == isDark else { return }
            gradientColors = resolved
        }
    }

    private func loadTracks() {
        isLoading = true

        let fetchedTracks: [Track]

        if entity is ArtistEntity {
            fetchedTracks = libraryManager.getTracksForArtist(entity.name)
        } else if let albumEntity = entity as? AlbumEntity {
            fetchedTracks = libraryManager.getTracksForAlbum(albumEntity)
        } else {
            fetchedTracks = []
        }

        // Albums with full track numbering force disc/track ordering; everything
        // else follows the user's saved global sort.
        let hasCompleteAlbumOrdering = entity is AlbumEntity
            && fetchedTracks.allSatisfy { ($0.trackNumber ?? 0) > 0 }

        if hasCompleteAlbumOrdering {
            trackTableSortOrder = [
                KeyPathComparator(\Track.sortableDiscNumber, order: .forward),
                KeyPathComparator(\Track.sortableTrackNumber, order: .forward)
            ]
        } else if let savedSort = UserDefaults.standard.dictionary(forKey: "trackTableSortOrder"),
                  let key = savedSort["key"] as? String,
                  let ascending = savedSort["ascending"] as? Bool,
                  let field = TrackSortField.from(storageKey: key) {
            trackTableSortOrder = [field.getComparator(ascending: ascending)]
        }

        self.tracks = fetchedTracks

        // Load artist bio for person entities (artists, album artists, composers)
        if entity is ArtistEntity {
            artistBio = libraryManager.getArtistBio(for: entity.name)
        } else {
            artistBio = nil
        }

        self.isLoading = false
    }

    // Folders retain folder queue source; every other entity type plays as a library queue.
    // Passed to TrackView so all of its playback paths (header, double-click, row button) agree.
    private var queueSource: PlaylistManager.QueueSource {
        entity is FolderEntity ? .folder : .library
    }

    private func playTrack(_ track: Track) {
        playlistManager.playTrack(track, fromTracks: tracks)
        selectedTrackID = track.id
    }

    private func playEntity(shuffle: Bool = false) {
        guard !tracks.isEmpty else { return }

        NotificationCenter.default.post(
            name: .playEntityTracks,
            object: entity,
            userInfo: [
                "shuffle": shuffle,
                "entityId": entity.id.uuidString
            ]
        )
    }
}

// MARK: - Preview

#Preview("Artist Detail") {
    let artist = ArtistEntity(name: "Test Artist", trackCount: 10)

    return EntityDetailView(
        entity: artist,
    ) { Logger.debugPrint("Back tapped") }
    .environmentObject(LibraryManager())
    .environmentObject(PlaybackManager(libraryManager: LibraryManager(), playlistManager: PlaylistManager()))
    .environmentObject(PlaylistManager())
    .frame(height: 600)
}

#Preview("Album Detail") {
    let album = AlbumEntity(name: "The Dark Side of the Moon", trackCount: 10, year: "1973", duration: 2580)

    return EntityDetailView(
        entity: album,
    ) { Logger.debugPrint("Back tapped") }
    .environmentObject(LibraryManager())
    .environmentObject(PlaybackManager(libraryManager: LibraryManager(), playlistManager: PlaylistManager()))
    .environmentObject(PlaylistManager())
    .frame(height: 600)
}
