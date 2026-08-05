//
// PetrichorApp (iOS)
//
// iOS entry point. Owns the AppCoordinator and the shared environment objects,
// and saves playback state when the app leaves the foreground. The audio
// session itself is configured by `AudioSessionController`, activated by
// `AVQueuePlayerBackend` on first playback.
//

import SwiftUI

@main
struct PetrichorApp: App {
    @StateObject private var appCoordinator: AppCoordinator
    @Environment(\.scenePhase) private var scenePhase

    init() {
        _appCoordinator = StateObject(wrappedValue: AppCoordinator())
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(appCoordinator.playbackManager)
                .environmentObject(appCoordinator.playbackManager.playbackProgressState)
                .environmentObject(appCoordinator.libraryManager)
                .environmentObject(appCoordinator.playlistManager)
                .tint(.pink)
                .onAppear {
                    // Re-apply the stored color scheme: overrideUserInterfaceStyle
                    // does not survive a relaunch on its own.
                    ColorMode.current.apply()
                }
                .onChange(of: scenePhase) { _, phase in
                    if phase == .background || phase == .inactive {
                        appCoordinator.savePlaybackState()
                    }
                }
        }
    }
}
