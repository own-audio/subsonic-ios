import XCTest

/// Add a server, open an album, play it, skip a track: the path every listener takes first.
///
/// Needs a real server with at least one album of two or more tracks:
///
/// ```
/// TEST_RUNNER_SUBSONIC_HOST=localhost:4533 TEST_RUNNER_SUBSONIC_USER=… TEST_RUNNER_SUBSONIC_PASSWORD=… \
/// xcodebuild test …   # optionally TEST_RUNNER_SUBSONIC_ALBUM="<name>"
/// ```
///
/// `TEST_RUNNER_SCREENSHOT_DIR` saves a screenshot of each step there as well as in the result.
final class PlaybackSmokeTests: XCTestCase {
    private var env: [String: String] { ProcessInfo.processInfo.environment }

    override func setUpWithError() throws {
        continueAfterFailure = false
        guard env["SUBSONIC_HOST"] != nil else {
            throw XCTSkip("SUBSONIC_HOST is not set")
        }
    }

    func testAddServerPlayAlbumAndSkip() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-uiTestReset"]
        app.launch()

        let address = app.textFields["addServer.address"]
        XCTAssertTrue(address.waitForExistence(timeout: 10))
        screenshot(app, "01-onboarding")
        address.tap()
        address.typeText(env["SUBSONIC_HOST"]!)
        app.textFields["addServer.username"].tap()
        app.textFields["addServer.username"].typeText(env["SUBSONIC_USER"] ?? "")
        app.secureTextFields["addServer.password"].tap()
        app.secureTextFields["addServer.password"].typeText(env["SUBSONIC_PASSWORD"] ?? "")
        app.buttons["addServer.connect"].tap()

        let albumsLink = app.buttons["Albums"]
        XCTAssertTrue(albumsLink.waitForExistence(timeout: 15), "the library should open after connecting")
        dismissSavePasswordPrompt(app)
        sleep(2)
        screenshot(app, "02-library")
        albumsLink.tap()

        // Without a name, the first album in the grid; it needs two or more tracks.
        let album = env["SUBSONIC_ALBUM"].map {
            app.buttons.containing(NSPredicate(format: "label CONTAINS %@", $0)).firstMatch
        } ?? app.scrollViews.buttons.firstMatch
        XCTAssertTrue(album.waitForExistence(timeout: 10))
        sleep(1)
        screenshot(app, "03-albums")
        album.tap()

        let play = app.buttons["detail.play"]
        XCTAssertTrue(play.waitForExistence(timeout: 10))
        XCTAssertTrue(waitUntil(timeout: 10) { play.isEnabled }, "Play should enable once the songs load")
        screenshot(app, "04-album")
        play.tap()

        let miniPlayer = app.buttons["miniPlayer"]
        XCTAssertTrue(miniPlayer.waitForExistence(timeout: 15), "the mini player should appear once playback starts")
        // A spinner stands where the button goes until the first audio arrives.
        let miniPlayPause = app.buttons["miniPlayer.playPause"]
        XCTAssertTrue(waitUntil(timeout: 30) { miniPlayPause.exists && miniPlayPause.label == "Pause" }, "playback should start")
        screenshot(app, "05-mini-player")
        miniPlayer.tap()

        let title = app.descendants(matching: .any)["player.title"].firstMatch
        let scrubber = app.descendants(matching: .any)["player.scrubber"].firstMatch
        XCTAssertTrue(scrubber.waitForExistence(timeout: 10))
        let firstTitle = title.label
        let firstPosition = scrubber.value as? String ?? ""
        sleep(3)
        XCTAssertNotEqual(scrubber.value as? String ?? "", firstPosition, "the position should advance while playing")
        screenshot(app, "06-player")

        app.buttons["player.next"].tap()
        XCTAssertTrue(waitUntil(timeout: 30) { title.exists && title.label != firstTitle }, "next should change the track")
        sleep(1)
        screenshot(app, "07-next-track")

        // Star the playing song and put it back, so the library ends as it began.
        let star = app.buttons["player.star"]
        XCTAssertTrue(star.waitForExistence(timeout: 5))
        let before = star.label
        star.tap()
        XCTAssertTrue(waitUntil(timeout: 5) { star.label != before }, "the star should flip")
        screenshot(app, "08-starred")
        star.tap()
        XCTAssertTrue(waitUntil(timeout: 5) { star.label == before }, "the star should flip back")

        app.buttons["player.playPause"].tap()
        let playPause = app.buttons["player.playPause"]
        XCTAssertTrue(waitUntil(timeout: 5) { playPause.exists && playPause.label == "Play" }, "pause should pause")
    }

    /// iOS offers to save the password after a sign-in form. It's the system's sheet, in the
    /// system's language, so it is found by position: "Not Now" is the first of its two buttons.
    private func dismissSavePasswordPrompt(_ app: XCUIApplication) {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        for owner in [app, springboard] {
            let notNow = owner.buttons.matching(NSPredicate(
                format: "label IN %@", ["Not Now", "Teď ne", "Jetzt nicht", "Plus tard", "Ahora no"]
            )).firstMatch
            if notNow.waitForExistence(timeout: 3) {
                notNow.tap()
                return
            }
        }
    }

    private func waitUntil(timeout: TimeInterval, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
        }
        return condition()
    }

    private func screenshot(_ app: XCUIApplication, _ name: String) {
        let shot = app.screenshot()
        let attachment = XCTAttachment(screenshot: shot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        if let directory = env["SCREENSHOT_DIR"] {
            try? shot.pngRepresentation.write(to: URL(fileURLWithPath: directory).appendingPathComponent("\(name).png"))
        }
    }
}
