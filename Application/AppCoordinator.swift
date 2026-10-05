//
// AppCoordinator class
//
// This class handles playback initialization & state saving and restoration based on library updates.
//

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
    /// Fifth seam: phone→Mac listen/favorite journal. Created only on iOS;
    /// macOS leaves this nil and applies a transferred JSONL file manually.
    let playbackJournal: (any PlaybackJournal)?
    
    private var hadFoldersAtStartup: Bool = false
    private let playbackStateKey = "SavedPlaybackState"
    private let playbackUIStateKey = "SavedPlaybackUIState"
    
    // Track restoration state to prevent race conditions
    private var isRestoringPlayback = false
    private var libraryObserver: NSObjectProtocol?
    
    // MARK: - Initialization
    
    init(deferLaunchWork: Bool = false) {
        // Initialize managers
        libraryManager = LibraryManager(deferLaunchWork: deferLaunchWork)
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

        playbackJournal = PlaybackJournalFactory.make()

        hadFoldersAtStartup = !libraryManager.folders.isEmpty

        Self.shared = self
        
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
    
    private func clearAllSavedState() {
        UserDefaults.standard.removeObject(forKey: playbackStateKey)
        UserDefaults.standard.removeObject(forKey: playbackUIStateKey)
        playbackManager.restoredUITrack = nil
        playbackManager.currentTrack = nil
    }
    
    func savePlaybackState() {
        // macOS termination path. The playback journal is nil here (macOS
        // applies a transferred JSONL file manually), so there is nothing to
        // flush; the iOS backgrounding path does that in
        // `savePlaybackStateInBackground()`.

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
        await playbackJournal?.flush()

        guard let currentTrack = playbackManager.currentTrack else {
            clearAllSavedState()
            return
        }

        guard currentTrack.trackId != nil else { return }

        let input = snapshotInput(currentTrack: currentTrack)
        let stateKey = playbackStateKey
        let uiStateKey = playbackUIStateKey
        await Task.detached(priority: .userInitiated) {
            Self.write(Self.snapshot(from: input), stateKey: stateKey, uiStateKey: uiStateKey)
        }.value
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

        let currentTrack = state.currentTrackId.flatMap { id in restoredQueue.first { $0.trackId == id } }
        let isReadable = currentTrack.map { track in
            FileManager.default.fileExists(atPath: track.url.path)
                && FileManager.default.isReadableFile(atPath: track.url.path)
        } ?? false
        return .restore(Restoration(
            state: state,
            queue: restoredQueue,
            currentTrack: currentTrack,
            isCurrentTrackReadable: isReadable
        ))
    }

    private func apply(_ restoration: Restoration) {
        let state = restoration.state
        let restoredQueue = restoration.queue

        // Restore playback settings first
        playlistManager.isShuffleEnabled = state.shuffleEnabled
        playlistManager.repeatMode = state.repeatModeEnum
        playbackManager.setVolume(state.isMuted ? 0 : state.volume)

        playlistManager.replaceCurrentQueue(
            restoredQueue,
            index: min(state.currentQueueIndex, restoredQueue.count - 1)
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
            playbackManager.prepareTrackForRestoration(currentTrack, at: state.playbackPosition)
            Logger.info("Playback state restored")
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
