//
// AVQueuePlayerBackend
//
// iOS `PlaybackBackend` built on `AVQueuePlayer`. Gapless transitions between
// tracks are a property of the queue architecture itself, not a setting: the
// player always holds the current item plus everything queued after it, so
// advancing to the next item never re-opens a file mid-playback.
//
// The equalizer is not supported on iOS: every EQ method is a no-op.
//
// Concurrency: AVFoundation KVO notifications are not guaranteed to land on
// any particular thread. `CrescendoPlaybackBackend` (the macOS backend) always
// calls `backendDelegate` from the main thread - its callbacks arrive via a
// `@MainActor` bridge, so every `handle*` forward is already on-main by
// construction. This backend has no such bridge, so it dispatches explicitly:
// every `backendDelegate` call is routed through `runOnMain` to match that
// convention.
//
// Background playback, the lock-screen tile and remote-command buttons are
// this backend's responsibility too, wired up in `init`:
//   - `AudioSessionController` configures the `.playback` audio session and
//     reacts to interruptions/route changes.
//   - `NowPlayingPublisher` publishes the descriptive `MPNowPlayingInfoCenter`
//     tile from `setNowPlayingMetadata(_:)`.
//   - `MPRemoteCommandCenter` targets translate lock-screen/Control Center
//     button taps into calls on this backend, since `MPNowPlayingInfoCenter`
//     only *displays* the tile - it does not react to taps on its own.
//

import AVFoundation
import Foundation
import MediaPlayer

final class AVQueuePlayerBackend: NSObject, PlaybackBackend {
    weak var backendDelegate: PlaybackBackendDelegate?

    private let player = AVQueuePlayer()
    private var entries: [QueueEntry] = []
    private var currentIndex: Int = 0
    private var currentItemObservation: NSKeyValueObservation?
    private var timeControlObservation: NSKeyValueObservation?
    private var previousState: AudioPlayerState = .stopped

    private lazy var audioSession = AudioSessionController(
        onPause: { [weak self] in self?.pause() },
        onResume: { [weak self] in self?.resume() }
    )

