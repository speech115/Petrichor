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
            // A warm cache paints before the first frame, so a page seen
            // before opens already colored instead of white-then-color.
            .onAppear {
                guard tint == nil, let cached = cachedTint else { return }
                tint = cached
            }
            .task(id: taskID) {
                await refresh()
            }
    }

    private var cachedTint: Color? {
        guard useArtworkColors, let imageData,
              let cached = ImageUtils.cachedDominantColorsIfAvailable(id: cacheID, imageData: imageData)?.first
        else { return nil }
        return Color(platformColor: cached)
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
        if let cachedTint {
            tint = cachedTint
            return
        }
        let dominant = await ImageUtils.headerDominantColor(id: cacheID, imageData: imageData)
        guard !Task.isCancelled else { return }
        // A fresh extraction lands while the page is already up: fade the
        // color in rather than switching the whole page in one frame.
        withAnimation(.easeInOut(duration: 0.35)) {
            tint = dominant.map { Color(platformColor: $0) }
        }
    }
}

extension View {
    func detailHeaderTint(cacheID: String, imageData: Data?, tint: Binding<Color?>) -> some View {
        modifier(DetailHeaderTintModifier(cacheID: cacheID, imageData: imageData, tint: tint))
    }
}
