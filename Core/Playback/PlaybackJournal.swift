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
/// journal file through `PlaybackJournalApply` / `LibraryManager`.
@MainActor
protocol PlaybackJournal: AnyObject {
    func trackPlayed(relativePath: String, at date: Date)
    func favoriteChanged(relativePath: String, value: Bool, at date: Date)
    func flush()
}

/// One JSONL line in `Documents/Sync/playback-journal.jsonl`.
enum PlaybackJournalEvent: Equatable, Sendable {
    case played(path: String, at: Date)
    case favorite(path: String, value: Bool, at: Date)

    var path: String {
        switch self {
        case .played(let path, _), .favorite(let path, _, _):
            path
        }
    }

    var timestamp: Date {
        switch self {
        case .played(_, let at), .favorite(_, _, let at):
            at
        }
    }
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
        let dto: LineDTO
        switch event {
        case .played(let path, let at):
            dto = LineDTO(ts: makeISOFormatter().string(from: at), type: "played", path: path, value: nil)
        case .favorite(let path, let value, let at):
            dto = LineDTO(ts: makeISOFormatter().string(from: at), type: "favorite", path: path, value: value)
        }
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
              !dto.path.isEmpty
        else {
            throw CodecError.malformed(trimmed)
        }

        switch dto.type {
        case "played":
            return .played(path: dto.path, at: timestamp)
        case "favorite":
            guard let value = dto.value else { throw CodecError.malformed(trimmed) }
            return .favorite(path: dto.path, value: value, at: timestamp)
        default:
            throw CodecError.malformed(trimmed)
        }
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

enum PlaybackJournalApply {
    /// Event `path` is relative to the library root. A stored absolute path
    /// matches when it ends with `"/" + path`, or equals `path` exactly.
    static func matches(storedPath: String, eventPath: String) -> Bool {
        storedPath == eventPath || storedPath.hasSuffix("/" + eventPath)
    }

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
            let indices = tracks.indices.filter {
                matches(storedPath: tracks[$0].path, eventPath: event.path)
            }
            guard indices.count == 1, let index = indices.first else {
                skipped += 1
                continue
            }

            switch event {
            case .played(_, let at):
                tracks[index].playCount += 1
                if let existing = tracks[index].lastPlayedDate {
                    tracks[index].lastPlayedDate = max(existing, at)
                } else {
                    tracks[index].lastPlayedDate = at
                }
            case .favorite(_, let value, _):
                tracks[index].isFavorite = value
            }

            applied += 1
            newCursor = event.timestamp
        }

        return PlaybackJournalApplyResult(applied: applied, skipped: skipped, cursor: newCursor)
    }
}
