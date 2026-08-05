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
// Background playback and the lock-screen tile are this backend's
// responsibility too, wired up in `activateSessionIfNeeded()` on the first
// real start of playback (not `init` - see that method's doc):
//   - `AudioSessionController` configures the `.playback` audio session and
//     reacts to interruptions/route changes.
//   - `NowPlayingPublisher` publishes the descriptive `MPNowPlayingInfoCenter`
//     tile from `setNowPlayingMetadata(_:)`.
// The lock-screen/Control Center transport *buttons* are not this backend's
// responsibility: `Managers/RemoteCommandManager.swift` owns the single
// `MPRemoteCommandCenter` registration for the whole app (routed through
// `PlaybackManager`, which knows about the queue and playlists - this
// backend only knows its own queue). Registering targets here too would
// double-fire every button tap.
//

import AVFoundation
import Foundation

final class AVQueuePlayerBackend: NSObject, PlaybackBackend {
    weak var backendDelegate: PlaybackBackendDelegate?

    private let player = AVQueuePlayer()
    private var entries: [QueueEntry] = []
    private var currentIndex: Int = 0
    private var currentItemObservation: NSKeyValueObservation?
    private var timeControlObservation: NSKeyValueObservation?
    private var previousState: AudioPlayerState = .stopped

    // MARK: - Queue item failure tracking

    /// Maps a live `AVPlayerItem`'s identity to the queue entry it was built
    /// from, so a failure reported against the item (which carries no entry
    /// id of its own) can be attributed back to an `AudioEntryId`.
    private var itemEntryMap: [ObjectIdentifier: AudioEntryId] = [:]
    private var itemStatusObservations: [ObjectIdentifier: NSKeyValueObservation] = [:]
    /// De-dupes a single item's failure being reported twice - `.status ==
    /// .failed` (KVO) and `failedToPlayToEndTimeNotification` can both fire
    /// for the same underlying failure.
    private var failedItemKeys: Set<ObjectIdentifier> = []
    /// Set right before this backend itself removes the *current* failed item
    /// from the player (to skip past it). The resulting `currentItem` KVO
    /// change is a consequence of that removal, not a normal end-of-track
    /// advance, so `handleCurrentItemChange` must not report it as one.
    private var suppressNextCurrentItemTransition = false

    private lazy var audioSession = AudioSessionController(
        onPause: { [weak self] in self?.pause() },
        onResume: { [weak self] in self?.resume() }
    )

    /// Set once `activateSessionIfNeeded()` has run. Grabbing the shared
    /// `AVAudioSession` is deferred to the first real start of playback
    /// rather than `init`, for two reasons: it avoids touching the
    /// process-wide singleton before the app actually intends to make
    /// sound, and it keeps `AVQueuePlayerBackend()` cheap to construct
    /// directly in tests (see `QueueBackendTests`), which never start
    /// playback and so never trip this activation at all.
    private var didActivateSession = false

    override init() {
        super.init()
        player.actionAtItemEnd = .advance
        observeTrackChanges()
        observeStateChanges()
        observeItemFailureNotifications()
    }

    /// Activates the shared `AVAudioSession`, exactly once, on the first path
    /// that actually starts playback. `AudioSessionController.activate()` is
    /// not idempotent (it registers interruption/route-change observers with
    /// no matching removal), so this must not run more than once per
    /// instance.
    private func activateSessionIfNeeded() {
        guard !didActivateSession else { return }
        didActivateSession = true
        audioSession.activate()
    }

