import Foundation

struct LyricLine: Identifiable, Codable, Equatable {
    var id = UUID()
    let text: String
    let startTime: TimeInterval // seconds
    var endTime: TimeInterval?  // seconds; nil for the last line
    
    init(text: String, startTime: TimeInterval, endTime: TimeInterval? = nil) {
        self.text = text
        self.startTime = startTime
        self.endTime = endTime
    }
}

typealias Lyrics = [LyricLine]

extension Collection where Element == LyricLine {
    var hasTimedLyrics: Bool {
        contains { $0.startTime > 0 || $0.endTime != nil }
    }
}

extension LyricLine {
    static func parseLRC(from lrcString: String) -> Lyrics {
        LyricsParser.parseLRC(from: lrcString)
    }

    static func parseSRT(from srtString: String) -> Lyrics {
        LyricsParser.parseSRT(from: srtString)
    }
}
