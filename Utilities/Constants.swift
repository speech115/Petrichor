import Foundation

// MARK: - Icons

enum Icons {
    // Music & Audio
    static let musicNote = "music.note"
    static let musicNoteList = "music.note.list"
    static let smartPlaylist = "custom.music.note.gear"
    static let musicNoteHouse = "music.note.house"
    static let musicNoteHouseFill = "music.note.house.fill"
    static let musicPagesFill = "custom.music.pages.fill"
    
    // Playback Controls
    static let star = "star"
    static let playFill = "play.fill"
    static let pauseFill = "pause.fill"
    static let playPauseFill = "playpause.fill"
    static let playCircleFill = "play.circle.fill"
    static let pauseCircleFill = "pause.circle.fill"
    static let backwardFill = "backward.fill"
    static let previousFIll = "backward.end.alt.fill"
    static let forwardFill = "forward.fill"
    static let nextFill = "forward.end.alt.fill"
    static let shuffleFill = "shuffle"
    static let repeatFill = "repeat"
    static let repeat1Fill = "repeat.1"
    static let volumeIncrease = "speaker.plus.fill"
    static let volumeDecrease = "speaker.minus.fill"
    
    // Navigation
    static let chevronRight = "chevron.right"
    static let chevronDown = "chevron.down"
    static let xmarkCircleFill = "xmark.circle.fill"
    
    // File & Folder
    static let folder = "folder"
    static let folderFill = "folder.fill"
    static let folderBadgePlus = "folder.badge.plus"
    static let folderFillBadgePlus = "folder.fill.badge.plus"
    static let folderFillBadgeMinus = "folder.fill.badge.minus"
    
    // UI Elements
    static let sparkles = "sparkles"
    static let settings = "gear"
    static let edit = "square.and.pencil"
    static let magnifyingGlass = "magnifyingglass"
    static let checkmarkSquareFill = "checkmark.square.fill"
    static let square = "square"
    static let trash = "trash"
    static let infoCircle = "info.circle"
    static let questionmarkCircle = "questionmark.circle"
    static let plusCircle = "plus.circle"
    static let checkForUpdates = "square.and.arrow.down"
    static let chartUptrendFill = "chart.line.uptrend.xyaxis.circle.fill"
    static let infoCircleFill = "info.circle.fill"
    static let plusCircleFill = "plus.circle.fill"
    static let minusSquareFill = "minus.square.fill"
    static let minusCircleFill = "minus.circle.fill"
    static let arrowClockwise = "arrow.clockwise"
    static let arrowClockwiseCircle = "arrow.clockwise.circle"
    static let globe = "globe"
    static let paintpalette = "paintpalette"

    // Entity Icons
    static let personFill = "person.fill"
    static let person2Fill = "person.2.fill"
    static let person2CropSquareStackFill = "person.2.crop.square.stack.fill"
    static let person2Wave2Fill = "person.2.wave.2.fill"
    static let opticalDiscFill = "opticaldisc.fill"
    static let calendarBadgeClock = "calendar.badge.clock"
    static let calendarCircleFill = "calendar.circle.fill"
    
    // Smart Playlist Icons
    static let starFill = "star.fill"
    static let starSlash = "star.slash"
    static let clockFill = "clock.fill"
    
    // Sort Icons
    static let sortAscending = "sort.ascending"
    static let sortDescending = "sort.descending"

    // Mini/Immersive Player
    static let miniPlayer = "pip.enter"
    static let immersive = "arrow.up.left.and.arrow.down.right.square"
    static let queueList = "list.bullet"

    // Custom Icons (from project assets)
    static let customLossless = "custom.lossless"
    static let customMusicNoteRectangleStack = "custom.music.note.rectangle.stack"
    static let customMusicNoteRectangleStackFill = "custom.music.note.rectangle.stack.fill"
    static let customLyrics = "custom.music.microphone.bubble.right"
}

// MARK: - About

enum About {
    static let bundleIdentifier = "org.Petrichor"
    static let appTitle = "Petrichor"
    static let appSubtitle = "An offline macOS music player"
    static let appWebsite = "https://petrichor.page"
    static let appFAQ = "https://petrichor.page/faq/"
    static let appRepository = "https://github.com/kushalpandya/Petrichor"
    static let appWiki = "https://github.com/kushalpandya/Petrichor/wiki"
    static let reportIssue = "https://github.com/kushalpandya/Petrichor/issues/new/choose"
    static let donate = "https://www.petrichor.page/donate/"
    static let appVersion = "1.6.1"
    static let appBuild = "161"
    static let knownArtistsSampleFile = "known_artists_YYYYMMDD.txt"
}

// MARK: - Audio File Formats

