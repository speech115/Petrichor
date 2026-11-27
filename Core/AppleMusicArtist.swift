//
// AppleMusicArtist
//
// Pure parsing for the Apple Music artist source: picking the catalog artist
// that is the library's artist, and reading the photo and the bio out of the
// public artist page (music.apple.com), which carries them in its
// `serialized-server-data` JSON. No network here; ArtistBioManager fetches.
//

import Foundation

/// The `image_source` / `bio_source` value of what came from Apple Music.
enum ArtistInfoSource {
    static let appleMusic = "applemusic"
    /// When Apple Music became the source. A row stamped earlier was filled
    /// from the old sources and is due for an Apple Music attempt.
    static let appleMusicSince = Date(timeIntervalSince1970: 1_795_780_800) // 2026-11-27 12:00 UTC
}

enum AppleMusicArtist {
    struct Candidate: Equatable {
        let id: Int
        let name: String
    }

    struct Page: Equatable {
        /// The artist's own photo. An artist without one has no `artwork` in
        /// the header, only `fallbackArtwork` (an album cover), which is not
        /// a photo of them and is left out.
        let imageURL: URL?
        /// Plain text, paragraphs separated by a blank line.
        let bio: String?
    }

    /// Side of the requested photo; the page serves any size from a template.
    static let imageSide = 1000

    // MARK: - Choosing the artist

    /// The candidates named exactly like the library artist, ignoring case,
    /// accents and character width, in search order.
    static func sameName(as name: String, in candidates: [Candidate]) -> [Candidate] {
        candidates.filter { isSameName(name, $0.name) }
    }

    /// The library artist's catalog id, or nil when that can't be told.
    /// One same-named candidate is taken. Several ("RAM", "Decades") are told
    /// apart by the albums: the one whose catalog has an album the library
    /// has wins, and when none or more than one does, nothing is taken, since
    /// someone else's face is worse than initials.
    static func pick(
        name: String,
        candidates: [Candidate],
        catalogAlbums: (Candidate) -> [String],
        libraryAlbums: [String]
    ) -> Candidate? {
        let named = sameName(as: name, in: candidates)
        if named.count <= 1 { return named.first }
        let confirmed = named.filter { sharesAlbum(catalogAlbums($0), libraryAlbums) }
        return confirmed.count == 1 ? confirmed[0] : nil
    }

    /// True when a catalog album and a library album are the same record.
    /// The catalog suffixes singles and EPs (" - Single") and the library
    /// often drops or adds edition notes, so titles are compared without them.
    static func sharesAlbum(_ catalog: [String], _ library: [String]) -> Bool {
        let libraryKeys = Set(library.map(albumKey).filter { !$0.isEmpty })
        return catalog.contains { libraryKeys.contains(albumKey($0)) }
    }

    static func albumKey(_ title: String) -> String {
        var key = title
        for suffix in [" - Single", " - EP"] where key.hasSuffix(suffix) {
            key.removeLast(suffix.count)
        }
        // "Blonde (Deluxe Edition)" and "Blonde [Explicit]" are "Blonde".
        key = key.replacingOccurrences(of: #"\s*[\(\[][^\)\]]*[\)\]]"#, with: "", options: .regularExpression)
        return key.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func isSameName(_ lhs: String, _ rhs: String) -> Bool {
        lhs.compare(rhs, options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive]) == .orderedSame
    }

    // MARK: - Search results

    /// Artists from an iTunes Search `entity=musicArtist` response.
    static func candidates(fromSearch data: Data) -> [Candidate] {
        results(in: data).compactMap { result in
            guard result["wrapperType"] as? String == "artist",
                  let id = result["artistId"] as? Int,
                  let name = result["artistName"] as? String else { return nil }
            return Candidate(id: id, name: name)
        }
    }

    /// Album titles from an iTunes `lookup?entity=album` response.
    static func albumTitles(fromLookup data: Data) -> [String] {
        results(in: data).compactMap { result in
            guard result["wrapperType"] as? String == "collection" else { return nil }
            return result["collectionName"] as? String
        }
    }

    private static func results(in data: Data) -> [[String: Any]] {
        let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        return json?["results"] as? [[String: Any]] ?? []
    }

    // MARK: - Artist page

    /// Photo and bio from an artist page, or nil when the page has no artist
    /// header (a 404 page, a changed layout).
    static func parsePage(html: String) -> Page? {
        guard let header = artistHeader(in: html) else { return nil }
        let template = (header["artwork"] as? [String: Any])
            .flatMap { $0["dictionary"] as? [String: Any] }?["url"] as? String
        let bio = (header["bio"] as? String).map(plainText).flatMap { $0.isEmpty ? nil : $0 }
        return Page(imageURL: template.flatMap { imageURL(template: $0, side: imageSide) }, bio: bio)
    }

    /// "…/{w}x{h}{c}.{f}" → "…/1000x1000bb.jpg".
    static func imageURL(template: String, side: Int) -> URL? {
        URL(string: template
            .replacingOccurrences(of: "{w}", with: String(side))
            .replacingOccurrences(of: "{h}", with: String(side))
            .replacingOccurrences(of: "{c}", with: "bb")
            .replacingOccurrences(of: "{f}", with: "jpg"))
    }

    /// The bio comes as light HTML (`<i>` for titles, `<br>` now and then).
    static func plainText(_ html: String) -> String {
        html
            .replacingOccurrences(of: #"<br\s*/?>"#, with: "\n", options: [.regularExpression, .caseInsensitive])
            .replacingOccurrences(of: "<[^>]*>", with: "", options: .regularExpression)
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .joined(separator: "\n")
            .replacingOccurrences(of: #"\n{3,}"#, with: "\n\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func artistHeader(in html: String) -> [String: Any]? {
        guard let open = html.range(of: #"id="serialized-server-data">"#),
              let close = html.range(of: "</script>", range: open.upperBound..<html.endIndex),
              let json = try? JSONSerialization.jsonObject(with: Data(html[open.upperBound..<close.lowerBound].utf8)),
              let pages = (json as? [String: Any])?["data"] as? [[String: Any]] else { return nil }
        for page in pages {
            let sections = (page["data"] as? [String: Any])?["sections"] as? [[String: Any]] ?? []
            for section in sections where section["itemKind"] as? String == "artistDetailHeader" {
                return (section["items"] as? [[String: Any]])?.first
            }
        }
        return nil
    }
}
