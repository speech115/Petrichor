//
// CrossfadeArtwork
//
// The current track's cover on the player surfaces (the iOS mini player and
// Now Playing screen, the macOS player bar). A track change cross-fades from
// the old cover to the new one; the old cover stays fully drawn underneath
// until the new image is decoded, so the slot never passes through a
// placeholder or an empty frame on the way.
//
// Fed by `NowPlayingArtworkHold`, which keeps the previous track's bytes
// while the next track's artwork loads from the database. This view covers
// the second gap: the decode.
//

import SwiftUI
import ImageIO

struct CrossfadeArtwork: View {
    let artwork: NowPlayingArtworkHold.Shown?
    var cornerRadius: CGFloat = 6
    var iconSize: CGFloat = 22
    /// Largest decoded edge in physical pixels.
    var maxPixelSize: CGFloat
    /// A smaller rendition another surface may already have decoded (the mini
    /// player's), drawn on the first frame while this one decodes its own.
    var fallbackMaxPixelSize: CGFloat?

    /// What is fully drawn.
    @State private var base: Layer
    /// What is fading in over `base`.
    @State private var top: Layer?
    @State private var topOpacity: Double = 0

    init(
        artwork: NowPlayingArtworkHold.Shown?,
        cornerRadius: CGFloat = 6,
        iconSize: CGFloat = 22,
        maxPixelSize: CGFloat,
        fallbackMaxPixelSize: CGFloat? = nil
    ) {
        self.artwork = artwork
        self.cornerRadius = cornerRadius
        self.iconSize = iconSize
        self.maxPixelSize = maxPixelSize
        self.fallbackMaxPixelSize = fallbackMaxPixelSize
        // A cache hit paints on the first frame: opening Now Playing must not
        // flash the placeholder and then fade the cover in.
        let initial = [maxPixelSize, fallbackMaxPixelSize].compactMap { size -> Layer? in
            guard let size, let key = Self.imageKey(artwork, maxPixelSize: size),
                  let image = Self.cache.object(forKey: key as NSString) else { return nil }
            return .image(key: key, image)
        }.first
        _base = State(initialValue: initial ?? .placeholder)
    }

    var body: some View {
        ZStack {
            layerView(base)
            if let top {
                layerView(top)
                    .opacity(topOpacity)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
        .task(id: Self.imageKey(artwork, maxPixelSize: maxPixelSize) ?? "placeholder") {
            await showCurrentArtwork()
        }
        // The title beside or below the cover already names the content.
        .accessibilityRepresentation { EmptyView() }
    }

    // MARK: - Layers

    private enum Layer: Equatable {
        case placeholder
        case image(key: String, PlatformImage)

        static func == (lhs: Layer, rhs: Layer) -> Bool {
            switch (lhs, rhs) {
            case (.placeholder, .placeholder): true
            case let (.image(left, _), .image(right, _)): left == right
            default: false
            }
        }
    }

    @ViewBuilder
    private func layerView(_ layer: Layer) -> some View {
        switch layer {
        case .placeholder:
            ZStack {
                RoundedRectangle(cornerRadius: cornerRadius)
                    .fill(Color.secondary.opacity(0.12))
                Image(systemName: Icons.musicNote)
                    .font(.system(size: iconSize))
                    .foregroundColor(.secondary)
            }
        case let .image(_, image):
            // Anchored on `Color.clear` so a non-square cover fills the
            // proposed frame instead of reporting its own enlarged size.
            Color.clear
                .overlay {
                    Image(platformImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                }
                .clipped()
        }
    }

    private func showCurrentArtwork() async {
        let target: Layer
        if let key = Self.imageKey(artwork, maxPixelSize: maxPixelSize), let data = artwork?.artwork {
            if let cached = Self.cache.object(forKey: key as NSString) {
                target = .image(key: key, cached)
            } else {
                let size = maxPixelSize
                // ImageIO's HEVC decoder waits on its own dispatch work, so the
                // decode runs on GCD rather than a cooperative executor thread.
                let decoded: CGImage? = await withCheckedContinuation { continuation in
                    DispatchQueue.global(qos: .userInitiated).async {
                        continuation.resume(returning: Self.downsample(data, maxPixelSize: size))
                    }
                }
                guard !Task.isCancelled, let decoded else { return }
                let image = PlatformImage.from(cgImage: decoded)
                Self.cache.setObject(image, forKey: key as NSString)
                target = .image(key: key, image)
            }
        } else {
            target = .placeholder
        }
        guard !Task.isCancelled else { return }
        present(target)
    }

    private func present(_ target: Layer) {
        guard target != (top ?? base) else { return }
        // A change mid-fade: the half-faded layer becomes the floor.
        if let top { base = top }
        top = target
        topOpacity = 0
        withAnimation(.easeInOut(duration: 0.3)) {
            topOpacity = 1
        } completion: {
            guard top == target else { return }
            base = target
            top = nil
        }
    }

    // MARK: - Decoding

    @MainActor private static let cache: NSCache<NSString, PlatformImage> = {
        let cache = NSCache<NSString, PlatformImage>()
        cache.countLimit = 12
        return cache
    }()

    /// Keyed by track, artwork size and pixel size: a track first carries a
    /// thumbnail and later its full cover, and the two must not share a slot.
    private static func imageKey(_ artwork: NowPlayingArtworkHold.Shown?, maxPixelSize: CGFloat) -> String? {
        guard let artwork, let data = artwork.artwork else { return nil }
        return "\(artwork.trackID)#\(data.count)@\(Int(maxPixelSize.rounded(.up)))"
    }

    private nonisolated static func downsample(_ data: Data, maxPixelSize: CGFloat) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: max(1, Int(maxPixelSize.rounded(.up))),
            kCGImageSourceShouldCacheImmediately: true
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }
}
