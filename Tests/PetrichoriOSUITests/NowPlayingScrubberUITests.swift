//
// NowPlayingScrubberUITests
//
// A drag that starts on the Now Playing seek bar is a seek, whichever way the
// thumb drifts. The full player is a `fullScreenCover` with the system zoom
// transition, whose interactive dismissal is a pan of its own; when it won the
// touch, a slightly downward scrub started closing the player instead of
// seeking (the lock screen's scrubber never did that). A drag that starts on
// the bar's 20 pt row already won. The drags that lost started a few points
// off it, on the elapsed/remaining times under it or just above it, which a
// thumb hits as often as the bar. The tests drag from each of those places
// with a downward component and check the player is still there; a control
// checks the same drag from the cover does close it, so the tests can see a
// dismissal at all.
//

import XCTest

final class NowPlayingScrubberUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    /// A shallow drag, the way a thumb usually scrubs: mostly sideways,
    /// drifting down a little.
    func testShallowScrubKeepsThePlayerOpen() throws {
        try assertScrubKeepsPlayerOpen(from: .onBar, dx: 160, dy: 45, named: "shallow")
    }

    /// A steep drag from the bar: still a scrub, as in Apple Music, because it
    /// started on the bar.
    func testSteepScrubKeepsThePlayerOpen() throws {
        try assertScrubKeepsPlayerOpen(from: .onBar, dx: 60, dy: 260, named: "steep")
    }

    /// The times under the bar read as part of the scrubber, and a thumb
    /// aimed at the bar lands on them.
    func testScrubFromTheTimesKeepsThePlayerOpen() throws {
        try assertScrubKeepsPlayerOpen(from: .onTimes, dx: 60, dy: 260, named: "times")
    }

    /// A touch a few points above the thin bar is still aimed at it.
    func testScrubFromJustAboveTheBarKeepsThePlayerOpen() throws {
        try assertScrubKeepsPlayerOpen(from: .justAbove, dx: 60, dy: 260, named: "above")
    }

    /// Control: the same drag from the cover, where it is meant to dismiss.
    /// If this one leaves the player open, the scrub tests above prove
    /// nothing — a synthesized drag would not reach the dismiss pan at all.
    func testDragFromTheCoverDismissesThePlayer() throws {
        let app = XCUIApplication()
        app.launchArguments += ["--uitest-seed-fixtures", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()

        let closeButton = openNowPlaying(in: app)
        let window = app.windows.firstMatch
        let start = window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3))
        start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: 60, dy: 260)))

        attachBestEffortScreenshot(of: app, named: "after-cover-drag")
        XCTAssertTrue(
            closeButton.waitForNonExistence(timeout: 3),
            "свайп вниз по обложке не закрыл Now Playing — синтетический драг не доходит до жеста закрытия"
        )
    }

    private enum Start {
        case onBar, onTimes, justAbove
    }

    private func assertScrubKeepsPlayerOpen(
        from startPoint: Start,
        dx: CGFloat,
        dy: CGFloat,
        named name: String
    ) throws {
        let app = XCUIApplication()
        app.launchArguments += ["--uitest-seed-fixtures", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()

        let closeButton = openNowPlaying(in: app)

        let scrubber = app.descendants(matching: .any)["Playback position"].firstMatch
        XCTAssertTrue(scrubber.waitForExistence(timeout: 5), "скраббер не найден в Now Playing")

        // The accessibility element spans the 20 pt bar row and the times
        // row under it; the visible bar sits in the middle of the top 20 pt.
        let top = scrubber.coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0))
        let start: XCUICoordinate
        switch startPoint {
        case .onBar:
            start = top.withOffset(CGVector(dx: 0, dy: 10))
        case .onTimes:
            start = scrubber.coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.85))
        case .justAbove:
            start = top.withOffset(CGVector(dx: 0, dy: -6))
        }
        let end = start.withOffset(CGVector(dx: dx, dy: dy))
        start.press(forDuration: 0.05, thenDragTo: end)

        attachBestEffortScreenshot(of: app, named: "after-\(name)-scrub")
        XCTAssertFalse(
            closeButton.waitForNonExistence(timeout: 3),
            "перемотка закрыла Now Playing (жест закрытия перехватил скраббер)"
        )
        XCTAssertTrue(closeButton.isHittable, "Now Playing не остался открытым после перемотки")
    }

    /// Starts "Alpha One" from Songs and opens the full player from the mini
    /// player. Returns the player's Close control.
    private func openNowPlaying(in app: XCUIApplication) -> XCUIElement {
        XCTAssertTrue(app.buttons["home.favorites"].waitForExistence(timeout: 60), "библиотека не загрузилась")
        app.tabBars.buttons["Search"].tap()
        let songsRow = app.buttons["library.allMusic"]
        XCTAssertTrue(songsRow.waitForExistence(timeout: 10), "каталог песен не появился в поиске")
        songsRow.tap()

        let alphaRow = app.buttons.matching(
            NSPredicate(format: "label CONTAINS[c] 'Alpha One'")
        ).firstMatch
        XCTAssertTrue(alphaRow.waitForExistence(timeout: 30), "строка Alpha One не появилась в списке треков")
        alphaRow.tap()

        let miniPlayer = app.buttons["MiniPlayer"]
        XCTAssertTrue(miniPlayer.waitForExistence(timeout: 30), "мини-плеер не появился")
        miniPlayer.tap()

        let closeButton = app.buttons["Close"].firstMatch
        XCTAssertTrue(closeButton.waitForExistence(timeout: 10), "Now Playing не открылся")
        // Let the zoom settle: a drag during the transition is a different case.
        sleep(1)
        return closeButton
    }
}
