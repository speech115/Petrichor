//
// LyricsTimeline
//
// Pure timeline logic for timed lyrics: which line is active at a given
// playhead time. Shared by the macOS lyrics views and the iOS Now Playing
// lyrics panel so both platforms highlight the same line.
//

import Foundation

enum LyricsTimeline {
    /// Index of the line active at `time`, or -1 when no line covers it.
    ///
    /// A line with an `endTime` covers `startTime <= time < endTime`; a line
    /// with `nil` endTime (the last line) covers `startTime <= time` for the
    /// rest of the track.
    static func activeLineIndex(in lines: [LyricLine], at time: TimeInterval) -> Int {
        lines.firstIndex { line in
            if let end = line.endTime {
                return time >= line.startTime && time < end
            } else {
                return line.startTime <= time
            }
        } ?? -1
    }
}
