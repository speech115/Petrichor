import Foundation
import GRDB
import PetrichorCore

extension DatabaseManager {
    func updateArtistInfo(
        artistId: Int64, imageData: Data? = nil, imageUrl: String? = nil,
        imageSource: String? = nil, bio: String? = nil, bioSource: String? = nil
    ) {
        do {
            let thumbnail = imageData.flatMap {
                ImageUtils.makeThumbnail(from: $0, source: "artist: id=\(artistId)")
            }
            try core.updateArtistInfo(
                p: ArtistInfoPatch(
                    artistId: artistId, imageData: imageData,
                    thumbnail: thumbnail, imageUrl: imageUrl, imageSource: imageSource,
                    bio: bio, bioSource: bioSource, now: Date().timeIntervalSince1970))
            if imageData != nil {
                NotificationCenter.default.post(name: .artistArtworkDidChange, object: nil)
            }
        } catch { Logger.error("Failed to update artist info for ID \(artistId): \(error)") }
    }
    func deleteArtistImage(artistId: Int64) {
        do {
            try core.deleteArtistImage(artistId: artistId, now: Date().timeIntervalSince1970)
            NotificationCenter.default.post(name: .artistArtworkDidChange, object: nil)
        } catch { Logger.error("Failed to delete artist image for ID \(artistId): \(error)") }
    }
    func markArtistImageFetchFailed(artistId: Int64) {
        markArtistFetchFailed(artistId, image: true)
    }
    func markArtistBioFetchFailed(artistId: Int64) { markArtistFetchFailed(artistId, image: false) }
    private func markArtistFetchFailed(_ id: Int64, image: Bool) {
        do {
            try core.markArtistFetchFailed(
                artistId: id, image: image, now: Date().timeIntervalSince1970)
        } catch { Logger.error("Failed to mark artist fetch failure for ID \(id): \(error)") }
    }
    struct ArtistFetchInfo {
        let id: Int64
        let name: String
        let hasImage: Bool
        let hasBio: Bool
    }
    func getArtistsNeedingImageOrBio() -> [ArtistFetchInfo] {
        do {
            let cutoff = Calendar.current.date(byAdding: .day, value: -7, to: Date()) ?? Date()
            return try rows(core.artistsNeedingImageOrBio(cutoff: cutoff.timeIntervalSince1970))
                .compactMap { row in
                    guard let id: Int64 = row["id"], let name: String = row["name"] else {
                        return nil
                    }
                    let image: String? = row["image_source"]
                    let bio: String? = row["bio"]
                    return ArtistFetchInfo(
                        id: id, name: name, hasImage: image != nil, hasBio: bio != nil)
                }
        } catch {
            Logger.error("Failed to get artists needing image or bio: \(error)")
            return []
        }
    }
}
