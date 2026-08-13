//
// AccessibilityAuditUITests
//
// The accessibility regression gate: four screens must pass
// `performAccessibilityAudit` — Home, the Songs list, Now Playing and
// Settings. One screen excludes contrast: Now Playing's surface is painted
// with the palette of the artwork's dominant color, so a contrast gate would
// go red whenever a cover changes. Now Playing's Dynamic Type gate is scoped
// to its title and artist instead: the transport/chip glyphs are deliberately
// capped `@ScaledMetric` icons, not growing text, sized to fixed hit targets.
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

    /// Home is the default tab; wait for the Library section (the Songs row)
    /// so the audit runs on the settled screen, not on the launch spinner.
    private func launchSeededApp() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += ["--uitest-seed-fixtures"]
        app.launch()

        let songsRow = app.buttons.matching(
            NSPredicate(format: "label BEGINSWITH 'Songs'")
        ).firstMatch
        XCTAssertTrue(songsRow.waitForExistence(timeout: 60), "строка Songs не появилась (Documents пуст?)")
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

    private func attachScreenshot(of app: XCUIApplication, named name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    // MARK: - Audits

    func testHomeScreenPassesAccessibilityAudit() async throws {
        let app = launchSeededApp()

        try app.performAccessibilityAudit()

        attachScreenshot(of: app, named: "AX-Home")
    }

    func testTrackListPassesAccessibilityAudit() async throws {
        let app = launchSeededApp()

        let songsRow = app.buttons.matching(
            NSPredicate(format: "label BEGINSWITH 'Songs'")
        ).firstMatch
        scrollTo(songsRow, in: app)
        songsRow.tap()

        let alphaRow = app.buttons.matching(
            NSPredicate(format: "label CONTAINS[c] 'Alpha One'")
        ).firstMatch
        XCTAssertTrue(alphaRow.waitForExistence(timeout: 30), "список треков не загрузился")

        // The list scrolls 80pt short of the screen bottom (contentMargins),
        // so no row ever renders under the floating tab bar's translucent
        // material, which the screenshot-based contrast check would flag as
        // ghosted text.
        try app.performAccessibilityAudit()

        attachScreenshot(of: app, named: "AX-TrackList")
    }

    func testNowPlayingPassesAccessibilityAudit() async throws {
        let app = launchSeededApp()

        let songsRow = app.buttons.matching(
            NSPredicate(format: "label BEGINSWITH 'Songs'")
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

        attachScreenshot(of: app, named: "AX-NowPlaying")
    }

    func testSettingsPassesAccessibilityAudit() async throws {
        let app = launchSeededApp()

        let settingsButton = app.buttons["Settings"]
        XCTAssertTrue(settingsButton.waitForExistence(timeout: 15))
        settingsButton.tap()

        let rescanButton = app.buttons["Rescan Library"]
        XCTAssertTrue(rescanButton.waitForExistence(timeout: 15), "экран настроек не открылся")

        try app.performAccessibilityAudit()

        attachScreenshot(of: app, named: "AX-Settings")
    }
}
