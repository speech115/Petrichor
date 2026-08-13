//
// CrescendoPlaybackBackend
//
// The Crescendo-backed `PlaybackBackend`. It wraps `CrescendoPlayer` and reports
// events to the `PlaybackEngine` facade. This is the only playback file that
// imports Crescendo.
//
// Concurrency: `PlaybackBackend` is `@MainActor`, and so is this backend by
// conformance; `CrescendoPlayer` and `CrescendoPlayerDelegate` are `@MainActor`
// too, so isolation matches directly — no leftover hop.
//

import Crescendo
import Foundation

final class CrescendoPlaybackBackend: PlaybackBackend, CrescendoPlayerDelegate {
    // MARK: - Backend Surface

    weak var backendDelegate: PlaybackBackendDelegate?

    var volume: Float {
        get { player.volume }
        set { player.volume = newValue }
    }

    var state: AudioPlayerState {
        Self.mapState(player.state)
    }

    var currentPlaybackProgress: Double {
        player.currentTime
    }

    var duration: Double {
        player.duration
    }

    var queue: [AudioEntryId] {
        player.queue.map { AudioEntryId(id: $0.id.id) }
    }

    // Answered from the player's queue directly: building the mapped array just to
    // find one index (or read a count) allocates the whole thing per call, and these
    // run on every queue edit and every track boundary.
    func queueIndex(of entryId: AudioEntryId) -> Int? {
        player.queue.firstIndex { $0.id.id == entryId.id }
    }

    var hasQueuedSuccessor: Bool {
        player.currentIndex.map { $0 + 1 < player.queue.count } ?? false
    }

    // MARK: - Private Properties

    private let player: CrescendoPlayer

    // Effects state. Crescendo applies all effects as property sets, so there is
    // no graph to build; we keep the user-facing state here and push it down.
    private var eqEnabled = false
    private var currentEQGains = [Float](repeating: 0, count: 10)
    private var stereoWideningEnabled = false
    private var userPreampGain: Float = 0

    private static let flatEQGains = [Float](repeating: 0, count: 10)

    // MARK: - Initialization

    init() {
        player = CrescendoPlayer()
        player.delegate = self
        // The engine owns the info tile: it anchors elapsed/duration/rate off the
        // real playback clock, which the app can only approximate.
        player.nowPlayingInfoEnabled = true
        // Commands stay app-owned: Crescendo's next/previous walk its queue in raw
        // order, ignoring Petrichor's repeat, shuffle and injected lookahead.
        player.remoteCommandsEnabled = false
        installLogBridge()
    }

    // MARK: - Playback Control

    // MARK: - Queue

    func setQueue(_ entries: [QueueEntry], startingAt index: Int, startPaused: Bool) {
        let mapped = entries.map { CrescendoQueueEntry(url: $0.url, entryId: CrescendoEntryId(id: $0.entryId.id)) }
        player.setQueue(mapped, startingAt: index, startPaused: startPaused)
    }

    func insert(_ entry: QueueEntry, at index: Int) {
        player.insert(url: entry.url, entryId: CrescendoEntryId(id: entry.entryId.id), at: index)
    }

    func append(_ entry: QueueEntry) {
        player.append(url: entry.url, entryId: CrescendoEntryId(id: entry.entryId.id))
    }

    func insertNext(_ entry: QueueEntry) {
        player.insertNext(url: entry.url, entryId: CrescendoEntryId(id: entry.entryId.id))
    }

    func move(from: Int, to: Int) {
        player.move(from: from, to: to)
    }

    func removeQueueEntry(at index: Int) {
        _ = player.remove(at: index)
    }

    func removeQueueEntry(id: AudioEntryId) {
        _ = player.remove(entryId: CrescendoEntryId(id: id.id))
    }

    func clearQueue() {
        player.clearQueue()
    }

    func playQueueEntry(at index: Int, startPaused: Bool) {
        player.play(at: index, startPaused: startPaused)
    }

    func shuffleQueue() {
        player.shuffle()
    }

    // MARK: - Now Playing

    func setNowPlayingMetadata(_ metadata: NowPlayingMetadata?) {
        let mapped = metadata.map {
            CrescendoNowPlayingMetadata(
                title: $0.title,
                artist: $0.artist,
                albumTitle: $0.albumTitle,
                albumArtist: $0.albumArtist,
                genre: $0.genre,
                artworkData: $0.artworkData
            )
        }
        player.setNowPlayingMetadata(mapped)
    }

    func pause() { player.pause() }
    func resume() { player.resume() }
    func stop() { player.stop() }
    func togglePlayPause() { player.togglePlayPause() }

    @discardableResult
    func seek(to time: Double) -> Bool {
        guard time >= 0 else { return false }
        return player.seek(to: time)
    }

    @discardableResult
    func seekForward(_ seconds: Double) -> Bool {
        player.seekForward(seconds)
    }

    @discardableResult
    func seekBackward(_ seconds: Double) -> Bool {
        player.seekBackward(seconds)
    }

    // MARK: - Audio Effects

