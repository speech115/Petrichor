import Foundation
import Testing
@testable import Petrichor

/// `AppleMusicArtist` decides which catalog artist is the library's artist
/// and what the artist page says about them. A wrong pick puts someone
/// else's face on the page, so the picker is tested for never guessing.
struct AppleMusicArtistTests {
    // MARK: - Page

    /// The header of a real page, cut down: the photo template and the bio
    /// with its HTML, behind a section of another kind.
    private static func page(header: String) -> String {
        """
        <html><head><script type="application/json" id="serialized-server-data">\
        {"data":[{"data":{"sections":[{"itemKind":"squareLockup","items":[]},\
        {"itemKind":"artistDetailHeader","items":[\(header)]}]}}]}\
        </script></head></html>
        """
    }

    @Test func readsPhotoAndBioFromTheArtistHeader() {
        let html = Self.page(header: """
            {"title":"Radiohead",\
            "artwork":{"dictionary":{"url":"https://is1-ssl.mzstatic.com/image/thumb/A/v4/x.png/{w}x{h}{c}.{f}"}},\
            "bio":"Formed in 1985.\\n\\nThen \\u003Ci>Kid A\\u003C/i> &amp; more."}
            """)

        let page = AppleMusicArtist.parsePage(html: html)

        #expect(page?.imageURL?.absoluteString == "https://is1-ssl.mzstatic.com/image/thumb/A/v4/x.png/1000x1000bb.jpg")
        #expect(page?.bio == "Formed in 1985.\n\nThen Kid A & more.")
    }

    /// An artist without a photo has only an album cover as fallback: not
    /// their face, so no photo. An empty bio is no bio.
    @Test func albumCoverFallbackIsNotAPhoto() {
        let html = Self.page(header: """
            {"artwork":null,"bio":"",\
            "fallbackArtwork":{"dictionary":{"url":"https://is1-ssl.mzstatic.com/image/thumb/M/cover.jpg/{w}x{h}{c}.{f}"}}}
            """)

        #expect(AppleMusicArtist.parsePage(html: html) == AppleMusicArtist.Page(imageURL: nil, bio: nil))
    }

    @Test(arguments: [
        "<!DOCTYPE html><html><head></head><body>Not Found</body></html>",
        #"<script type="application/json" id="serialized-server-data">{"data":[]}</script>"#,
        #"<script type="application/json" id="serialized-server-data">{not json</script>"#,
        ""
    ])
    func pageWithoutArtistHeaderIsNoPage(html: String) {
        #expect(AppleMusicArtist.parsePage(html: html) == nil)
    }

    /// Whatever HTML the bio carries, the text keeps none of it, and
    /// cleaning clean text changes nothing.
    @Test(arguments: FuzzText.seeds(200))
    func plainTextHasNoTagsAndIsStable(seed: UInt64) {
        var rng = SeededGenerator(seed: seed)
        let pool = FuzzText.fragments + ["<i>", "</i>", "<br>", "<br/>", "<b class=\"x\">", "&amp;", "\n\n\n"]
        let text = AppleMusicArtist.plainText(FuzzText.string(using: &rng, from: pool, maxFragments: 16))

        #expect(text.range(of: "<[a-zA-Z/][^>]*>", options: .regularExpression) == nil)
        #expect(!text.contains("\n\n\n"))
        #expect(AppleMusicArtist.plainText(text) == text || text.contains("&"))
    }

    // MARK: - Picking the artist

    private typealias Candidate = AppleMusicArtist.Candidate

    private static func pick(
        _ name: String,
        _ candidates: [Candidate],
        catalog: [Int: [String]] = [:],
        library: [String] = []
    ) -> Candidate? {
        AppleMusicArtist.pick(
            name: name,
            candidates: candidates,
            catalogAlbums: { catalog[$0.id] ?? [] },
            libraryAlbums: library
        )
    }

    /// One same-named artist is taken however the tag spells the case,
    /// accents or width; a different name never is, even as the only result.
    @Test(arguments: [
        ("DENZEL CURRY", "Denzel Curry", true),
        ("Röyksopp", "Royksopp", true),
        ("Tyler， The Creator", "Tyler, The Creator", true),
        ("Моргенштерн", "MORGENSHTERN", false),
        ("Pilo", "Kristaq Pilo", false),
        ("pure catharsis", "Marshmello", false)
    ])
    func takesOnlyTheSameName(tag: String, catalogName: String, taken: Bool) {
        let candidate = Candidate(id: 1, name: catalogName)
        #expect(Self.pick(tag, [Candidate(id: 9, name: "Someone Else"), candidate]) == (taken ? candidate : nil))
    }

    /// Several artists of one name: the one with an album the library has.
    @Test func sameNamedArtistsAreToldApartByAlbums() {
        let candidates = [Candidate(id: 1, name: "RAM"), Candidate(id: 2, name: "RAM")]
        let catalog = [1: ["Morning Sun - Single"], 2: ["Reptile (Deluxe Edition)", "Other"]]

        #expect(Self.pick("RAM", candidates, catalog: catalog, library: ["Reptile"]) == candidates[1])
    }

    /// No album, or an album both have, tells them apart: nothing is taken.
    @Test(arguments: [["Unknown"], ["Shared"], []])
    func unconfirmedSameNamedArtistsAreNotGuessed(library: [String]) {
        let candidates = [Candidate(id: 1, name: "Decades"), Candidate(id: 2, name: "Decades")]
        let catalog = [1: ["Shared", "A"], 2: ["Shared - EP", "B"]]

        #expect(Self.pick("Decades", candidates, catalog: catalog, library: library) == nil)
    }

    /// Whatever the names, the pick is a same-named candidate or nothing.
    @Test(arguments: FuzzText.seeds(200))
    func pickIsAlwaysSameNamed(seed: UInt64) {
        var rng = SeededGenerator(seed: seed)
        let names = ["RAM", "ram", "Ram", "RAMM", "Кино", "КИНО", "", " "]
        let name = names.randomElement(using: &rng)!
        let candidates = (0..<Int.random(in: 0...5, using: &rng)).map {
            Candidate(id: $0, name: names.randomElement(using: &rng)!)
        }
        let albums = ["A", "B", "A - Single"]
        let catalog = Dictionary(uniqueKeysWithValues: candidates.map { ($0.id, [albums.randomElement(using: &rng)!]) })

        guard let picked = Self.pick(name, candidates, catalog: catalog, library: ["A"]) else { return }
        #expect(AppleMusicArtist.sameName(as: name, in: candidates).contains(picked))
    }

    @Test(arguments: FuzzText.seeds(100))
    func albumKeyIsIdempotent(seed: UInt64) {
        var rng = SeededGenerator(seed: seed)
        let title = FuzzText.string(using: &rng, from: FuzzText.fragments + [" - Single", " - EP", " (Deluxe)"])
        let key = AppleMusicArtist.albumKey(title)
        #expect(AppleMusicArtist.albumKey(key) == key)
    }

    // MARK: - Search answers

    @Test func readsArtistsAndAlbumsFromITunesAnswers() {
        let search = Data("""
            {"results":[{"wrapperType":"artist","artistName":"Radiohead","artistId":657515},
            {"wrapperType":"collection","collectionName":"Kid A","artistId":657515}]}
            """.utf8)
        #expect(AppleMusicArtist.candidates(fromSearch: search) == [Candidate(id: 657515, name: "Radiohead")])
        #expect(AppleMusicArtist.albumTitles(fromLookup: search) == ["Kid A"])
        #expect(AppleMusicArtist.candidates(fromSearch: Data("oops".utf8)).isEmpty)
    }
}
