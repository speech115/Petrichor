import Testing
@testable import Petrichor

/// Pure-logic test of the playback state machine (`Core/Playback/PlaybackPhase`).
/// `legal` is the spec: every transition that may happen, and where it leads.
/// Any pair missing from it must be refused.

private let legal: [PlaybackPhase: [PlaybackEvent: PlaybackPhase]] = [
    .idle: [.load: .loading, .stop: .idle, .fail: .failed],
    .loading: [
        .load: .loading, .start: .playing, .pause: .paused, .advance: .playing,
        .stop: .idle, .fail: .failed,
    ],
    .playing: [
        .load: .loading, .start: .playing, .pause: .paused, .advance: .playing,
        .finish: .ended, .stop: .idle, .fail: .failed,
    ],
    .paused: [.load: .loading, .start: .playing, .pause: .paused, .stop: .idle, .fail: .failed],
    .ended: [.load: .loading, .start: .playing, .stop: .idle, .fail: .failed],
    .failed: [.load: .loading, .start: .playing, .stop: .idle, .fail: .failed],
]

@Test(arguments: PlaybackPhase.allCases)
func everyTransitionMatchesTheTable(phase: PlaybackPhase) {
    for event in PlaybackEvent.allCases {
        #expect(phase.applying(event) == legal[phase]?[event], "\(phase) + \(event)")
    }
}

@Test func onlyPlayingIsPlaying() {
    #expect(PlaybackPhase.allCases.filter(\.isPlaying) == [.playing])
}

@Test func ordinaryListeningSession() {
    var machine = PlaybackPhaseMachine()
    for event: PlaybackEvent in [.load, .start, .pause, .start, .advance, .finish] {
        let before = machine.phase
        let accepted = machine.send(event)
        #expect(accepted, "\(event) refused in \(before)")
    }
    #expect(machine.phase == .ended)
    #expect(machine.rejected.isEmpty)
}

@Test func restoredTrackSettlesPausedThenResumes() {
    var machine = PlaybackPhaseMachine()
    machine.send(.load)
    machine.send(.pause) // startPaused load
    machine.send(.start)
    #expect(machine.phase == .playing)
}

/// A finish that raced in after a new load belongs to the old track: it must
/// not end the one now loading.
@Test func staleFinishAfterLoadIsRefused() {
    var machine = PlaybackPhaseMachine()
    machine.send(.load)
    let accepted = machine.send(.finish)
    #expect(!accepted)
    #expect(machine.phase == .loading)
    #expect(machine.rejected == [PlaybackRejection(phase: .loading, event: .finish)])
}

@Test func errorThenNewTrackRecovers() {
    var machine = PlaybackPhaseMachine()
    machine.send(.load)
    machine.send(.start)
    machine.send(.fail)
    #expect(machine.phase == .failed)
    let pauseAccepted = machine.send(.pause)
    #expect(!pauseAccepted)
    machine.send(.load)
    machine.send(.start)
    #expect(machine.phase == .playing)
}

@Test func everyPhaseIsReachableFromIdleAndCanReturnToIdle() {
    var reached: Set<PlaybackPhase> = [.idle]
    var frontier: [PlaybackPhase] = [.idle]
    while let phase = frontier.popLast() {
        for event in PlaybackEvent.allCases {
            if let next = phase.applying(event), reached.insert(next).inserted {
                frontier.append(next)
            }
        }
    }
    #expect(reached == Set(PlaybackPhase.allCases))
    for phase in PlaybackPhase.allCases {
        #expect(phase.applying(.stop) == .idle)
    }
}

/// Property over long random event streams (fixed seeds, so a failure replays):
/// a refused event changes nothing, `ended` is entered only from `playing`,
/// `playing` only through `start` or `advance`, and `load`/`stop`/`fail`
/// always land where they promise.
@Test(arguments: [UInt64](1...12))
func randomEventStreamsKeepTheInvariants(seed: UInt64) {
    var rng = SeededGenerator(seed: seed)
    var machine = PlaybackPhaseMachine()
    for _ in 0..<500 {
        let event = PlaybackEvent.allCases.randomElement(using: &rng)!
        let before = machine.phase
        let accepted = machine.send(event)
        let after = machine.phase

        #expect(accepted == (before.applying(event) != nil))
        if !accepted {
            #expect(after == before)
            continue
        }
        if after == .ended, before != .ended {
            #expect(before == .playing)
        }
        if after == .playing, before != .playing {
            #expect(event == .start || event == .advance)
        }
        switch event {
        case .load: #expect(after == .loading)
        case .stop: #expect(after == .idle)
        case .fail: #expect(after == .failed)
        default: break
        }
    }
}
