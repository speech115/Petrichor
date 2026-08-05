//
// AVAudioPlaybackBackend
//
// iOS `PlaybackBackend` built on AVAudioPlayer. MP3-only, single-player with an
// in-memory queue mirror, matching the `PlaybackBackend` contract the rest of
// the app already consumes (PlaybackEngine facade).
//

import AVFoundation
import Foundation
import MediaPlayer

final class AVAudioPlaybackBackend: NSObject, PlaybackBackend, AVAudioPlayerDelegate {
    // MARK: - Backend Surface

    weak var backendDelegate: PlaybackBackendDelegate?

    var volume: Float {
        get { player?.volume ?? 0.7 }
        set { player?.volume = newValue }
    }

    var state: AudioPlayerState = .stopped {
        didSet {
            guard oldValue != state else { return }
            backendDelegate?.backendStateChanged(with: state, previous: oldValue)
        }
    }

    var currentPlaybackProgress: Double {
        player?.currentTime ?? 0
    }

    var duration: Double {
        player?.duration ?? 0
    }

    private(set) var queue: [AudioEntryId] = []

    func queueIndex(of entryId: AudioEntryId) -> Int? {
        queue.firstIndex { $0.id == entryId.id }
    }

    var hasQueuedSuccessor: Bool {
        currentIndex.map { $0 + 1 < queue.count } ?? false
    }

    // MARK: - Private Properties

    private var player: AVAudioPlayer?
    private var currentEntryId: AudioEntryId?
    private var currentIndex: Int?
    private var entries: [QueueEntry] = []

    // Effects state (no-op on AVAudioPlayer; kept so settings round-trip).
    private var eqEnabled = false
    private var currentEQGains = [Float](repeating: 0, count: 10)
    private var stereoWideningEnabled = false
    private var userPreampGain: Float = 0

    private var nowPlayingMetadata: NowPlayingMetadata?
    private var nowPlayingTimer: Timer?

    // MARK: - Playback Control

    func setQueue(_ entries: [QueueEntry], startingAt index: Int, startPaused: Bool) {
        self.entries = entries
        self.queue = entries.map(\.entryId)

        guard !entries.isEmpty, index >= 0, index < entries.count else {
            currentIndex = nil
            currentEntryId = nil
            return
        }

        currentIndex = index
        if startPaused {
            loadEntry(at: index)
            player?.pause()
            state = .paused
        } else {
            playEntry(at: index)
        }
    }

    func insert(_ entry: QueueEntry, at index: Int) {
        guard index >= 0, index <= entries.count else { return }
        entries.insert(entry, at: index)
        queue.insert(entry.entryId, at: index)
        if let currentIndex, index <= currentIndex {
            self.currentIndex = currentIndex + 1
        }
    }

    func append(_ entry: QueueEntry) {
        entries.append(entry)
        queue.append(entry.entryId)
    }

    func insertNext(_ entry: QueueEntry) {
        guard let currentIndex else {
            append(entry)
            return
        }
        insert(entry, at: currentIndex + 1)
    }

    func move(from: Int, to: Int) {
        guard from >= 0, from < entries.count, to >= 0, to < entries.count else { return }
        let entry = entries.remove(at: from)
        entries.insert(entry, at: to)
        queue.remove(at: from)
        queue.insert(entry.entryId, at: to)
        if let currentIndex {
            self.currentIndex = from == currentIndex ? to : (from < currentIndex && to >= currentIndex ? currentIndex - 1 : currentIndex)
        }
    }

    func removeQueueEntry(at index: Int) {
        guard index >= 0, index < entries.count else { return }
        entries.remove(at: index)
        queue.remove(at: index)
        if let currentIndex {
            self.currentIndex = index < currentIndex ? currentIndex - 1 : currentIndex
        }
    }

    func removeQueueEntry(id: AudioEntryId) {
        if let index = queueIndex(of: id) {
            removeQueueEntry(at: index)
        }
    }

    func clearQueue() {
        entries = []
        queue = []
        currentIndex = nil
        currentEntryId = nil
        player?.stop()
        player = nil
        state = .stopped
    }

    func playQueueEntry(at index: Int, startPaused: Bool) {
        guard index >= 0, index < entries.count else { return }
        currentIndex = index
        if startPaused {
            loadEntry(at: index)
            player?.pause()
            state = .paused
        } else {
            playEntry(at: index)
        }
    }

    func shuffleQueue() {
        guard let currentIndex, currentIndex + 1 < entries.count else { return }
        var tail = Array(entries[(currentIndex + 1)...])
        tail.shuffle()
        entries = Array(entries[0...currentIndex]) + tail
        queue = entries.map(\.entryId)
    }

    func pause() {
        player?.pause()
        if currentEntryId != nil {
            state = .paused
        }
    }

    func resume() {
        guard let player else { return }
        if !player.isPlaying {
            player.play()
        }
        state = .playing
    }

    func stop() {
        player?.stop()
        player = nil
        currentEntryId = nil
        currentIndex = nil
        state = .stopped
        updateNowPlaying(nil)
    }

    func togglePlayPause() {
        if player?.isPlaying == true {
            pause()
        } else {
            resume()
        }
    }

