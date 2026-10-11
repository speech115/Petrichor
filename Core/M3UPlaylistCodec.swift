//
// M3UPlaylistCodec
//
// Pure playlist text and naming policy. macOS uses Rust; iOS keeps its
// Foundation implementation. File encoding, I/O and persistence stay in Swift.
//
import Foundation
#if os(macOS)
import PetrichorCore
#endif

enum M3UPlaylistCodec {
    static func parse(_ content: String) -> [String] {
        #if os(macOS)
        return m3uParse(content: content)
        #else
        return content.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
        #endif
    }

    static func uniqueName(baseName: String, existingNames: Set<String>) -> String {
        #if os(macOS)
        return m3uUniquePlaylistName(baseName: baseName, existingNames: Array(existingNames))
        #else
        guard existingNames.contains(baseName.lowercased()) else { return baseName }
        let baseNameLower = baseName.lowercased()
        let highestNumber = existingNames.reduce(1) { currentMax, name in
            guard name.hasPrefix(baseNameLower + " ") else { return currentMax }
            let suffix = String(name.dropFirst(baseNameLower.count + 1))
            return max(currentMax, Int(suffix) ?? 0)
        }
        return "\(baseName) \(highestNumber + 1)"
        #endif
    }

    static func exportFilename(_ name: String) -> String {
        #if os(macOS)
        return m3uExportFilename(name: name)
        #else
        return FilesystemUtils.sanitizeFilename(name) + ".m3u"
        #endif
    }

    static func generate(_ tracks: [Track]) -> String {
        #if os(macOS)
        return m3uGenerate(entries: tracks.map {
            M3uExportEntry(durationSeconds: Int64(Int($0.duration)), artist: $0.artist, title: $0.title, path: $0.url.path)
        })
        #else
        var lines = ["#EXTM3U"]
        for track in tracks {
            lines.append("#EXTINF:\(Int(track.duration)),\(track.artist) - \(track.title)")
            lines.append(track.url.path)
        }
        return lines.joined(separator: "\r\n")
        #endif
    }
}
