//
// PerfLibraryFixtures (iOS)
//
// DEBUG-only seeding for the CI benchmark (`--perf-seed-library`): a library
// the size of the one the playlist-perf phase was tuned on, so launch, the
// long playlist and Now Playing are measured on realistic data instead of the
// three smoke-test files. 100 albums x 15 tracks (1500 silent MP3s with
// ID3 tags and a per-album JPEG cover) in `Documents/Music/Perf Library`, and
// `Documents/Petrichor-Playlists/Perf Big.m3u` with the first 1200 of them,
// which the launch reconciliation auto-imports as the "Perf Big" playlist.
//
// Idempotent: the M3U is written last, so its presence means the library is
// complete and later launches skip the generation entirely.
//

#if DEBUG
import Foundation
import UIKit

let perfSeedLibraryLaunchArgument = "--perf-seed-library"

enum PerfLibraryFixture {
    static let albumCount = 100
    static let tracksPerAlbum = 15
    static let playlistSize = 1200
    static let playlistName = "Perf Big"

    /// Unique per track, so a UI test can find one row by its label.
    static func title(_ index: Int) -> String {
        String(format: "Perf Song %04d", index)
    }
}

@MainActor
func seedPerfLibraryIfNeeded() throws {
    let fileManager = FileManager.default
    let root = LibraryPathStore.libraryRoot
    let playlistsDirectory = root.appendingPathComponent("Petrichor-Playlists", isDirectory: true)
    let m3uURL = playlistsDirectory
        .appendingPathComponent(PerfLibraryFixture.playlistName)
        .appendingPathExtension("m3u")
    guard !fileManager.fileExists(atPath: m3uURL.path) else { return }

    let libraryDirectory = root
        .appendingPathComponent("Music", isDirectory: true)
        .appendingPathComponent("Perf Library", isDirectory: true)
    try fileManager.createDirectory(at: libraryDirectory, withIntermediateDirectories: true)
    try fileManager.createDirectory(at: playlistsDirectory, withIntermediateDirectories: true)

    var m3uLines = ["#EXTM3U"]
    var trackIndex = 0
    for albumIndex in 1...PerfLibraryFixture.albumCount {
        let album = String(format: "Perf Album %03d", albumIndex)
        let artist = String(format: "Perf Artist %03d", (albumIndex - 1) / 4 + 1)
        let albumDirectory = libraryDirectory.appendingPathComponent(album, isDirectory: true)
        try fileManager.createDirectory(at: albumDirectory, withIntermediateDirectories: true)
        let cover = perfCoverJPEG(hue: CGFloat(albumIndex) / CGFloat(PerfLibraryFixture.albumCount))

        for trackNumber in 1...PerfLibraryFixture.tracksPerAlbum {
            trackIndex += 1
            let title = PerfLibraryFixture.title(trackIndex)
            let fileName = String(format: "%02d %@.mp3", trackNumber, title)
            let destination = albumDirectory.appendingPathComponent(fileName)
            if !fileManager.fileExists(atPath: destination.path) {
                let generated = try makeSilentMP3(
                    artist: artist,
                    title: title,
                    album: album,
                    albumArtist: artist,
                    genre: "Perf",
                    year: "2026",
                    trackNumber: trackNumber,
                    totalTracks: PerfLibraryFixture.tracksPerAlbum,
                    artwork: cover
                )
                try fileManager.moveItem(at: generated, to: destination)
            }
            if trackIndex <= PerfLibraryFixture.playlistSize {
                m3uLines.append("#EXTINF:1,\(artist) - \(title)")
                // Entries resolve against the M3U's own folder.
                m3uLines.append("../Music/Perf Library/\(album)/\(fileName)")
            }
        }
    }

    try (m3uLines.joined(separator: "\n") + "\n").write(to: m3uURL, atomically: true, encoding: .utf8)
}

/// A 600 px cover in one hue per album: real JPEG bytes, so the scan's
/// thumbnail path and the rows' artwork decode do the work a real library
/// makes them do.
@MainActor
private func perfCoverJPEG(hue: CGFloat) -> Data? {
    let size = CGSize(width: 600, height: 600)
    let format = UIGraphicsImageRendererFormat()
    format.scale = 1
    let image = UIGraphicsImageRenderer(size: size, format: format).image { context in
        UIColor(hue: hue, saturation: 0.6, brightness: 0.8, alpha: 1).setFill()
        context.fill(CGRect(origin: .zero, size: size))
        UIColor(hue: hue, saturation: 0.8, brightness: 0.4, alpha: 1).setFill()
        context.fill(CGRect(x: 0, y: size.height * 0.6, width: size.width, height: size.height * 0.4))
    }
    return image.jpegData(compressionQuality: 0.8)
}
#endif
