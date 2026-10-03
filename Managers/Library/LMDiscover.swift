import Foundation

extension LibraryManager {
    // MARK: - Constants
    private static let discoverTrackIdsKey = "discoverTrackIds"
    private static let discoverLastUpdatedKey = "discoverLastUpdated"
    private static let discoverUpdateIntervalKey = "discoverUpdateInterval"
    private static let discoverTrackCountKey = "discoverTrackCount"
    
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
        let database = databaseManager
        let task = Task { @MainActor in
            let tracks = await Task.detached(priority: .userInitiated) {
                var rows: [Track]
                if let savedIDs {
                    rows = database.getTracks(byIds: savedIDs)
                    if populateArtwork { database.populateAlbumArtworkForTracks(&rows) }
                } else {
                    rows = database.getDiscoverTracks(limit: count, populateArtwork: populateArtwork)
                }
                if !populateArtwork {
                    database.populateAlbumArtworkThumbnailsForTracks(&rows, limit: 4)
                }
                return rows
            }.value
            guard !Task.isCancelled else { return }
            if savedIDs == nil, !tracks.isEmpty {
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

    /// Check if discover list needs refresh
    private func shouldRefreshDiscover() -> Bool {
        guard let lastUpdated = userDefaults.object(forKey: Self.discoverLastUpdatedKey) as? Date else {
            return true // Never updated
        }
        
        let timeElapsed = Date().timeIntervalSince(lastUpdated)
        return timeElapsed >= discoverUpdateInterval.timeInterval
    }
}