    deinit {
        currentItemObservation?.invalidate()
        timeControlObservation?.invalidate()
        itemStatusObservations.values.forEach { $0.invalidate() }
        NotificationCenter.default.removeObserver(self)
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
        clearItemTracking()
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

    /// Сколько треков вперёд ставится в плеер заранее. Больше — плавнее
    /// переход между треками, дороже старт: каждый `AVPlayerItem` делает
    /// синхронный XPC-запрос к медиасервису, и построение всей очереди
    /// сразу (тысячи треков из «Все треки») вешает главный поток, пока
    /// watchdog не убьёт приложение.
    private static let lookaheadItemCount = 16

    /// Ставит текущий трек и до `lookaheadItemCount` следующих: успешник уже
    /// загружен в плеер, поэтому переход происходит без паузы. Остаток
    /// очереди доливается в `handleCurrentItemChange` по мере проигрывания.
    private func rebuildPlayerItems(startPaused: Bool) {
        player.removeAllItems()
        clearItemTracking()

        guard !entries.isEmpty else {
            runOnMain { self.notifyStateIfChanged() }
            return
        }

        let end = min(entries.count, currentIndex + 1 + Self.lookaheadItemCount)
        for entry in entries[currentIndex..<end] {
            player.insert(makePlayerItem(for: entry), after: nil)
        }
        if startPaused {
            player.pause()
        } else {
            activateSessionIfNeeded()
            player.play()
        }
        runOnMain { self.notifyStateIfChanged() }
    }

    /// Пересобирает только ещё не прозвучавший хвост (до `lookaheadItemCount`
    /// треков), не трогая играющий трек.
    private func refillUpcomingItems() {
        guard !entries.isEmpty else {
            player.removeAllItems()
            clearItemTracking()
            return
        }
        guard player.currentItem != nil else { return }

        for item in player.items().dropFirst() {
            player.remove(item)
            removeTracking(for: item)
        }
        let end = min(entries.count, currentIndex + 1 + Self.lookaheadItemCount)
        for entry in entries[(currentIndex + 1)..<end] {
            player.insert(makePlayerItem(for: entry), after: nil)
        }
    }

    /// Builds a fresh `AVPlayerItem` for `entry` and starts tracking it so a
    /// later load/playback failure can be attributed back to `entry.entryId`.
    private func makePlayerItem(for entry: QueueEntry) -> AVPlayerItem {
        let item = AVPlayerItem(url: entry.url)
        let key = ObjectIdentifier(item)
        itemEntryMap[key] = entry.entryId
        itemStatusObservations[key] = item.observe(\.status, options: [.new]) { [weak self] item, _ in
            guard let self, item.status == .failed else { return }
            self.runOnMain { self.handleItemFailure(item) }
        }
        return item
    }

    /// Stops tracking `item` - called once it has left the player, whether
    /// because it finished, was skipped, or the whole queue was torn down.
    private func removeTracking(for item: AVPlayerItem) {
        let key = ObjectIdentifier(item)
        itemStatusObservations.removeValue(forKey: key)?.invalidate()
        itemEntryMap.removeValue(forKey: key)
        failedItemKeys.remove(key)
    }

    private func clearItemTracking() {
        itemStatusObservations.values.forEach { $0.invalidate() }
        itemStatusObservations.removeAll()
        itemEntryMap.removeAll()
        failedItemKeys.removeAll()
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
            // A transition to nil with no tracked items is our own queue
            // teardown (rebuild/clear), not the last track finishing: the KVO
            // fires asynchronously, after clearItemTracking has emptied the
            // map, so reporting it as eof would invent a finished track,
            // advance the queue and bump play counts for nothing.
            if new == nil, itemEntryMap.isEmpty {
                return
            }

            defer { removeTracking(for: finished) }

            if suppressNextCurrentItemTransition {
                // This transition is the result of this backend removing a
                // failed *current* item to skip past it - `handleItemFailure`
                // already reported `backendDidSkipQueueEntry` and adjusted
                // `currentIndex` for it. Reporting it again here as a normal
                // finish would be wrong (it never finished) and would double
                // the index advance.
                suppressNextCurrentItemTransition = false
                refillUpcomingItems()
            } else {
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
                refillUpcomingItems()
            }
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

    // MARK: - Queue item failures

    /// Catches failures that happen *after* an item started playing (e.g. a
    /// mid-file decode error). Load-time failures - a missing or unreadable
    /// file, caught before the item ever became ready - are covered by the
    /// `.status == .failed` KVO in `makePlayerItem(for:)` instead, since this
    /// notification is only posted for items that had begun playing.
    private func observeItemFailureNotifications() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleFailedToPlayToEndTime(_:)),
            name: AVPlayerItem.failedToPlayToEndTimeNotification,
            object: nil
        )
    }

    @objc private func handleFailedToPlayToEndTime(_ notification: Notification) {
        guard let item = notification.object as? AVPlayerItem else { return }
        let error = notification.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? Error
        runOnMain { self.handleItemFailure(item, explicitError: error) }
    }

    /// Reports a queue entry that could not play - a missing file, a
    /// corrupt/unsupported one, or any other AVFoundation load/playback
    /// failure - and drops it from the queue so a single bad file in a
    /// 2000+ track library doesn't stall the player. Reports through the
    /// same two delegate calls `CrescendoPlaybackBackend` uses for this on
    /// macOS: `backendUnexpectedError` for the error itself, then
    /// `backendDidSkipQueueEntry` for the entry that got dropped.
    private func handleItemFailure(_ item: AVPlayerItem, explicitError: Error? = nil) {
        let key = ObjectIdentifier(item)
        guard !failedItemKeys.contains(key) else { return }
        failedItemKeys.insert(key)

        guard let entryId = itemEntryMap[key] else { return }

        backendDelegate?.backendUnexpectedError(error: Self.mapPlaybackError(explicitError ?? item.error))

        guard let index = queueIndex(of: entryId) else {
            removeTracking(for: item)
            return
        }

        let wasCurrent = index == currentIndex && player.currentItem === item

        entries.remove(at: index)
        if index < currentIndex {
            currentIndex -= 1
        } else if index == currentIndex {
            currentIndex = min(currentIndex, max(0, entries.count - 1))
        }

        backendDelegate?.backendDidSkipQueueEntry(entryId: entryId)

        if wasCurrent {
            // `handleCurrentItemChange` finishes the cleanup (tracking +
            // refilling the tail) once the resulting `currentItem` KVO fires.
            suppressNextCurrentItemTransition = true
            player.remove(item)
        } else {
            player.remove(item)
            removeTracking(for: item)
        }

        runOnMain { self.notifyStateIfChanged() }
    }

    /// Maps an AVFoundation load/playback failure to the shared
    /// `AudioPlayerError` the rest of the app understands. A pure function of
    /// its input, so it is covered directly by a unit test without needing a
    /// real failing `AVPlayerItem`.
    static func mapPlaybackError(_ error: Error?) -> AudioPlayerError {
        guard let error else {
            return .engineError(NSError(
                domain: "AVQueuePlayerBackend",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Unknown playback failure"]
            ))
        }

        let nsError = error as NSError
        if isFileNotFoundError(nsError) { return .fileNotFound }
        if isUnsupportedFormatError(nsError) { return .invalidFormat }
        return .engineError(error)
    }

    private static func isFileNotFoundError(_ error: NSError) -> Bool {
        switch (error.domain, error.code) {
        case (NSCocoaErrorDomain, NSFileReadNoSuchFileError),
             (NSURLErrorDomain, NSURLErrorFileDoesNotExist):
            return true
        default:
            break
        }
        if let underlying = error.userInfo[NSUnderlyingErrorKey] as? NSError {
            return isFileNotFoundError(underlying)
        }
        return false
    }

    private static func isUnsupportedFormatError(_ error: NSError) -> Bool {
        if error.domain == AVFoundationErrorDomain {
            switch error.code {
            case AVError.Code.fileFormatNotRecognized.rawValue,
                 AVError.Code.fileFailedToParse.rawValue,
                 AVError.Code.failedToParse.rawValue,
                 AVError.Code.decodeFailed.rawValue,
                 AVError.Code.undecodableMediaData.rawValue:
                return true
            default:
                break
            }
        }
        if let underlying = error.userInfo[NSUnderlyingErrorKey] as? NSError {
            return isUnsupportedFormatError(underlying)
        }
        return false
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
        activateSessionIfNeeded()
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
            activateSessionIfNeeded()
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