    /// Unit tests construct `AVQueuePlayerBackend()` directly (see
    /// `QueueBackendTests`) to exercise queue bookkeeping without touching
    /// AVFoundation's playback surface. Grabbing the shared `AVAudioSession`
    /// and registering process-wide `MPRemoteCommandCenter` targets on every
    /// such instance is unwanted there - it has nothing to do with what those
    /// tests check, and it fights every other test's backend instance over
    /// the same shared session/command center. Production has exactly one
    /// backend for the app's lifetime (`PlaybackEngine`), so gating this on
    /// "not under test" costs nothing there.
    private static var isRunningUnitTests: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }

    override init() {
        super.init()
        player.actionAtItemEnd = .advance
        observeTrackChanges()
        observeStateChanges()

        if !Self.isRunningUnitTests {
            audioSession.activate()
            configureRemoteCommandCenter()
        }
    }

    deinit {
        currentItemObservation?.invalidate()
        timeControlObservation?.invalidate()
    }

    // MARK: - State

    var volume: Float {
        get { player.volume }
        set { player.volume = newValue }
    }

    var state: AudioPlayerState { mapState(player.timeControlStatus) }

    var currentPlaybackProgress: Double {
        guard duration > 0 else { return 0 }
        let seconds = player.currentTime().seconds
        return seconds.isFinite ? seconds / duration : 0
    }

    var duration: Double {
        let seconds = player.currentItem?.duration.seconds ?? 0
        return seconds.isFinite ? seconds : 0
    }

    // MARK: - Queue

    var queue: [AudioEntryId] { entries.map(\.entryId) }

    func queueIndex(of entryId: AudioEntryId) -> Int? {
        entries.firstIndex { $0.entryId == entryId }
    }

    var hasQueuedSuccessor: Bool { currentIndex + 1 < entries.count }

    func setQueue(_ newEntries: [QueueEntry], startingAt index: Int, startPaused: Bool) {
        entries = newEntries
        currentIndex = newEntries.isEmpty ? 0 : max(0, min(index, newEntries.count - 1))
        rebuildPlayerItems(startPaused: startPaused)
    }

    func insert(_ entry: QueueEntry, at index: Int) {
        let position = max(0, min(index, entries.count))
        entries.insert(entry, at: position)
        if position <= currentIndex { currentIndex += 1 }
        refillUpcomingItems()
    }

    func append(_ entry: QueueEntry) {
        entries.append(entry)
        refillUpcomingItems()
    }

    func insertNext(_ entry: QueueEntry) {
        insert(entry, at: currentIndex + 1)
    }

    func move(from source: Int, to destination: Int) {
        guard entries.indices.contains(source) else { return }
        let entry = entries.remove(at: source)
        let target = max(0, min(destination, entries.count))
        entries.insert(entry, at: target)

        if source == currentIndex {
            currentIndex = target
        } else if source < currentIndex, target >= currentIndex {
            currentIndex -= 1
        } else if source > currentIndex, target <= currentIndex {
            currentIndex += 1
        }
        refillUpcomingItems()
    }

    func removeQueueEntry(at index: Int) {
        guard entries.indices.contains(index) else { return }
        entries.remove(at: index)
        if index < currentIndex {
            currentIndex -= 1
        } else if index == currentIndex {
            currentIndex = min(currentIndex, max(0, entries.count - 1))
        }
        refillUpcomingItems()
        runOnMain { self.notifyStateIfChanged() }
    }

    func removeQueueEntry(id: AudioEntryId) {
        guard let index = queueIndex(of: id) else { return }
        removeQueueEntry(at: index)
    }

    func clearQueue() {
        entries.removeAll()
        currentIndex = 0
        player.removeAllItems()
        runOnMain { self.notifyStateIfChanged() }
    }

    func playQueueEntry(at index: Int, startPaused: Bool) {
        guard entries.indices.contains(index) else { return }
        currentIndex = index
        rebuildPlayerItems(startPaused: startPaused)
    }

    func shuffleQueue() {
        guard currentIndex + 1 < entries.count else { return }
        let head = entries[...currentIndex]
        let tail = entries[(currentIndex + 1)...].shuffled()
        entries = Array(head) + tail
        refillUpcomingItems()
    }

    // MARK: - Player items

    /// Ставит текущий трек и всё, что за ним: успешник уже загружен в плеер,
    /// поэтому переход происходит без паузы.
    private func rebuildPlayerItems(startPaused: Bool) {
        player.removeAllItems()

        guard !entries.isEmpty else {
            runOnMain { self.notifyStateIfChanged() }
            return
        }

        for entry in entries[currentIndex...] {
            player.insert(AVPlayerItem(url: entry.url), after: nil)
        }
        if startPaused {
            player.pause()
        } else {
            player.play()
        }
        runOnMain { self.notifyStateIfChanged() }
    }

    /// Пересобирает только ещё не прозвучавший хвост, не трогая играющий трек.
    private func refillUpcomingItems() {
        guard !entries.isEmpty else {
            player.removeAllItems()
            return
        }
        guard player.currentItem != nil else { return }

        for item in player.items().dropFirst() { player.remove(item) }
        for entry in entries.dropFirst(currentIndex + 1) {
            player.insert(AVPlayerItem(url: entry.url), after: nil)
        }
    }

    // MARK: - KVO

    /// AVQueuePlayer сам переходит на следующий элемент без паузы. Смена
    /// `currentItem` — единственный сигнал о том, что трек закончился и
    /// заиграл следующий, поэтому оба события делегата шлются отсюда.
    private func observeTrackChanges() {
        currentItemObservation = player.observe(\.currentItem, options: [.old, .new]) { [weak self] player, change in
            guard let self else { return }
            let old = change.oldValue ?? nil
            let new = player.currentItem
            self.runOnMain {
                self.handleCurrentItemChange(old: old, new: new)
            }
        }
    }

    private func handleCurrentItemChange(old: AVPlayerItem?, new: AVPlayerItem?) {
        if let finished = old, finished !== new {
            let finishedIndex = currentIndex
            // Read the finished item's own duration - by the time this runs,
            // `player.currentItem` already points at the next track, so the
            // shared `duration` getter would report the wrong track's length.
            let finishedSeconds = finished.duration.seconds
            let finishedDuration = finishedSeconds.isFinite ? finishedSeconds : 0

            if entries.indices.contains(finishedIndex) {
                backendDelegate?.backendDidFinishPlaying(
                    entryId: entries[finishedIndex].entryId,
                    stopReason: .eof,
                    progress: 1.0,
                    duration: finishedDuration
                )
            }
            currentIndex = min(finishedIndex + 1, max(0, entries.count - 1))
        }

        guard new != nil, entries.indices.contains(currentIndex) else { return }
        let started = entries[currentIndex].entryId
        backendDelegate?.backendDidStartPlaying(with: started)
        backendDelegate?.backendDidFinishBuffering(with: started)
    }

    /// `timeControlStatus` is the only reliable signal for play/pause
    /// transitions on `AVQueuePlayer` - there is no "did start/stop" delegate
    /// callback to hook into, unlike `AVAudioPlayerDelegate`.
    private func observeStateChanges() {
        timeControlObservation = player.observe(\.timeControlStatus, options: [.new]) { [weak self] _, _ in
            guard let self else { return }
            self.runOnMain { self.notifyStateIfChanged() }
        }
    }

    private func notifyStateIfChanged() {
        let newState = mapState(player.timeControlStatus)
        guard newState != previousState else { return }
        let previous = previousState
        previousState = newState
        backendDelegate?.backendStateChanged(with: newState, previous: previous)
    }

    /// `AVPlayer.TimeControlStatus` has no "stopped" case of its own - an empty
    /// queue is what `AudioPlayerState.stopped` means here, same as `.paused`
    /// with nothing queued in `AVAudioPlaybackBackend`.
    private func mapState(_ status: AVPlayer.TimeControlStatus) -> AudioPlayerState {
        switch status {
        case .playing:
            return .playing
        case .paused, .waitingToPlayAtSpecifiedRate:
            return entries.isEmpty ? .stopped : .paused
        @unknown default:
            return entries.isEmpty ? .stopped : .paused
        }
    }

    // MARK: - Remote command center

    /// Lock-screen and Control Center transport buttons. `MPNowPlayingInfoCenter`
    /// only renders the tile - without this, none of the buttons it shows
    /// would do anything.
    private func configureRemoteCommandCenter() {
        let center = MPRemoteCommandCenter.shared()
        let managedCommands: [MPRemoteCommand] = [
            center.playCommand,
            center.pauseCommand,
            center.togglePlayPauseCommand,
            center.nextTrackCommand,
            center.previousTrackCommand,
            center.changePlaybackPositionCommand
        ]
        // Defensive: guarantees a single backend never ends up with duplicate
        // targets on the process-wide command center.
        for command in managedCommands { command.removeTarget(nil) }

        center.playCommand.addTarget { [weak self] _ in
            guard let self else { return .commandFailed }
            self.resume()
            return .success
        }

        center.pauseCommand.addTarget { [weak self] _ in
            guard let self else { return .commandFailed }
            self.pause()
            return .success
        }

        center.togglePlayPauseCommand.addTarget { [weak self] _ in
            guard let self else { return .commandFailed }
            self.togglePlayPause()
            return .success
        }

        center.nextTrackCommand.addTarget { [weak self] _ in
            guard let self, self.hasQueuedSuccessor else { return .commandFailed }
            self.playQueueEntry(at: self.currentIndex + 1, startPaused: false)
            return .success
        }

        center.previousTrackCommand.addTarget { [weak self] _ in
            guard let self else { return .commandFailed }
            if self.currentIndex > 0 {
                self.playQueueEntry(at: self.currentIndex - 1, startPaused: false)
            } else {
                self.seek(to: 0)
            }
            return .success
        }

        center.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let self, let positionEvent = event as? MPChangePlaybackPositionCommandEvent else {
                return .commandFailed
            }
            return self.seek(to: positionEvent.positionTime) ? .success : .commandFailed
        }
    }

    /// Delegate calls arrive from AVFoundation's KVO machinery, which makes no
    /// promise about which thread it fires on. Mirrors `CrescendoPlaybackBackend`'s
    /// contract of always calling `backendDelegate` from the main thread.
    private func runOnMain(_ body: @escaping () -> Void) {
        if Thread.isMainThread {
            body()
        } else {
            DispatchQueue.main.async(execute: body)
        }
    }
}

