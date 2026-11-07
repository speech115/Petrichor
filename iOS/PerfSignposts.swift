//
// PerfSignposts (iOS)
//
// Points-of-Interest intervals that the CI benchmark reads through
// `XCTOSSignpostMetric` (Tests/PetrichoriOSUITests/PerformanceUITests.swift).
// Launch already marks "Prepare Home" in `PetrichorApp`; this file adds the
// interactions the benchmark measures that have no system signpost of their
// own. Signposts cost nothing when no one is recording, so they ship in
// Release too and Instruments shows the same intervals on a device.
//

import OSLog

@MainActor
enum PerfSignposts {
    nonisolated static let subsystem = "org.Petrichor.ios"
    nonisolated static let signposter = OSSignposter(subsystem: subsystem, category: .pointsOfInterest)

    /// "Open Now Playing": from the moment the player is asked for (tap or
    /// swipe on the mini player) to the first frame the presented player
    /// commits. `onAppear` runs inside the transaction that builds that frame,
    /// so the end is posted one main-queue turn later, after the commit.
    nonisolated static let openNowPlaying: StaticString = "Open Now Playing"
    private static var openNowPlayingState: OSSignpostIntervalState?

    static func beginOpenNowPlaying() {
        guard openNowPlayingState == nil else { return }
        openNowPlayingState = signposter.beginInterval(openNowPlaying)
    }

    static func endOpenNowPlaying() {
        guard let state = openNowPlayingState else { return }
        openNowPlayingState = nil
        DispatchQueue.main.async {
            signposter.endInterval(openNowPlaying, state)
        }
    }
}
