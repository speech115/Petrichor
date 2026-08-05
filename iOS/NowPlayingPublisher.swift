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

enum NowPlayingPublisher {
    /// - Parameter rate: The player's instantaneous rate (0 while paused, 1
    ///   while playing). Without it the system assumes 1.0 and keeps
    ///   advancing the lock-screen elapsed-time indicator while paused.
    static func publish(_ metadata: NowPlayingMetadata?, progress: Double, duration: Double, rate: Double) {
        guard let metadata else {
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
            return
        }

        var info: [String: Any] = [
            MPMediaItemPropertyTitle: metadata.title ?? "",
            MPMediaItemPropertyArtist: metadata.artist ?? "",
            MPMediaItemPropertyAlbumTitle: metadata.albumTitle ?? "",
            MPMediaItemPropertyPlaybackDuration: duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: progress * duration,
            MPNowPlayingInfoPropertyPlaybackRate: rate
        ]

        if let data = metadata.artworkData, let image = UIImage(data: data) {
            info[MPMediaItemPropertyArtwork] = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
        }

        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }
}