enum AudioFormat {
    // The file extensions Petrichor imports and plays: the engine's real decode
    // capability, so this cannot drift from what actually plays, minus the two
    // exclusion lists below.
    static let supportedExtensions: [String] = {
        let excluded = Set(unsupportedExtensions).union(withheldExtensions)
        let extensions = MetadataEngine.supportedFileExtensions
            .filter { !excluded.contains($0) }
            .sorted()
        if extensions.isEmpty {
            // A scan would silently import nothing, so make the cause obvious.
            Logger.error("Playback engine reported no decodable formats; no audio files will be imported")
        }
        return extensions
    }()

    // Lookup form for `isSupported`, which a scan calls once per file.
    private static let supportedExtensionSet = Set(supportedExtensions)

    // Formats the engine cannot decode
    static let unsupportedExtensions = [
        // DRM'd or container forms the engine deliberately declines
        "m4b", "m4p", "aa", "aax",
        // Tracker modules: not decodable by Crescendo
        "mod", "it", "s3m", "xm",
        // Never supported
        "ra", "ram", "mid", "midi"
    ]

    // Decodable, but withheld because the engine reports no duration for them, so
    // they would import as tracks that play yet show 0:00 and cannot be seeked.
    static let withheldExtensions = ["thd", "mlp", "aifc"]

    static var supportedFormatsDisplay: String {
        let exts = supportedExtensions.map { $0.uppercased() }
        guard exts.count > 1 else { return exts.first ?? "" }
        return ListFormatter.localizedString(byJoining: exts)
    }

    static func isSupported(_ fileExtension: String) -> Bool {
        supportedExtensionSet.contains(fileExtension.lowercased())
    }
    
    static func isNotSupported(_ fileExtension: String) -> Bool {
        let ext = fileExtension.lowercased()
        return unsupportedExtensions.contains(ext) || withheldExtensions.contains(ext)
    }
}

// MARK: - Artwork File Formats

enum AlbumArtFormat {
    static let supportedExtensions = ["jpg", "jpeg", "png", "tiff", "tif", "bmp"]
    
    static let knownFilenames = [
        "cover", "Cover",
        "folder", "Folder",
        "album", "Album",
        "artwork", "Artwork",
        "front", "Front"
    ]
    
    static let maxArtworkSize: Int = 20 * 1024 * 1024
    static let maxArtworkPixelDimension: Int = 8000

    static func isSupported(_ fileExtension: String) -> Bool {
        supportedExtensions.contains(fileExtension.lowercased())
    }
}

// MARK: - View Defaults

enum ViewDefaults {
    static let listArtworkSize: CGFloat = 40
    static let gridArtworkSize: CGFloat = 160
}

// MARK: - Window Identifiers

enum WindowIdentifier {
    static let mainWindow = "MainWindow"
}

// MARK: - String Formats

enum StringFormat {
    static let hhmmss: String = "%d:%02d:%02d"
    static let mmss: String = "%d:%02d"
    static let logEntryFormat: String = "yyyy-MM-dd HH:mm:ss.SSS"
}

// MARK: - Animation Durations

enum AnimationDuration {
    static let quickDuration: TimeInterval = 0.1
    static let standardDuration: TimeInterval = 0.15
    static let mediumDuration: TimeInterval = 0.2
    static let immersiveTransition: TimeInterval = 0.25
}

// MARK: - Delay Durations

enum TimeConstants {
    static let fiftyMilliseconds: UInt64 = 50_000_000
    static let oneHundredMilliseconds: UInt64 = 100_000_000
    static let searchDebounceDuration: UInt64 = 350_000_000

    /// Long enough to clear the system zoom transition, so work deferred past
    /// the open animation (fine scrubber sampling) never fights
    /// `matchedTransitionSource` on the main thread. The measured zoom is
    /// ~480ms, so this sits a comfortable margin past it.
    static let zoomTransitionSettle: TimeInterval = 0.6

    /// Defer for detail-header dominant-color extraction so it doesn't compete
    /// with the open transition.
    static let headerTintDefer: TimeInterval = 0.32

    /// Filesystem clock-jitter tolerance for mtime comparisons: a file modified
    /// within this window of its stored scan time reads as unchanged.
    static let filesystemMtimeTolerance: TimeInterval = 1.0
}

// MARK: - Default Playlists

enum DefaultPlaylists {
    static let favorites = "Favorites"
    static let mostPlayed = "Top 25 Most Played"
    static let recentlyPlayed = "Top 25 Recently Played"
}

/// Regular playlists the owner keeps as library stand-ins.
enum LibraryPlaylists {
    /// M3U export of the library. Home/Library "Songs" / "All Tracks" show this
    /// playlist's size when it exists, so the number matches the Playlists tab.
    static let allTracks = "Все треки"
}

extension DefaultPlaylists {
    static func displayName(for playlist: Playlist) -> String {
        guard playlist.type == .smart && !playlist.isUserEditable else { return playlist.name }
        return displayName(forStoredName: playlist.name)
    }

    static func displayName(forStoredName name: String) -> String {
        switch name {
        case DefaultPlaylists.favorites:
            return String(localized: "Favorites")
        case DefaultPlaylists.mostPlayed:
            return String(localized: "Top 25 Most Played")
        case DefaultPlaylists.recentlyPlayed:
            return String(localized: "Top 25 Recently Played")
        default:
            return name
        }
    }

