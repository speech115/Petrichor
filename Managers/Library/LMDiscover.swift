import Foundation

extension LibraryManager {
    // MARK: - Constants
    private static let discoverTrackIdsKey = "discoverTrackIds"
    private static let discoverLastUpdatedKey = "discoverLastUpdated"
    private static let discoverUpdateIntervalKey = "discoverUpdateInterval"
    private static let discoverTrackCountKey = "discoverTrackCount"
    /// Every track drawn since the pool last ran out; a draw never repeats one.
    private static let discoverShownTrackIdsKey = "discoverShownTrackIds"
    /// Tracks that started playing anywhere. A skip counts: the user has met it.
    private static let discoverHeardTrackIdsKey = "discoverHeardTrackIds"
    
    private var discoverUpdateInterval: DiscoverUpdateInterval {
        let rawValue = userDefaults.string(forKey: Self.discoverUpdateIntervalKey) ?? DiscoverUpdateInterval.weekly.rawValue
        return DiscoverUpdateInterval(rawValue: rawValue) ?? .weekly
    }
    
    private var discoverTrackCount: Int {
        let count = userDefaults.integer(forKey: Self.discoverTrackCountKey)
        return count > 0 ? count : 50
    }
    
    var discoverLastUpdated: Date? {
        userDefaults.object(forKey: Self.discoverLastUpdatedKey) as? Date
    }
    
    // MARK: - Methods
    
    func loadDiscoverTracks(populateArtwork: Bool = true) async {
        if let pending = discoverLoadTask {
            await pending.value
            return
        }
        let storedIDs = userDefaults.array(forKey: Self.discoverTrackIdsKey) as? [Int64]
        let savedIDs = shouldRefreshDiscover() || storedIDs?.isEmpty != false ? nil : storedIDs
        let count = discoverTrackCount
        // A new draw skips the rotation it replaces, even after the history restarts.
        let previousIDs = storedIDs ?? []
        let heardIDs = trackIDs(forKey: Self.discoverHeardTrackIdsKey)
        let shownIDs = trackIDs(forKey: Self.discoverShownTrackIdsKey)
        let database = databaseManager
        let task = Task { @MainActor in
            let (tracks, history) = await Task.detached(priority: .userInitiated) {
                var rows: [Track]
                var history = shownIDs
                if let savedIDs {
                    rows = database.getTracks(byIds: savedIDs)
                    if populateArtwork { database.populateAlbumArtworkForTracks(&rows) }
                } else {
                    let met = heardIDs.union(previousIDs)
                    rows = database.getDiscoverTracks(
                        limit: count,
                        excluding: Array(met.union(shownIDs)),
                        populateArtwork: populateArtwork
                    )
                    if rows.count < count {
                        // Every track has been shown once; the history starts over.
                        history = []
                        rows = database.getDiscoverTracks(limit: count, excluding: Array(met), populateArtwork: populateArtwork)
                    }
                    history.formUnion(rows.compactMap(\.trackId))
                }
                if !populateArtwork {
                    database.populateAlbumArtworkThumbnailsForTracks(&rows, limit: 4)
                }
                return (rows, history)
            }.value
            guard !Task.isCancelled else { return }
            if savedIDs == nil, !tracks.isEmpty {
                userDefaults.set(Array(history), forKey: Self.discoverShownTrackIdsKey)
                userDefaults.set(tracks.compactMap(\.trackId), forKey: Self.discoverTrackIdsKey)
                userDefaults.set(Date(), forKey: Self.discoverLastUpdatedKey)
            }
            discoverTracks = tracks
            discoverLoadTask = nil
            Logger.info("Discover tracks loaded")
        }
        discoverLoadTask = task
        await task.value
    }

    /// Keep the previous selection visible while the replacement is read.
    func refreshDiscoverTracks(populateArtwork: Bool = true) async {
        discoverLoadTask?.cancel()
        discoverLoadTask = nil
        userDefaults.removeObject(forKey: Self.discoverLastUpdatedKey)
        await loadDiscoverTracks(populateArtwork: populateArtwork)
    }

    /// Keeps a started track out of later draws; the current rotation stays as drawn.
    func markHeardForDiscover(_ track: Track) {
        guard let trackId = track.trackId else { return }
        var heard = trackIDs(forKey: Self.discoverHeardTrackIdsKey)
        guard heard.insert(trackId).inserted else { return }
        userDefaults.set(Array(heard), forKey: Self.discoverHeardTrackIdsKey)
    }

    private func trackIDs(forKey key: String) -> Set<Int64> {
        Set(userDefaults.array(forKey: key) as? [Int64] ?? [])
    }

    /// Check if discover list needs refresh
    private func shouldRefreshDiscover() -> Bool {
        guard let lastUpdated = userDefaults.object(forKey: Self.discoverLastUpdatedKey) as? Date else {
            return true // Never updated
        }
        
        let timeElapsed = Date().timeIntervalSince(lastUpdated)
        return timeElapsed >= discoverUpdateInterval.timeInterval
    }
}
