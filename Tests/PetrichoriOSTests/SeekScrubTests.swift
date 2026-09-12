import Foundation
import Testing
@testable import Petrichor

/// Seam test for the shared seek math (design spec: seek-математика в
/// `Core/NowPlaying`). `SeekScrub` is the exact computation the macOS main
/// player bar and the iOS Now Playing progress bars run for drag/tap seeking
/// and progress fill — one copy, so the two platforms can't drift apart.

@Test func seekTimeMapsPositionToTime() {
    // Midpoint of a 100pt bar on a 4-minute track.
    #expect(SeekScrub.seekTime(position: 50, width: 100, duration: 240) == 120)
    #expect(SeekScrub.seekTime(position: 25, width: 100, duration: 240) == 60)
}

@Test func seekTimeClampsOutOfBoundsPositions() {
    #expect(SeekScrub.seekTime(position: -10, width: 100, duration: 240) == 0)
    #expect(SeekScrub.seekTime(position: 110, width: 100, duration: 240) == 240)
}

@Test func seekTimeSanitizesInvalidDurations() {
    // Negative, NaN, and infinite durations behave like zero, not like a seek to nowhere.
    #expect(SeekScrub.seekTime(position: 50, width: 100, duration: -240) == 0)
    #expect(SeekScrub.seekTime(position: 50, width: 100, duration: .nan) == 0)
    #expect(SeekScrub.seekTime(position: 50, width: 100, duration: .infinity) == 0)
    #expect(SeekScrub.seekTime(position: 50, width: 100, duration: 0) == 0)
}

@Test func seekTimeZeroWidthIsZero() {
    #expect(SeekScrub.seekTime(position: 0, width: 0, duration: 240) == 0)
    #expect(SeekScrub.seekTime(position: 50, width: 0, duration: 240) == 0)
}

@Test func fillFractionTracksThePlayhead() {
    #expect(SeekScrub.fillFraction(currentTime: 60, duration: 240, scrubbing: false, scrubTime: 0) == 0.25)
}

@Test func fillFractionPrefersScrubTimeWhileDragging() {
    #expect(SeekScrub.fillFraction(currentTime: 60, duration: 240, scrubbing: true, scrubTime: 180) == 0.75)
}

@Test func fillFractionClampsOutOfRangeTimes() {
    #expect(SeekScrub.fillFraction(currentTime: 300, duration: 240, scrubbing: false, scrubTime: 0) == 1)
    #expect(SeekScrub.fillFraction(currentTime: -10, duration: 240, scrubbing: false, scrubTime: 0) == 0)
}

@Test func fillFractionZeroWithoutAPositiveDuration() {
    #expect(SeekScrub.fillFraction(currentTime: 60, duration: 0, scrubbing: false, scrubTime: 0) == 0)
    #expect(SeekScrub.fillFraction(currentTime: 60, duration: -240, scrubbing: false, scrubTime: 0) == 0)
    #expect(SeekScrub.fillFraction(currentTime: 60, duration: .nan, scrubbing: false, scrubTime: 0) == 0)
}


@Test func dragMovesRelativeToPlayheadWithoutJumpingToTheTouch() {
    #expect(SeekScrub.dragTime(startTime: 60, translation: 0, width: 300, duration: 180) == 60)
    #expect(SeekScrub.dragTime(startTime: 60, translation: 50, width: 300, duration: 180) == 90)
    #expect(SeekScrub.dragTime(startTime: 60, translation: -50, width: 300, duration: 180) == 30)
    #expect(SeekScrub.dragTime(startTime: 60, translation: -500, width: 300, duration: 180) == 0)
    #expect(SeekScrub.dragTime(startTime: 60, translation: 500, width: 300, duration: 180) == 180)
    #expect(SeekScrub.dragTime(startTime: 60, translation: 50, width: 300, duration: .nan) == 0)
}