// MARK: - Transport, Now Playing, Effects

extension AVQueuePlayerBackend {
    func pause() {
        player.pause()
        runOnMain { self.notifyStateIfChanged() }
    }

    func resume() {
        player.play()
        runOnMain { self.notifyStateIfChanged() }
    }

    func stop() {
        player.pause()
        clearQueue()
    }

    func togglePlayPause() {
        if player.timeControlStatus == .playing {
            player.pause()
        } else {
            player.play()
        }
        runOnMain { self.notifyStateIfChanged() }
    }

    @discardableResult
    func seek(to time: Double) -> Bool {
        guard time >= 0 else { return false }
        player.seek(to: CMTime(seconds: time, preferredTimescale: 600))
        return true
    }

    @discardableResult
    func seekForward(_ seconds: Double) -> Bool {
        seek(to: player.currentTime().seconds + seconds)
    }

    @discardableResult
    func seekBackward(_ seconds: Double) -> Bool {
        seek(to: max(0, player.currentTime().seconds - seconds))
    }

    // MARK: - Now Playing

    func setNowPlayingMetadata(_ metadata: NowPlayingMetadata?) {
        NowPlayingPublisher.publish(
            metadata,
            progress: currentPlaybackProgress,
            duration: duration,
            rate: Double(player.rate)
        )
    }

    // MARK: - Audio Effects (unsupported on iOS)

    func setStereoWidening(enabled: Bool) {}
    func isStereoWideningEnabled() -> Bool { false }
    func setEQEnabled(_ enabled: Bool) {}
    func isEQEnabled() -> Bool { false }
    func applyEQPreset(_ preset: EqualizerPreset) {}
    func applyEQCustom(gains: [Float]) {}
    func setPreamp(_ gain: Float) {}
    func getPreamp() -> Float { 0 }
}
