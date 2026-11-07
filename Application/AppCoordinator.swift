//
// AppCoordinator class
//
// This class handles playback initialization & state saving and restoration based on library updates.
//

import Combine
import SwiftUI

@MainActor
class AppCoordinator: ObservableObject {
    // MARK: - Managers
    private(set) static var shared: AppCoordinator?
    let libraryManager: LibraryManager
    let playlistManager: PlaylistManager
    let playbackManager: PlaybackManager
    #if os(macOS)
    let menuBarManager: MenuBarManager
    #endif
    let scrobbleManager: ScrobbleManager
    /// Fifth seam: this device's listen/favorite journal for the other device.
    let playbackJournal: any PlaybackJournal
    
    private var hadFoldersAtStartup: Bool = false
    private let playbackStateKey = "SavedPlaybackState"
    private let playbackUIStateKey = "SavedPlaybackUIState"
    nonisolated private static let playbackPositionKey = "SavedPlaybackPosition"

    /// The playhead alone. A kill or crash runs neither the backgrounding nor
    /// the termination save, so both platforms write this mark every few
    /// seconds of playback and on pause, and restoration prefers it whenever
    /// it names a track from the saved queue. Every full write refreshes it,
    /// so it is never older than the snapshot.
    struct PlaybackPositionMark: Codable, Sendable {
        let trackId: Int64
        let position: Double
    }

    // Track restoration state to prevent race conditions
    private var isRestoringPlayback = false
    private var libraryObserver: NSObjectProtocol?

    /// What a kill would otherwise lose: see `observePlaybackForPersistence`.
    private var persistenceObservers: Set<AnyCancellable> = []
    /// The last full snapshot write; the next one waits for it, so an older
    /// snapshot never lands after a newer one.
    private var snapshotWrite: Task<Void, Never>?
    nonisolated static let positionMarkInterval: TimeInterval = 15
    
    // MARK: - Initialization
    
