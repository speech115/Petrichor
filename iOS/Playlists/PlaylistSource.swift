//
// PlaylistSource (iOS)
//
// Where an imported playlist came from. The library is built from M3U exports
// whose names carry the service they came from ("01 ВКонтакте",
// "05 Spotify - Shazam"), and the Playlists tab groups by that: one section
// per service, the service's mark in the section header.
//
// Two things decide a section's contents. A `pinned` list names the playlists
// that belong to a source explicitly, in the order they should appear, and may
// give a playlist its own cover; anything not pinned falls back to matching
// the service's name inside the playlist's own and sorts after the pinned ones.
// The pinned list exists because neither membership nor order is fully
// derivable: "Любимые треки" is a VK export that never says so, and the order
// the owner wants is not the order the exporter numbered them in.
//
// The number prefixes in those names are the exporter's sort keys, not part of
// what a playlist is called, so they are stripped for display while the stored
// name — what rename and lookup work on — is left alone.
//

import SwiftUI

enum PlaylistSource: CaseIterable {
    case spotify
    case vk
    case yandex

    /// Section title. These are brand names, not UI copy, so they are not
    /// localized — they read the same in every language.
    var title: String {
        switch self {
        case .spotify: return "Spotify"
        case .vk: return "VK"
        case .yandex: return "Яндекс Музыка"
        }
    }

    /// Case-insensitive markers that identify the service in a playlist name.
    private var markers: [String] {
        switch self {
        case .spotify: return ["spotify"]
        case .vk: return ["вконтакте", "vkontakte"]
        case .yandex: return ["яндекс", "yandex"]
        }
    }

    /// Playlists placed in this section by hand, in display order, matched on
    /// the display name (prefix already stripped), case-insensitively.
    var pinned: [PinnedPlaylist] {
        switch self {
        // The "Spotify - " these carry is the exporter repeating the section
        // header on every row, so the titles drop it.
        case .spotify:
            return [
                PinnedPlaylist("Spotify - Liked Songs", title: "Liked Songs", cover: .likedSongs),
                PinnedPlaylist("Spotify - Любимые песни", title: "Любимые песни (любимого) человека"),
                PinnedPlaylist("Spotify - Топ 2020", title: "Топ 2020", cover: .top2020),
                PinnedPlaylist("Spotify - Shazam", title: "Shazam", cover: .shazam)
            ]
        case .vk:
            return [
                PinnedPlaylist("ВКонтакте", cover: .vkMusic),
                PinnedPlaylist("Любимые треки"),
                PinnedPlaylist(
                    "ВКонтакте - Tyler instrumental",
                    title: "Tyler Instrumental",
                    cover: .tylerInstrumental
                ),
                PinnedPlaylist("ВКонтакте - Френки шоу", cover: .frankieShow)
            ]
        case .yandex:
            return [
                PinnedPlaylist("Яндекс Музыка", cover: .yandexLikes)
            ]
        }
    }

    /// When true the section shows its pinned playlists and nothing else:
    /// anything else that matched the service by name is left out of the
    /// Playlists tab entirely. Spotify and VK are curated that closely — their
    /// exports left behind lists their owner does not want on the phone.
    var showsOnlyPinned: Bool {
        switch self {
        case .spotify, .vk: return true
        case .yandex: return false
        }
    }

    /// Whether this playlist is shown at all. A strict section hides the
    /// exports it did not pin; nothing is deleted, and search still finds them.
    static func isHidden(_ playlist: Playlist) -> Bool {
        guard let source = of(playlist), source.showsOnlyPinned else { return false }
        return source.pinnedIndex(of: playlist) == nil
    }

    static func of(_ playlist: Playlist) -> PlaylistSource? {
        guard playlist.type == .regular else { return nil }
        if let pinned = allCases.first(where: { $0.pinnedIndex(of: playlist) != nil }) {
            return pinned
        }
        let name = playlist.name.lowercased()
        return allCases.first { source in
            source.markers.contains { name.contains($0) }
        }
    }

    /// Position in `pinned`, or nil when the playlist is not pinned here.
    func pinnedIndex(of playlist: Playlist) -> Int? {
        let name = PlaylistDisplay.storedName(for: playlist)
        return pinned.firstIndex { $0.name.compare(name, options: .caseInsensitive) == .orderedSame }
    }

