import Foundation
import Testing
@testable import Petrichor

/// Seam test for M3U import (design spec: "Разбор M3U: сохранение порядка и
/// числовых префиксов, включая переписанные относительные пути"). Drives the
/// exact production code the import runs: `parseM3UContent` turns the file
/// into ordered entries, `generatePathVariations` resolves a rewritten
/// relative entry (`../Spotify/...`) against the M3U's own directory, and the
/// path seam (`LibraryPathStore.storedPath`) turns that back into the
/// Documents-relative form the database stores. No `DatabaseManager` involved:
/// like the other seam tests, this exercises the pure predicates, not the
/// full async import pipeline.

@Test func m3uParsingKeepsOrderAndNumericPrefixes() {
    let content = """
    #EXTM3U
    #EXTINF:268,Some Artist - Some Title
    ../Spotify/Shazam/0019 - Rik Schaffer - Ruff Ryder.mp3

    #EXTINF:251,Another Artist - Another Title
    ../Spotify/0023 - Jeune Ras - Hidden Gem.mp3
    # a plain comment line must be ignored
    """

    let manager = PlaylistManager()
    let entries = manager.parseM3UContent(content)

    #expect(entries == [
        "../Spotify/Shazam/0019 - Rik Schaffer - Ruff Ryder.mp3",
        "../Spotify/0023 - Jeune Ras - Hidden Gem.mp3"
    ])
}

@Test func m3uRelativeEntriesResolveFromDocumentsRoot() {
    let sourceDirectory = LibraryPathStore.libraryRoot
        .appendingPathComponent("Petrichor-Playlists")
    let manager = PlaylistManager()

    let variations = manager.generatePathVariations(
        "../Spotify/Shazam/0019 - Rik Schaffer - Ruff Ryder.mp3",
        sourceDirectory: sourceDirectory
    )

    // First variation: the rewritten path resolved against the M3U's directory,
    // i.e. Documents/Spotify/... — exactly what the scanner registered.
    let expected = LibraryPathStore.libraryRoot
        .appendingPathComponent("Spotify/Shazam/0019 - Rik Schaffer - Ruff Ryder.mp3")
    #expect(variations.first == expected.standardizedFileURL.path)

    // The path seam must store it relative to Documents, not absolute — the
    // container UUID is not stable across reinstalls.
    let stored = LibraryPathStore.storedPath(for: URL(fileURLWithPath: variations[0]))
    #expect(stored == "Spotify/Shazam/0019 - Rik Schaffer - Ruff Ryder.mp3")
    #expect(!stored.hasPrefix("/"))
}

@Test func m3uParsingIgnoresEmptyFileAndComments() {
    let manager = PlaylistManager()

    #expect(manager.parseM3UContent("#EXTM3U\n\n#EXTINF:1,A - B\n").isEmpty)
    #expect(manager.parseM3UContent("").isEmpty)
}

// MARK: - Normalized filename matching

/// The phone's files were renamed during transfer (numeric prefixes stripped,
/// `,` → `;`, extra spaces), so the exact-filename fallback of the M3U import
/// misses most entries. The normalized fallback must strip the same shapes so
/// a mac-written M3U still lands on the renamed file.
@Test func m3uFilenameNormalizationStripsNumericPrefix() {
    #expect(M3UFilenameNormalizer.normalize("0001 - Annabel - Above your hand.mp3")
            == "annabel - above your hand.mp3")
    #expect(M3UFilenameNormalizer.normalize("104 - ДО ОБЕДА.mp3") == "до обеда.mp3")
    #expect(M3UFilenameNormalizer.normalize("Already - dashed.mp3") == "already - dashed.mp3")
}

@Test func m3uFilenameNormalizationUnifiesPunctuation() {
    #expect(M3UFilenameNormalizer.normalize("$atori Zoom;DVRST - Still Breathing (Sped Up).mp3")
            == "$atori zoom,dvrst - still breathing (sped up).mp3")
    #expect(M3UFilenameNormalizer.normalize("  Artist  -  Title.mp3") == "artist - title.mp3")
}

/// The matcher maps a mac filename onto the single renamed database filename
/// with the same normalized key, and refuses ambiguous keys.
@Test func m3uFilenameMatcherResolvesRenamedFilesAndRejectsAmbiguity() {
    let candidates = [
        "Annabel - Above your hand.mp3",
        "Boulevard Depo, DJ Stonik1917 - TEKK.mp3",
        "Foo;Bar.mp3",
        "Foo, Bar.mp3",
        "Plain name.mp3"
    ]

    let resolve = { M3UFilenameMatcher.resolveAll([$0], against: candidates)[$0] }

    #expect(resolve("0001 - Annabel - Above your hand.mp3") == "Annabel - Above your hand.mp3")
    #expect(resolve("Boulevard Depo;DJ Stonik1917 - TEKK.mp3") == "Boulevard Depo, DJ Stonik1917 - TEKK.mp3")
    #expect(resolve("No such track.mp3") == nil)
    // "Foo;Bar.mp3" and "Foo, Bar.mp3" collapse onto one normalized key:
    // both must be refused rather than guessing.
    #expect(resolve("Foo;Bar.mp3") == nil)
    #expect(resolve("Foo, Bar.mp3") == nil)
}

/// A key must stay blocked after its first collision: a third candidate on
/// the same key would otherwise look unambiguous again.
@Test func m3uFilenameMatcherKeepsCollidedKeysBlocked() {
    let candidates = [
        "Foo;Bar.mp3",
        "Foo, Bar.mp3",
        "Foo , Bar.mp3"
    ]
    #expect(M3UFilenameMatcher.resolveAll(["Foo;Bar.mp3"], against: candidates).isEmpty)
}
