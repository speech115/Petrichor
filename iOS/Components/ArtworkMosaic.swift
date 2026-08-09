//
// ArtworkMosaic (iOS)
//
// 2x2 mosaic of the first four covers for playlist cards and playlist
// headers; fewer covers show the first one, none - a placeholder.
//

import SwiftUI
import UIKit

struct ArtworkMosaic: View {
    let covers: [Data]

    var body: some View {
        Group {
            if covers.count >= 4 {
                LazyVGrid(
                    columns: [
                        GridItem(.flexible(), spacing: 2),
                        GridItem(.flexible(), spacing: 2)
                    ],
                    spacing: 2
                ) {
                    ForEach(Array(covers.prefix(4).enumerated()), id: \.offset) { _, data in
                        tile(data)
                    }
                }
            } else if let cover = covers.first {
                tile(cover)
            } else {
                ArtworkTile(data: nil, cornerRadius: 10, iconSize: 28, isDecorative: true)
            }
        }
        // Square first, then clip: `clipShape` cuts to the view's own bounds,
        // so a branch that laid out wider than its frame would be clipped to
        // the wrong, wider rectangle and still bleed over the row beside it.
        .aspectRatio(1, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    /// The square belongs on the tile: a resizable image has no intrinsic size
    /// to bound the grid's row height, so a non-square cover makes the grid
    /// grow past the frame it was given and spill over its neighbours.
    private func tile(_ data: Data) -> some View {
        ArtworkTile(data: data, cornerRadius: 8, isDecorative: true)
            .aspectRatio(1, contentMode: .fit)
    }
}
