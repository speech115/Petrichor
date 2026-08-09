//
// TrackInfoSheet (iOS)
//
// Everything the database knows about one track, as a phone sheet: the cover,
// the names, a Details list and a File Details group that stays folded until
// asked for. The row that opens it is "Show Info" in the track menu.
//
// The list rows come from `FullTrack`, which carries the columns the library's
// list queries deliberately leave behind — bitrate, codec, file size, play
// counts. It is loaded on appearance rather than carried by the row, so
// opening a list never pays for metadata no list shows.
//

import SwiftUI

struct TrackInfoSheet: View {
    let track: Track

    @EnvironmentObject private var libraryManager: LibraryManager
    @Environment(\.dismiss) private var dismiss

    @State private var fullTrack: FullTrack?
    @State private var loadFailed = false

    var body: some View {
        NavigationStack {
            Group {
                if let fullTrack {
                    details(for: fullTrack)
                } else if loadFailed {
                    unavailable
                } else {
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .navigationTitle(String(localized: "Track Info"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(String(localized: "Done")) { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
        // Opaque, not the default glass: at the half detent a busy track list
        // or the player's artwork showed through and the labels turned to mud.
        .presentationBackground(Color(.systemGroupedBackground))
        .task(id: track.id) {
            await load()
        }
    }

    // MARK: - Content

    private func details(for fullTrack: FullTrack) -> some View {
        List {
            Section {
                header(for: fullTrack)
                    .frame(maxWidth: .infinity)
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            }

            let items = TrackInfoFields.details(for: fullTrack)
            if !items.isEmpty {
                Section(String(localized: "Details")) {
                    ForEach(items) { item in
                        LabeledContent(item.label, value: item.value)
                    }
                }
            }

            Section {
                DisclosureGroup(String(localized: "File Details")) {
                    ForEach(TrackInfoFields.file(for: fullTrack)) { item in
                        LabeledContent(item.label) {
                            Text(item.value)
                                .multilineTextAlignment(.trailing)
                                .textSelection(.enabled)
                        }
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
    }

    private func header(for fullTrack: FullTrack) -> some View {
        VStack(spacing: 10) {
            ArtworkTile(
                data: fullTrack.artworkData,
                cacheKey: fullTrack.trackId.map { "track-info-\($0)" },
                cornerRadius: 10,
                iconSize: 48,
                maxPixelSize: 600,
                // The names under the cover say what this is.
                isDecorative: true
            )
            .frame(width: 180, height: 180)
            .shadow(color: .black.opacity(0.18), radius: 10, y: 5)

            VStack(spacing: 2) {
                Text(fullTrack.title)
                    .font(.headline)
                Text(LibraryFilterType.artists.localizedDisplay(fullTrack.artist))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                if !fullTrack.album.isEmpty, fullTrack.album != "Unknown Album" {
                    Text(fullTrack.album)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            .multilineTextAlignment(.center)
            .textSelection(.enabled)
        }
        .padding(.vertical, 8)
    }

    private var unavailable: some View {
        ContentUnavailableView(
            String(localized: "Unable to Load Track Details"),
            systemImage: "exclamationmark.triangle"
        )
    }

    // MARK: - Loading

    private func load() async {
        do {
            let loaded = try await libraryManager.fullTrack(for: track)
            fullTrack = loaded
            loadFailed = loaded == nil
        } catch {
            Logger.error("Failed to load track details: \(error)")
            loadFailed = true
        }
    }
}

// MARK: - Fields

/// The label/value rows, kept apart from the view so the ordering reads as one
/// list instead of being spread through a body.
enum TrackInfoFields {
    struct Item: Identifiable {
        let label: String
        let value: String

        var id: String { label }
    }

    static func details(for track: FullTrack) -> [Item] {
        var items: [Item] = []

        if let albumArtist = track.albumArtist, !albumArtist.isEmpty {
            items.append(Item(label: String(localized: "Album Artist"), value: albumArtist))
        }

        items.append(Item(
            label: String(localized: "Duration"),
            value: HelperUtils.formattedShortDuration(track.duration)
        ))

        if let trackNumber = track.trackNumber {
            items.append(Item(
                label: String(localized: "Track"),
                value: track.totalTracks.map { String(localized: "\(trackNumber) of \($0)") } ?? "\(trackNumber)"
            ))
        }

        if let discNumber = track.discNumber {
            items.append(Item(
                label: String(localized: "Disc"),
                value: track.totalDiscs.map { String(localized: "\(discNumber) of \($0)") } ?? "\(discNumber)"
            ))
        }

        appendIfKnown(String(localized: "Genre"), track.genre, unknown: "Unknown Genre", to: &items)
        appendIfKnown(String(localized: "Year"), track.year, unknown: "Unknown Year", to: &items)
        appendIfKnown(String(localized: "Composer"), track.composer, unknown: "Unknown Composer", to: &items)

        if let releaseDate = track.releaseDate, !releaseDate.isEmpty {
            items.append(Item(label: String(localized: "Release Date"), value: releaseDate))
        }

        if let extended = track.extendedMetadata {
            for (label, value) in [
                (String(localized: "Conductor"), extended.conductor),
                (String(localized: "Producer"), extended.producer),
                (String(localized: "Label"), extended.label),
                (String(localized: "Publisher"), extended.publisher),
                (String(localized: "ISRC"), extended.isrc)
            ] {
                if let value, !value.isEmpty {
                    items.append(Item(label: label, value: value))
                }
            }
        }

        if let bpm = track.bpm, bpm > 0 {
            items.append(Item(label: String(localized: "BPM"), value: "\(bpm)"))
        }

        if track.playCount > 0 {
            items.append(Item(label: String(localized: "Play Count"), value: "\(track.playCount)"))
        }

        if let lastPlayed = track.lastPlayedDate {
            items.append(Item(label: String(localized: "Last Played"), value: formatted(lastPlayed)))
        }

        return items
    }

    static func file(for track: FullTrack) -> [Item] {
        var items: [Item] = [
            Item(label: String(localized: "Format"), value: track.format.uppercased())
        ]

        if let codec = track.codecDisplay {
            items.append(Item(label: String(localized: "Codec"), value: codec))
        }

        if let bitrate = track.bitrateDisplay {
            items.append(Item(label: String(localized: "Bitrate"), value: bitrate))
        }

        if let sampleRate = track.sampleRateDisplay {
            items.append(Item(label: String(localized: "Sample Rate"), value: sampleRate))
        }

        if let bitDepth = track.bitDepth, bitDepth > 0 {
            items.append(Item(label: String(localized: "Bit Depth"), value: String(localized: "\(bitDepth)-bit")))
        }

        if let channels = track.channelsDisplay {
            items.append(Item(label: String(localized: "Channels"), value: channels))
        }

        if let fileSize = track.fileSize, fileSize > 0 {
            items.append(Item(
                label: String(localized: "File Size"),
                value: ByteCountFormatter.string(fromByteCount: fileSize, countStyle: .file)
            ))
        }

        items.append(Item(label: String(localized: "File Path"), value: track.url.path))

        if let dateAdded = track.dateAdded {
            items.append(Item(label: String(localized: "Date Added"), value: formatted(dateAdded)))
        }

        return items
    }

    private static func appendIfKnown(
        _ label: String,
        _ value: String,
        unknown: String,
        to items: inout [Item]
    ) {
        guard !value.isEmpty, value != unknown else { return }
        items.append(Item(label: label, value: value))
    }

    private static func formatted(_ date: Date) -> String {
        date.formatted(date: .abbreviated, time: .shortened)
    }
}
