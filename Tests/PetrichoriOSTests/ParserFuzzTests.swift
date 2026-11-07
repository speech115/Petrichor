import Foundation
import Testing
@testable import Petrichor

/// Property tests that feed the text parsers malformed input: what broken
/// tags, hand-edited or foreign playlists and mis-decoded files are made of
/// (`FuzzText`). Every property case takes a seed, so a red case names the
/// seed that reproduces it; the minimal failing input of each property found
/// so far is pinned as a separate example next to it.

// MARK: - M3U: reading

/// A playlist line, never blank and never a comment, that may hold any
/// character a CR/LF-separated line can hold — including U+0085 and U+2028.
private func m3uEntry(index: Int, using rng: inout SeededGenerator) -> String {
    "Music/\(index)" + FuzzText.string(using: &rng, from: FuzzText.singleLineFragments) + ".mp3"
}

@MainActor
@Test(arguments: FuzzText.seeds(200))
func m3uEntriesSurviveEveryLineEnding(seed: UInt64) {
    var rng = SeededGenerator(seed: seed)
    let entries = (0..<Int.random(in: 1...6, using: &rng)).map { m3uEntry(index: $0, using: &rng) }
    let ending = ["\n", "\r\n", "\r"].randomElement(using: &rng)!
    var lines = ["#EXTM3U"]
    for entry in entries {
        lines.append("#EXTINF:1,Artist - Title")
        lines.append(entry)
    }

    #expect(PlaylistManager().parseM3UContent(lines.joined(separator: ending)) == entries)
}

@MainActor
@Test func m3uEntryWithAUnicodeLineSeparatorStaysOneEntry() {
    #expect(PlaylistManager().parseM3UContent("#EXTM3U\nMusic/a\u{2028}b.mp3") == ["Music/a\u{2028}b.mp3"])
}

@MainActor
@Test func m3uByteOrderMarkIsNotAnEntry() throws {
    var data = Data([0xEF, 0xBB, 0xBF])
    data.append(Data("#EXTM3U\r\n#EXTINF:1,A - B\r\nMusic/a.mp3\r\n".utf8))
    let content = try #require(PlaylistManager.decodeM3UData(data))

    #expect(PlaylistManager().parseM3UContent(content) == ["Music/a.mp3"])
    #expect(PlaylistManager().parseM3UContent("\u{FEFF}#EXTM3U\nMusic/a.mp3") == ["Music/a.mp3"])
}

/// Windows tools write UTF-16 playlists with a byte order mark; UTF-8 fails on
/// them, and the Latin-1 catch-all turns every entry into NUL-riddled noise.
@MainActor
@Test(arguments: [true, false])
func m3uInUTF16WithByteOrderMarkDecodes(littleEndian: Bool) throws {
    let text = "#EXTM3U\r\n#EXTINF:1,Кино - Группа крови\r\nМузыка/Кино - Группа крови.mp3\r\n"
    var data = Data(littleEndian ? [0xFF, 0xFE] : [0xFE, 0xFF])
    data.append(utf16Bytes(text, littleEndian: littleEndian))
    let content = try #require(PlaylistManager.decodeM3UData(data))

    #expect(PlaylistManager().parseM3UContent(content) == ["Музыка/Кино - Группа крови.mp3"])
}

// MARK: - M3U: export round trip

/// Whatever the tags hold, an exported playlist reads back as the same paths:
/// a line break inside a title must not turn its tail into a track entry.
@MainActor
@Test(arguments: FuzzText.seeds(200))
func m3uExportReadsBackTheSamePaths(seed: UInt64) {
    var rng = SeededGenerator(seed: seed)
    let tracks = (0..<Int.random(in: 1...5, using: &rng)).map { index in
        let name = "\(index)" + FuzzText.string(using: &rng, from: FuzzText.filenameFragments)
        var track = Track(url: URL(fileURLWithPath: "/Music/\(name).mp3"))
        track.title = FuzzText.string(using: &rng)
        track.artist = FuzzText.string(using: &rng)
        return track
    }
    let manager = PlaylistManager()

    #expect(manager.parseM3UContent(manager.generateM3UContent(for: tracks)) == tracks.map(\.url.path))
}