    func setStereoWidening(enabled: Bool) {
        stereoWideningEnabled = enabled
        // Crescendo uses a mid/side width (1.0 neutral); SFB used a Haas delay, so
        // the two engines sound slightly different here.
        player.stereoWidth = enabled ? 2.0 : 1.0
    }

    func isStereoWideningEnabled() -> Bool { stereoWideningEnabled }

    func setEQEnabled(_ enabled: Bool) {
        eqEnabled = enabled
        pushEQGains()
        pushEffectivePreamp()
    }

    func isEQEnabled() -> Bool { eqEnabled }

    func applyEQPreset(_ preset: EqualizerPreset) {
        currentEQGains = preset.gains
        pushEQGains()
        pushEffectivePreamp()
    }

    func applyEQCustom(gains: [Float]) {
        guard gains.count == 10 else {
            Logger.warning("Equalizer gains array must contain exactly 10 values, got \(gains.count)")
            return
        }
        currentEQGains = gains
        pushEQGains()
        pushEffectivePreamp()
    }

    func setPreamp(_ gain: Float) {
        userPreampGain = max(-12, min(12, gain))
        pushEffectivePreamp()
    }

    func getPreamp() -> Float { userPreampGain }

    // Disabled EQ is expressed as flat (all-zero) gains rather than Crescendo's
    // `effectsEnabled`, which would bypass preamp and width too.
    private func pushEQGains() {
        let gains = eqEnabled ? currentEQGains : Self.flatEQGains
        player.equalizerGains = gains
    }

    private func pushEffectivePreamp() {
        let compensation = EqualizerHeadroomCompensation.gainOffset(
            eqEnabled: eqEnabled,
            gains: currentEQGains
        )
        player.preampGain = userPreampGain + compensation
    }

    // MARK: - Logging bridge

    @MainActor
    private func installLogBridge() {
        player.logHandler = { record in
            let message = "[Crescendo/\(record.category.rawValue)] \(record.message)"
            switch record.level {
            case .warning: Logger.warning(message)
            case .error: Logger.error(message)
            case .fault: Logger.critical(message)
            case .debug, .info: Logger.info(message)
            @unknown default: Logger.info(message)
            }
        }
        player.logLevel = AppInfo.isDebugBuild ? .info : .warning
    }

    // MARK: - CrescendoPlayerDelegate

    func playerDidStartPlaying(_ player: CrescendoPlayer, entryId: CrescendoEntryId) {
        backendDelegate?.backendDidStartPlaying(with: AudioEntryId(id: entryId.id))
    }

    func playerDidChangeState(
        _ player: CrescendoPlayer,
        from oldState: CrescendoPlayerState,
        to newState: CrescendoPlayerState
    ) {
        backendDelegate?.backendStateChanged(with: Self.mapState(newState), previous: Self.mapState(oldState))
    }

    func playerDidFinishPlaying(
        _ player: CrescendoPlayer,
        entryId: CrescendoEntryId,
        reason: CrescendoStopReason,
        progress: TimeInterval,
        duration: TimeInterval
    ) {
        backendDelegate?.backendDidFinishPlaying(
            entryId: AudioEntryId(id: entryId.id),
            stopReason: Self.mapStopReason(reason),
            progress: progress,
            duration: duration
        )
    }

    func playerDidEncounterError(_ player: CrescendoPlayer, error: CrescendoError, entryId: CrescendoEntryId?) {
        backendDelegate?.backendUnexpectedError(error: Self.mapError(error))
    }

    func playerDidFinishBuffering(_ player: CrescendoPlayer, entryId: CrescendoEntryId) {
        backendDelegate?.backendDidFinishBuffering(with: AudioEntryId(id: entryId.id))
    }

    func playerDidSkipQueueEntry(
        _ player: CrescendoPlayer,
        entryId: CrescendoEntryId,
        url: URL,
        reason: CrescendoError
    ) {
        Logger.warning("Crescendo skipped \(url.lastPathComponent): \(reason.localizedDescription)")
        backendDelegate?.backendDidSkipQueueEntry(entryId: AudioEntryId(id: entryId.id))
    }

    // MARK: - Mapping

    private static func mapState(_ state: CrescendoPlayerState) -> AudioPlayerState {
        switch state {
        // `.buffering` is the stream-connect window; local files never enter it.
        case .idle, .buffering, .ready: return .ready
        case .playing: return .playing
        case .paused: return .paused
        case .stopped: return .stopped
        @unknown default: return .ready
        }
    }

    private static func mapStopReason(_ reason: CrescendoStopReason) -> AudioPlayerStopReason {
        switch reason {
        case .endOfFile: return .eof
        case .userAction: return .userAction
        case .error: return .error
        // Treat an unknown future reason as a user action so it neither advances
        // the queue nor surfaces as an error.
        @unknown default: return .userAction
        }
    }

    private static func mapError(_ error: CrescendoError) -> AudioPlayerError {
        switch error {
        case .fileNotFound: return .fileNotFound
        case .unsupportedFormat: return .invalidFormat
        case .seekFailed: return .seekError
        case .invalidState: return .invalidState
        case .decoderError, .rendererError, .streamingError, .notImplemented: return .engineError(error)
        @unknown default: return .engineError(error)
        }
    }
}
