//
//  LyricsManager.swift
//  Petrichor
//
//  Handles fetching lyrics from online sources (LRCLIB) and coordinating
//  with database storage for caching.
//

import Foundation

/// Genuinely `Sendable`: no stored mutable state, only `static let` constants
/// and a computed `UserDefaults` read - nothing to race on. `final` because a
/// non-final class cannot conform to `Sendable` (a subclass could add
/// mutable state the checker never re-verifies).
final class LyricsManager: Sendable {
    // MARK: - Singleton
    
    static let shared = LyricsManager()
    
    // MARK: - Constants
    
    private enum LRCLIB {
        static let baseURL = "https://lrclib.net/api"
        static let getEndpoint = "/get"
    }
    
    private enum UserDefaultsKeys {
        static let onlineLyricsEnabled = "onlineLyricsEnabled"
    }
    
    // MARK: - Properties

    /// Whether online lyrics fetching is enabled (user preference)
    var isOnlineLyricsEnabled: Bool {
        UserDefaults.standard.bool(forKey: UserDefaultsKeys.onlineLyricsEnabled)
    }

    // MARK: - Initialization

    private init() {}
    
    // MARK: - Public Methods
    
    /// Fetch lyrics for a track from online sources
    /// - Parameters:
    ///   - fullTrack: The full track to fetch lyrics for
    ///   - databaseManager: Database manager for storing fetched lyrics
    /// - Returns: Lyrics text if found, nil otherwise
    func fetchLyrics(for fullTrack: FullTrack, using databaseManager: DatabaseManager) async throws -> String? {
        guard isOnlineLyricsEnabled else {
            Logger.info("LyricsManager: Online lyrics fetching is disabled")
            return nil
        }
        
        // Skip tracks with unknown/missing metadata
        guard isValidForLyricsFetch(fullTrack) else {
            Logger.info("LyricsManager: Track metadata insufficient for lyrics search")
            return nil
        }
        
        Logger.info("LyricsManager: Fetching lyrics for '\(fullTrack.title)' by '\(fullTrack.artist)'")
        
        // Try LRCLIB API
        if let lyrics = try await fetchFromLRCLIB(fullTrack: fullTrack) {
            // Store in database for future use
            await storeLyrics(lyrics, for: fullTrack, using: databaseManager)
            return lyrics
        }
        
        Logger.info("LyricsManager: No lyrics found online for '\(fullTrack.title)'")
        return nil
    }
    
    // MARK: - Private Methods
    
    /// Check if track has sufficient metadata for lyrics search
    private func isValidForLyricsFetch(_ fullTrack: FullTrack) -> Bool {
        let hasValidTitle = !fullTrack.title.isEmpty
        let hasValidArtist = !fullTrack.artist.isEmpty && fullTrack.artist != "Unknown Artist"
        
        return hasValidTitle && hasValidArtist
    }
    
    /// Fetch lyrics from LRCLIB API
    private func fetchFromLRCLIB(fullTrack: FullTrack) async throws -> String? {
        // Try with album first if available
        if !fullTrack.album.isEmpty && fullTrack.album != "Unknown Album" {
            if let lyrics = try await requestLRCLIB(fullTrack: fullTrack, includeAlbum: true) {
                return lyrics
            }
            // Retry without album
            Logger.info("LyricsManager: Retrying without album name")
        }
        
        return try await requestLRCLIB(fullTrack: fullTrack, includeAlbum: false)
    }
            
    /// Make a request to LRCLIB API
    private func requestLRCLIB(fullTrack: FullTrack, includeAlbum: Bool) async throws -> String? {
        guard var components = URLComponents(string: LRCLIB.baseURL + LRCLIB.getEndpoint) else {
            Logger.error("LyricsManager: Failed to create URL components")
            return nil
        }
        
        // Build query parameters
        var queryItems: [URLQueryItem] = [
            URLQueryItem(name: "track_name", value: fullTrack.title),
            URLQueryItem(name: "artist_name", value: fullTrack.artist)
        ]
        
        // Add album if requested and available
        if includeAlbum && !fullTrack.album.isEmpty && fullTrack.album != "Unknown Album" {
            queryItems.append(URLQueryItem(name: "album_name", value: fullTrack.album))
        }
        
        // Add duration if available (crucial for accurate matching)
        if fullTrack.duration > 0 {
            queryItems.append(URLQueryItem(name: "duration", value: String(Int(fullTrack.duration))))
        }
        
        components.queryItems = queryItems
        
        guard let url = components.url else {
            Logger.error("LyricsManager: Failed to build LRCLIB URL")
            return nil
        }
        
        var request = URLRequest(url: url)
        request.setValue(AppInfo.userAgent, forHTTPHeaderField: "User-Agent")
        let (data, response) = try await AppInfo.urlSession.data(for: request)
        guard let response = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        return try parseLRCLIBResponse(data, statusCode: response.statusCode)
    }

    /// A missing match is different from a failed request: callers can offer retry.
    func parseLRCLIBResponse(_ data: Data, statusCode: Int) throws -> String? {
        if statusCode == 404 { return nil }
        guard statusCode == 200 else { throw URLError(.badServerResponse) }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw URLError(.cannotParseResponse)
        }
        if let synced = json["syncedLyrics"] as? String, !synced.isEmpty { return synced }
        if let plain = json["plainLyrics"] as? String, !plain.isEmpty { return plain }
        return nil
    }

    /// Store fetched lyrics in the database
    private func storeLyrics(_ lyrics: String, for fullTrack: FullTrack, using databaseManager: DatabaseManager) async {
        guard fullTrack.trackId != nil else {
            Logger.error("LyricsManager: Cannot store lyrics - track has no database ID")
            return
        }
        
        do {
            try await databaseManager.updateTrackLyrics(for: fullTrack, lyrics: lyrics)
            Logger.info("LyricsManager: Stored lyrics in database for '\(fullTrack.title)'")
        } catch {
            Logger.error("LyricsManager: Failed to store lyrics - \(error.localizedDescription)")
        }
    }
}
