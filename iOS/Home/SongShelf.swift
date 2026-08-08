//
// SongShelf (iOS)
//
// A horizontal grid of songs, four rows deep - the hit-parade pattern from
// Apple Music. Rows are compact (42 pt artwork, title, artist): no swipes,
// no playing indicator, this is a show window, not a list. The section
// title links to the full list; a tap plays the track in the context of the
// whole selection.
//
// The component is generic over title and destination so a future Home
// section of songs can reuse it as-is.
//

import SwiftUI

struct SongShelf: View {
    let title: String
    let destination: LibraryDestination
    let tracks: [Track]
    let onPlay: (Track) -> Void

    private static let columnWidth: CGFloat = 288
    private static let rowHeight: CGFloat = 48
    private static let columnCount = 4
    /// Three columns of four rows; the rest lives behind the section link.
    private static let displayLimit = 12

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeaderLink(title: title, value: destination)

            ScrollView(.horizontal, showsIndicators: false) {
                LazyHGrid(
                    rows: Array(
                        repeating: GridItem(.fixed(Self.rowHeight), spacing: 8),
                        count: Self.columnCount
                    ),
                    spacing: 12
                ) {
                    ForEach(tracks.prefix(Self.displayLimit)) { track in
                        row(track)
                    }
                }
                .padding(.horizontal, 16)
            }
        }
    }

    private func row(_ track: Track) -> some View {
        Button {
            onPlay(track)
        } label: {
            HStack(spacing: 10) {
                ArtworkTile(data: track.displayArtwork, cacheKey: track.albumId.map(String.init), cornerRadius: 6)
                    .frame(width: 42, height: 42)

                VStack(alignment: .leading, spacing: 2) {
                    Text(track.title)
                        .font(.subheadline.weight(.medium))
                        .lineLimit(1)
                    Text(track.displayArtist)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 0)
            }
            .frame(width: Self.columnWidth, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
