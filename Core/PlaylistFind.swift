//
// PlaylistFind
//
// Music's "Find in Playlist": the playlist's own songs narrowed to those
// whose title, artist or album holds every word typed, in playlist order.
// Case, accents and full-width forms are ignored, so "bjork" finds "Björk".
//

import Foundation

enum PlaylistFind {
    static func filter(_ tracks: [Track], query: String) -> [Track] {
        let words = query.split(whereSeparator: \.isWhitespace)
        guard !words.isEmpty else { return tracks }
        return tracks.filter { track in
            let fields = [track.title, track.artist, track.album]
            return words.allSatisfy { word in
                fields.contains { $0.range(of: word, options: options) != nil }
            }
        }
    }

    private static let options: String.CompareOptions = [
        .caseInsensitive, .diacriticInsensitive, .widthInsensitive
    ]
}
