//
// FolderRowView (iOS)
//
// The folder row reused at every level of the tree: name and a subtitle with
// the folder and track counts, mirroring the macOS sidebar's format.
//

import SwiftUI

struct FolderRowView: View {
    @ObservedObject var node: FolderNode

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: Icons.folderFill)
                .foregroundColor(.accentColor)

            VStack(alignment: .leading, spacing: 2) {
                Text(node.name)
                    .lineLimit(1)
                if let subtitle {
                    Text(subtitle)
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 0)
        }
    }

    private var subtitle: String? {
        let folderCount = node.immediateFolderCount
        let trackCount = node.displayTrackCount
        if folderCount > 0 && trackCount > 0 {
            return String(localized: "\(folderCount) folders, \(trackCount) tracks")
        } else if folderCount > 0 {
            return String(localized: "\(folderCount) folders")
        } else if trackCount > 0 {
            return String(localized: "\(trackCount) tracks")
        }
        return nil
    }
}
