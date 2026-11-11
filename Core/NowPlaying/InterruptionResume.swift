//
// InterruptionResume
//
// Whether playback resumes when an audio interruption (a call, Siri, an
// alarm) ends. Pure state, so the decision is tested on every order of
// notifications the system can post, not only the one a device happens to
// produce. `AudioSessionController` feeds it the notifications.
//

struct InterruptionResume: Equatable {
    /// The app meant to be playing when the current interruption began.
    private(set) var resumesOnEnd = false

    /// An interruption began. The system has already paused the player, so
    /// `wantsPlayback` is the app's own intent, not the player's state.
    mutating func began(wantsPlayback: Bool) {
        resumesOnEnd = wantsPlayback
    }

    /// The interruption ended. Returns whether to resume: only when the
    /// system allows it and the app was playing when it began.
    mutating func ended(shouldResume: Bool) -> Bool {
        defer { resumesOnEnd = false }
        return shouldResume && resumesOnEnd
    }

    /// The sound would now come out of the phone itself (headphones gone):
    /// the end of a call must not resume through the speaker.
    mutating func outputMovedToPhone() {
        resumesOnEnd = false
    }
}
