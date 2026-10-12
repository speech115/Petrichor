//
// PlaylistManager class extension
//
// This extension contains methods managing playback queue.
//

import Foundation

extension PlaylistManager {
    func createLibraryQueue() {
        guard let library = libraryManager else { return }
        replaceCurrentQueue(library.tracks)
        currentPlaylist = nil
        currentQueueSource = .library
        Logger.info("Created playback queue from library")
        if isShuffleEnabled {
            shuffleCurrentQueue()
            Logger.info("Shuffled the playback queue")
        }
    }

    func clearQueue() {
        currentQueue.removeAll()
        currentQueueIndex = -1
        currentPlaylist = nil
        audioPlayer?.stop()
        audioPlayer?.queueDidClear()
        audioPlayer?.currentTrack = nil
        Logger.info("Cleared playback queue")
    }

    func playNext(_ track: Track) {
        guard let plan = QueuePolicy.playNextPlan(
            tracks: currentQueue, cursor: currentQueueIndex, track: track
        ) else { return }
        if plan.replace {
            replaceCurrentQueue([track], index: 0)
            audioPlayer?.startQueue(at: 0)
            return
        }

        if let existingIndex = plan.removeIndex {
            currentQueue.remove(at: existingIndex)
            if currentQueueIndex != plan.cursorAfterRemoval { currentQueueIndex = plan.cursorAfterRemoval }
            // Publish the adjusted cursor before the mirror re-primes lookahead.
            audioPlayer?.queueDidRemove(at: existingIndex)
        }

        let position = plan.insertionIndex
        let lightTrack = track.withoutArtwork()
        insertCurrentQueueEntry(track, at: position)
        audioPlayer?.queueDidInsert(lightTrack, at: position)
        Logger.info("Added track to playback queue to play up next")
    }

    func addToQueue(_ track: Track) {
        if currentQueue.isEmpty {
            replaceCurrentQueue([track], index: 0)
            audioPlayer?.startQueue(at: 0)
            return
        }

        if QueuePolicy.shouldAppend(tracks: currentQueue, track: track) {
            let lightTrack = track.withoutArtwork()
            appendCurrentQueueEntry(track)
            audioPlayer?.queueDidAppend(lightTrack)
            Logger.info("Added track to playback queue")
        }
    }

    func removeFromQueue(at index: Int) {
        guard let cursor = QueuePolicy.removalCursor(
            count: currentQueue.count, cursor: currentQueueIndex, index: index, allowCurrent: false
        ) else { return }
        currentQueue.remove(at: index)
        if currentQueueIndex != cursor { currentQueueIndex = cursor }
        // After the cursor: the mirror re-primes the repeat lookahead from it, and a
        // stale cursor indexes past the end of the shortened queue.
        audioPlayer?.queueDidRemove(at: index)
        Logger.info("Remove track from playback queue")
    }

    /// Drops a row the engine has already discarded, adjusting the cursor. The engine
    /// and mirror are updated by the caller, so this does not notify them back.
    func dropQueueEntry(at index: Int) {
        guard let cursor = QueuePolicy.removalCursor(
            count: currentQueue.count, cursor: currentQueueIndex, index: index, allowCurrent: true
        ) else { return }
        currentQueue.remove(at: index)
        if index == currentQueueIndex || currentQueueIndex != cursor { currentQueueIndex = cursor }
    }

    func moveInQueue(from sourceIndex: Int, to destinationIndex: Int) {
        guard let cursor = QueuePolicy.moveCursor(
            count: currentQueue.count, cursor: currentQueueIndex, source: sourceIndex, destination: destinationIndex
        ) else { return }
        let track = currentQueue.remove(at: sourceIndex)
        currentQueue.insert(track, at: destinationIndex)
        if currentQueueIndex != cursor { currentQueueIndex = cursor }
        // After the cursor, so the mirror's repeat lookahead is primed from the
        // position the moved entry actually left behind.
        audioPlayer?.queueDidMove(from: sourceIndex, to: destinationIndex)
        Logger.info("Moved track in playback queue")
    }

    func playFromQueue(at index: Int) {
        guard index >= 0 && index < currentQueue.count else { return }

        currentQueueIndex = index
        audioPlayer?.jumpToQueueEntry(at: index)
    }

    /// Shuffles the upcoming entries, leaving played ones and the current track put.
    internal func shuffleCurrentQueue() {
        guard !currentQueue.isEmpty else { return }

        guard let audioPlayer, audioPlayer.hasMirroredQueue else {
            // No engine queue to disagree with; reorder the whole thing app-side.
            currentQueue.shuffle()
            currentQueueIndex = 0
            Logger.info("Shuffled the playback queue")
            return
        }

        guard let reordered = audioPlayer.shuffleUpcomingQueueEntries() else { return }
        replaceCurrentQueue(reordered, index: audioPlayer.mirroredQueuePosition)
        Logger.info("Shuffled the upcoming playback queue")
    }
}