/// U+0085 is what a cp1252 "…" becomes when a tag is decoded as Latin-1.
@MainActor
@Test(arguments: ["Intro\nOutro", "Wait\u{0085}", "A\rB"])
func m3uExportOfTitleWithLineBreakKeepsOneEntry(title: String) {
    var track = Track(url: URL(fileURLWithPath: "/Music/a.mp3"))
    track.title = title
    let manager = PlaylistManager()

    #expect(manager.parseM3UContent(manager.generateM3UContent(for: [track])) == ["/Music/a.mp3"])
}

// MARK: - M3U: normalized filename key

private func word(using rng: inout SeededGenerator) -> String {
    let letters = Array("abcxyzKLMабвгЁЖЩ")
    let part = { (rng: inout SeededGenerator) -> String in
        String((0..<Int.random(in: 1...6, using: &rng)).map { _ in letters.randomElement(using: &rng)! })
    }
    let first = part(&rng)
    return Bool.random(using: &rng) ? first + " " + part(&rng) : first
}

/// The transfer to the phone strips the numeric prefix, turns `, ` into `;`
/// and leaves stray spaces; the mac-written M3U entry and the renamed file
/// must still meet on one key.
@Test(arguments: FuzzText.seeds(200))
func m3uKeyIgnoresTransferRenameNoise(seed: UInt64) {
    var rng = SeededGenerator(seed: seed)
    let artists = (0..<Int.random(in: 1...4, using: &rng)).map { _ in word(using: &rng) }
    let title = word(using: &rng)
    let number = String(Int.random(in: 1...9999, using: &rng))
    let prefix = String(repeating: "0", count: 4 - number.count) + number

    let macName = prefix + " - " + artists.joined(separator: ", ") + " - " + title + ".mp3"
    let separators = [",", ", ", " , ", ";", "; ", " ; ", ";  ", "  ;  ", "  ,  "]
    var phoneName = artists[0]
    for artist in artists.dropFirst() {
        phoneName += separators.randomElement(using: &rng)! + artist
    }
    phoneName += " - " + title + ".mp3"

    #expect(M3UFilenameNormalizer.normalize(macName) == M3UFilenameNormalizer.normalize(phoneName))
}

@Test func m3uKeyOfDoubleSpacedSemicolonMatchesComma() {
    #expect(M3UFilenameNormalizer.normalize("0001 - Foo, Bar - Song.mp3")
            == M3UFilenameNormalizer.normalize("Foo;  Bar - Song.mp3"))
}

@Test(arguments: FuzzText.seeds(200))
func m3uKeyIsStableUnderRenormalization(seed: UInt64) {
    var rng = SeededGenerator(seed: seed)
    // A leading letter: a name that starts with `NNNN - ` twice is not stable
    // by design (one prefix per normalization).
    let name = "x" + FuzzText.string(using: &rng, from: FuzzText.filenameFragments) + ".mp3"
    let key = M3UFilenameNormalizer.normalize(name)

    #expect(M3UFilenameNormalizer.normalize(key) == key, "\(name.debugDescription)")
}

// MARK: - Filename fallback

private func isBlank(_ string: String) -> Bool {
    string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
}

@Test(arguments: FuzzText.seeds(300))
func filenameFallbackNeverYieldsABlankName(seed: UInt64) {
    var rng = SeededGenerator(seed: seed)
    let pool = FuzzText.filenameFragments + [" - ", " - ", "0001", "  "]
    var base = FuzzText.string(using: &rng, from: pool, maxFragments: 6)
    if Bool.random(using: &rng) {
        base = "0042 - " + base
    }
    let parsed = FilenameMetadataFallback.parse(URL(fileURLWithPath: "/Music").appendingPathComponent(base + ".mp3"))

    if let artist = parsed.artist {
        #expect(!isBlank(artist), "\(base.debugDescription)")
    }
    if !isBlank(base) {
        #expect(!isBlank(parsed.title), "\(base.debugDescription)")
    }
}

