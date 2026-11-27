import Foundation
import Testing
@testable import Petrichor

struct PlaylistFindTests {
    // MARK: - Properties

    @Test(arguments: FuzzText.seeds(200))
    func resultKeepsPlaylistOrderAndOnlyItsSongs(seed: UInt64) {
        var rng = SeededGenerator(seed: seed)
        let tracks = Self.tracks(using: &rng)
        let query = FuzzText.string(using: &rng, maxFragments: 3)

        let found = PlaylistFind.filter(tracks, query: query)

        // A subsequence: every found song is the next matching one in order.
        var remaining = tracks[...]
        for track in found {
            guard let index = remaining.firstIndex(of: track) else {
                Issue.record("\(track.title) out of order or not in the playlist (seed \(seed))")
                return
            }
            remaining = remaining[(index + 1)...]
        }
    }

    @Test(arguments: FuzzText.seeds(200))
    func findingAgainChangesNothing(seed: UInt64) {
        var rng = SeededGenerator(seed: seed)
        let tracks = Self.tracks(using: &rng)
        let query = FuzzText.string(using: &rng, maxFragments: 3)

        let once = PlaylistFind.filter(tracks, query: query)
        #expect(PlaylistFind.filter(once, query: query) == once)
    }

    @Test(arguments: FuzzText.seeds(200))
    func aSongNamedExactlyLikeTheQueryIsFound(seed: UInt64) {
        var rng = SeededGenerator(seed: seed)
        var tracks = Self.tracks(using: &rng)
        let query = FuzzText.string(using: &rng, from: FuzzText.singleLineFragments, maxFragments: 3)
        var named = Track(url: URL(fileURLWithPath: "/music/named-\(seed).mp3"))
        named.title = query
        tracks.insert(named, at: Int.random(in: 0...tracks.count, using: &rng))

        #expect(PlaylistFind.filter(tracks, query: query).contains(named))
    }

    @Test(arguments: ["", " ", "\t\n", "\u{3000}"])
    func aBlankQueryShowsTheWholePlaylist(query: String) {
        var rng = SeededGenerator(seed: 7)
        let tracks = Self.tracks(using: &rng)
        #expect(PlaylistFind.filter(tracks, query: query) == tracks)
    }

    // MARK: - Examples

    @Test
    func everyWordMayMatchADifferentField() {
        var track = Track(url: URL(fileURLWithPath: "/music/a.mp3"))
        track.title = "Hunter"
        track.artist = "Björk"
        track.album = "Homogenic"

        #expect(PlaylistFind.filter([track], query: "bjork hunter") == [track])
        #expect(PlaylistFind.filter([track], query: "HOMO") == [track])
        #expect(!PlaylistFind.filter([track], query: "bjork vespertine").contains(track))
    }

    // MARK: - Inputs

    private static func tracks(using rng: inout SeededGenerator) -> [Track] {
        (0..<Int.random(in: 0...12, using: &rng)).map { index in
            var track = Track(url: URL(fileURLWithPath: "/music/\(index).mp3"))
            track.title = FuzzText.string(using: &rng)
            track.artist = FuzzText.string(using: &rng)
            track.album = FuzzText.string(using: &rng)
            return track
        }
    }
}
