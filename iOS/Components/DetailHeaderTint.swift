//
// DetailHeaderTint (iOS)
//
// Artwork-derived header tint for the detail pages (album / artist / playlist).
// Owns the `useArtworkColors` preference and the dominant-color extraction, and
// writes the resolved `Color?` into a binding the screen hands to `DetailHeader`
// and `.detailPageWash`. Replaces `NowPlayingArtwork.headerTint`, which lived in
// the macOS-only `Views/` tree.
//

import SwiftUI

struct DetailHeaderTintModifier: ViewModifier {
    /// The `ImageUtils` color-cache id: the same `"album-<id>"` / artist name /
    /// playlist UUID the Now Playing surfaces use, so a warm player cache hit
    /// serves the header too.
    let cacheID: String
    let imageData: Data?
    @Binding var tint: Color?

    @AppStorage("useArtworkColors")
    private var useArtworkColors = true

    func body(content: Content) -> some View {
        content
            .task(id: taskID) {
                await refresh()
            }
    }

    private var taskID: String {
        "\(cacheID)-\(imageData?.count ?? 0)-\(useArtworkColors)"
    }

    @MainActor
    private func refresh() async {
        guard useArtworkColors, let imageData else {
            tint = nil
            return
        }
        let dominant = await ImageUtils.headerDominantColor(id: cacheID, imageData: imageData)
        guard !Task.isCancelled else { return }
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            tint = dominant.map { Color(platformColor: $0) }
        }
    }
}

extension View {
    func detailHeaderTint(cacheID: String, imageData: Data?, tint: Binding<Color?>) -> some View {
        modifier(DetailHeaderTintModifier(cacheID: cacheID, imageData: imageData, tint: tint))
    }
}
