import Foundation
import GRDB
@testable import Petrichor

/// A throwaway file-backed `DatabasePool` for tests, created inside the
/// caller's temp directory (the test's own `defer` removes that directory).
/// A true in-memory pool is not available: `DatabasePool` hard-requires WAL
/// (no journal-mode override in this GRDB version), and SQLite refuses WAL on
/// shared-cache in-memory databases. A temp file also exercises the exact
/// WAL path production uses, minus Application Support.
func makeTestDatabasePool(in directory: URL) throws -> DatabasePool {
    try DatabasePool(
        path: directory.appendingPathComponent("test-\(UUID().uuidString).db").path
    )
}

/// Deterministic `MetadataReader` for scan seam tests, installed via
/// `MetadataEngine.readerOverride`. The scanner pipeline is exercised without
/// the simulator's media service, which is shared and intermittently fails
/// `AVAsset.load(.metadata)` under parallel test load. Artist and title are
/// parsed from the filename (`Artist - Title.mp3`); `overrides` supplies
/// values a filename cannot carry (album), keyed by absolute file path.
final class TestMetadataReader: MetadataReader, @unchecked Sendable {
    static let shared = TestMetadataReader()

    private let lock = NSLock()
    private var overrides: [String: (artist: String?, title: String?, album: String?)] = [:]

    func setOverride(
        for url: URL,
        artist: String? = nil,
        title: String? = nil,
        album: String? = nil
    ) {
        lock.lock()
        overrides[url.path] = (artist, title, album)
        lock.unlock()
    }

    func reset() {
        lock.lock()
        overrides.removeAll()
        lock.unlock()
    }

    func extractMetadata(
        from url: URL,
        externalArtwork: Data?,
        artworkCache: ArtworkCompressionCache?
    ) async -> TrackMetadata {
        var metadata = TrackMetadata(url: url)
        let base = url.deletingPathExtension().lastPathComponent

        let override = lock.withLock { overrides[url.path] }

        if let override {
            metadata.artist = override.artist
            metadata.title = override.title
            metadata.album = override.album
        } else {
            let parts = base.components(separatedBy: " - ")
            if parts.count >= 2 {
                metadata.artist = parts[0]
                metadata.title = parts.dropFirst().joined(separator: " - ")
            } else {
                metadata.title = base
            }
        }

        metadata.duration = 1
        return metadata
    }
}

/// Writes a short silent WAV. Generated rather than checked in so tests carry
/// no binary fixture, and silent because only the transport matters. A queue
/// entry pointing at a *missing* file is not a valid fixture: AVPlayerItem
/// fails asynchronously and `handleItemFailure` drops it from the queue,
/// which races with the bookkeeping assertions.
func makeSilentWAV(seconds: Int = 2) throws -> URL {
    let sampleRate = 44_100
    let channels = 1
    let bitsPerSample = 16
    let byteRate = sampleRate * channels * bitsPerSample / 8
    let blockAlign = channels * bitsPerSample / 8
    let dataSize = byteRate * seconds

    var data = Data()
    func append(_ string: String) { data.append(contentsOf: Array(string.utf8)) }
    func append(u32 value: Int) { data.append(contentsOf: withUnsafeBytes(of: UInt32(value).littleEndian, Array.init)) }
    func append(u16 value: Int) { data.append(contentsOf: withUnsafeBytes(of: UInt16(value).littleEndian, Array.init)) }

    append("RIFF")
    append(u32: 36 + dataSize)
    append("WAVE")
    append("fmt ")
    append(u32: 16)
    append(u16: 1)
    append(u16: channels)
    append(u32: sampleRate)
    append(u32: byteRate)
    append(u16: blockAlign)
    append(u16: bitsPerSample)
    append("data")
    append(u32: dataSize)
    data.append(Data(count: dataSize))

    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("\(UUID().uuidString).wav")
    try data.write(to: url)
    return url
}

// MARK: - Property-test inputs

/// SplitMix64: a deterministic `RandomNumberGenerator` for property tests.
/// Each test case takes a seed as its argument, so a failure names the seed
/// that reproduces it, and every run walks the same inputs.
struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var mixed = state
        mixed = (mixed ^ (mixed >> 30)) &* 0xBF58_476D_1CE4_E5B9
        mixed = (mixed ^ (mixed >> 27)) &* 0x94D0_49BB_1331_11EB
        return mixed ^ (mixed >> 31)
    }
}

/// Malformed text for parser property tests: the pieces that broken tags,
/// hand-edited playlists and mis-decoded files are actually made of —
/// separators, every Unicode line break, BOM, NUL, combining marks, mixed
/// scripts, percent escapes, timestamps.
enum FuzzText {
    static let lineBreaks = ["\n", "\r", "\r\n", "\u{0085}", "\u{2028}", "\u{2029}"]

    static let fragments: [String] = [
        "a", "Z", "q", "0", "7", "42", "1999",
        " ", "  ", "\t", "\u{00A0}", "\u{3000}",
        " - ", "-", ",", ";", " , ", " ; ", "&", "/", "\\", "#", ".", "..", "./", "../",
        "%", "%20", "%2", "file://", "(", ")", "[", "]", "<", ">", ":",
        "\u{FEFF}", "\u{0000}", "\u{200B}", "e\u{0301}", "İ", "ß", "Ω",
        "Кино", "ёлка", "Сплин", "宇多田", "🎸", "👩‍👩‍👧",
        "[00:12.50]", "<00:01.00>", "feat. ", " x ", " vs ", " & "
    ] + lineBreaks

    /// Seeds for `@Test(arguments:)`: one test case per seed.
    static func seeds(_ count: Int) -> [UInt64] {
        (0..<UInt64(count)).map { $0 &* 0x2545_F491_4F6C_DD1D &+ 1 }
    }

    /// 0...`maxFragments` fragments from `pool`, concatenated.
    static func string(
        using rng: inout SeededGenerator,
        from pool: [String] = fragments,
        maxFragments: Int = 8
    ) -> String {
        (0..<Int.random(in: 0...maxFragments, using: &rng))
            .map { _ in pool.randomElement(using: &rng)! }
            .joined()
    }

    /// Fragments without CR or LF: what one physical line of a text file can
    /// hold. The other Unicode line breaks stay in — they are ordinary
    /// characters to a file that separates lines with CR/LF.
    static let singleLineFragments = fragments.filter { !containsCROrLF($0) }

    /// Fragments a filename can carry: no path separator, no NUL, no line break.
    static let filenameFragments = fragments.filter { fragment in
        !fragment.unicodeScalars.contains { $0 == "/" || $0 == "\u{0000}" || isLineBreak($0) }
    }

    /// Scalar-level, so a `"\r\n"` grapheme counts: `Character` comparison
    /// would treat it as one character equal to neither CR nor LF.
    static func containsCROrLF(_ string: String) -> Bool {
        string.unicodeScalars.contains { $0 == "\n" || $0 == "\r" }
    }

    static func isLineBreak(_ scalar: Unicode.Scalar) -> Bool {
        let breaks: [Unicode.Scalar] = ["\n", "\r", "\u{0085}", "\u{2028}", "\u{2029}"]
        return breaks.contains(scalar)
    }
}

/// UTF-16 code units of `text`, without a byte order mark.
func utf16Bytes(_ text: String, littleEndian: Bool) -> Data {
    var data = Data()
    for unit in text.utf16 {
        let ordered = littleEndian ? unit.littleEndian : unit.bigEndian
        withUnsafeBytes(of: ordered) { data.append(contentsOf: $0) }
    }
    return data
}
