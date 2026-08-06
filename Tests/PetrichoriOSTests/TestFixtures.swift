import Foundation

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
