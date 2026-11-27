//
//  ArtistBioManager.swift
//  Petrichor
//
//  Handles fetching artist photos and bios and storing them in the database.
//  Apple Music comes first for both; MusicBrainz/Wikidata and TMDB (photos)
//  and Last.fm (bios) fill in for an artist Apple Music has nothing on.
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

    /// The iTunes Search API finds the artist (about 20 requests a minute
    /// are allowed); the public artist page carries the photo and the bio.
    /// The Russian storefront has Russian bios of Russian artists and no bio
    /// of many others, which the US storefront has in English.
    private enum AppleMusic {
        static let searchURL = "https://itunes.apple.com/search"
        static let lookupURL = "https://itunes.apple.com/lookup"
        static let pageURL = "https://music.apple.com"
        static let storefronts = ["ru", "us"]
        static let searchDelay: TimeInterval = 3.1
        static let pageDelay: TimeInterval = 1.0
    }

    private enum LastFM {
        static let apiBaseURL = "https://ws.audioscrobbler.com/2.0/"
        static let rateLimitDelay: TimeInterval = 0.25
    }

    private enum UserDefaultsKeys {
        static let artistInfoFetchEnabled = "artistInfoFetchEnabled"
        static let lastFetchStart = "artistInfoFetchLastStart"
    }

    /// A run walks every artist still without a photo at about one request a
    /// second; every launch and every library reload used to start one from
    /// the top, and the same artists were asked again and again (11 000
    /// requests in a week on one phone). One run per this interval is enough.
    private static let minimumRunInterval: TimeInterval = 4 * 60 * 60

    // MARK: - Properties

    private var fetchTask: Task<Void, Never>?
    private var lastMusicBrainzRequest: Date?
    private var lastWikimediaRequest: Date?
    private var lastTMDBRequest: Date?
    private var lastLastFMRequest: Date?
    private var lastITunesRequest: Date?
    private var lastAppleMusicPageRequest: Date?
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

    private struct AppleMusicInfo {
        let image: ImageResult?
        let bio: String?
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
        // Checked before the cancel: a second trigger (scan, refresh, Settings)
        // must leave a run that started recently alone, not cut it short and
        // then refuse to start another.
        let lastStart = UserDefaults.standard.object(forKey: UserDefaultsKeys.lastFetchStart) as? Date
        guard ArtistInfoSource.isRunDue(lastStart: lastStart, now: Date(), interval: Self.minimumRunInterval) else {
            Logger.info("Artist info fetch ran recently, skipping")
            return
        }
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
            // Stamped only once there is work: before the first scan the query
            // is empty, and that attempt must not consume the interval.
            UserDefaults.standard.set(Date(), forKey: UserDefaultsKeys.lastFetchStart)

            Logger.info("Starting fetch for \(artists.count) artists")

            // Stop a doomed run (offline / APIs down) instead of timing out on every
            // artist. Only transport errors count: an empty answer means the artist
            // has no data there, which is stamped and retried in 7 days.
            let maxConsecutiveFailures = 10
            var consecutiveFailures = 0

            for artist in artists {
                guard !Task.isCancelled, self.isArtistInfoFetchEnabled else {
                    Logger.info("Fetch stopped")
                    break
                }

                Logger.info("Fetching info for '\(artist.name)' (image: \(artist.wantsImage), bio: \(artist.wantsBio))")
                // Failures are tracked per field, so a bio that arrived doesn't turn an
                // image request that failed in transit into a month-long miss.
                var errorsBefore = await self.networkErrors
                let apple = await self.fetchAppleMusicInfo(name: artist.name) {
                    databaseManager.getAlbumTitles(artistId: artist.id)
                }
                let appleFailed = await self.networkErrors != errorsBefore

                // The old sources only fill a gap: an artist that already has a
                // photo or bio from them keeps it when Apple Music has none.
                errorsBefore = await self.networkErrors
                var imageResult = artist.wantsImage ? apple?.image : nil
                if artist.wantsImage, imageResult == nil, !artist.hasImage {
                    imageResult = await self.fetchArtistImage(name: artist.name)
                }
                let imageErrorsAfter = await self.networkErrors
                let imageFailed = appleFailed || imageErrorsAfter != errorsBefore

                errorsBefore = await self.networkErrors
                var bio = artist.wantsBio ? apple?.bio : nil
                var bioSource = ArtistInfoSource.appleMusic
                if artist.wantsBio, bio == nil, !artist.hasBio {
                    bio = await self.fetchArtistBio(name: artist.name)
                    bioSource = "last.fm"
                }
                let bioErrorsAfter = await self.networkErrors
                let bioFailed = appleFailed || bioErrorsAfter != errorsBefore

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
                        bioSource: bio != nil ? bioSource : nil
                    )
                } else if let bio {
                    databaseManager.updateArtistInfo(artistId: artist.id, bio: bio, bioSource: bioSource)
                }

                if (imageFailed || bioFailed) && imageResult == nil && bio == nil {
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
                    // stays unstamped so it retries rather than being skipped.)
                    if artist.wantsImage && imageResult == nil && !imageFailed {
                        databaseManager.markArtistImageFetchFailed(artistId: artist.id)
                    }
                    if artist.wantsBio && bio == nil && !bioFailed {
                        databaseManager.markArtistBioFetchFailed(artistId: artist.id)
                    }
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

    // MARK: - Apple Music

    /// The artist's Apple Music photo and bio, or nil when the catalog has no
    /// artist that is surely this one. The bio is taken from the first
    /// storefront that has one; the photo is the same in all of them.
    private func fetchAppleMusicInfo(name: String, libraryAlbums: @Sendable () -> [String]) async -> AppleMusicInfo? {
        guard var components = URLComponents(string: AppleMusic.searchURL) else { return nil }
        components.queryItems = [
            URLQueryItem(name: "term", value: name),
            URLQueryItem(name: "entity", value: "musicArtist"),
            URLQueryItem(name: "limit", value: "10"),
            URLQueryItem(name: "country", value: AppleMusic.storefronts[0])
        ]
        guard let searchURL = components.url,
              let searchData = await appleMusicData(searchURL, isSearch: true) else { return nil }

        let candidates = AppleMusicArtist.candidates(fromSearch: searchData)
        // Albums are looked up only to tell same-named artists apart, for at
        // most three of them; with more, the pick stays undecided.
        let named = AppleMusicArtist.sameName(as: name, in: candidates)
        var lookups: [Int: [String]] = [:]
        if named.count > 1 {
            for candidate in named.prefix(3) {
                lookups[candidate.id] = await catalogAlbums(artistId: candidate.id)
            }
        }
        guard let artist = AppleMusicArtist.pick(
            name: name,
            candidates: candidates,
            catalogAlbums: { lookups[$0.id] },
            libraryAlbums: lookups.isEmpty ? [] : libraryAlbums()
        ) else { return nil }

        var imageURL: URL?
        var bio: String?
        for storefront in AppleMusic.storefronts {
            guard let pageURL = URL(string: "\(AppleMusic.pageURL)/\(storefront)/artist/\(artist.id)"),
                  let pageData = await appleMusicData(pageURL, isSearch: false),
                  let html = String(bytes: pageData, encoding: .utf8),
                  let page = AppleMusicArtist.parsePage(html: html) else { continue }
            imageURL = imageURL ?? page.imageURL
            bio = page.bio
            if bio != nil { break }
        }

        var image: ImageResult?
        if let imageURL, let data = await downloadImageData(from: imageURL.absoluteString) {
            image = ImageResult(imageData: data, imageUrl: imageURL.absoluteString, source: ArtistInfoSource.appleMusic)
        }
        return AppleMusicInfo(image: image, bio: bio)
    }

    private func catalogAlbums(artistId: Int) async -> [String] {
        guard var components = URLComponents(string: AppleMusic.lookupURL) else { return [] }
        components.queryItems = [
            URLQueryItem(name: "id", value: String(artistId)),
            URLQueryItem(name: "entity", value: "album"),
            URLQueryItem(name: "limit", value: "200"),
            URLQueryItem(name: "country", value: AppleMusic.storefronts[0])
        ]
        guard let url = components.url, let data = await appleMusicData(url, isSearch: true) else { return [] }
        return AppleMusicArtist.albumTitles(fromLookup: data)
    }

    /// The body of a 200 answer, rate-limited per host; nil otherwise. A 404
    /// page (an artist the storefront doesn't carry) is an empty answer.
    private func appleMusicData(_ url: URL, isSearch: Bool) async -> Data? {
        if isSearch {
            lastITunesRequest = await waitForRateLimit(lastRequest: lastITunesRequest, delay: AppleMusic.searchDelay)
        } else {
            lastAppleMusicPageRequest = await waitForRateLimit(
                lastRequest: lastAppleMusicPageRequest,
                delay: AppleMusic.pageDelay
            )
        }
        var request = URLRequest(url: url)
        request.setValue(AppInfo.userAgent, forHTTPHeaderField: "User-Agent")
        do {
            let (data, response) = try await fetch(request)
            return (response as? HTTPURLResponse)?.statusCode == 200 ? data : nil
        } catch {
            if isCancellation(error) { return nil }
            if error is URLError { networkErrors += 1 }
            Logger.error("Apple Music error for '\(url.absoluteString)': \(error.localizedDescription)")
            return nil
        }
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
