//
// NowPlayingPublisher
//
// Publishes the "Now Playing" tile shown on the lock screen and in Control
// Center. `MPNowPlayingInfoCenter` only *displays* the tile - transport
// buttons are routed separately through `MPRemoteCommandCenter`, wired up in
// `AVQueuePlayerBackend`.
//

import MediaPlayer
import UIKit
import ImageIO

struct PreparedNowPlayingArtwork: Sendable {
    let image: CGImage
}

@MainActor
enum NowPlayingPublisher {
    /// Decodes and downsamples artwork without blocking MainActor. `CGImage` is
    /// an immutable, Sendable bitmap; constructing the UIKit wrapper later is
    /// consequently a short publication-only hop.
    nonisolated static func prepareArtwork(from data: Data?) -> PreparedNowPlayingArtwork? {
        guard let data,
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceThumbnailMaxPixelSize: 1024,
                  kCGImageSourceCreateThumbnailWithTransform: true,
                  kCGImageSourceShouldCacheImmediately: true
              ] as CFDictionary) else { return nil }
        return PreparedNowPlayingArtwork(image: image)
    }

    static func artwork(from prepared: PreparedNowPlayingArtwork?) -> MPMediaItemArtwork? {
        guard let prepared else { return nil }
        let image = UIImage(cgImage: prepared.image)
        return MPMediaItemArtwork(boundsSize: image.size) { _ in image }
    }

    /// - Parameter elapsed: Seconds already played, so the lock-screen tile's
    ///   elapsed-time indicator matches the app's own seek bar.
    /// - Parameter rate: The player's instantaneous rate (0 while paused, 1
    ///   while playing). Without it the system assumes 1.0 and keeps
    ///   advancing the lock-screen elapsed-time indicator while paused.
    static func publish(
        _ metadata: NowPlayingMetadata?,
        artwork: MPMediaItemArtwork?,
        elapsed: Double,
        duration: Double,
        rate: Double
    ) {
        guard let metadata else {
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
            return
        }

        var info: [String: Any] = [
            MPMediaItemPropertyTitle: metadata.title ?? "",
            MPMediaItemPropertyArtist: metadata.artist ?? "",
            MPMediaItemPropertyAlbumTitle: metadata.albumTitle ?? "",
            MPMediaItemPropertyPlaybackDuration: duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: elapsed,
            MPNowPlayingInfoPropertyPlaybackRate: rate
        ]

        if let artwork {
            info[MPMediaItemPropertyArtwork] = artwork
        }

        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }
}