    /// The pinned entry for this playlist, if it has one.
    static func pinnedEntry(for playlist: Playlist) -> PinnedPlaylist? {
        guard let source = of(playlist), let index = source.pinnedIndex(of: playlist) else { return nil }
        return source.pinned[index]
    }
}

struct PinnedPlaylist {
    /// The playlist's own name, as stored, minus the numeric prefix. This is
    /// what the entry matches on, so it has to keep tracking the library even
    /// when `title` renames the playlist on screen.
    let name: String
    /// What to show instead of `name`. Renaming here and not in the database
    /// keeps M3U re-imports, which key on the stored name, from splitting the
    /// playlist in two — the price is that the app's own Rename sheet still
    /// opens on the stored name.
    let title: String?
    let cover: PlaylistCover?

    init(_ name: String, title: String? = nil, cover: PlaylistCover? = nil) {
        self.name = name
        self.title = title
        self.cover = cover
    }
}

// MARK: - Display Name

enum PlaylistDisplay {
    /// The name to show: the pinned entry's title when it renames the
    /// playlist, otherwise its own stored name.
    static func name(for playlist: Playlist) -> String {
        PlaylistSource.pinnedEntry(for: playlist)?.title ?? storedName(for: playlist)
    }

    /// The playlist's own name with the exporter's numeric sort prefix
    /// removed. A number is only a prefix when a separator follows it, so
    /// "2000s Hits" keeps its name and "05 Spotify" loses its "05". This is
    /// what pinned entries match on — never the renamed title.
    static func storedName(for playlist: Playlist) -> String {
        let stored = DefaultPlaylists.displayName(for: playlist)
        guard let match = stored.firstMatch(of: prefix) else { return stored }
        let stripped = stored[match.range.upperBound...]
        return stripped.isEmpty ? stored : String(stripped)
    }

    private static let prefix = /^\d{1,3}[ ._-]+/
}

// MARK: - Logo

/// The service's mark on its brand tile, built the way the services build
/// their own app icons.
///
/// The marks are the official vectors, bundled in the asset catalog as
/// template images so the tile decides their color:
/// `logo-spotify` and `logo-vk` come from the brands' published SVGs, and
/// `logo-yandex-music` is the flash from `music.yandex.ru/favicon.svg` — the
/// 2024 rebrand's mark, not the note it replaced.
struct PlaylistSourceLogo: View {
    let source: PlaylistSource
    var cornerRadius: CGFloat = 8

    var body: some View {
        GeometryReader { geometry in
            let side = min(geometry.size.width, geometry.size.height)

            ZStack {
                source.tile
                Image(source.asset)
                    .resizable()
                    .renderingMode(.template)
                    .aspectRatio(contentMode: .fit)
                    .foregroundStyle(source.mark)
                    .frame(width: side * source.markScale, height: side * source.markScale)
            }
            .frame(width: side, height: side)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .accessibilityLabel(source.title)
    }
}

private extension PlaylistSource {
    var asset: String {
        switch self {
        case .spotify: return "logo-spotify"
        case .vk: return "logo-vk"
        case .yandex: return "logo-yandex-music"
        }
    }

    var tile: Color {
        switch self {
        case .spotify: return .black
        case .vk: return Color(red: 0.0, green: 0.467, blue: 1.0)
        case .yandex: return Color(red: 0.09, green: 0.06, blue: 0.05)
        }
    }

    var mark: Color {
        switch self {
        case .spotify: return Color(red: 0.118, green: 0.843, blue: 0.376)
        case .vk: return .white
        case .yandex: return Color(red: 1.0, green: 0.737, blue: 0.051)
        }
    }

    /// How much of the tile the mark's own artboard fills. The three vectors
    /// frame their marks differently — Spotify's fills its box edge to edge,
    /// VK's and Yandex's sit inside padding of their own — so the scale is per
    /// source rather than one shared number.
    var markScale: CGFloat {
        switch self {
        case .spotify: return 0.76
        case .vk: return 0.96
        case .yandex: return 1.08
        }
    }
}
