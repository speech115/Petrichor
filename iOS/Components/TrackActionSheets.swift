// Shared presentation for lists and the full-screen player. Only the visible
// surface receives menu requests, so sheets never open behind Now Playing.
import SwiftUI

private struct TrackActionSheets: ViewModifier {
    let isActive: Bool
    let playlistManager: PlaylistManager
    @ObservedObject var creation: PlaylistCreatePresentationObservation
    @State private var infoTrack: Track?
    @State private var playlistTrack: Track?

    private var isCreating: Binding<Bool> {
        Binding(
            get: { isActive && creation.isPresented },
            set: { if isActive { playlistManager.showingCreatePlaylistModal = $0 } }
        )
    }

    func body(content: Content) -> some View {
        content
            .sheet(item: $infoTrack) { TrackInfoSheet(track: $0) }
            .sheet(item: $playlistTrack) { track in
                AddToPlaylistSheet(track: track, playlistManager: playlistManager)
            }
            .sheet(isPresented: isCreating) {
                CreatePlaylistSheet(
                    isPresented: isCreating,
                    playlistName: Binding(
                        get: { creation.playlistName },
                        set: { playlistManager.newPlaylistName = $0 }
                    ),
                    tracksToAdd: creation.tracksToAdd,
                    onCreate: { playlistManager.createPlaylistFromModal() }
                )
                .environmentObject(playlistManager)
            }
            .onReceive(NotificationCenter.default.publisher(for: .showTrackInfo)) { notification in
                guard isActive else { return }
                infoTrack = notification.userInfo?["track"] as? Track
            }
            .onReceive(NotificationCenter.default.publisher(for: .addTrackToPlaylist)) { notification in
                guard isActive else { return }
                playlistTrack = notification.userInfo?["track"] as? Track
            }
    }
}

extension View {
    func trackActionSheets(isActive: Bool, playlistManager: PlaylistManager) -> some View {
        modifier(TrackActionSheets(
            isActive: isActive,
            playlistManager: playlistManager,
            creation: playlistManager.createPresentationObservation
        ))
    }
}
