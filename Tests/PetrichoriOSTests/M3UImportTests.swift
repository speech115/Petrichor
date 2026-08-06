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
