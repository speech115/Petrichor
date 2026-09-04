//
// PetrichorApp (iOS)
//
// iOS entry point. Owns the AppCoordinator and the shared environment objects,
// and saves playback state when the app leaves the foreground. The audio
// session itself is configured by `AudioSessionController`, activated by
// `AVQueuePlayerBackend` on first playback.
//

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

    // Ignore the first .active transition generated during launch.
    @State private var hasAppearedActiveOnce = false

    init() {
        #if DEBUG
        // UI tests are self-sufficient: launched with `--uitest-seed-fixtures`,
        // the app seeds Documents/Music with the smoke-test fixtures before
        // AppCoordinator kicks off the launch scan, so a clean
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
        let coordinator = AppCoordinator(cacheEntityArtwork: false)
        _appCoordinator = StateObject(wrappedValue: coordinator)

        // The iOS library is the app's own Documents folder, so it must be
        // registered on every launch (no picker step). Fire-and-forget; the
        // coordinator captured the pre-scan folder state before this runs.
        coordinator.libraryManager.scanLibraryInBackground()

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
                            appCoordinator.libraryManager.scanLibraryInBackground()
                        }
                    case .background:
                        // Save off-main within a background task so the system
                        // cannot suspend the app mid-write.
                        let backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "Save playback state")
                        Task {
                            await appCoordinator.savePlaybackStateInBackground()
                            UIApplication.shared.endBackgroundTask(backgroundTask)
                        }
                    case .inactive:
                        break
                    @unknown default:
                        break
                    }
                }
        }
    }
}
