//
// PetrichorApp (iOS)
//
// iOS entry point. Owns the AppCoordinator and the shared environment objects,
// and saves playback state when the app leaves the foreground. The audio
// session itself is configured by `AudioSessionController`, activated by
// `AVQueuePlayerBackend` on first playback.
//

import SwiftUI

/// The app's brand accent: system pink darkened until it clears the WCAG AA
/// bar (4.5:1) against the white Form cells and list backgrounds the tinted
/// controls sit on. System `.pink` measures ~3.6:1 there, and the
/// accessibility gate flags every tinted control (links, enabled switches).
extension Color {
    static let brandAccent = Color(red: 0.871, green: 0.122, blue: 0.302)
}

@main
struct PetrichorApp: App {
    @StateObject private var appCoordinator: AppCoordinator
    @Environment(\.scenePhase) private var scenePhase

    // The first .active arrives right after launch, when AppCoordinator.init
    // has already kicked off reconciliation; only later transitions back to
    // .active (return from background) are a reconciliation trigger.
    @State private var hasAppearedActiveOnce = false

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

        // iPhone rows load artwork only as they become visible. Keeping every
        // album and artist BLOB in the shared entity cache costs hundreds of
        // megabytes on a real library and makes launch contend with the UI.
        _appCoordinator = StateObject(wrappedValue: AppCoordinator(cacheEntityArtwork: false))

        // Catches the search-index deletions reconciliation never causes on
        // its own: folder removal and entity merges, both of which post
        // `.libraryDataDidChange`. See `SpotlightIndexer.observeLibraryChanges()`.
        SpotlightIndexer.observeLibraryChanges()
    }

    var body: some Scene {
        WindowGroup {
            ContentView(
                playlistManager: appCoordinator.playlistManager,
                playbackManager: appCoordinator.playbackManager
            )
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
                        appCoordinator.savePlaybackState()
                    @unknown default:
                        break
                    }
                }
        }
    }
}
