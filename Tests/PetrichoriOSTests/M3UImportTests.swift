import Foundation
import Testing
@testable import Petrichor

/// Seam test for M3U import (design spec: "Разбор M3U: сохранение порядка и
/// числовых префиксов, включая переписанные относительные пути"). Drives the
/// exact production code the import runs: `parseM3UContent` turns the file
/// into ordered entries, `M3UTrackResolver.pathVariations` resolves a rewritten
/// relative entry (`../Spotify/...`) against the M3U's own directory, and the
/// path seam (`LibraryPathStore.storedPath`) turns that back into the
/// Documents-relative form the database stores. The pure predicates run
/// without a database; `fullM3UImportMatchesInOrderWithRenamesAndRefusesAmbiguity`
/// drives the whole chain — scan, resolver, ambiguity policy — against a
/// throwaway temp pool.

@MainActor
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

    let variations = M3UTrackResolver.pathVariations(
        for: "../Spotify/Shazam/0019 - Rik Schaffer - Ruff Ryder.mp3",
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

@MainActor
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

/// Seam test «полный импорт M3U» (design spec, пункт 2): a real M3U file plus
/// files on disk plus an in-memory database — the whole import chain runs
/// through `M3UTrackResolver.resolveTracks` (via `parseM3UContent` and the
/// database-backed `m3uQuery()`). Matches land in M3U order across all three
/// stages (path → exact name → normalized name), renamed files are found, and
/// ambiguous keys are refused. Impossible before `DatabaseManager(pool:)` and
/// the resolver module: the old tests drove `M3UFilenameMatcher.resolveAll`
/// against a hand-built candidate list instead of the real pipeline.
@MainActor
@Test func fullM3UImportMatchesInOrderWithRenamesAndRefusesAmbiguity() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("petrichor-m3u-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }

    // The library as it lives on the phone: rewritten relative layout plus the
    // transfer rename (`0001 - ` prefix stripped) and a collision set.
    let spotifyDir = root.appendingPathComponent("Spotify/Shazam", isDirectory: true)
    let renamedDir = root.appendingPathComponent("Renamed", isDirectory: true)
    let ambiguousDir = root.appendingPathComponent("Ambiguous", isDirectory: true)
    for dir in [spotifyDir, renamedDir, ambiguousDir] {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    let ruffRyder = try makeSilentMP3(artist: "Rik Schaffer", title: "Ruff Ryder")
    let hiddenGem = try makeSilentMP3(artist: "Jeune Ras", title: "Hidden Gem")
    let renamed = try makeSilentMP3(artist: "Annabel", title: "Above your hand")
    let fooSemicolon = try makeSilentMP3()
    let fooComma = try makeSilentMP3()
    let fooSpaced = try makeSilentMP3()
    defer {
        for url in [ruffRyder, hiddenGem, renamed, fooSemicolon, fooComma, fooSpaced] {
            try? FileManager.default.removeItem(at: url)
        }
    }
    try FileManager.default.moveItem(
        at: ruffRyder,
        to: spotifyDir.appendingPathComponent("0019 - Rik Schaffer - Ruff Ryder.mp3"))
    try FileManager.default.moveItem(
        at: hiddenGem,
        to: root.appendingPathComponent("Spotify/0023 - Jeune Ras - Hidden Gem.mp3"))
    try FileManager.default.moveItem(
        at: renamed,
        to: renamedDir.appendingPathComponent("Annabel - Above your hand.mp3"))
    // All three collapse onto one normalized key `foo,bar.mp3`; none may win.
    try FileManager.default.moveItem(at: fooSemicolon, to: ambiguousDir.appendingPathComponent("Foo;Bar.mp3"))
    try FileManager.default.moveItem(at: fooComma, to: ambiguousDir.appendingPathComponent("Foo, Bar.mp3"))
    try FileManager.default.moveItem(at: fooSpaced, to: ambiguousDir.appendingPathComponent("Foo , Bar.mp3"))

    // Deterministic metadata: the simulator's media service is shared and
    // flakes under parallel load, so the scan pipeline gets a fixed reader.
    MetadataEngine.readerOverride = TestMetadataReader.shared

    // Scan the folder into an in-memory pool with the real scan pipeline.
    let databaseManager = try DatabaseManager(pool: makeTestDatabasePool(in: root))
    _ = try await databaseManager.addFoldersAsync([root], bookmarkDataMap: [:])

    // The M3U file, written the way `sync-m3u.py` rewrites it: entries relative
    // to Documents/Petrichor-Playlists.
    let playlistsDir = root.appendingPathComponent("Petrichor-Playlists", isDirectory: true)
    try FileManager.default.createDirectory(at: playlistsDir, withIntermediateDirectories: true)
    let m3uURL = playlistsDir.appendingPathComponent("Test Playlist.m3u")
    let content = """
        #EXTM3U
        #EXTINF:268,Rik Schaffer - Ruff Ryder
        ../Spotify/Shazam/0019 - Rik Schaffer - Ruff Ryder.mp3

        #EXTINF:251,Jeune Ras - Hidden Gem
        ../Spotify/0023 - Jeune Ras - Hidden Gem.mp3

        #EXTINF:200,Annabel - Above your hand
        ../Renamed/0001 - Annabel - Above your hand.mp3

        #EXTINF:180,Foo - Bar
        ../Ambiguous/Foo ; Bar.mp3

        #EXTINF:160,Missing Track
        ../Empty/Never Existed.mp3
        """
    try content.write(to: m3uURL, atomically: true, encoding: .utf8)
    let fileContent = try String(contentsOf: m3uURL, encoding: .utf8)
    let entries = PlaylistManager().parseM3UContent(fileContent)

    let resolved = await M3UTrackResolver.resolveTracks(
        for: entries,
        sourceDirectory: playlistsDir,
        using: databaseManager.m3uQuery()
    )

    // Matches come back in M3U order: exact path first, then the renamed file
    // through the normalized-name stage.
    let matched = resolved.compactMap { $0 }
    #expect(matched.count == 3)
    #expect(matched.map { $0.url.lastPathComponent } == [
        "0019 - Rik Schaffer - Ruff Ryder.mp3",
        "0023 - Jeune Ras - Hidden Gem.mp3",
        "Annabel - Above your hand.mp3"
    ])

    // The collided key is refused rather than guessed, and the missing file
    // stays unmatched. `resolved` is one element per entry, in entry order.
    #expect(resolved[3] == nil)
    #expect(resolved[4] == nil)
}

@Test func importedPlaylistNamesStaySeparateFromPersonalPlaylists() {
    for name in ["Все треки", "03 Все треки", "Spotify - Liked Songs", "Любимые треки", "Яндекс Музыка"] {
        let playlist = Playlist(name: name, tracks: [])
        #expect(PlaylistSource.isImported(playlist))
        #expect(playlist.name == name)
    }
    #expect(PlaylistDisplay.name(for: Playlist(name: "Все треки", tracks: [])) == "Все треки")
    #expect(!PlaylistSource.isImported(Playlist(name: "Road Trip", tracks: [])))
    #expect(!PlaylistSource.isImported(Playlist(name: "Favorites", tracks: [])))
}