    init(databaseManager: DatabaseManager, deferLaunchWork: Bool = false) {
        // Initialize managers
        libraryManager = LibraryManager(databaseManager: databaseManager, deferLaunchWork: deferLaunchWork)
        playlistManager = PlaylistManager()
        
        // Create audio player with dependencies
        playbackManager = PlaybackManager(libraryManager: libraryManager, playlistManager: playlistManager)
        
        // Connect managers
        playlistManager.setAudioPlayer(playbackManager)
        playlistManager.setLibraryManager(libraryManager)
        
        // Setup now playing - PlaybackManager owns the single Now Playing path
        playbackManager.connectRemoteCommandCenter()
        
        #if os(macOS)
        // Setup menubar
        menuBarManager = MenuBarManager(playbackManager: playbackManager, playlistManager: playlistManager)
        #endif
        
        // Setup Scrobbling
        scrobbleManager = ScrobbleManager()

        playbackJournal = JSONLPlaybackJournal()

        hadFoldersAtStartup = !libraryManager.folders.isEmpty

        Self.shared = self

        observePlaybackForPersistence()

        // Launch counts as coming to the foreground: a Mac app opened in the
        // background never becomes active. A caller that defers launch work
        // (the iPhone) applies the journal at the end of its launch
        // reconciliation instead, once the files it names are scanned (D-8).
        if !deferLaunchWork {
            Task { await libraryManager.applyPeerJournal() }
        }

        // Check if library is empty at startup - if so, clear any saved state
        if !hadFoldersAtStartup {
            clearAllSavedState()
        } else {
            // Only restore if we have folders
            restoreUIStateImmediately()
            
            // Schedule restoration after a minimal delay to ensure UI is ready
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
                self?.restorePlaybackState()
            }
        }
    }
    
    isolated deinit {
        if let observer = libraryObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }
    
    // MARK: - Playback State Persistence

    /// A kill or crash never reaches `savePlaybackState` or the backgrounding
    /// save, so what the next launch restores is written as it changes: the
    /// full snapshot shortly after the queue, shuffle, repeat or queue source
    /// changes, and the playhead mark while playing and on pause.
    private func observePlaybackForPersistence() {
        let playlists = playlistManager
        Publishers.MergeMany(
            playlists.$currentQueue.map { $0.map(\.id) }.removeDuplicates().dropFirst().map { _ in () }.eraseToAnyPublisher(),
            playlists.$isShuffleEnabled.removeDuplicates().dropFirst().map { _ in () }.eraseToAnyPublisher(),
            playlists.$repeatMode.removeDuplicates().dropFirst().map { _ in () }.eraseToAnyPublisher(),
            playlists.$currentQueueSource.removeDuplicates().dropFirst().map { _ in () }.eraseToAnyPublisher()
        )
        .debounce(for: .seconds(1), scheduler: DispatchQueue.main)
        .sink { [weak self] in
            MainActor.assumeIsolated { self?.saveSnapshotAfterChange() }
        }
        .store(in: &persistenceObservers)

        Timer.publish(every: Self.positionMarkInterval, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, self.playbackManager.isPlaying else { return }
                    self.savePlaybackPosition()
                }
            }
            .store(in: &persistenceObservers)

        playbackManager.$isPlaying
            .removeDuplicates()
            .dropFirst()
            .filter { !$0 }
            .sink { [weak self] _ in
                MainActor.assumeIsolated { self?.savePlaybackPosition() }
            }
            .store(in: &persistenceObservers)
    }

    /// The change-driven snapshot. Unlike the backgrounding save it never
    /// clears anything: with no current track there is nothing worth keeping
    /// over what is saved, and the temporary tile has no identity yet (I-3.4).
    private func saveSnapshotAfterChange() {
        guard let currentTrack = playbackManager.currentTrack, currentTrack.trackId != nil else { return }
        enqueueSnapshotWrite(snapshotInput(currentTrack: currentTrack), priority: .utility)
    }

    /// Builds, encodes and writes a snapshot off the main actor, after any
    /// write still in flight.
    @discardableResult
    private func enqueueSnapshotWrite(_ input: SnapshotInput, priority: TaskPriority) -> Task<Void, Never> {
        let previous = snapshotWrite
        let stateKey = playbackStateKey
        let uiStateKey = playbackUIStateKey
        let task = Task {
            await previous?.value
            await Task.detached(priority: priority) {
                Self.write(Self.snapshot(from: input), stateKey: stateKey, uiStateKey: uiStateKey)
            }.value
        }
        snapshotWrite = task
        return task
    }

    func savePlaybackPosition() {
        guard let trackId = playbackManager.currentTrack?.trackId else { return }
        Self.write(PlaybackPositionMark(trackId: trackId, position: playbackManager.currentTime))
    }

    nonisolated private static func write(_ mark: PlaybackPositionMark) {
        guard let data = try? JSONEncoder().encode(mark) else { return }
        UserDefaults.standard.set(data, forKey: playbackPositionKey)
    }

    nonisolated private static func savedPositionMark() -> PlaybackPositionMark? {
        UserDefaults.standard.data(forKey: playbackPositionKey)
            .flatMap { try? JSONDecoder().decode(PlaybackPositionMark.self, from: $0) }
    }

    private func clearAllSavedState() {
        UserDefaults.standard.removeObject(forKey: playbackStateKey)
        UserDefaults.standard.removeObject(forKey: playbackUIStateKey)
        UserDefaults.standard.removeObject(forKey: Self.playbackPositionKey)
        // Only the restored tile goes: a track the user started meanwhile
        // keeps playing and showing (I-3.3, D-2). Play pressed on the tile
        // latches until the restore lands; a dropped restore releases it.
        playbackManager.dropRestoredTile()
    }
    
    func savePlaybackState() {
        // macOS termination path. Journal events are already on disk: the
        // journal appends each one as it is recorded.

        guard let currentTrack = playbackManager.currentTrack else {
            clearAllSavedState()
            return
        }

        // The restored tile has no database identity until its real track loads.
        guard currentTrack.trackId != nil else { return }

        persist(Self.snapshot(from: snapshotInput(currentTrack: currentTrack)))
    }

    /// iOS backgrounding path: the same snapshot, but building, encoding and
    /// writing it run off the main actor. Matching every queued track to its
    /// stored path resolves symlinks file by file, and the brief background
    /// transition must not pin the UI thread on that. The caller holds a
    /// `beginBackgroundTask` open until this returns.
    func savePlaybackStateInBackground() async {
        await playbackJournal.flush()

        guard let currentTrack = playbackManager.currentTrack else {
            clearAllSavedState()
            return
        }

        guard currentTrack.trackId != nil else { return }

        await enqueueSnapshotWrite(snapshotInput(currentTrack: currentTrack), priority: .userInitiated).value
    }

    private struct PlaybackStateSnapshot: Sendable {
        let state: PlaybackState
        let uiState: PlaybackUIState?
    }

    /// Main-actor state a snapshot needs, captured as plain values.
    private struct SnapshotInput: Sendable {
        let currentTrack: Track
        let position: Double
        let queue: [Track]
        let queueIndex: Int
        let queueSource: PlaylistManager.QueueSource
        let playlistID: String?
        let volume: Float
        let shuffleEnabled: Bool
        let repeatMode: RepeatMode
    }

    private func snapshotInput(currentTrack: Track) -> SnapshotInput {
        SnapshotInput(
            currentTrack: currentTrack,
            position: playbackManager.currentTime,
            queue: playlistManager.currentQueue,
            queueIndex: playlistManager.currentQueueIndex,
            queueSource: playlistManager.currentQueueSource,
            playlistID: playlistManager.currentPlaylist?.id.uuidString,
            volume: playbackManager.volume,
            shuffleEnabled: playlistManager.isShuffleEnabled,
            repeatMode: playlistManager.repeatMode
        )
    }

    nonisolated private static func snapshot(from input: SnapshotInput) -> PlaybackStateSnapshot {
        let sourceIdentifier = input.queueSource == .playlist ? input.playlistID : nil

        let state = PlaybackState(
            currentTrack: input.currentTrack,
            playbackPosition: input.position,
            queue: input.queue,
            currentQueueIndex: input.queueIndex,
            queueSource: input.queueSource,
            sourceIdentifier: sourceIdentifier,
            volume: input.volume,
            isMuted: input.volume < 0.01,
            shuffleEnabled: input.shuffleEnabled,
            repeatMode: input.repeatMode
        )
        return PlaybackStateSnapshot(
            state: state,
            uiState: state.createUIState(from: input.currentTrack)
        )
    }

    private func persist(_ snapshot: PlaybackStateSnapshot) {
        Self.write(snapshot, stateKey: playbackStateKey, uiStateKey: playbackUIStateKey)
    }

    nonisolated private static func write(
        _ snapshot: PlaybackStateSnapshot,
        stateKey: String,
        uiStateKey: String
    ) {
        if let uiState = snapshot.uiState,
           let uiData = try? JSONEncoder().encode(uiState) {
            UserDefaults.standard.set(uiData, forKey: uiStateKey)
        }

        do {
            let encoder = JSONEncoder()
            let data = try encoder.encode(snapshot.state)
            UserDefaults.standard.set(data, forKey: stateKey)
            if let trackId = snapshot.state.currentTrackId {
                write(PlaybackPositionMark(trackId: trackId, position: snapshot.state.playbackPosition))
            }
            Logger.info("Playback state saved")
        } catch {
            Logger.warning("Failed to save playback state: \(error)")
        }
    }
    
    func restoreUIStateImmediately() {
        // Try to restore UI state immediately
        guard let uiData = UserDefaults.standard.data(forKey: playbackUIStateKey),
              let uiState = try? JSONDecoder().decode(PlaybackUIState.self, from: uiData) else {
            return
        }
        
        // Restore UI immediately
        playbackManager.restoreUIState(uiState)
    }
    
    func restorePlaybackState() {
        // Prevent concurrent restorations
        guard !isRestoringPlayback else {
            return
        }
        
        isRestoringPlayback = true
        
        // Don't restore immediately, wait for library to be fully loaded
        if libraryManager.totalTrackCount == 0 {
            if libraryManager.folders.isEmpty {
                clearAllSavedState()
                isRestoringPlayback = false
                return
            }
            
            // Use a stored observer reference to ensure proper cleanup
            libraryObserver = NotificationCenter.default.addObserver(
                forName: NSNotification.Name("LibraryDidLoad"),
                object: libraryManager,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.libraryDidLoad()
                }
            }
            return
        }
        
        // Proceed with restoration
        performActualRestoration()
    }
    
    @objc
    private func libraryDidLoad() {
        if let observer = libraryObserver {
            NotificationCenter.default.removeObserver(observer)
            libraryObserver = nil
        }
        
        // Don't restore if we didn't have folders at startup
        if !hadFoldersAtStartup {
            playbackManager.abandonPendingPlayOnRestore()
            isRestoringPlayback = false
            return
        }
        
        // Check if library is loaded with content
        if libraryManager.folders.isEmpty || libraryManager.totalTrackCount == 0 {
            clearAllSavedState()
            isRestoringPlayback = false
            return
        }
        
        // Now perform restoration
        performActualRestoration()
    }
    
    private func performActualRestoration() {
        guard let data = UserDefaults.standard.data(forKey: playbackStateKey) else {
            playbackManager.dropRestoredTile()
            isRestoringPlayback = false
            return
        }
        let database = libraryManager.databaseManager
        Task {
            defer { isRestoringPlayback = false }
            // Decoding the saved queue, fetching its rows and matching their
            // paths touch thousands of tracks and filesystem entries; none of
            // it runs on the main actor while the first screens appear.
            let outcome = await Task.detached(priority: .userInitiated) {
                Self.loadRestoration(from: data, database: database)
            }.value
            switch outcome {
            case .discard:
                clearAllSavedState()
            case .restore(let restoration):
                apply(restoration)
            }
        }
    }

    private struct Restoration: Sendable {
        let state: PlaybackState
        let queue: [Track]
        let currentTrack: Track?
        let queueIndex: Int
        let position: Double
        let isCurrentTrackReadable: Bool
    }

    private enum RestorationOutcome: Sendable {
        case discard
        case restore(Restoration)
    }

    nonisolated private static func loadRestoration(from data: Data, database: DatabaseManager) -> RestorationOutcome {
        let state: PlaybackState
        do {
            state = try JSONDecoder().decode(PlaybackState.self, from: data)
        } catch {
            Logger.warning("Failed to restore playback state: \(error)")
            return .discard
        }

        // Clear saved state if older than 7 days
        guard Date().timeIntervalSince(state.savedDate) <= 7 * 24 * 60 * 60 else { return .discard }

        // Load only the tracks we need for restoration — no artwork payloads.
        // Now Playing enrichment and FullTrack load fill art for the current
        // entry; the queue itself stays payload-light.
        let trackIdsNeeded = Set(state.queueTrackIds + [state.currentTrackId].compactMap { $0 })
        let relevantTracks = database.getTracks(byIds: Array(trackIdsNeeded))

        let trackIdMap: [Int64: Track] = Dictionary(
            relevantTracks.compactMap { track in
                guard let trackId = track.trackId else { return nil }
                return (trackId, track)
            }
        ) { first, _ in first }

        // Path fallback, built only when an id is missing. Both sides use the
        // Documents-relative path now that `PlaybackState` persists relative
        // paths (the same seam the database uses).
        var trackPathMap: [String: Track]?
        func track(atPath path: String) -> Track? {
            if trackPathMap == nil {
                trackPathMap = Dictionary(
                    relevantTracks.map { (LibraryPathStore.storedPath(for: $0.url), $0) }
                ) { first, _ in first }
            }
            return trackPathMap?[path]
        }

        var restoredQueue: [Track] = []
        restoredQueue.reserveCapacity(state.queueTrackIds.count)
        for (index, trackId) in state.queueTrackIds.enumerated() {
            if let track = trackIdMap[trackId] {
                restoredQueue.append(track)
            } else if index < state.queueTrackPaths.count, let track = track(atPath: state.queueTrackPaths[index]) {
                restoredQueue.append(track)
            }
        }

        // Check if we restored at least 50% queue (songs may have been removed)
        let restorationRatio = Double(restoredQueue.count) / Double(state.queueTrackPaths.count)
        guard restorationRatio >= 0.5, !restoredQueue.isEmpty else { return .discard }

        var currentTrackId = state.currentTrackId
        var queueIndex = state.currentQueueIndex
        var position = state.playbackPosition
        if let mark = savedPositionMark(),
           let markIndex = restoredQueue.firstIndex(where: { $0.trackId == mark.trackId }) {
            currentTrackId = mark.trackId
            queueIndex = markIndex
            position = mark.position
        }
        let currentTrack = currentTrackId.flatMap { id in restoredQueue.first { $0.trackId == id } }
        let isReadable = currentTrack.map { track in
            FileManager.default.fileExists(atPath: track.url.path)
                && FileManager.default.isReadableFile(atPath: track.url.path)
        } ?? false
        return .restore(Restoration(
            state: state,
            queue: restoredQueue,
            currentTrack: currentTrack,
            queueIndex: queueIndex,
            position: position,
            isCurrentTrackReadable: isReadable
        ))
    }

    private func apply(_ restoration: Restoration) {
        // A track the user started while restoration waited for the library
        // owns the queue and the player now (I-3.3, D-2).
        guard !playbackManager.hasEngineSession else {
            Logger.info("Playback started before restoration finished; keeping it")
            return
        }
        let state = restoration.state
        let restoredQueue = restoration.queue

        // Restore playback settings first
        playlistManager.isShuffleEnabled = state.shuffleEnabled
        playlistManager.repeatMode = state.repeatModeEnum
        playbackManager.setVolume(state.isMuted ? 0 : state.volume)

        playlistManager.replaceCurrentQueue(
            restoredQueue,
            index: min(restoration.queueIndex, restoredQueue.count - 1)
        )
        playlistManager.currentQueueSource = state.queueSourceEnum

        // Try to restore the source context
        switch state.queueSourceEnum {
        case .playlist:
            if let playlistId = state.sourceIdentifier,
               let uuid = UUID(uuidString: playlistId),
               let playlist = playlistManager.playlists.first(where: { $0.id == uuid }) {
                playlistManager.currentPlaylist = playlist
            }
        default:
            break
        }

        // Prepare the current track if its file is still there
        if let currentTrack = restoration.currentTrack {
            guard restoration.isCurrentTrackReadable else {
                clearAllSavedState()
                return
            }

            // Clear the temporary UI track before setting the real one
            playbackManager.restoredUITrack = nil
            playbackManager.prepareTrackForRestoration(currentTrack, at: restoration.position)
            Logger.info("Playback state restored")
        } else {
            // The queue came back but not its current track: no tile may stay
            // behind with nothing to play (I-3.1, D-3).
            playbackManager.dropRestoredTile()
        }
    }
    
    func handleLibraryChanged() {
        // If the library was significantly changed (e.g., folders removed),
        // the saved state might no longer be valid
        if let savedStateData = UserDefaults.standard.data(forKey: playbackStateKey),
           let state = try? JSONDecoder().decode(PlaybackState.self, from: savedStateData) {
            // Check if the current track still exists
            if let trackId = state.currentTrackId {
                let trackExists = libraryManager.databaseManager.trackExists(withId: trackId)
                if !trackExists {
                    UserDefaults.standard.removeObject(forKey: playbackStateKey)
                }
            }
            
            // Also check UI state validity
            if let uiData = UserDefaults.standard.data(forKey: playbackUIStateKey),
               (try? JSONDecoder().decode(PlaybackUIState.self, from: uiData)) != nil {
                // If the main state is invalid, clear UI state too
                if UserDefaults.standard.data(forKey: playbackStateKey) == nil {
                    UserDefaults.standard.removeObject(forKey: playbackUIStateKey)
                }
            }
        }
    }
}
