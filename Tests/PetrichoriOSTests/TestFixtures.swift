import Foundation
import GRDB

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
