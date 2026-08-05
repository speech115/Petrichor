import AVFoundation
import Foundation
import Testing
@testable import Petrichor

// The only test that proves audio actually starts: everything else exercises
// queue bookkeeping, which stays green even when nothing ever reaches the
// speaker. Playback touches the process-wide `AVAudioSession`, so these run
// serially and apart from the queue tests.
@Suite(.serialized)
struct PlaybackStartTests {
    /// Writes a short silent WAV. Generated rather than checked in so the test
    /// carries no binary fixture, and silent because only the transport matters.
    private func makeSilentWAV(seconds: Int = 2) throws -> URL {
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

    /// Polls instead of sleeping a fixed amount: the player reaches `.playing`
    /// only after the item loads, and that timing is not ours to predict.
    private func waitForPlaying(_ backend: AVQueuePlayerBackend, timeout: Duration = .seconds(10)) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if backend.state == .playing { return true }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return false
    }

    @Test func startingAQueueReachesThePlayingState() async throws {
        let url = try makeSilentWAV()
        defer { try? FileManager.default.removeItem(at: url) }

        let backend = AVQueuePlayerBackend()
        backend.setQueue(
            [QueueEntry(entryId: AudioEntryId(id: "silent"), url: url)],
            startingAt: 0,
            startPaused: false
        )

        #expect(await waitForPlaying(backend), "плеер не дошёл до состояния playing")
    }

    @Test func resumeAfterAPausedStartAlsoReachesThePlayingState() async throws {
        let url = try makeSilentWAV()
        defer { try? FileManager.default.removeItem(at: url) }

        let backend = AVQueuePlayerBackend()
        backend.setQueue(
            [QueueEntry(entryId: AudioEntryId(id: "silent"), url: url)],
            startingAt: 0,
            startPaused: true
        )
        #expect(backend.state == .paused)

        backend.resume()

        #expect(await waitForPlaying(backend), "resume не запустил воспроизведение")
    }
}
