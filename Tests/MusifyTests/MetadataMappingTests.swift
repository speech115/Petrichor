import Foundation
import Testing
@testable import Musify

@Test func filenameFallbackExtractsArtistAndKeepsPrefixedTitle() {
    let url = URL(fileURLWithPath: "/tmp/0239 - Jeune Ras - Ruff Ryder - Remix.mp3")

    let parsed = FilenameMetadataFallback.parse(url)

    #expect(parsed.artist == "Jeune Ras")
    #expect(parsed.title == "0239 - Jeune Ras - Ruff Ryder - Remix")
}

@Test func filenameWithoutNumericPrefixIsLeftAlone() {
    let url = URL(fileURLWithPath: "/tmp/Just A Song.mp3")

    let parsed = FilenameMetadataFallback.parse(url)

    #expect(parsed.artist == nil)
    #expect(parsed.title == "Just A Song")
}

@Test func plainArtistDashTitleExtractsArtist() {
    let url = URL(fileURLWithPath: "/tmp/System of a down - Violent pornography.mp3")

    let parsed = FilenameMetadataFallback.parse(url)

    #expect(parsed.artist == "System of a down")
    #expect(parsed.title == "Violent pornography")
}

@Test func plainArtistDashTitleWithLowercaseWords() {
    let url = URL(fileURLWithPath: "/tmp/avatar the last airbender - safe return.mp3")

    let parsed = FilenameMetadataFallback.parse(url)

    #expect(parsed.artist == "avatar the last airbender")
    #expect(parsed.title == "safe return")
}

@Test func shortArtistDashTitleExtractsArtist() {
    let url = URL(fileURLWithPath: "/tmp/Jaden - The Passion.mp3")

    let parsed = FilenameMetadataFallback.parse(url)

    #expect(parsed.artist == "Jaden")
    #expect(parsed.title == "The Passion")
}

@Test func titleWithMultipleDashesReassemblesRemainder() {
    let url = URL(fileURLWithPath: "/tmp/Jeune Ras - Ruff Ryder - Remix.mp3")

    let parsed = FilenameMetadataFallback.parse(url)

    #expect(parsed.artist == "Jeune Ras")
    #expect(parsed.title == "Ruff Ryder - Remix")
}

@Test func numericPrefixedTitleTrimsWhitespace() {
    let url = URL(fileURLWithPath: "/tmp/  0239 - Jeune Ras - Ruff Ryder - Remix  .mp3")

    let parsed = FilenameMetadataFallback.parse(url)

    #expect(parsed.artist == "Jeune Ras")
    #expect(parsed.title == "0239 - Jeune Ras - Ruff Ryder - Remix")
}
