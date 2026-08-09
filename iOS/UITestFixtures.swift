//
// UITestFixtures (iOS)
//
// DEBUG-only audio fixture generation. `makeSilentMP3` used to live in the
// unit-test target; it moved into the app target so the app can seed its own
// `Documents/Music` on launch (`--uitest-seed-fixtures`) while the seam tests
// keep calling it through `@testable import Petrichor` — one copy, no
// duplication. No binary fixtures are checked into the repository.
//

#if DEBUG
import Foundation

/// Writes a short silent MP3 with optional ID3v2.3 tags. The library scan
/// seam only imports what `AudioFormat.supportedExtensions` claims (mp3 on
/// iOS), so the folder-scan test needs real `.mp3` files, not WAVs. The audio
/// is a stream of well-formed MPEG-1 Layer III silence frames (128 kbps,
/// 44.1 kHz); the tags carry artist/title/album so the scan's metadata path
/// and artist/album grouping are exercised, not just the filename fallback.
func makeSilentMP3(
    artist: String? = nil,
    title: String? = nil,
    album: String? = nil,
    seconds: Int = 1
) throws -> URL {
    var data = Data()

    // ID3v2.3 header, then one frame per non-nil tag. Text is latin-1 with
    // the 0x00 encoding byte; ASCII fixture values make that safe.
    let tags = [
        ("TIT2", title),
        ("TPE1", artist),
        ("TALB", album)
    ].compactMap { id, value -> Data? in
        guard let value, let bytes = value.data(using: .isoLatin1) else { return nil }
        var frame = Data()
        frame.append(contentsOf: Array(id.utf8))
        frame.append(contentsOf: withUnsafeBytes(of: UInt32(bytes.count + 1).bigEndian, Array.init))
        frame.append(contentsOf: [0, 0]) // flags
        frame.append(0) // text encoding: latin-1
        frame.append(bytes)
        return frame
    }
    if !tags.isEmpty {
        let tagSize = tags.reduce(0) { $0 + $1.count }
        data.append(contentsOf: Array("ID3".utf8))
        data.append(contentsOf: [3, 0, 0]) // version 2.3, no flags
        // Syncsafe size: only the low 7 bits of each byte count.
        data.append(UInt8((tagSize >> 21) & 0x7F))
        data.append(UInt8((tagSize >> 14) & 0x7F))
        data.append(UInt8((tagSize >> 7) & 0x7F))
        data.append(UInt8(tagSize & 0x7F))
        for frame in tags { data.append(frame) }
    }

    // MPEG-1 Layer III frames: header 0xFF 0xFB 0x90 0x00 (128 kbps,
    // 44.1 kHz, no padding), frame length 144 * 128000 / 44100 = 417 bytes,
    // main data zeroed. One frame is 1152 samples ≈ 26 ms.
    let frameLength = 417
    let frameCount = Int(ceil(Double(seconds) * 44_100 / 1152))
    let frameHeader: [UInt8] = [0xFF, 0xFB, 0x90, 0x00]
    for _ in 0..<frameCount {
        data.append(contentsOf: frameHeader)
        data.append(Data(count: frameLength - frameHeader.count))
    }

    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("\(UUID().uuidString).mp3")
    try data.write(to: url)
    return url
}

// MARK: - UI-test seeding

/// Launch argument that makes the DEBUG app seed the smoke-test fixtures into
/// `Documents/Music` before the library reconciliation starts. The UI test
/// passes it explicitly; without it nothing is seeded, and the whole file is
/// DEBUG-only, so the seeding never reaches a Release build.
let uitestSeedFixturesLaunchArgument = "--uitest-seed-fixtures"

/// Fixture names `PlaybackSmokeUITests` expects in `Documents/Music`, as
/// `<name>.mp3`.
let uitestFixtureNames = ["Alpha One", "Beta Two", "Gamma Three"]

/// Seeds the UI-test fixtures into `Documents/Music`, idempotently: an
/// existing file with the same name is left untouched, so repeated launches
/// (and repeated test runs without an app reinstall) do not rewrite anything.
/// Called before `AppCoordinator` is created, so the fixtures are on disk
/// before the launch reconciliation scans the library.
func seedUITestFixturesIfNeeded() throws {
    let fileManager = FileManager.default
    let musicDirectory = LibraryPathStore.libraryRoot
        .appendingPathComponent("Music", isDirectory: true)
    try fileManager.createDirectory(at: musicDirectory, withIntermediateDirectories: true)

    for name in uitestFixtureNames {
        let destination = musicDirectory
            .appendingPathComponent(name)
            .appendingPathExtension("mp3")
        guard !fileManager.fileExists(atPath: destination.path) else { continue }
        // Tags make the metadata path deterministic; the filename fallback
        // would give the same title, but tags remove the ambiguity.
        let generated = try makeSilentMP3(artist: name, title: name)
        try fileManager.moveItem(at: generated, to: destination)
    }
}
#endif
