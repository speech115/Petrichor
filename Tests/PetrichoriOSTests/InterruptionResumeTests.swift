import Foundation
import Testing
@testable import Petrichor

/// `InterruptionResume` decides whether music comes back after a call. The
/// system's notifications do not arrive in one tidy order: on 2026-11-10 a
/// call posted `began` twice, the second after the app had already paused,
/// and the music never resumed. Property: within one interruption, extra
/// `began` notifications never change the outcome.

private enum InterruptionEvent: CustomStringConvertible {
    case began(wantsPlayback: Bool)
    case outputMovedToPhone

    var description: String {
        switch self {
        case .began(let wants): "began(\(wants))"
        case .outputMovedToPhone: "outputMovedToPhone"
        }
    }
}

@Test func aSecondBeganDuringOneCallKeepsTheResume() {
    var interruption = InterruptionResume()
    interruption.began(wantsPlayback: true)
    // The app paused for the first one, so the second reads `false`.
    interruption.began(wantsPlayback: false)
    #expect(interruption.ended(shouldResume: true), "music did not come back after the call")
}

@Test(arguments: FuzzText.seeds(200))
func repeatedBeganNotificationsNeverChangeTheOutcome(seed: UInt64) {
    var rng = SeededGenerator(seed: seed)
    let wantsAtStart = Bool.random(using: &rng)
    let shouldResume = Bool.random(using: &rng)
    // After the first `began` the app has paused itself: later ones read false.
    let tail: [InterruptionEvent] = (0..<Int.random(in: 0...4, using: &rng)).map { _ in
        Int.random(in: 0..<4, using: &rng) == 0 ? .outputMovedToPhone : .began(wantsPlayback: false)
    }

    var withRepeats = InterruptionResume()
    var reference = InterruptionResume()
    withRepeats.began(wantsPlayback: wantsAtStart)
    reference.began(wantsPlayback: wantsAtStart)
    for event in tail {
        switch event {
        case .began(let wants):
            withRepeats.began(wantsPlayback: wants)
        case .outputMovedToPhone:
            withRepeats.outputMovedToPhone()
            reference.outputMovedToPhone()
        }
    }

    #expect(
        withRepeats.ended(shouldResume: shouldResume) == reference.ended(shouldResume: shouldResume),
        "began(\(wantsAtStart)) then \(tail), shouldResume \(shouldResume)"
    )
}

@Test(arguments: FuzzText.seeds(50))
func anInterruptionNeverStartsMusicThatWasNotPlaying(seed: UInt64) {
    var rng = SeededGenerator(seed: seed)
    var interruption = InterruptionResume()
    interruption.began(wantsPlayback: false)
    for _ in 0..<Int.random(in: 0...3, using: &rng) {
        interruption.began(wantsPlayback: Bool.random(using: &rng))
    }
    #expect(!interruption.ended(shouldResume: Bool.random(using: &rng)))
}

@Test func endingAnInterruptionClosesIt() {
    var interruption = InterruptionResume()
    interruption.began(wantsPlayback: true)
    #expect(interruption.ended(shouldResume: true))
    // A new call while paused must not inherit the previous call's resume.
    interruption.began(wantsPlayback: false)
    #expect(!interruption.ended(shouldResume: true))
}

@Test func headphonesGoneDuringACallKeepTheSpeakerQuiet() {
    var interruption = InterruptionResume()
    interruption.began(wantsPlayback: true)
    interruption.outputMovedToPhone()
    #expect(!interruption.ended(shouldResume: true))
}
