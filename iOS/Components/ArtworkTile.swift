//
// ArtworkTile (iOS)
//
// The artwork slot every list row and card shares: the image when the row
// carries artwork data, a rounded placeholder with a music note otherwise.
// Rows only differ in size and corner radius, so those are the parameters.
//

import SwiftUI
import UIKit

struct ArtworkTile: View {
    let data: Data?
    var cornerRadius: CGFloat = 6
    var iconSize: CGFloat = 16
    var placeholderIcon: String = Icons.musicNote

    var body: some View {
        Group {
            if let data, let image = UIImage(data: data) {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                ZStack {
                    RoundedRectangle(cornerRadius: cornerRadius)
                        .fill(Color.secondary.opacity(0.12))
                    Image(systemName: placeholderIcon)
                        .font(.system(size: iconSize))
                        .foregroundColor(.secondary)
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
    }
}
