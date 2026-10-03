//
// PlaybackControlIntents
//
// The intents behind the Control Center buttons. Compiled into both the app
// and the PetrichorWidgets extension: the extension declares the controls,
// the app performs them. As `AudioPlaybackIntent`s they run in the app's
// process — launched in the background if needed — so the extension never
// touches playback and needs no shared container. The app fills in
// `PlaybackControlActions` at launch; in the extension they stay no-ops.
//

import AppIntents

@MainActor
enum PlaybackControlActions {
    static var playPause: () -> Void = {}
    static var nextTrack: () -> Void = {}
}

struct PlayPauseControlIntent: AudioPlaybackIntent {
    static let title: LocalizedStringResource = "Play/Pause"
    static let isDiscoverable = false

    @MainActor
    func perform() async throws -> some IntentResult {
        PlaybackControlActions.playPause()
        return .result()
    }
}

struct NextTrackControlIntent: AudioPlaybackIntent {
    static let title: LocalizedStringResource = "Next Track"
    static let isDiscoverable = false

    @MainActor
    func perform() async throws -> some IntentResult {
        PlaybackControlActions.nextTrack()
        return .result()
    }
}
