//
// RemoteCommandManager class
//
// Routes the system transport commands (Control Center, media keys, AirPlay
// remote) to Petrichor's playback and queue managers. The Now Playing info tile
// is published by the engine - see `PlaybackEngine.setNowPlayingMetadata`.
//
// Concurrency: MPRemoteCommandCenter invokes target handlers on the main
// thread by contract, and the returned status drives the enabled state of the
// Control Center buttons, so a no-op command (already playing, already
// paused) must return `.commandFailed` synchronously. `MainActor.assumeIsolated`
// turns the documented main-thread guarantee into a checked one.
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
        // Remove any existing handlers
        for command in managedCommands {
            command.removeTarget(nil)
        }
    }

    func connectRemoteCommandCenter(audioPlayer: PlaybackManager, playlistManager: PlaylistManager) {
        let commandCenter = MPRemoteCommandCenter.shared()

        // Add handler for play command
        commandCenter.playCommand.addTarget { [weak audioPlayer] _ in
            guard let audioPlayer = audioPlayer else { return .commandFailed }
            return MainActor.assumeIsolated {
                guard !audioPlayer.isPlaying else { return .commandFailed }
                audioPlayer.togglePlayPause()
                return .success
            }
        }

        // Add handler for pause command
        commandCenter.pauseCommand.addTarget { [weak audioPlayer] _ in
            guard let audioPlayer = audioPlayer else { return .commandFailed }
            return MainActor.assumeIsolated {
                guard audioPlayer.isPlaying else { return .commandFailed }
                audioPlayer.togglePlayPause()
                return .success
            }
        }

        // Add handler for toggle play/pause command
        commandCenter.togglePlayPauseCommand.addTarget { [weak audioPlayer] _ in
            guard audioPlayer != nil else { return .commandFailed }
            Task { @MainActor [weak audioPlayer] in
                guard let audioPlayer else { return }
                audioPlayer.togglePlayPause()
            }
            return .success
        }

        // Add handler for next track command
        commandCenter.nextTrackCommand.addTarget { [weak playlistManager] _ in
            guard playlistManager != nil else { return .commandFailed }
            Task { @MainActor [weak playlistManager] in
                guard let playlistManager else { return }
                playlistManager.playNextTrack()
            }
            return .success
        }

        // Add handler for previous track command
        commandCenter.previousTrackCommand.addTarget { [weak playlistManager] _ in
            guard playlistManager != nil else { return .commandFailed }
            Task { @MainActor [weak playlistManager] in
                guard let playlistManager else { return }
                playlistManager.playPreviousTrack()
            }
            return .success
        }

        // Add handler for seeking
        commandCenter.changePlaybackPositionCommand.addTarget { [weak audioPlayer] event in
            guard let audioPlayer = audioPlayer,
                  let positionEvent = event as? MPChangePlaybackPositionCommandEvent else {
                return .commandFailed
            }
            // Read the position out of the (non-Sendable) event before crossing into
            // the isolated closure - passing `positionEvent` itself in gets flagged as
            // sending task-isolated state across the hop.
            let position = positionEvent.positionTime
            Task { @MainActor [weak audioPlayer] in
                guard let audioPlayer else { return }
                audioPlayer.seekTo(time: position)
            }
            return .success
        }
    }
}
