//
// NowPlayingScrubberUITests
//
// A drag that starts on the Now Playing seek bar is a seek, whichever way the
// thumb drifts. The full player is a `fullScreenCover` with the system zoom
// transition, whose interactive dismissal is a pan of its own; when it won the
// touch, a slightly downward scrub started closing the player instead of
// seeking (the lock screen's scrubber never did that). The test drags from the
// bar with a downward component and checks the player is still there.
//

import XCTest

final class NowPlayingScrubberUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    /// A shallow drag, the way a thumb usually scrubs: mostly sideways,
    /// drifting down a little.
    func testShallowScrubKeepsThePlayerOpen() throws {
        try assertScrubKeepsPlayerOpen(dx: 160, dy: 45, named: "shallow")
    }

    /// A steep drag from the bar: still a scrub, as in Apple Music, because it
    /// started on the bar. This is the case the dismiss pan won every time.
    func testSteepScrubKeepsThePlayerOpen() throws {
        try assertScrubKeepsPlayerOpen(dx: 60, dy: 260, named: "steep")
    }

    private func assertScrubKeepsPlayerOpen(dx: CGFloat, dy: CGFloat, named name: String) throws {
        let app = XCUIApplication()
        app.launchArguments += ["--uitest-seed-fixtures", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()

        let closeButton = openNowPlaying(in: app)

        let scrubber = app.descendants(matching: .any)["Playback position"].firstMatch
        XCTAssertTrue(scrubber.waitForExistence(timeout: 5), "скраббер не найден в Now Playing")

        let start = scrubber.coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.3))
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
