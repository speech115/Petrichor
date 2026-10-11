import Foundation

enum Logger {
    static func info(_ message: String) {}
    static func warning(_ message: String) {}
}
enum About { static let knownArtistsSampleFile = "sample" }

func lookup(_ artist: String) -> [String: [String: String]] {
    ["artist": ["alias": artist], "composer": ["alias": "Composer"]]
}
ArtistParser.setLibraryArtists(lookup("First"))
for _ in 0..<3 {
    precondition(ArtistParser.parse("alias", role: "artist") == ["First"])
    precondition(ArtistParser.parse("alias", role: "composer") == ["Composer"])
    precondition(ArtistParser.parse("", unknownPlaceholder: "Empty", role: nil) == ["Empty"])
    precondition(ArtistParser.parse("", unknownPlaceholder: "Missing", role: nil) == ["Missing"])
}
ArtistParser.setLibraryArtists(lookup("Second"))
precondition(ArtistParser.parse("alias", role: "artist") == ["Second"])
precondition(ArtistParser.normalizeArtistName("Beyoncé") == ArtistParser.normalizeArtistName("Beyonce\u{301}"))

DispatchQueue.concurrentPerform(iterations: 2_000) { index in
    if index.isMultiple(of: 19) { ArtistParser.setLibraryArtists(lookup(index.isMultiple(of: 2) ? "First" : "Second")) }
    let value = ArtistParser.parse("alias", role: "artist")
    precondition(value == ["First"] || value == ["Second"])
}
ArtistParser.setLibraryArtists(lookup("Final"))
precondition(ArtistParser.parse("alias", role: "artist") == ["Final"])
ArtistParser.setLibraryArtists([:])
precondition(ArtistParser.parse("alias", role: "artist") == ["alias"])

// The runner owns this temporary executable directory, never an application bundle.
guard let resourcePath = Bundle.main.resourcePath else { fatalError("Missing test resource directory") }
let directory = URL(fileURLWithPath: resourcePath)
precondition(directory.lastPathComponent.hasPrefix("petrichor-bridge."))
let resource = directory.appendingPathComponent("known_artists_99999999.txt")
try "mumford & sons".write(to: resource, atomically: true, encoding: .utf8)
defer { try? FileManager.default.removeItem(at: resource) }
precondition(Set(ArtistParser.parse("Mumford & Sons", role: nil)) == ["Mumford", "Sons"])
ArtistParser.loadKnownArtists()
precondition(ArtistParser.parse("Mumford & Sons", role: nil) == ["Mumford & Sons"])
ArtistParser.loadKnownArtists()
ArtistParser.unloadKnownArtists()
precondition(ArtistParser.parse("Mumford & Sons", role: nil) == ["Mumford & Sons"])
ArtistParser.unloadKnownArtists()
precondition(Set(ArtistParser.parse("Mumford & Sons", role: nil)) == ["Mumford", "Sons"])
// swiftlint:disable:next no_print_statements
print("PASS artist bridge cache: roles, placeholders, replacement, Unicode, concurrent mutations, retain/release")
