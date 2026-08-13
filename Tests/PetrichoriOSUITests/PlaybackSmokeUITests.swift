//
// PlaybackSmokeUITests
//
// The user-visible regression behind the "player does not open" bug: launching
// a track from "Songs" must not hang the main thread (watchdog kill) and
// must surface the mini player and the Now Playing screen. The app seeds its
// own audio fixtures when launched with `--uitest-seed-fixtures` (DEBUG-only),
// so the test is self-sufficient on any clean simulator.
//

import XCTest

final class PlaybackSmokeUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    /// The app seeds three silent MP3s named "Alpha One.mp3", "Beta Two.mp3",
    /// "Gamma Three.mp3" into Documents/Music when launched with
    /// `--uitest-seed-fixtures` (DEBUG-only, idempotent — existing files are
    /// left untouched). The scanner picks them up on launch; titles fall back
    /// to file names. The iOS port plays MP3 only (AVAssetMetadataReader), so
    /// WAV fixtures will never appear in the library.
    func testLaunchingATrackFromSongsReachesThePlayer() throws {
        let app = XCUIApplication()
        app.launchArguments += ["--uitest-seed-fixtures"]
        app.launch()

        // Home is the default tab; the Songs row lives in the Library section
        // at the bottom of the Home scroll.
        let songsRow = app.buttons.matching(
            NSPredicate(format: "label BEGINSWITH 'Songs'")
        ).firstMatch
        XCTAssertTrue(
            songsRow.waitForExistence(timeout: 60),
            "строка Songs не появилась (Documents пуст?)"
        )
        var scrollAttempts = 0
        while !songsRow.isHittable && scrollAttempts < 6 {
            app.swipeUp()
            scrollAttempts += 1
        }
        songsRow.tap()

        // The track list is alphabet-indexed; tap the seeded "Alpha One" row
        // by name, so the test is immune to whatever else sits in Documents.
        // The button's label combines title and artist, hence the CONTAINS.
        let alphaRow = app.buttons.matching(
            NSPredicate(format: "label CONTAINS[c] 'Alpha One'")
        ).firstMatch
        XCTAssertTrue(alphaRow.waitForExistence(timeout: 30), "строка Alpha One не появилась в списке треков")
        alphaRow.tap()

        // A track must start without hanging the main thread: the mini player
        // appears in its playing state.
        let pauseButton = app.buttons["Pause"]
        // No button-tree dump on failure: `allElementsBoundByIndex` has timed
        // out on CI and failed the test before XCTFail.
        XCTAssertTrue(
            pauseButton.waitForExistence(timeout: 30),
            "мини-плеер не появился в играющем состоянии (запуск трека не работает)"
        )

        // Tapping the mini player must open Now Playing.
        let miniPlayer = app.buttons["MiniPlayer"]
        XCTAssertTrue(miniPlayer.waitForExistence(timeout: 5))
        miniPlayer.tap()

        let closeButton = app.buttons["Close"]
        XCTAssertTrue(closeButton.waitForExistence(timeout: 10), "Now Playing не открылся")

        // Watchdog regression: the app must stay alive well past the 5-second
        // window that used to kill it while preloading the whole queue.
        sleep(8)
        XCTAssertEqual(app.state, .runningForeground, "приложение упало после запуска трека")
    }
}