@Test(arguments: ["0001 -  - Intro", "0001 -   - Intro", "12 -  - "])
func filenameFallbackWithEmptyArtistSlotHasNoArtist(base: String) {
    #expect(FilenameMetadataFallback.parse(URL(fileURLWithPath: "/Music/\(base).mp3")).artist == nil)
}

// MARK: - Track number (TRCK)

@Test(arguments: FuzzText.seeds(200))
func trackNumberReadsEveryTextShape(seed: UInt64) {
    var rng = SeededGenerator(seed: seed)
    let number = Int.random(in: 1...999, using: &rng)
    let total: Int? = Bool.random(using: &rng) ? Int.random(in: number...999, using: &rng) : nil
    var text = total.map { "\(number)/\($0)" } ?? "\(number)"
    switch Int.random(in: 0...4, using: &rng) {
    case 1: text = " \(text) "
    case 2: text = "0" + text
    case 3: text += "\u{0000}" // NUL-terminated, as ID3 writers often leave it
    case 4: text = total.map { "\(number) / \($0)" } ?? text
    default: break
    }
    let parsed = MetadataMapping.trackNumber(from: text)

    #expect(parsed?.number == number, "\(text.debugDescription)")
    #expect(parsed?.total == total, "\(text.debugDescription)")
}

/// "/12" carries a total and no track number; it must not become track 12.
@Test(arguments: ["/12", " / 12", "/", ""])
func trackNumberWithoutANumberIsMissing(text: String) {
    #expect(MetadataMapping.trackNumber(from: text) == nil)
}

@Test(arguments: FuzzText.seeds(200))
func trackNumberDecodesEveryID3TextEncoding(seed: UInt64) {
    var rng = SeededGenerator(seed: seed)
    let number = Int.random(in: 1...999, using: &rng)
    let total: Int? = Bool.random(using: &rng) ? Int.random(in: number...999, using: &rng) : nil
    let text = total.map { "\(number)/\($0)" } ?? "\(number)"
    let encoding = UInt8.random(in: 0...3, using: &rng)

    var frame = Data([encoding])
    switch encoding {
    case 1:
        let littleEndian = Bool.random(using: &rng)
        frame.append(contentsOf: littleEndian ? [0xFF, 0xFE] : [0xFE, 0xFF])
        frame.append(utf16Bytes(text, littleEndian: littleEndian))
    case 2:
        frame.append(utf16Bytes(text, littleEndian: false))
    default: // 0 latin-1, 3 UTF-8: identical bytes for digits and "/"
        frame.append(Data(text.utf8))
    }
    if Bool.random(using: &rng) {
        frame.append(contentsOf: encoding == 1 || encoding == 2 ? [0, 0] : [0])
    }
    let parsed = MetadataMapping.trackNumber(fromID3TextFrame: frame)

    #expect(parsed?.number == number, "frame \(Array(frame))")
    #expect(parsed?.total == total, "frame \(Array(frame))")
}

@Test func trackNumberFromABareOneDigitFrame() {
    #expect(MetadataMapping.trackNumber(fromID3TextFrame: Data("7".utf8))?.number == 7)
}

// MARK: - Lyrics

private func twoDigits(_ value: Int) -> String {
    value < 10 ? "0\(value)" : "\(value)"
}

/// Lyric text that cannot form a timestamp or a word tag by itself.
private let lyricFragments = FuzzText.singleLineFragments.filter { fragment in
    !fragment.unicodeScalars.contains { "[]<>".unicodeScalars.contains($0) }
}

