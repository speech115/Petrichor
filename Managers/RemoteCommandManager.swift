//
// RemoteCommandManager class
//
// Routes the system transport commands (Control Center, media keys, AirPlay
// remote) to Petrichor's playback and queue managers. The Now Playing info tile
// is published by the engine - see `PlaybackEngine.setNowPlayingMetadata`.
//
// Concurrency: MPRemoteCommandCenter invokes target handlers on the main
// thread (the canonical `MPRemoteCommand.addTarget(handler:)` sample reads
// player state and calls play() directly in the handler), and the returned
// status drives the enabled state of the Control Center buttons, so a no-op
// command (already playing, already paused) must return `.commandFailed`
// synchronously. `MainActor.assumeIsolated` turns that guarantee into a
// checked one.
//

import Foundation
import MediaPlayer

class RemoteCommandManager {
    init() {
        setupRemoteCommandCenter()
    }

    /// The remote commands Petrichor handles. Single source of truth for remote
    /// command teardown and registration.
    private var managedCommands: [MPRemoteCommand] {
        let center = MPRemoteCommandCenter.shared()
        return [
            center.playCommand,
            center.pauseCommand,
            center.togglePlayPauseCommand,
            center.nextTrackCommand,
            center.previousTrackCommand,
            center.changePlaybackPositionCommand
        ]
    }

    // MARK: - Remote Command Center

    private func setupRemoteCommandCenter() {
        for command in managedCommands {
            command.removeTarget(nil)
        }
    }

    func connectRemoteCommandCenter(audioPlayer: PlaybackManager, playlistManager: PlaylistManager) {
        let commandCenter = MPRemoteCommandCenter.shared()

        commandCenter.playCommand.addTarget { [weak audioPlayer] _ in
            guard let audioPlayer else { return .commandFailed }
            return MainActor.assumeIsolated {
                guard !audioPlayer.isPlaying else { return .commandFailed }
                audioPlayer.togglePlayPause()
                return .success
            }
        }

        commandCenter.pauseCommand.addTarget { [weak audioPlayer] _ in
            guard let audioPlayer else { return .commandFailed }
            return MainActor.assumeIsolated {
                guard audioPlayer.isPlaying else { return .commandFailed }
                audioPlayer.togglePlayPause()
                return .success
            }
        }

        commandCenter.togglePlayPauseCommand.addTarget { [weak audioPlayer] _ in
            guard let audioPlayer else { return .commandFailed }
            return MainActor.assumeIsolated {
                audioPlayer.togglePlayPause()
                return .success
            }
        }

        commandCenter.nextTrackCommand.addTarget { [weak playlistManager] _ in
            guard let playlistManager else { return .commandFailed }
            return MainActor.assumeIsolated {
                playlistManager.playNextTrack()
                return .success
            }
        }

        commandCenter.previousTrackCommand.addTarget { [weak playlistManager] _ in
            guard let playlistManager else { return .commandFailed }
            return MainActor.assumeIsolated {
                playlistManager.playPreviousTrack()
                return .success
            }
        }

        commandCenter.changePlaybackPositionCommand.addTarget { [weak audioPlayer] event in
            guard let audioPlayer,
                  let positionEvent = event as? MPChangePlaybackPositionCommandEvent else {
                return .commandFailed
            }
            let position = positionEvent.positionTime
            return MainActor.assumeIsolated {
                audioPlayer.seekTo(time: position)
                return .success
            }
        }
    }
}
