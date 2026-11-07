//
// PlaybackPhase
//
// The player's playback lifecycle as one explicit state machine: every phase
// and every legal transition is in `applying(_:)`, so "what can happen after
// what" is read in one place instead of being reconstructed from the boolean
// flips spread across the engine callbacks. Pure: no engine, no clock.
//

import Foundation

/// Where playback stands.
enum PlaybackPhase: Hashable, CaseIterable {
    /// Nothing loaded: fresh launch or after a stop.
    case idle
    /// A track was handed to the engine; it has not reported playing or paused yet.
    case loading
    case playing
    case paused
    /// The last queued track finished and nothing follows it.
    case ended
    /// The engine reported an error for the loaded track.
    case failed

    /// Whether the transport is moving. The only phase that animates the bar.
    var isPlaying: Bool { self == .playing }

    /// The phase after `event`, or nil when `event` cannot happen in this phase.
    /// A nil is a stale or out-of-order callback: callers keep the current phase.
    func applying(_ event: PlaybackEvent) -> PlaybackPhase? {
        switch (self, event) {
        // A new load, a stop and an error are legal from anywhere.
        case (_, .load):
            return .loading
        case (_, .stop):
            return .idle
        case (_, .fail):
            return .failed

        // The engine reports the loaded track playing, or a paused load settled.
        case (.loading, .start), (.paused, .start), (.playing, .start),
             (.ended, .start), (.failed, .start):
            return .playing
        case (.loading, .pause), (.playing, .pause), (.paused, .pause):
            return .paused

        // The engine walking to the next entry means it is playing that entry;
        // only a playing track can run out.
        case (.loading, .advance), (.playing, .advance):
            return .playing
        case (.playing, .finish):
            return .ended

        default:
            return nil
        }
    }
}

/// What the engine or the user did.
enum PlaybackEvent: Hashable, CaseIterable {
    /// A track was handed to the engine.
    case load
    /// The engine reports the transport playing.
    case start
    /// The engine reports the transport paused.
    case pause
    /// The engine moved on to the next queued entry by itself.
    case advance
    /// The current entry finished and nothing is queued after it.
    case finish
    /// The engine failed the loaded entry.
    case fail
    /// Playback was torn down.
    case stop
}

/// One refused transition: the phase it arrived in and the event itself.
struct PlaybackRejection: Equatable {
    let phase: PlaybackPhase
    let event: PlaybackEvent
}

/// A phase plus the transitions it refused, for the one owner that feeds it
/// engine events. Refused events leave the phase unchanged.
struct PlaybackPhaseMachine: Equatable {
    private(set) var phase: PlaybackPhase = .idle
    private(set) var rejected: [PlaybackRejection] = []

    /// Applies `event`; returns false and records it when the phase forbids it.
    @discardableResult
    mutating func send(_ event: PlaybackEvent) -> Bool {
        guard let next = phase.applying(event) else {
            rejected.append(PlaybackRejection(phase: phase, event: event))
            return false
        }
        phase = next
        return true
    }
}
