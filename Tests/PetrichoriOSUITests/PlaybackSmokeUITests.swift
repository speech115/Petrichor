//
// PlaybackSmokeUITests
//
// The user-visible regression behind the "player does not open" bug: launching
// a track from "All Tracks" must not hang the main thread (watchdog kill) and
// must surface the mini player and the Now Playing screen. Requires audio
// fixtures in the app's Documents folder on the simulator - see the comment in
// setUp for how to seed them.
//

import XCTest

final class PlaybackSmokeUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    /// Seeds a few silent WAVs named "Alpha One.wav", "Beta Two.wav",
    /// "Gamma Three.wav" into the app container first, e.g.:
    ///
    ///   xcrun simctl push booted org.Petrichor.ios \
    ///     ~/Music/Alpha\ One.wav \
    ///     Documents/Music/Alpha\ One.wav
    ///
    /// The scanner picks them up on launch; titles fall back to file names.
    func testLaunchingATrackFromAllTracksReachesThePlayer() throws {
        let app = XCUIApplication()
        app.launch()

        // Library tab is selected by default; the category list must appear
        // once the initial scan has settled.
        let allTracks = app.buttons["All Tracks"]
        XCTAssertTrue(
            allTracks.waitForExistence(timeout: 60),
            "категории библиотеки не появились (Documents пуст?)"
        )
        allTracks.tap()

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
        if !pauseButton.waitForExistence(timeout: 15) {
            let visible = app.descendants(matching: .any)
                .matching(NSPredicate(format: "isHittable == true"))
            print("UI-DIAG buttons:", app.buttons.allElementsBoundByIndex.map(\.label).prefix(40))
            XCTFail("мини-плеер не появился в играющем состоянии (запуск трека не работает)")
        }

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
