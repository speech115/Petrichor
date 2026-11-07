import Foundation
import Testing
@testable import Petrichor

/// The cover never blanks between tracks: the player surfaces keep the
/// previous cover until the next track's artwork is known.

private let coverA = Data([0xA1])
private let coverB = Data([0xB2])

@Test func holdsThePreviousCoverWhileTheNextTrackLoads() {
    var hold = NowPlayingArtworkHold()
    hold.trackChanged(to: "a", artwork: coverA)
    hold.trackChanged(to: "b", artwork: nil)
    #expect(hold.shown == .init(trackID: "a", artwork: coverA))
    #expect(hold.pendingTrackID == "b")

    hold.artworkResolved(for: "b", artwork: coverB)
    #expect(hold.shown == .init(trackID: "b", artwork: coverB))
    #expect(hold.pendingTrackID == nil)
}

@Test func enrichedTrackReplacesTheHeldCover() {
    // The usual path: PlaybackManager re-publishes the track with its bytes.
    var hold = NowPlayingArtworkHold()
    hold.trackChanged(to: "a", artwork: coverA)
    hold.trackChanged(to: "b", artwork: nil)
    hold.trackChanged(to: "b", artwork: coverB)
    #expect(hold.shown == .init(trackID: "b", artwork: coverB))
    #expect(hold.pendingTrackID == nil)
}

@Test func trackWithoutArtworkFallsBackToThePlaceholder() {
    var hold = NowPlayingArtworkHold()
    hold.trackChanged(to: "a", artwork: coverA)
    hold.trackChanged(to: "b", artwork: nil)
    hold.artworkResolved(for: "b", artwork: nil)
    #expect(hold.shown == .init(trackID: "b", artwork: nil))
}

@Test func lateLoadForAnEarlierTrackIsIgnored() {
    var hold = NowPlayingArtworkHold()
    hold.trackChanged(to: "a", artwork: coverA)
    hold.trackChanged(to: "b", artwork: nil)
    hold.artworkResolved(for: "a", artwork: coverB)
    #expect(hold.shown == .init(trackID: "a", artwork: coverA))
    #expect(hold.pendingTrackID == "b")
}

@Test func goingBackToTheHeldTrackStopsWaiting() {
    var hold = NowPlayingArtworkHold()
    hold.trackChanged(to: "a", artwork: coverA)
    hold.trackChanged(to: "b", artwork: nil)
    hold.trackChanged(to: "a", artwork: nil)
    #expect(hold.shown == .init(trackID: "a", artwork: coverA))
    #expect(hold.pendingTrackID == nil)
}

@Test func stoppingClearsTheCover() {
    var hold = NowPlayingArtworkHold()
    hold.trackChanged(to: "a", artwork: coverA)
    hold.trackChanged(to: nil, artwork: nil)
    #expect(hold.shown == nil)
    #expect(hold.pendingTrackID == nil)
}

// MARK: - Properties over generated event sequences

private enum HoldEvent {
    case change(String?, Data?)
    case resolve(String, Data?)
}

private func randomEvents(seed: UInt64) -> [HoldEvent] {
    var rng = SeededGenerator(seed: seed)
    let ids: [String?] = ["a", "b", "c", nil]
    let covers: [Data?] = [nil, coverA, coverB]
    return (0..<Int.random(in: 1...24, using: &rng)).map { _ in
        if Bool.random(using: &rng) {
            return .change(ids.randomElement(using: &rng)!, covers.randomElement(using: &rng)!)
        }
        return .resolve(["a", "b", "c"].randomElement(using: &rng)!, covers.randomElement(using: &rng)!)
    }
}

@Test(arguments: 0..<300)
func coverIsAlwaysTheCurrentTracksOrAHeldOne(seed: Int) {
    var hold = NowPlayingArtworkHold()
    var current: String?
    for event in randomEvents(seed: UInt64(seed)) {
        let before = hold
        switch event {
        case let .change(id, artwork):
            hold.trackChanged(to: id, artwork: artwork)
            if id != current, let id, artwork == nil, before.shown?.artwork != nil, before.shown?.trackID != id {
                // Never blanks: a cover on screen stays until the next is known.
                #expect(hold.shown == before.shown, "seed \(seed)")
                #expect(hold.pendingTrackID == id, "seed \(seed)")
            }
            if let artwork, let id {
                #expect(hold.shown == .init(trackID: id, artwork: artwork), "seed \(seed)")
            }
            current = id
        case let .resolve(id, artwork):
            hold.artworkResolved(for: id, artwork: artwork)
            if id != current {
                #expect(hold == before, "a load for a track that is not current changed the hold, seed \(seed)")
            } else if before.pendingTrackID == id || before.shown?.trackID == id {
                #expect(hold.shown == .init(trackID: id, artwork: artwork), "seed \(seed)")
                #expect(hold.pendingTrackID == nil, "seed \(seed)")
            }
        }

        guard let current else {
            #expect(hold.shown == nil, "seed \(seed)")
            continue
        }
        // What is drawn is the current track's cover, or a real cover held
        // while the current track's artwork loads — never another track's
        // placeholder.
        let isCurrent = hold.shown?.trackID == current
        let isHeld = hold.pendingTrackID == current && hold.shown?.artwork != nil
        #expect(isCurrent || isHeld, "seed \(seed)")
        if hold.pendingTrackID != nil {
            #expect(hold.pendingTrackID == current, "seed \(seed)")
        }
    }
}