    @discardableResult
    func seek(to time: Double) -> Bool {
        guard let player, time >= 0, time <= player.duration else { return false }
        player.currentTime = time
        return true
    }

    @discardableResult
    func seekForward(_ seconds: Double) -> Bool {
        guard let player else { return false }
        return seek(to: player.currentTime + seconds)
    }

    @discardableResult
    func seekBackward(_ seconds: Double) -> Bool {
        guard let player else { return false }
        return seek(to: player.currentTime - seconds)
    }

    // MARK: - Now Playing

    func setNowPlayingMetadata(_ metadata: NowPlayingMetadata?) {
        nowPlayingMetadata = metadata
        publishNowPlayingInfo()
    }

    private func publishNowPlayingInfo() {
        guard let metadata = nowPlayingMetadata, let player else {
            updateNowPlaying(nil)
            return
        }

        var info: [String: Any] = [
            MPMediaItemPropertyTitle: metadata.title ?? "",
            MPMediaItemPropertyArtist: metadata.artist ?? "",
            MPMediaItemPropertyAlbumTitle: metadata.albumTitle ?? "",
            MPMediaItemPropertyPlaybackDuration: player.duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: player.currentTime,
            MPNowPlayingInfoPropertyPlaybackRate: player.isPlaying ? 1.0 : 0.0
        ]

        if let artworkData = metadata.artworkData {
            let artwork = MPMediaItemArtwork(boundsSize: CGSize(width: 512, height: 512)) { _ in
                PlatformImage(data: artworkData) ?? PlatformImage()
            }
            info[MPMediaItemPropertyArtwork] = artwork
        }

        updateNowPlaying(info)
    }

    private func updateNowPlaying(_ info: [String: Any]?) {
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    // MARK: - Audio Effects (no-op on AVAudioPlayer)

    func setStereoWidening(enabled: Bool) { stereoWideningEnabled = enabled }
    func isStereoWideningEnabled() -> Bool { stereoWideningEnabled }

    func setEQEnabled(_ enabled: Bool) { eqEnabled = enabled }
    func isEQEnabled() -> Bool { eqEnabled }

    func applyEQPreset(_ preset: EqualizerPreset) {
        currentEQGains = preset.gains
    }

    func applyEQCustom(gains: [Float]) {
        guard gains.count == 10 else { return }
        currentEQGains = gains
    }

    func setPreamp(_ gain: Float) {
        userPreampGain = max(-12, min(12, gain))
    }

    func getPreamp() -> Float { userPreampGain }

    // MARK: - Internal Loading

    private func loadEntry(at index: Int) {
        guard index < entries.count else { return }
        let entry = entries[index]
        let url = entry.url

        let loadedPlayer = (try? AVAudioPlayer(contentsOf: url)) ?? (try? AVAudioPlayer(data: Data(contentsOf: url)))
        guard let loadedPlayer else {
            Logger.warning("AVAudioPlayer failed to load \(url.lastPathComponent)")
            backendDelegate?.backendDidSkipQueueEntry(entryId: entry.entryId)
            return
        }

        loadedPlayer.delegate = self
        loadedPlayer.volume = volume
        loadedPlayer.prepareToPlay()
        player = loadedPlayer
        currentEntryId = entry.entryId
    }

    private func playEntry(at index: Int) {
        loadEntry(at: index)
        guard let player else {
            state = .stopped
            return
        }
        player.play()
        state = .playing
        if let currentEntryId {
            backendDelegate?.backendDidStartPlaying(with: currentEntryId)
        }
        startNowPlayingTimer()
    }

    private func advanceToNext() {
        guard let currentIndex, currentIndex + 1 < entries.count else { return }
        let finishedId = currentEntryId
        let finishedProgress = player?.currentTime ?? 0
        let finishedDuration = player?.duration ?? 0

        let nextIndex = currentIndex + 1
        self.currentIndex = nextIndex
        loadEntry(at: nextIndex)
        player?.play()
        state = .playing

        if let finishedId {
            backendDelegate?.backendDidFinishPlaying(
                entryId: finishedId,
                stopReason: .eof,
                progress: finishedProgress,
                duration: finishedDuration
            )
        }
        if let currentEntryId {
            backendDelegate?.backendDidStartPlaying(with: currentEntryId)
        }
        publishNowPlayingInfo()
    }

    // MARK: - AVAudioPlayerDelegate

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        guard let finishedId = currentEntryId else { return }
        let finishedProgress = player.currentTime
        let finishedDuration = player.duration

        if hasQueuedSuccessor {
            advanceToNext()
        } else {
            currentIndex = nil
            currentEntryId = nil
            state = .stopped
            backendDelegate?.backendDidFinishPlaying(
                entryId: finishedId,
                stopReason: .eof,
                progress: finishedProgress,
                duration: finishedDuration
            )
            updateNowPlaying(nil)
        }
    }

    // MARK: - Now Playing Timer

    private func startNowPlayingTimer() {
        nowPlayingTimer?.invalidate()
        let timer = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.publishNowPlayingInfo()
        }
        RunLoop.main.add(timer, forMode: .common)
        nowPlayingTimer = timer
    }
}
