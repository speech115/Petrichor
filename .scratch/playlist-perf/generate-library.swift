// Ticket 01: generates the seeded simulator library.
//
// Writes 1500 short silent MP3s (100 albums x 15 tracks, ID3v2.3 tags with
// artist/title/album) into <out>/Music/, plus <out>/Petrichor-Playlists/big.m3u
// referencing the first 1200 of them by relative path. The MP3 layout mirrors
// Tests/PetrichoriOSTests/TestFixtures.swift makeSilentMP3 (the app under test
// reads the tags via AVAssetMetadataReader, so real tags are required).
//
// Usage: swift generate-library.swift [output-dir]
// Default output dir: $HOME/scratch/perf-library

import Foundation

let arguments = CommandLine.arguments
let defaultOut = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("scratch/perf-library", isDirectory: true).path
let outDir = arguments.count > 1 ? arguments[1] : defaultOut

let albumCount = 100
let tracksPerAlbum = 15
let playlistSize = 1200

// MARK: - Silent MP3 with ID3v2.3 tags

func silentMP3(artist: String, title: String, album: String) -> Data {
    var data = Data()

    let tags = [
        ("TIT2", title),
        ("TPE1", artist),
        ("TALB", album)
    ].compactMap { (id: String, value: String) -> Data? in
        guard let bytes = value.data(using: .isoLatin1) else { return nil }
        var frame = Data()
        frame.append(contentsOf: Array(id.utf8))
        let size = UInt32(bytes.count + 1).bigEndian
        withUnsafeBytes(of: size) { frame.append(contentsOf: $0) }
        frame.append(contentsOf: [0, 0]) // flags
        frame.append(0) // text encoding: latin-1
        frame.append(bytes)
        return frame
    }
    if !tags.isEmpty {
        let tagSize = tags.reduce(0) { $0 + $1.count }
        data.append(contentsOf: Array("ID3".utf8))
        data.append(contentsOf: [3, 0, 0]) // version 2.3, no flags
        // Syncsafe size: only the low 7 bits of each byte count.
        data.append(UInt8((tagSize >> 21) & 0x7F))
        data.append(UInt8((tagSize >> 14) & 0x7F))
        data.append(UInt8((tagSize >> 7) & 0x7F))
        data.append(UInt8(tagSize & 0x7F))
        for frame in tags { data.append(frame) }
    }

    // MPEG-1 Layer III silence: header 0xFF 0xFB 0x90 0x00 (128 kbps, 44.1 kHz),
    // frame length 144 * 128000 / 44100 = 417 bytes, one second of audio.
    let frameLength = 417
    let frameCount = Int(ceil(1.0 * 44_100 / 1152))
    let frameHeader: [UInt8] = [0xFF, 0xFB, 0x90, 0x00]
    for _ in 0..<frameCount {
        data.append(contentsOf: frameHeader)
        data.append(Data(count: frameLength - frameHeader.count))
    }
    return data
}

// MARK: - Generation

let fileManager = FileManager.default
let musicDir = URL(fileURLWithPath: outDir).appendingPathComponent("Music", isDirectory: true)
let playlistsDir = URL(fileURLWithPath: outDir)
    .appendingPathComponent("Petrichor-Playlists", isDirectory: true)

try fileManager.createDirectory(at: musicDir, withIntermediateDirectories: true)
try fileManager.createDirectory(at: playlistsDir, withIntermediateDirectories: true)

var m3uLines = ["#EXTM3U"]
var fileURLs: [URL] = []

for albumIndex in 1...albumCount {
    let albumName = String(format: "Album %03d", albumIndex)
    let albumDir = musicDir.appendingPathComponent(albumName, isDirectory: true)
    try fileManager.createDirectory(at: albumDir, withIntermediateDirectories: true)

    for trackNumber in 1...tracksPerAlbum {
        let artist = String(format: "Artist %03d", albumIndex)
        let title = String(format: "Track %02d", trackNumber)
        let fileName = String(format: "%04d.mp3", trackNumber)
        let url = albumDir.appendingPathComponent(fileName)
        try silentMP3(artist: artist, title: title, album: albumName).write(to: url)
        fileURLs.append(url)

        if fileURLs.count <= playlistSize {
            m3uLines.append("#EXTINF:1,\(artist) - \(title)")
            // Entries resolve relative to the M3U's own directory
            // (Documents/Petrichor-Playlists), so Music/ is one level up.
            m3uLines.append("../Music/\(albumName)/\(fileName)")
        }
    }
}

let m3uURL = playlistsDir.appendingPathComponent("big.m3u")
try (m3uLines.joined(separator: "\n") + "\n").write(to: m3uURL, atomically: true, encoding: .utf8)

print("Generated \(fileURLs.count) mp3s under \(musicDir.path)")
print("Wrote \(m3uURL.path) with \(playlistSize) entries")
