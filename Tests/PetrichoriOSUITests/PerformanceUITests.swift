//
// PerformanceUITests
//
// The CI benchmark: launch, Home's data, the long playlist (opening and scrolling it) and
// opening Now Playing, measured on a 1500-track library with a 1200-track
// playlist that the DEBUG app generates itself (`--perf-seed-library`, see
// iOS/PerfLibraryFixtures.swift). Every number comes from a signpost the
// system or the app emits, not from XCUI's polling, so the test runner's own
// latency stays out of the measurement.
//
// The tests only measure. Regression thresholds live in
// `.github/perf-budget.json`; `.github/scripts/perf-gate.py` reads the
// metrics out of the result bundle and compares their medians with it. The
// job that does that is `perf` in .github/workflows/ci.yml.
//
// Skipped unless the runner's environment has PETRICHOR_PERF=1
// (`TEST_RUNNER_PETRICHOR_PERF=1 xcodebuild test ...`): the first run writes
// 1500 files into the simulator and every test relaunches the app several
// times, which a plain `xcodebuild test` should not pay for.
//

import XCTest

@MainActor
final class PerformanceUITests: XCTestCase {
    private static let subsystem = "org.Petrichor.ios"
    private static let pointsOfInterest = "PointsOfInterest"
    private static let playlistName = "Perf Big"
    /// The first row of "Perf Big" (see `PerfLibraryFixture.title`).
    private static let firstTrackTitle = "Perf Song 0001"

    /// Set once per test process: the library is generated and scanned on
    /// the first launch, every later launch finds it already in place.
    private static var isLibraryReady = false

    override func setUp() async throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["PETRICHOR_PERF"] == "1",
            "the benchmark runs only in the CI perf job (PETRICHOR_PERF=1)"
        )
        continueAfterFailure = false
        if !Self.isLibraryReady {
            prepareLibrary()
            Self.isLibraryReady = true
        }
    }

    // MARK: - Benchmarks

    /// Process start to the first responsive frame (system metric). The
    /// library is already in the database, as on every launch but the first.
    func testLaunch() throws {
        let app = makeApp()
        measure(metrics: [XCTApplicationLaunchMetric(waitUntilResponsive: true)]) {
            app.launch()
        }
    }

    /// The app's own "Prepare Home" interval: the Home data that Home's first
    /// frame waits for. Its own test: in one `measure` with the launch metric,
    /// an iteration could end without this interval and XCTest rejects
    /// iterations with different metric counts.
    func testHomeReady() throws {
        let app = makeApp()
        measure(metrics: [
            XCTOSSignpostMetric(subsystem: Self.subsystem, category: Self.pointsOfInterest, name: "Prepare Home"),
        ]) {
            app.launch()
            XCTAssertTrue(app.buttons["home.favorites"].waitForExistence(timeout: 60), "Home не открылся")
        }
    }

    /// Tap on the 1200-track playlist to the end of the push: the system's
    /// navigation-transition interval, which a slow first frame of the
    /// destination stretches.
    func testOpenLongPlaylist() throws {
        let app = makeApp()
        app.launch()
        let options = XCTMeasureOptions()
        options.invocationOptions = [.manuallyStart, .manuallyStop]
        measure(metrics: [XCTOSSignpostMetric.navigationTransitionMetric], options: options) {
            openPlaylistsTab(app)
            let row = playlistRow(app)
            XCTAssertTrue(row.waitForExistence(timeout: 30), "плейлист \(Self.playlistName) не найден")
            startMeasuring()
            row.tap()
            XCTAssertTrue(firstTrackRow(app).waitForExistence(timeout: 30), "строки плейлиста не появились")
            stopMeasuring()
            app.navigationBars.buttons.element(boundBy: 0).tap()
            XCTAssertTrue(row.waitForExistence(timeout: 10))
        }
    }

    /// A fast fling through the long playlist: the system's scroll
    /// deceleration interval with its hitch time ratio.
    func testScrollLongPlaylist() throws {
        let app = makeApp()
        app.launch()
        openPlaylistsTab(app)
        let row = playlistRow(app)
        XCTAssertTrue(row.waitForExistence(timeout: 30), "плейлист \(Self.playlistName) не найден")
        row.tap()
        XCTAssertTrue(firstTrackRow(app).waitForExistence(timeout: 30), "строки плейлиста не появились")

        let list = app.collectionViews.firstMatch
        let options = XCTMeasureOptions()
        options.invocationOptions = [.manuallyStop]
        measure(metrics: [XCTOSSignpostMetric.scrollDecelerationMetric], options: options) {
            list.swipeUp(velocity: .fast)
            stopMeasuring()
            list.swipeDown(velocity: .fast)
        }
    }

    /// Tap on the mini player to the first committed frame of the player:
    /// the app's "Open Now Playing" interval (iOS/PerfSignposts.swift).
    func testOpenNowPlaying() throws {
        let app = makeApp()
        app.launch()
        openPlaylistsTab(app)
        let row = playlistRow(app)
        XCTAssertTrue(row.waitForExistence(timeout: 30), "плейлист \(Self.playlistName) не найден")
        row.tap()
        let track = firstTrackRow(app)
        XCTAssertTrue(track.waitForExistence(timeout: 30), "строки плейлиста не появились")
        track.tap()

        let miniPlayer = app.buttons["MiniPlayer"]
        XCTAssertTrue(miniPlayer.waitForExistence(timeout: 30), "мини-плеер не появился")

        let options = XCTMeasureOptions()
        options.invocationOptions = [.manuallyStop]
        measure(
            metrics: [XCTOSSignpostMetric(subsystem: Self.subsystem, category: Self.pointsOfInterest, name: "Open Now Playing")],
            options: options
        ) {
            miniPlayer.tap()
            let close = app.buttons["Close"]
            XCTAssertTrue(close.waitForExistence(timeout: 10), "Now Playing не открылся")
            stopMeasuring()
            close.tap()
            XCTAssertTrue(miniPlayer.waitForExistence(timeout: 10))
        }
    }

    // MARK: - Library

    private func makeApp() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += ["--perf-seed-library", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        return app
    }

    /// First launch: the app writes the library, scans it after Home is up
    /// and imports "Perf Big" once the scan has matched its tracks. Waiting
    /// for the playlist row is waiting for all of that. A fresh launch after
    /// it then starts from a database that already holds the library.
    private func prepareLibrary() {
        let app = makeApp()
        app.launch()
        XCTAssertTrue(app.buttons["home.favorites"].waitForExistence(timeout: 120), "Home не открылся")
        openPlaylistsTab(app)
        XCTAssertTrue(
            playlistRow(app).waitForExistence(timeout: 600),
            "плейлист \(Self.playlistName) не импортировался после скана"
        )
        // Let the tail of the reconciliation (artwork, search index) settle
        // before the first measured launch.
        sleep(10)
        app.terminate()
    }

    private func openPlaylistsTab(_ app: XCUIApplication) {
        let tab = app.tabBars.buttons["Playlists"]
        XCTAssertTrue(tab.waitForExistence(timeout: 30), "вкладка Playlists не появилась")
        tab.tap()
    }

    private func playlistRow(_ app: XCUIApplication) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", Self.playlistName)).firstMatch
    }

    private func firstTrackRow(_ app: XCUIApplication) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label CONTAINS %@", Self.firstTrackTitle)).firstMatch
    }
}
