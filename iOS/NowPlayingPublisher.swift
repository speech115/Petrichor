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

@MainActor
enum NowPlayingPublisher {
    static func artwork(from data: Data?) -> MPMediaItemArtwork? {
        guard let data, let image = UIImage(data: data) else { return nil }
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
