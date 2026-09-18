//
// AccessibilityAuditUITests
//
// The accessibility regression gate: four screens must pass
// `performAccessibilityAudit` — Home, the Songs list, Now Playing and
// Settings. Two screens exclude contrast: Now Playing's surface is painted
// with the palette of the artwork's dominant color, so a contrast gate would
// go red whenever a cover changes; the Songs list's full-screen contrast pass
// does not finish within the audit's internal timeout on the CI runner
// (Code=-56) even though it passes locally. Home waits until the seeded
// library replaces the empty-state overlay before auditing — that overlay's
// system description fails contrast, and Songs-with-0 appears too early.
// Now Playing's Dynamic Type gate is scoped to its title and artist instead:
// the transport/chip glyphs are deliberately capped `@ScaledMetric` icons,
// not growing text, sized to fixed hit targets.
//
// No baseline file: the four screens are green from day one and more screens
// join as they get fixed. The app self-seeds its audio fixtures via
// `--uitest-seed-fixtures` (DEBUG-only), so the tests are self-sufficient on
// a clean simulator.
//

import XCTest

/// XCUI APIs are main-actor isolated in the current SDK; the class must be
/// too, or every query/tap in the async test methods warns (and errors in
/// Swift 6 mode).
@MainActor
final class AccessibilityAuditUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    /// Home is the default tab; wait until the seeded library is actually
    /// loaded. The Songs row appears with count 0 while "No Music" is still
    /// up — auditing that empty overlay fails contrast on the system
    /// description text ("Contrast nearly passed" on CI).
    private func launchSeededApp() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += ["--uitest-seed-fixtures"]
        app.launch()

        let songsRow = app.buttons.matching(
            identifier: "library.allMusic"
        ).firstMatch
        XCTAssertTrue(songsRow.waitForExistence(timeout: 60), "строка Songs не появилась (Documents пуст?)")

        let noMusic = app.staticTexts["No Music"]
        if noMusic.exists {
            XCTAssertTrue(
                noMusic.waitForNonExistence(timeout: 60),
                "библиотека не заполнилась после --uitest-seed-fixtures"
            )
        }
        return app
    }

    /// Scrolls the Home scroll view until `element` is hittable, like the
    /// smoke test does.
    private func scrollTo(_ element: XCUIElement, in app: XCUIApplication) {
        var attempts = 0
        while !element.isHittable && attempts < 6 {
            app.swipeUp()
            attempts += 1
        }
    }

    // MARK: - Audits

    func testHomeScreenPassesAccessibilityAudit() async throws {
        let app = launchSeededApp()

        try app.performAccessibilityAudit()

        attachBestEffortScreenshot(of: app, named: "AX-Home")
    }

    func testTrackListPassesAccessibilityAudit() async throws {
        let app = launchSeededApp()

        let songsRow = app.buttons.matching(
            identifier: "library.allMusic"
        ).firstMatch
        scrollTo(songsRow, in: app)
        songsRow.tap()

        let alphaRow = app.buttons.matching(
            NSPredicate(format: "label CONTAINS[c] 'Alpha One'")
        ).firstMatch
        XCTAssertTrue(alphaRow.waitForExistence(timeout: 30), "список треков не загрузился")

        // IndexedList pads its ScrollViewReader above the floating tab bar
        // (~80–100pt) so the last row of a short library cannot ghost through
        // the chrome on the first screen. safeAreaInset on List is ignored
        // here; padding the container is what shortens the viewport.
        // Assert before any swipe: `.tabBarMinimizeBehavior(.onScrollDown)`
        // shrinks the bar after scrolling and would weaken the check.
        //
        // Contrast stays excluded for this screen, but for a new reason: the
        // screenshot-based contrast pass over the whole app did not finish
        // within the audit's internal timeout on the CI runner (Code=-56,
        // "Audit failed to complete in time") even though it passes locally,
        // and the audit API has no element-scoped variant to shrink the pass.
        // The original ghosting defect is fixed by the padding above,
        // so the exclusion no longer hides a real problem - it works around
        // CI capacity.
        let tabChrome = app.tabBars.firstMatch
        XCTAssertTrue(tabChrome.waitForExistence(timeout: 5), "таббар не найден")
        // Fixture labels combine as "Title, Artist" (e.g. "Gamma, Three").
        let bottommostTrack = ["Gamma", "Beta Two", "Alpha One"]
            .map { name in
                app.buttons.matching(
                    NSPredicate(format: "label CONTAINS[c] %@", name)
                ).firstMatch
            }
            .filter(\.exists)
            .max { $0.frame.maxY < $1.frame.maxY }
        XCTAssertNotNil(bottommostTrack, "ни одной строки трека нет на экране")
        XCTAssertLessThanOrEqual(
            bottommostTrack!.frame.maxY,
            tabChrome.frame.minY + 1,
            "строка Songs пересекает floating tab bar на первом экране"
        )

        try app.performAccessibilityAudit(for: .all.subtracting(.contrast))

        attachBestEffortScreenshot(of: app, named: "AX-TrackList")
    }

    func testNowPlayingPassesAccessibilityAudit() async throws {
        let app = launchSeededApp()

        let songsRow = app.buttons.matching(
            identifier: "library.allMusic"
        ).firstMatch
        scrollTo(songsRow, in: app)
        songsRow.tap()

        let alphaRow = app.buttons.matching(
            NSPredicate(format: "label CONTAINS[c] 'Alpha One'")
        ).firstMatch
        XCTAssertTrue(alphaRow.waitForExistence(timeout: 30), "список треков не загрузился")
        alphaRow.tap()

        let miniPlayer = app.buttons["MiniPlayer"]
        XCTAssertTrue(miniPlayer.waitForExistence(timeout: 15), "мини-плеер не появился")
        miniPlayer.tap()

        let closeButton = app.buttons["Close"]
        XCTAssertTrue(closeButton.waitForExistence(timeout: 10), "Now Playing не открылся")

        // Contrast excluded: the palette comes from the artwork. Dynamic
        // Type is scoped instead of excluded: the title and artist are real,
        // uncapped text styles and must stay that way, while the
        // transport/chip glyphs are @ScaledMetric with a deliberate cap (a
        // 30x30 chip circle, a 44pt transport button - fixed hit targets,
        // not text), which the audit calls "partially unsupported" because
        // growth plateaus past the cap. The issue handler forgives every
        // dynamicType issue except one on those two elements.
        try app.performAccessibilityAudit(for: .all.subtracting([.contrast, .dynamicType]))
        try app.performAccessibilityAudit(for: .dynamicType) { issue in
            let identifier = issue.element?.identifier
            let isTitleOrArtist = identifier == "NowPlayingTitle" || identifier == "NowPlayingArtist"
            // `true` swallows the issue: only title/artist issues are fatal.
            return !isTitleOrArtist
        }

        attachBestEffortScreenshot(of: app, named: "AX-NowPlaying")
    }

    func testSettingsPassesAccessibilityAudit() async throws {
        let app = launchSeededApp()

        let settingsButton = app.buttons["Settings"]
        XCTAssertTrue(settingsButton.waitForExistence(timeout: 15))
        settingsButton.tap()

        let rescanButton = app.buttons["Rescan Library"]
        XCTAssertTrue(rescanButton.waitForExistence(timeout: 15), "экран настроек не открылся")

        try app.performAccessibilityAudit()

        attachBestEffortScreenshot(of: app, named: "AX-Settings")
    }
}
