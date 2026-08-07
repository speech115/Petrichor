//
// SeekScrub
//
// Pure seek math for the progress slider, shared by the macOS main player bar
// and the iOS Now Playing progress bars: a drag/tap position maps onto a
// clamped playhead time, and the playhead maps back onto a fill fraction.
//

import Foundation

enum SeekScrub {
    /// Playhead time (seconds) for a horizontal drag/tap position within a
    /// track `width` points wide. The position is clamped to the track bounds,
    /// and non-finite or negative durations sanitize to zero.
    static func seekTime(position: Double, width: Double, duration: Double) -> Double {
        let fraction = width > 0 ? min(1, max(0, position / width)) : 0
        return HelperUtils.sanitizedDuration(duration) * fraction
    }

    /// Fill fraction of the progress track: the scrub time while the user is
    /// dragging, otherwise the current playhead time. Zero when there is no
    /// track or the duration is not positive.
    static func fillFraction(currentTime: Double, duration: Double, scrubbing: Bool, scrubTime: Double) -> Double {
        guard duration > 0 else { return 0 }
        return min(1, max(0, (scrubbing ? scrubTime : currentTime) / duration))
    }
}