    static func noSongsText(for playlist: Playlist) -> String {
        if playlist.type == .smart && !playlist.isUserEditable {
            switch playlist.name {
            case DefaultPlaylists.favorites:
                return String(localized: "No Favorite Songs")
            case DefaultPlaylists.mostPlayed:
                return String(localized: "No Frequently Played Songs")
            case DefaultPlaylists.recentlyPlayed:
                return String(localized: "No Recently Played Songs")
            default:
                return String(localized: "Empty Smart Playlist")
            }
        }
        return String(localized: "Empty Playlist")
    }
    
    static func emptyStateText(for playlist: Playlist) -> String {
        if playlist.type == .smart && !playlist.isUserEditable {
            switch playlist.name {
            case DefaultPlaylists.favorites:
                return String(localized: "Mark songs as favorites to see them here")
            case DefaultPlaylists.mostPlayed:
                return String(localized: "Songs played 5 or more times will appear here")
            case DefaultPlaylists.recentlyPlayed:
                return String(localized: "Songs played in the last week will appear here")
            default:
                return String(localized: "This smart playlist will update automatically based on its criteria")
            }
        }
        return String(localized: "Add some tracks to this playlist to get started")
    }
}

// MARK: - Global Event Notifications

extension Notification.Name {
    static let initialScanStarted = Notification.Name("initialScanStarted")
    static let checkInitialScanThreshold = Notification.Name("checkInitialScanThreshold")
    static let initialScanCompleted = Notification.Name("initialScanCompleted")
    static let foldersAddedToDatabase = Notification.Name("foldersAddedToDatabase")

    static let showFolderImporter = Notification.Name("showFolderImporter")

    static let libraryDataDidChange = Notification.Name("LibraryDataDidChange")
    /// The database was wiped and re-migrated (`DatabaseManager.resetDatabase()`
    /// via `LibraryManager.resetAllData()`): row ids restart from 1, so a
    /// listener that tracks state keyed by id (`iOS/SpotlightIndexer.swift`)
    /// must drop that state outright rather than diff it - a reused id could
    /// otherwise be misread as "unchanged" against stale data from before
    /// the reset. Distinct from `.libraryDataDidChange`, which means "diff
    /// the live database against what you know", not "what you know no
    /// longer means anything".
    static let libraryDataDidReset = Notification.Name("LibraryDataDidReset")
    static let goToLibraryFilter = Notification.Name("GoToLibraryFilter")
    static let showTrackInfo = Notification.Name("ShowTrackInfo")

    static let selectPlaylist = Notification.Name("SelectPlaylist")
    static let importPlaylists = Notification.Name("ImportPlaylists")
    static let exportPlaylists = Notification.Name("ExportPlaylists")
    
    static let navigateToPlaylists = Notification.Name("navigateToPlaylists")
    
    static let playEntityTracks = Notification.Name("playEntityTracks")
    static let playPlaylistTracks = Notification.Name("playPlaylistTracks")
    static let trackTableSortChanged = Notification.Name("trackTableSortChanged")
    static let trackTableRowSizeChanged = Notification.Name("trackTableRowSizeChanged")
    static let trackFavoriteStatusChanged = Notification.Name("trackFavoriteStatusChanged")
    static let createPlaylistFromSelection = Notification.Name("createPlaylistFromSelection")
    
    static let focusSearchField = Notification.Name("FocusSearchField")

    static let toggleImmersivePlayer = Notification.Name("ToggleImmersivePlayer")
}

// MARK: - Icon Helpers

extension Icons {
    static func repeatIcon(for mode: RepeatMode) -> String {
        switch mode {
        case .off:
            return Icons.repeatFill
        case .one:
            return Icons.repeat1Fill
        case .all:
            return Icons.repeatFill
        }
    }
    
    static func sortIcon(for isAscending: Bool) -> String {
        isAscending ? Icons.sortAscending : Icons.sortDescending
    }
    
    static func entityIcon(for entity: any Entity) -> String {
        if entity is ArtistEntity {
            return Icons.personFill
        } else if entity is AlbumEntity {
            return Icons.opticalDiscFill
        }
        return Icons.musicNote
    }
    
    static func defaultPlaylistIcon(for playlist: Playlist) -> String {
        if playlist.type == .smart {
            if !playlist.isUserEditable {
                switch playlist.name {
                case DefaultPlaylists.favorites:
                    return Icons.starFill
                case DefaultPlaylists.mostPlayed:
                    return Icons.chartUptrendFill
                case DefaultPlaylists.recentlyPlayed:
                    return Icons.clockFill
                default:
                    return Icons.smartPlaylist
                }
            }
            // User-created smart playlists use the dedicated smart-playlist symbol
            return Icons.smartPlaylist
        }

        return Icons.musicNoteList
    }
}
