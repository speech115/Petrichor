import Foundation
import PetrichorCore

extension DatabaseManager {
    func loadScanArtists() {
        ArtistParser.loadKnownArtists()
        let content = ArtistParser.findKnownArtistsFile().flatMap { try? String(contentsOf: $0, encoding: .utf8) }
        core.loadScanArtists(content: content)
    }

    func unloadScanArtists() {
        core.unloadScanArtists()
        ArtistParser.unloadKnownArtists()
    }

    func normalizeCompilationAlbums() async throws {
        try core.normalizeCompilationAlbums(now: Date().timeIntervalSince1970)
    }

}
