//
// PetrichorApp (iOS)
//
// iOS entry point. Owns the AppCoordinator and the shared environment objects,
// configures the audio session for background playback, and saves playback state
// when the app leaves the foreground.
//

import AVFoundation
import SwiftUI

@main
struct PetrichorApp: App {
    @StateObject private var appCoordinator: AppCoordinator
    @Environment(\.scenePhase) private var scenePhase

    init() {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .default)
        try? session.setActive(true)

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
                .onChange(of: scenePhase) { _, phase in
                    if phase == .background || phase == .inactive {
                        appCoordinator.savePlaybackState()
                    }
                }
        }
    }
}
