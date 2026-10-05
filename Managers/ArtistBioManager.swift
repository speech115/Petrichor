//
//  ArtistBioManager.swift
//  Petrichor
//
//  Handles fetching artist images (MusicBrainz/Wikidata, TMDB) and bios (Last.fm)
//  from online sources and storing them in the database.
//

import CryptoKit
import Foundation

/// An `actor`, not a `@MainActor` class: this is a background network worker
/// (rate-limited MusicBrainz/Wikidata/TMDB/Last.fm fetches), and its only
/// mutable state (`fetchTask`, the per-service rate-limit timestamps) is
/// touched exclusively from its own async methods - exactly what an actor is
/// for. `isArtistInfoFetchEnabled`/`tmdbReadAccessToken`/`lastfmApiKey` stay
/// `nonisolated`: they read `UserDefaults`/`Bundle` (both thread-safe) and
/// never touch actor-isolated storage, so callers on other threads (DM*
/// background scan code) can keep reading them synchronously.
actor ArtistBioManager {
    // MARK: - Singleton

    static let shared = ArtistBioManager()

    /// Minimum image size in bytes to filter out placeholder/silhouette images
    private static let minimumImageSize = 15_000

    // MARK: - Constants

    private enum MusicBrainz {
        static let searchURL = "https://musicbrainz.org/ws/2/artist/"
        static let rateLimitDelay: TimeInterval = 1.1 // 1 req/sec with margin
    }

    private enum Wikidata {
        static let apiURL = "https://www.wikidata.org/w/api.php"
        static let rateLimitDelay: TimeInterval = 0.5
    }

    private enum TMDB {
        static let searchURL = "https://api.themoviedb.org/3/search/person"
        static let personURL = "https://api.themoviedb.org/3/person"
        static let imageBaseURL = "https://image.tmdb.org/t/p/w500"
        static let rateLimitDelay: TimeInterval = 0.3 // ~40 req / 10s
    }

    private enum LastFM {
        static let apiBaseURL = "https://ws.audioscrobbler.com/2.0/"
        static let rateLimitDelay: TimeInterval = 0.25
    }

    private enum UserDefaultsKeys {
        static let artistInfoFetchEnabled = "artistInfoFetchEnabled"
    }

    // MARK: - Properties

    private var fetchTask: Task<Void, Never>?
    private var lastMusicBrainzRequest: Date?
    private var lastWikimediaRequest: Date?
    private var lastTMDBRequest: Date?
    private var lastLastFMRequest: Date?
    /// Requests that failed at the transport level (offline, DNS, timeout),
    /// as opposed to answering "nothing found". Drives the offline breaker.
    private var networkErrors = 0

    private nonisolated var tmdbReadAccessToken: String? {
        Bundle.main.object(forInfoDictionaryKey: "TMDB_READ_ACCESS_TOKEN") as? String
    }

    private nonisolated var lastfmApiKey: String? {
        Bundle.main.object(forInfoDictionaryKey: "LASTFM_API_KEY") as? String
    }

    nonisolated var isArtistInfoFetchEnabled: Bool {
        UserDefaults.standard.bool(forKey: UserDefaultsKeys.artistInfoFetchEnabled)
    }

    // MARK: - Initialization

    private init() {}

    // MARK: - Types

    struct ImageResult {
        let imageData: Data
        let imageUrl: String
        let source: String
    }

    // MARK: - Public Methods

    /// `nonisolated` so every existing call site (UI actions, `LibraryManager`
    /// post-scan hooks) can keep firing this synchronously instead of awaiting
    /// a background kickoff. The actual `fetchTask` bookkeeping is isolated
    /// actor state, so it happens in `startFetchingMissingArtistImages` below.
    nonisolated func fetchMissingArtistImages(using libraryManager: LibraryManager) {
        Task {
            await startFetchingMissingArtistImages(using: libraryManager)
        }
    }

    private func startFetchingMissingArtistImages(using libraryManager: LibraryManager) {
        fetchTask?.cancel()

        let databaseManager = libraryManager.databaseManager

        fetchTask = Task.detached(priority: .utility) { [weak self] in
            guard let self else { return }
            guard self.isArtistInfoFetchEnabled else {
                Logger.info("Artist info fetching is disabled")
                return
            }

            let artists = databaseManager.getArtistsNeedingImageOrBio()
            guard !artists.isEmpty else {
                Logger.info("No artists need fetching")
                return
            }

            Logger.info("Starting fetch for \(artists.count) artists")

            // Stop a doomed run (offline / APIs down) instead of timing out on every
            // artist. Only transport errors count: an empty answer means the artist
            // has no data there, which is stamped and retried in 7 days.
            let maxConsecutiveFailures = 10
            var consecutiveFailures = 0

            // Without a Last.fm key no bio can come back, so it isn't attempted.
            let canFetchBio = !(self.lastfmApiKey ?? "").isEmpty

            for artist in artists {
                guard !Task.isCancelled, self.isArtistInfoFetchEnabled else {
                    Logger.info("Fetch stopped")
                    break
                }

                let wantsImage = !artist.hasImage
                let wantsBio = !artist.hasBio && canFetchBio
                guard wantsImage || wantsBio else { continue }

                // Fetch image and bio, then write once
                Logger.info("Fetching info for '\(artist.name)' (image: \(wantsImage), bio: \(wantsBio))")
                let errorsBefore = await self.networkErrors
                let imageResult = wantsImage ? await self.fetchArtistImage(name: artist.name) : nil
                let bio = wantsBio ? await self.fetchArtistBio(name: artist.name) : nil
                let networkFailed = await self.networkErrors != errorsBefore

                // A cancel mid-fetch surfaces as nil results; bail before treating them
                // as misses so we don't stamp an interrupted artist as failed.
                if Task.isCancelled { break }

                if let imageResult,
                   let compressed = ImageUtils.compressImage(from: imageResult.imageData, source: "ArtistBioManager/\(imageResult.source)") {
                    let source = imageResult.source.components(separatedBy: " – ").first ?? imageResult.source
                    databaseManager.updateArtistInfo(
                        artistId: artist.id,
                        imageData: compressed,
                        imageUrl: imageResult.imageUrl,
                        imageSource: source,
                        bio: bio,
                        bioSource: bio != nil ? "last.fm" : nil
                    )
                } else if let bio {
                    databaseManager.updateArtistInfo(artistId: artist.id, bio: bio, bioSource: "last.fm")
                }

                if networkFailed && imageResult == nil && bio == nil {
                    // Nothing came back and a request failed in transit: leave the
                    // artist unstamped for a later retry and count toward the breaker.
                    consecutiveFailures += 1
                    if consecutiveFailures >= maxConsecutiveFailures {
                        Logger.warning("Stopping artist fetch after \(maxConsecutiveFailures) consecutive network failures")
                        break
                    }
                } else {
                    // A miss = an attempted fetch that got an empty remote response.
                    // (A downloaded image that fails local compression is not a miss; it
                    // stays unstamped so it retries rather than being skipped for 7 days.)
                    if wantsImage && imageResult == nil { databaseManager.markArtistImageFetchFailed(artistId: artist.id) }
                    if wantsBio && bio == nil { databaseManager.markArtistBioFetchFailed(artistId: artist.id) }
                    consecutiveFailures = 0
                }
            }

            Logger.info("Finished fetch")
        }
    }

    /// Search MusicBrainz/Wikidata and TMDB for all available artist images (used by image picker sheet)
    func searchAllImages(for artistName: String) async -> [ImageResult] {
        async let mbResults = searchMusicBrainzImages(name: artistName)
        async let tmdbResults = searchTMDBImages(name: artistName)
        return await mbResults + tmdbResults
    }

    // MARK: - Private: Image Fetch

    private func fetchArtistImage(name: String) async -> ImageResult? {
        // Try MusicBrainz/Wikidata first (CC0, no cache restrictions)
        if let result = await searchMusicBrainzImages(name: name, limit: 1).first {
            return result
        }
        // Fall back to TMDB
        return await searchTMDBImages(name: name, limit: 1).first
    }

    // MARK: - MusicBrainz / Wikidata Search

    private func searchMusicBrainzImages(name: String, limit: Int = 6) async -> [ImageResult] {
        lastMusicBrainzRequest = await waitForRateLimit(lastRequest: lastMusicBrainzRequest, delay: MusicBrainz.rateLimitDelay)

        guard var components = URLComponents(string: MusicBrainz.searchURL) else { return [] }
        components.queryItems = [
            URLQueryItem(name: "query", value: "artist:\"\(name)\""),
            URLQueryItem(name: "fmt", value: "json"),
            URLQueryItem(name: "limit", value: String(limit))
        ]
        guard let url = components.url else { return [] }

        do {
            var request = URLRequest(url: url)
            request.setValue(AppInfo.userAgent, forHTTPHeaderField: "User-Agent")

            let (data, response) = try await fetch(request)
            guard let httpResponse = response as? HTTPURLResponse,
                  httpResponse.statusCode == 200,
                  let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let artists = json["artists"] as? [[String: Any]] else {
                return []
            }

            var images: [ImageResult] = []
            for artist in artists.prefix(limit) {
                guard let mbid = artist["id"] as? String else { continue }

                // For auto-fetch, only accept the same name
                if limit == 1, let resultName = artist["name"] as? String,
                   !isNameMatch(query: name, result: resultName) { continue }

                // Look up the artist's relationships to find Wikidata link
                if let imageResult = await resolveImageViaMusicBrainz(mbid: mbid, artistName: artist["name"] as? String, limit: limit) {
                    images.append(imageResult)
                }
            }
            return images
        } catch {
            if isCancellation(error) { return [] }
            if error is URLError { networkErrors += 1 }
            Logger.error("MusicBrainz error for '\(name)': \(error.localizedDescription)")
            return []
        }
    }

    /// Fetch artist relationships from MusicBrainz to find Wikidata URL, then resolve image
    private func resolveImageViaMusicBrainz(mbid: String, artistName: String?, limit: Int) async -> ImageResult? {
        lastMusicBrainzRequest = await waitForRateLimit(lastRequest: lastMusicBrainzRequest, delay: MusicBrainz.rateLimitDelay)

        let lookupURLString = "\(MusicBrainz.searchURL)\(mbid)?inc=url-rels&fmt=json"
        guard let lookupURL = URL(string: lookupURLString) else { return nil }

        do {
            var request = URLRequest(url: lookupURL)
            request.setValue(AppInfo.userAgent, forHTTPHeaderField: "User-Agent")

            let (data, response) = try await fetch(request)
            guard let httpResponse = response as? HTTPURLResponse,
                  httpResponse.statusCode == 200,
                  let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let relations = json["relations"] as? [[String: Any]] else {
                return nil
            }

            // Find Wikidata relationship
            for relation in relations {
                guard let type = relation["type"] as? String, type == "wikidata",
                      let urlInfo = relation["url"] as? [String: Any],
                      let resource = urlInfo["resource"] as? String else { continue }

                if let imageResult = await resolveWikidataImage(wikidataUrl: resource, artistName: artistName, limit: limit) {
                    return imageResult
                }
            }
            return nil
        } catch {
            if isCancellation(error) { return nil }
            if error is URLError { networkErrors += 1 }
            Logger.error("MusicBrainz lookup error for MBID '\(mbid)': \(error.localizedDescription)")
            return nil
        }
    }

    /// Fetch P18 (image) property from Wikidata, then get a direct thumb URL from Commons API
    private func resolveWikidataImage(wikidataUrl: String, artistName: String?, limit: Int) async -> ImageResult? {
        // Extract QID from URL like "https://www.wikidata.org/wiki/Q2831"
        guard let qid = wikidataUrl.split(separator: "/").last.map(String.init) else { return nil }

        lastWikimediaRequest = await waitForRateLimit(lastRequest: lastWikimediaRequest, delay: Wikidata.rateLimitDelay)

        guard var components = URLComponents(string: Wikidata.apiURL) else { return nil }
        components.queryItems = [
            URLQueryItem(name: "action", value: "wbgetclaims"),
            URLQueryItem(name: "entity", value: qid),
            URLQueryItem(name: "property", value: "P18"),
            URLQueryItem(name: "format", value: "json")
        ]
        guard let url = components.url else { return nil }

        do {
            var request = URLRequest(url: url)
            request.setValue(AppInfo.userAgent, forHTTPHeaderField: "User-Agent")

            let (data, response) = try await fetch(request)
            guard let httpResponse = response as? HTTPURLResponse,
                  httpResponse.statusCode == 200,
                  let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let claims = json["claims"] as? [String: Any],
                  let p18Claims = claims["P18"] as? [[String: Any]],
                  let firstClaim = p18Claims.first,
                  let mainsnak = firstClaim["mainsnak"] as? [String: Any],
                  let datavalue = mainsnak["datavalue"] as? [String: Any],
                  let filename = datavalue["value"] as? String else {
                return nil
            }

            // Construct Wikimedia Commons thumb URL directly from filename MD5
            let imageUrl = commonsThumbUrl(filename: filename, width: 500)

            if let imageData = await downloadImageData(from: imageUrl) {
                let label = limit == 1 ? "musicbrainz" : artistName.map { "musicbrainz – \($0)" } ?? "musicbrainz"
                return ImageResult(imageData: imageData, imageUrl: imageUrl, source: label)
            }
            return nil
        } catch {
            if isCancellation(error) { return nil }
            if error is URLError { networkErrors += 1 }
            Logger.error("Wikidata error for '\(qid)': \(error.localizedDescription)")
            return nil
        }
    }

    /// Construct a direct Wikimedia Commons thumbnail URL from a filename.
    /// Uses the MD5-based path scheme: upload.wikimedia.org/wikipedia/commons/thumb/{a}/{ab}/{filename}/{width}px-{filename}
    private func commonsThumbUrl(filename: String, width: Int) -> String {
        let normalized = filename.replacingOccurrences(of: " ", with: "_")
        let md5 = md5Hash(normalized)
        let a = String(md5.prefix(1))
        let ab = String(md5.prefix(2))
        let encoded = normalized.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? normalized
        return "https://upload.wikimedia.org/wikipedia/commons/thumb/\(a)/\(ab)/\(encoded)/\(width)px-\(encoded)"
    }

    private func md5Hash(_ string: String) -> String {
        let digest = Insecure.MD5.hash(data: Data(string.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - TMDB Search

    private func searchTMDBImages(name: String, limit: Int = 6) async -> [ImageResult] {
        guard let token = tmdbReadAccessToken, !token.isEmpty else { return [] }

        if limit == 1 {
            lastTMDBRequest = await waitForRateLimit(lastRequest: lastTMDBRequest, delay: TMDB.rateLimitDelay)
        }

        guard var components = URLComponents(string: TMDB.searchURL) else { return [] }
        components.queryItems = [URLQueryItem(name: "query", value: name)]
        guard let url = components.url else { return [] }

        do {
            var request = URLRequest(url: url)
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            request.setValue(AppInfo.userAgent, forHTTPHeaderField: "User-Agent")

            let (data, response) = try await fetch(request)
            guard let httpResponse = response as? HTTPURLResponse,
                  httpResponse.statusCode == 200,
                  let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let results = json["results"] as? [[String: Any]] else {
                return []
            }

            var images: [ImageResult] = []
            // Auto-fetch looks past the first hit: TMDB also matches aliases, so the
            // artist can sit under a real name (Хаски -> Dmitry Kuznetsov) further down.
            for result in results.prefix(limit == 1 ? 3 : limit) {
                guard let profilePath = result["profile_path"] as? String else { continue }

                // For auto-fetch, only accept the same name or an alias
                if limit == 1, !isNameMatch(query: name, result: result["name"] as? String ?? "") {
                    guard let personId = result["id"] as? Int,
                          await tmdbAliases(personId: personId, token: token).contains(where: { isNameMatch(query: name, result: $0) })
                    else { continue }
                }

                let imageUrlString = TMDB.imageBaseURL + profilePath

                if let imageData = await downloadImageData(from: imageUrlString) {
                    let label = limit == 1 ? "tmdb" : (result["name"] as? String).map { "tmdb – \($0)" } ?? "tmdb"
                    images.append(ImageResult(imageData: imageData, imageUrl: imageUrlString, source: label))
                    if limit == 1 { break }
                }
            }
            return images
        } catch {
            if isCancellation(error) { return [] }
            if error is URLError { networkErrors += 1 }
            Logger.error("TMDB error for '\(name)': \(error.localizedDescription)")
            return []
        }
    }

    private func tmdbAliases(personId: Int, token: String) async -> [String] {
        lastTMDBRequest = await waitForRateLimit(lastRequest: lastTMDBRequest, delay: TMDB.rateLimitDelay)

        guard let url = URL(string: "\(TMDB.personURL)/\(personId)") else { return [] }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(AppInfo.userAgent, forHTTPHeaderField: "User-Agent")

        do {
            let (data, _) = try await fetch(request)
            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            return json?["also_known_as"] as? [String] ?? []
        } catch {
            if error is URLError { networkErrors += 1 }
            return []
        }
    }

    // MARK: - Last.fm Bio

    private func fetchArtistBio(name: String) async -> String? {
        guard let apiKey = lastfmApiKey, !apiKey.isEmpty else { return nil }

        lastLastFMRequest = await waitForRateLimit(lastRequest: lastLastFMRequest, delay: LastFM.rateLimitDelay)

        guard var components = URLComponents(string: LastFM.apiBaseURL) else { return nil }
        components.queryItems = [
            URLQueryItem(name: "method", value: "artist.getinfo"),
            URLQueryItem(name: "artist", value: name),
            URLQueryItem(name: "api_key", value: apiKey),
            URLQueryItem(name: "format", value: "json")
        ]

        guard let url = components.url else { return nil }

        do {
            var request = URLRequest(url: url)
            request.setValue(AppInfo.userAgent, forHTTPHeaderField: "User-Agent")

            let (data, response) = try await fetch(request)
            guard let httpResponse = response as? HTTPURLResponse,
                  httpResponse.statusCode == 200 else {
                return nil
            }

            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let artist = json["artist"] as? [String: Any],
                  let bio = artist["bio"] as? [String: Any],
                  let content = bio["summary"] as? String else {
                return nil
            }

            // Last.fm appends a "Read more" link in HTML
            let cleaned = content
                .replacingOccurrences(of: "<a href=\".*?\">.*?</a>", with: "", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)

            return cleaned.isEmpty ? nil : cleaned
        } catch {
            if isCancellation(error) { return nil }
            if error is URLError { networkErrors += 1 }
            Logger.error("Last.fm bio error for '\(name)': \(error.localizedDescription)")
            return nil
        }
    }

    // MARK: - Helpers

    /// A cancelled URLSession request throws `URLError.cancelled`, not `CancellationError`,
    /// so the fetch task being restarted/cancelled would otherwise log as an error.
    private func isCancellation(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        if let urlError = error as? URLError, urlError.code == .cancelled { return true }
        return false
    }

    private func downloadImageData(from urlString: String) async -> Data? {
        guard let url = URL(string: urlString) else { return nil }
        guard let (data, response) = try? await fetch(URLRequest(url: url)),
              let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200,
              data.count >= Self.minimumImageSize else {
            return nil
        }
        return data
    }

    /// Same name, ignoring case, accents and character width ("Tyler， The
    /// Creator" from a fullwidth-comma tag is "Tyler, The Creator"). The whole
    /// name, not a substring: "Pilo" must not land on an actor called Kristaq Pilo.
    /// `URLSession` throws only for transport failures. A 429 or 5xx is the
    /// service being unavailable too, not an answer, so it also counts toward
    /// the offline breaker instead of stamping the artist as a miss.
    private func fetch(_ request: URLRequest) async throws -> (Data, URLResponse) {
        let (data, response) = try await AppInfo.urlSession.data(for: request)
        if let status = (response as? HTTPURLResponse)?.statusCode, status == 429 || status >= 500 {
            networkErrors += 1
        }
        return (data, response)
    }

    private func isNameMatch(query: String, result: String) -> Bool {
        let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive, .widthInsensitive]
        return query.compare(result, options: options) == .orderedSame
    }

    // MARK: - Rate Limiting

    /// Takes the previous timestamp by value and returns the new one for the
    /// caller to store, rather than `inout`: an actor-isolated stored property
    /// can't be passed `inout` across the `await` inside here (exclusive
    /// access can't span a suspension point), even though nothing else could
    /// actually touch it meanwhile.
    private func waitForRateLimit(lastRequest: Date?, delay: TimeInterval) async -> Date {
        if let last = lastRequest {
            let elapsed = Date().timeIntervalSince(last)
            let waitTime = delay - elapsed
            if waitTime > 0 {
                try? await Task.sleep(nanoseconds: UInt64(waitTime * 1_000_000_000))
            }
        }
        return Date()
    }
}
