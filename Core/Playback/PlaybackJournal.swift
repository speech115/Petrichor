//
// PlaybackJournal
//
// Fifth platform seam: phone listen/favorite events travel to the Mac as an
// append-only JSONL file. The protocol is optional on AppCoordinator (nil on
// macOS); managers call through it the same way they reach ScrobbleManager.
//

import Foundation

/// Records listen and favorite mutations for later sync. Writing happens only
/// on iOS; macOS leaves the coordinator property nil and applies a transferred
/// journal file through `PlaybackJournalApply`.
@MainActor
protocol PlaybackJournal: AnyObject {
    func trackPlayed(relativePath: String, at date: Date)
    func favoriteChanged(relativePath: String, value: Bool, at date: Date)
    func flush()
}

/// One JSONL line in `Documents/Sync/playback-journal.jsonl`.
struct PlaybackJournalEvent: Equatable, Sendable {
    enum Kind: String, Equatable, Sendable {
        case played
        case favorite
    }

    var timestamp: Date
    var kind: Kind
    var path: String
    /// Favorite events only; ignored for `played`.
    var value: Bool?
}

enum PlaybackJournalCodec {
    private struct LineDTO: Codable {
        var ts: String
        var type: String
        var path: String
        var value: Bool?

        enum CodingKeys: String, CodingKey {
            case ts, type, path, value
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(ts, forKey: .ts)
            try container.encode(type, forKey: .type)
            try container.encode(path, forKey: .path)
            try container.encodeIfPresent(value, forKey: .value)
        }
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }()

    private static let decoder = JSONDecoder()

    private static func makeISOFormatter() -> ISO8601DateFormatter {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }

    static func encodeLine(_ event: PlaybackJournalEvent) throws -> String {
        let dto = LineDTO(
            ts: makeISOFormatter().string(from: event.timestamp),
            type: event.kind.rawValue,
            path: event.path,
            value: event.kind == .favorite ? (event.value ?? false) : nil
        )
        let data = try encoder.encode(dto)
        guard let line = String(data: data, encoding: .utf8) else {
            throw CodecError.utf8
        }
        return line
    }

    static func decodeLine(_ line: String) throws -> PlaybackJournalEvent {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw CodecError.emptyLine }
        guard let data = trimmed.data(using: .utf8) else { throw CodecError.utf8 }

        let dto: LineDTO
        do {
            dto = try decoder.decode(LineDTO.self, from: data)
        } catch {
            throw CodecError.malformed(trimmed)
        }

        guard let timestamp = makeISOFormatter().date(from: dto.ts),
              let kind = PlaybackJournalEvent.Kind(rawValue: dto.type),
              !dto.path.isEmpty
        else {
            throw CodecError.malformed(trimmed)
        }

        if kind == .favorite {
            guard let value = dto.value else { throw CodecError.malformed(trimmed) }
            return PlaybackJournalEvent(timestamp: timestamp, kind: kind, path: dto.path, value: value)
        }

        return PlaybackJournalEvent(timestamp: timestamp, kind: kind, path: dto.path, value: nil)
    }

    static func decodeLines(_ text: String) throws -> [PlaybackJournalEvent] {
        try text
            .split(whereSeparator: \.isNewline)
            .map(String.init)
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            .map(decodeLine)
    }

    enum CodecError: Error, Equatable {
        case utf8
        case emptyLine
        case malformed(String)
    }
}

/// Mutable track projection used by the pure apply pass (and mirrored into the
/// database by `PlaybackJournalApplier` on macOS).
struct PlaybackJournalTrackState: Equatable, Sendable {
    /// Absolute path as stored on macOS, or any path whose suffix can match
    /// the event's relative `path`.
    var path: String
    var playCount: Int
    var isFavorite: Bool
    var lastPlayedDate: Date?
}

struct PlaybackJournalApplyResult: Equatable, Sendable {
    var applied: Int
    var skipped: Int
    var cursor: Date?
}

enum PlaybackJournalMatcher {
    /// Event `path` is relative to the library root. A stored absolute path
    /// matches when it ends with `"/" + path`, or equals `path` exactly.
    static func matches(storedPath: String, eventPath: String) -> Bool {
        storedPath == eventPath || storedPath.hasSuffix("/" + eventPath)
    }

    static func matchingIndices(
        in tracks: [PlaybackJournalTrackState],
        eventPath: String
    ) -> [Int] {
        tracks.indices.filter { matches(storedPath: tracks[$0].path, eventPath: eventPath) }
    }
}

enum PlaybackJournalApply {
    /// Applies events whose timestamp is strictly after `cursor`. Zero or
    /// more than one path match increments `skipped`. The returned cursor is
    /// the timestamp of the last successfully applied event (or the input
    /// cursor when nothing applied).
    static func apply(
        events: [PlaybackJournalEvent],
        to tracks: inout [PlaybackJournalTrackState],
        cursor: Date?
    ) -> PlaybackJournalApplyResult {
        let pending = events
            .filter { event in
                guard let cursor else { return true }
                return event.timestamp > cursor
            }
            .sorted { $0.timestamp < $1.timestamp }

        var applied = 0
        var skipped = 0
        var newCursor = cursor

        for event in pending {
            let indices = PlaybackJournalMatcher.matchingIndices(in: tracks, eventPath: event.path)
            guard indices.count == 1, let index = indices.first else {
                skipped += 1
                continue
            }

            switch event.kind {
            case .played:
                tracks[index].playCount += 1
                if let existing = tracks[index].lastPlayedDate {
                    tracks[index].lastPlayedDate = max(existing, event.timestamp)
                } else {
                    tracks[index].lastPlayedDate = event.timestamp
                }
            case .favorite:
                tracks[index].isFavorite = event.value ?? false
            }

            applied += 1
            newCursor = event.timestamp
        }

        return PlaybackJournalApplyResult(applied: applied, skipped: skipped, cursor: newCursor)
    }
}

enum PlaybackJournalCursorStore {
    static let defaultsKey = "PlaybackJournalCursor"

    static func load(from defaults: UserDefaults = .standard) -> Date? {
        defaults.object(forKey: defaultsKey) as? Date
    }

    static func save(_ date: Date?, to defaults: UserDefaults = .standard) {
        if let date {
            defaults.set(date, forKey: defaultsKey)
        } else {
            defaults.removeObject(forKey: defaultsKey)
        }
    }
}
