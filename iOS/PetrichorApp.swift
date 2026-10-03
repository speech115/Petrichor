//
// PetrichorApp (iOS)
//
// iOS entry point. Owns the AppCoordinator and the shared environment objects,
// and saves playback state when the app leaves the foreground. The audio
// session itself is configured by `AudioSessionController`, activated by
// `AVQueuePlayerBackend` on first playback.
//

import OSLog
import SwiftUI

/// The app's brand accent, adaptive to the color scheme. Light mode keeps
/// the darkened system pink that clears the WCAG AA bar (4.5:1) against the
/// white Form cells and list backgrounds — system `.pink` measures ~3.6:1
/// there. Dark mode needs the inverse adjustment: the same pink lands at
/// ~3.6:1 on the grouped background and ~2.9:1 on inset row cells, so it is
/// blended 40% toward white, which keeps the hue and clears 4.5:1 on both
/// (6.2:1 grouped, 5.1:1 rows).
extension Color {
    static let brandAccent = Color(uiColor: UIColor { traits in
        if traits.userInterfaceStyle == .dark {
            return UIColor(red: 0.922, green: 0.475, blue: 0.581, alpha: 1)
        }
        return UIColor(red: 0.871, green: 0.122, blue: 0.302, alpha: 1)
    })
}

@main
struct PetrichorApp: App {
    @StateObject private var appCoordinator: AppCoordinator
    @Environment(\.scenePhase) private var scenePhase

    // Home, the tab on screen at launch, has its first frame ready before the
    // tab interface appears. Discover and playlist covers follow right after,
    // then the library's own background work.
    @State private var isInterfacePrepared = false

    // The first .active arrives right after launch, when AppCoordinator.init
    // has already kicked off reconciliation; only later transitions back to
    // .active (return from background) are a reconciliation trigger.
    @State private var hasAppearedActiveOnce = false
    @State private var playbackSaveTask: Task<Void, Never>?
    @State private var needsPlaybackSave = false
    @State private var backgroundSaveID = UIBackgroundTaskIdentifier.invalid
    private let launchStart = ContinuousClock.now
    /// Launch phases as Instruments intervals (Points of Interest); the log
    /// line below carries the same numbers off a device without Instruments.
    private static let signposter = OSSignposter(subsystem: "org.Petrichor.ios", category: .pointsOfInterest)

    init() {
        #if DEBUG
        // UI tests are self-sufficient: launched with `--uitest-seed-fixtures`,
        // the app seeds Documents/Music with the smoke-test fixtures before
        // AppCoordinator kicks off the launch reconciliation, so a clean
        // simulator needs no manual `simctl push`. Nothing runs without the
        // argument, and the whole path is DEBUG-only.
        if ProcessInfo.processInfo.arguments.contains(uitestSeedFixturesLaunchArgument) {
            do {
                try seedUITestFixturesIfNeeded()
            } catch {
                Logger.error("Failed to seed UI-test fixtures: \(error)")
            }
        }
        #endif

        GestureTips.configure()

        // iPhone rows load artwork only as they become visible. Keeping every
        // album and artist BLOB in the shared entity cache costs hundreds of
        // megabytes on a real library and makes launch contend with the UI.
        let coordinator = AppCoordinator(cacheEntityArtwork: false, deferLaunchWork: true)
        _appCoordinator = StateObject(wrappedValue: coordinator)

        // Control Center buttons run their intents here, in the app's process.
        PlaybackControlActions.playPause = { [playbackManager = coordinator.playbackManager] in
            playbackManager.togglePlayPause()
        }
        PlaybackControlActions.nextTrack = { [playlistManager = coordinator.playlistManager] in
            playlistManager.playNextTrack()
        }

        // Catches the search-index deletions reconciliation never causes on
        // its own: folder removal and entity merges, both of which post
        // `.libraryDataDidChange`. See `SpotlightIndexer.observeLibraryChanges()`.
        SpotlightIndexer.observeLibraryChanges()
    }

    var body: some Scene {
        WindowGroup {
            Group {
                if isInterfacePrepared {
                    ContentView(
                        playlistManager: appCoordinator.playlistManager,
                        playbackManager: appCoordinator.playbackManager
                    )
                } else {
                    Color(uiColor: .systemBackground).ignoresSafeArea()
                }
            }
                .task {
                    guard !isInterfacePrepared else { return }
                    let library = appCoordinator.libraryManager
                    let cache = LibraryScreenCache.shared
                    let homeInterval = Self.signposter.beginInterval("Prepare Home")
                    _ = await cache.prepareRecentAlbums(library)
                    Self.signposter.endInterval("Prepare Home", homeInterval)
                    guard !Task.isCancelled else { return }
                    let homeReady = ContinuousClock.now
                    var transaction = Transaction()
                    transaction.disablesAnimations = true
                    withTransaction(transaction) { isInterfacePrepared = true }

                    // The other tabs are prepared before one can realistically be
                    // tapped; ContentView's own tasks join these same runs.
                    async let discover: Void = cache.prepareDiscover(library)
                    async let previews: Void = cache.preparePlaylistPreviews(
                        appCoordinator.playlistManager.playlists,
                        library: library
                    )
                    let tabsInterval = Self.signposter.beginInterval("Prepare other tabs")
                    _ = await (discover, previews)
                    Self.signposter.endInterval("Prepare other tabs", tabsInterval)
                    Logger.info(
                        "Launch: Home ready \((homeReady - launchStart).formatted(.units(allowed: [.milliseconds]))) after app init, "
                            + "other tabs \((ContinuousClock.now - homeReady).formatted(.units(allowed: [.milliseconds]))) later"
                    )

                    // Only now the work no screen waits on: it competes for the
                    // database readers and CPU the preparation above needs. The
                    // iOS library is the app's own Documents folder, registered
                    // and reconciled on every launch; it has no folder watcher.
                    library.startLaunchWork(watchFolders: false)
                    library.reconcileInBackground()
                }
                .environmentObject(appCoordinator.playbackManager)
                .environmentObject(appCoordinator.playbackManager.playbackProgressState)
                .environmentObject(appCoordinator.libraryManager)
                .environmentObject(appCoordinator.playlistManager)
                .tint(.brandAccent)
                .onAppear {
                    // Re-apply the stored color scheme: overrideUserInterfaceStyle
                    // does not survive a relaunch on its own.
                    ColorMode.current.apply()
                }
                .onChange(of: scenePhase) { _, phase in
                    switch phase {
                    case .active:
                        guard hasAppearedActiveOnce else {
                            hasAppearedActiveOnce = true
                            return
                        }
                        Task(priority: .utility) {
                            do {
                                try await appCoordinator.libraryManager.reconcileLibrary()
                            } catch {
                                Logger.error("Failed to reconcile the library after returning to foreground: \(error)")
                            }
                        }
                    case .background, .inactive:
                        saveInBackground()
                    @unknown default:
                        break
                    }
                }
        }
    }

    private func saveInBackground() {
        needsPlaybackSave = true
        guard playbackSaveTask == nil else { return }
        backgroundSaveID = UIApplication.shared.beginBackgroundTask(withName: "Save playback state") {
            endBackgroundSave()
        }
        playbackSaveTask = Task {
            repeat {
                needsPlaybackSave = false
                await appCoordinator.savePlaybackStateInBackground()
            } while needsPlaybackSave
            endBackgroundSave()
            playbackSaveTask = nil
        }
    }

    private func endBackgroundSave() {
        guard backgroundSaveID != .invalid else { return }
        let identifier = backgroundSaveID
        backgroundSaveID = .invalid
        UIApplication.shared.endBackgroundTask(identifier)
    }
}
