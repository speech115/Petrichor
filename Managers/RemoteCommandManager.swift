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
        let routes: [(MPRemoteCommand, (MPRemoteCommandEvent) -> RemoteTransportCommand?)] = [
            (commandCenter.playCommand, { _ in .play }),
            (commandCenter.pauseCommand, { _ in .pause }),
            (commandCenter.togglePlayPauseCommand, { _ in .togglePlayPause }),
            (commandCenter.nextTrackCommand, { _ in .nextTrack }),
            (commandCenter.previousTrackCommand, { _ in .previousTrack }),
            (commandCenter.changePlaybackPositionCommand, { event in
                (event as? MPChangePlaybackPositionCommandEvent).map { .changePosition($0.positionTime) }
            })
        ]
        for (command, makeCommand) in routes {
            command.addTarget { [weak audioPlayer, weak playlistManager] event in
                guard let audioPlayer, let playlistManager, let transport = makeCommand(event) else {
                    return .commandFailed
                }
                return MainActor.assumeIsolated {
                    Self.perform(transport, playback: audioPlayer, playlists: playlistManager)
                }
            }
        }
    }

    /// Runs one system transport command. Separate from the registration so a
    /// test can drive exactly what a lock-screen button does.
    @MainActor
    static func perform(
        _ command: RemoteTransportCommand,
        playback: PlaybackManager,
        playlists: PlaylistManager
    ) -> MPRemoteCommandHandlerStatus {
        switch command {
        case .play:
            guard !playback.isPlaying else { return .commandFailed }
            playback.togglePlayPause()
        case .pause:
            guard playback.isPlaying else { return .commandFailed }
            playback.togglePlayPause()
        case .togglePlayPause:
            playback.togglePlayPause()
        case .nextTrack:
            playlists.playNextTrack()
        case .previousTrack:
            playlists.playPreviousTrack()
        case .changePosition(let position):
            playback.seekTo(time: position)
        }
        return .success
    }
}

/// The system transport commands Petrichor handles.
enum RemoteTransportCommand: Equatable {
    case play
    case pause
    case togglePlayPause
    case nextTrack
    case previousTrack
    case changePosition(Double)
}
