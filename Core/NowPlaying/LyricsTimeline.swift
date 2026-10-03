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

    /// How far through line `index` the playhead is at `time`, 0...1 — what
    /// the active line's fill follows. A last line without an `endTime` is
    /// given `lastLineDuration`, since the track's end is no sung boundary.
    static func lineProgress(
        in lines: [LyricLine],
        index: Int,
        at time: TimeInterval,
        lastLineDuration: TimeInterval = 4
    ) -> Double {
        guard lines.indices.contains(index) else { return 0 }
        let line = lines[index]
        let end = line.endTime ?? line.startTime + lastLineDuration
        guard end > line.startTime else { return 1 }
        return min(1, max(0, (time - line.startTime) / (end - line.startTime)))
    }
}