@Test(arguments: FuzzText.seeds(200))
func lrcKeepsEveryTimestampWithItsText(seed: UInt64) {
    var rng = SeededGenerator(seed: seed)
    var lines: [String] = []
    var expected: [(time: Double, text: String)] = []
    for _ in 0..<Int.random(in: 1...8, using: &rng) {
        if Int.random(in: 0...3, using: &rng) == 0 {
            lines.append("[ar:" + word(using: &rng) + "]")
            continue
        }
        let text = FuzzText.string(using: &rng, from: lyricFragments).trimmingCharacters(in: .whitespaces)
        var stamps = ""
        for _ in 0..<Int.random(in: 1...3, using: &rng) {
            let minutes = Int.random(in: 0...99, using: &rng)
            let seconds = Int.random(in: 0...59, using: &rng)
            let hundredths = Int.random(in: 0...99, using: &rng)
            stamps += "[\(twoDigits(minutes)):\(twoDigits(seconds)).\(twoDigits(hundredths))]"
            expected.append((Double(minutes * 60 + seconds) + Double(hundredths) / 100, text))
        }
        lines.append(stamps + text)
    }
    let ending = ["\n", "\r\n", "\r"].randomElement(using: &rng)!
    let lyrics = LyricLine.parseLRC(from: lines.joined(separator: ending))

    let ordered = expected.enumerated()
        .sorted { ($0.element.time, $0.offset) < ($1.element.time, $1.offset) }
        .map(\.element)
    #expect(lyrics.map(\.startTime) == ordered.map(\.time))
    #expect(lyrics.map(\.text) == ordered.map(\.text))
    for line in lyrics.dropLast() {
        #expect((line.endTime ?? -1) >= line.startTime)
    }
    #expect(lyrics.last?.endTime == nil)
}

/// `[mm:ss:xx]` — hundredths after a colon — is a common LRC variant; without
/// support the whole file falls through to plain text with the stamps shown.
@Test func lrcAcceptsColonSeparatedHundredths() {
    let lyrics = LyricLine.parseLRC(from: "[00:12:50]First\n[00:15:00]Second")

    #expect(lyrics.map(\.startTime) == [12.5, 15])
    #expect(lyrics.map(\.text) == ["First", "Second"])
}

/// Untimed lyrics (embedded USLT, online plain text) split on every line
/// ending: iTunes writes CR, Windows tools CRLF.
@Test(arguments: FuzzText.seeds(200))
func plainLyricsSplitOnEveryLineEnding(seed: UInt64) {
    var rng = SeededGenerator(seed: seed)
    let lines = (0..<Int.random(in: 1...6, using: &rng)).map { _ in
        "x" + FuzzText.string(using: &rng, from: lyricFragments)
    }
    let ending = ["\n", "\r\n", "\r"].randomElement(using: &rng)!
    let parsed = LyricsLoader.parseAnyLyrics(lines.joined(separator: ending))

    #expect(parsed.map(\.text) == lines.map { $0.trimmingCharacters(in: .whitespaces) })
}

// MARK: - Artist names

@Test(arguments: FuzzText.seeds(200))
func artistParseReturnsCleanDistinctNames(seed: UInt64) {
    var rng = SeededGenerator(seed: seed)
    let tag = FuzzText.string(using: &rng)
    let names = ArtistParser.isolatedLibraryArtists.withValue([:]) {
        ArtistParser.parse(tag, role: nil)
    }

    #expect(!names.isEmpty)
    for name in names {
        #expect(!isBlank(name), "\(tag.debugDescription) → \(names)")
        #expect(name == name.trimmingCharacters(in: .whitespacesAndNewlines), "\(tag.debugDescription) → \(names)")
    }
    #expect(Set(names.map(ArtistParser.normalizeArtistName)).count == names.count, "\(tag.debugDescription) → \(names)")
}

// MARK: - Year

@Test(arguments: FuzzText.seeds(200))
func yearIsAFourDigitYearTakenFromTheInput(seed: UInt64) {
    var rng = SeededGenerator(seed: seed)
    let text = FuzzText.string(using: &rng, from: FuzzText.fragments + ["2024-05-01", "20123", "1899"])
    guard let year = MetadataMapping.year(fromDateString: text) else { return }

    #expect(year.count == 4, "\(text.debugDescription)")
    #expect(text.contains(year), "\(text.debugDescription)")
    #expect((1900...2099).contains(Int(year) ?? 0), "\(text.debugDescription)")
}
