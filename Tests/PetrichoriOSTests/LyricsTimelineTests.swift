import Foundation
import Testing
@testable import Petrichor

/// Seam test for the shared lyrics timeline (design spec: тайминг лирики в
/// `Core/NowPlaying`). `LyricsTimeline.activeLineIndex` is the exact
/// computation both the iOS lyrics panel and the macOS `TrackLyricsView` run
/// on every playhead tick — one copy, so the two platforms can't drift apart.

private func line(_ text: String, _ start: TimeInterval, _ end: TimeInterval? = nil) -> LyricLine {
    LyricLine(text: text, startTime: start, endTime: end)
}

@Test func activeLinePicksTheLineWhoseWindowContainsTime() {
    let lines = [
        line("intro", 0, 5),
        line("verse", 5, 15),
        line("chorus", 15, 30),
        line("outro", 30)
    ]
    #expect(LyricsTimeline.activeLineIndex(in: lines, at: 3) == 0)
    #expect(LyricsTimeline.activeLineIndex(in: lines, at: 14.9) == 1)
    #expect(LyricsTimeline.activeLineIndex(in: lines, at: 20) == 2)
}

@Test func activeLineBoundariesAreHalfOpen() {
    let lines = [
        line("a", 0, 5),
        line("b", 5, 10)
    ]
    // startTime is inclusive: a line begins exactly at its own start.
    #expect(LyricsTimeline.activeLineIndex(in: lines, at: 0) == 0)
    #expect(LyricsTimeline.activeLineIndex(in: lines, at: 5) == 1)
    // endTime is exclusive: at the boundary the NEXT line is active.
    #expect(LyricsTimeline.activeLineIndex(in: lines, at: 10) == -1)
}

@Test func activeLineLastLineWithoutEndHoldsForTheRest() {
    let lines = [
        line("a", 0, 5),
        line("b", 5)
    ]
    #expect(LyricsTimeline.activeLineIndex(in: lines, at: 5) == 1)
    #expect(LyricsTimeline.activeLineIndex(in: lines, at: 999) == 1)
}

@Test func activeLineFallsBackToStartTimeWhenEndTimeIsNil() {
    let lines = [
        line("only", 10)
    ]
    #expect(LyricsTimeline.activeLineIndex(in: lines, at: 9.999) == -1)
    #expect(LyricsTimeline.activeLineIndex(in: lines, at: 10) == 0)
}

@Test func activeLineBeforeTheFirstLineAndEmptyTimelineReturnMinusOne() {
    let lines = [
        line("a", 5, 10),
        line("b", 10)
    ]
    #expect(LyricsTimeline.activeLineIndex(in: lines, at: 4.999) == -1)
    #expect(LyricsTimeline.activeLineIndex(in: [], at: 0) == -1)
}
