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
                ArtworkTile(data: nil, cornerRadius: 10, iconSize: 28)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private func tile(_ data: Data) -> some View {
        ArtworkTile(data: data, cornerRadius: 8)
    }
}
