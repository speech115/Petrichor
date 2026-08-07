//
// M3UFilenameNormalizer
//
// M3U import seam: files on the iPhone were renamed during transfer —
// numeric prefixes (`0001 - ...`) stripped, `;` substituted for `,`,
// whitespace collapsed. The import's exact-filename fallback misses them,
// so the normalized key below is what actually lands a mac-written M3U on
// the renamed database row. Normalization is a pure function of the name:
// both sides (the M3U entry and every stored filename) go through it, and
// the match is refused when two different files collapse onto one key.
//
// The mac-side helper `scripts/sync-m3u.py` rewrites the same playlists by
// file *size* (which the rename never changes) — keep the rename rules in
// both places in sync.
//

import Foundation

enum M3UFilenameNormalizer {
    /// The filename with transfer-rename noise removed:
    /// 1. a leading `NNNN - ` numeric prefix is stripped;
    /// 2. `;` becomes `,`;
    /// 3. spaces around commas and repeated whitespace collapse;
    /// 4. the key is lowercased — the filesystem is case-insensitive, so the
    ///    M3U entry and the stored filename must match despite case drift.
    static func normalize(_ filename: String) -> String {
        var name = filename

        if let digitsEnd = name.firstIndex(where: { !$0.isNumber }), digitsEnd != name.startIndex {
            let remainder = name[digitsEnd...]
            if remainder.hasPrefix(" - ") {
                name = String(remainder.dropFirst(3))
            }
        }

        name = name.replacingOccurrences(of: ";", with: ",")
        name = name.replacingOccurrences(of: ", ", with: ",")
        name = name.replacingOccurrences(of: " ,", with: ",")
        name = name.components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")

        return name.lowercased()
    }
}

enum M3UFilenameMatcher {
    /// Maps each requested filename onto the single candidate with the same
    /// normalized key, or omits it when no candidate (or more than one)
    /// matches. A key stays blocked after its first collision — with three
    /// candidates on one key, removing the second would let the third look
    /// unambiguous again. Building one key map for all candidates keeps the
    /// pass linear in the library size instead of quadratic.
    static func resolveAll(_ filenames: [String], against candidates: [String]) -> [String: String] {
        var keyToName: [String: String] = [:]
        var blockedKeys: Set<String> = []
        for candidate in candidates {
            let key = M3UFilenameNormalizer.normalize(candidate)
            if blockedKeys.contains(key) {
                continue
            }
            if keyToName[key] == nil {
                keyToName[key] = candidate
            } else {
                keyToName.removeValue(forKey: key)
                blockedKeys.insert(key)
            }
        }

        var resolved: [String: String] = [:]
        for filename in filenames {
            let key = M3UFilenameNormalizer.normalize(filename)
            if !blockedKeys.contains(key), let name = keyToName[key] {
                resolved[filename] = name
            }
        }
        return resolved
    }
}
