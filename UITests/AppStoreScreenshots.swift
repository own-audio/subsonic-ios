import XCTest

/// The App Store screenshots, taken from a real server. Not a test of behaviour: run it on
/// purpose, on the device sizes the store wants, with a clean status bar (see
/// `scripts/app-store-screenshots.sh`). Use a server whose music may be shown publicly.
///
/// `TEST_RUNNER_SCREENSHOT_LANGUAGE` is `en` or `cs`; `TEST_RUNNER_SCREENSHOT_DIR` is where
/// the PNGs go; `TEST_RUNNER_SCREENSHOT_ALBUM` picks the album shown.
final class AppStoreScreenshots: XCTestCase {
    private var env: [String: String] { ProcessInfo.processInfo.environment }

    override func setUpWithError() throws {
        continueAfterFailure = false
        guard env["SUBSONIC_HOST"] != nil, env["SCREENSHOT_DIR"] != nil, env["SCREENSHOT_LANGUAGE"] != nil else {
            throw XCTSkip("Set SUBSONIC_HOST, SCREENSHOT_DIR and SCREENSHOT_LANGUAGE to take store screenshots")
        }
    }

    func testTakeScreenshots() throws {
        let language = env["SCREENSHOT_LANGUAGE"]!
        let czech = language == "cs"
        let app = XCUIApplication()
        app.launchArguments = [
            "-uiTestReset", "-AppleLanguages", "(\(language))", "-AppleLocale", czech ? "cs_CZ" : "en_US",
        ]
        app.launch()

        let address = app.textFields["addServer.address"]
        XCTAssertTrue(address.waitForExistence(timeout: 10))
        address.tap()
        address.typeText(env["SUBSONIC_HOST"]!)
        app.textFields["addServer.username"].tap()
        app.textFields["addServer.username"].typeText(env["SUBSONIC_USER"] ?? "")
        app.secureTextFields["addServer.password"].tap()
        app.secureTextFields["addServer.password"].typeText(env["SUBSONIC_PASSWORD"] ?? "")
        // The library's title is the server's name; a plain one reads better than an address.
        let name = app.textFields["addServer.name"]
        name.tap()
        name.typeText(czech ? "Moje hudba" : "My Music")
        app.buttons["addServer.connect"].tap()
        sleep(4)
        dismissSavePasswordPrompt(app)

        // Library, with covers loaded.
        let albums = app.buttons[czech ? "Alba" : "Albums"]
        XCTAssertTrue(albums.waitForExistence(timeout: 15))
        sleep(3)
        save(app, "1-library")

        // Album.
        albums.tap()
        let album = env["SCREENSHOT_ALBUM"].map {
            app.buttons.containing(NSPredicate(format: "label CONTAINS %@", $0)).firstMatch
        } ?? app.scrollViews.buttons.firstMatch
        XCTAssertTrue(album.waitForExistence(timeout: 10))
        sleep(2)
        save(app, "2-albums")
        album.tap()
        let play = app.buttons["detail.play"]
        XCTAssertTrue(play.waitForExistence(timeout: 10))
        XCTAssertTrue(waitUntil(timeout: 10) { play.isEnabled })
        sleep(2)
        save(app, "3-album")

        // Player, a little way into the song.
        play.tap()
        let miniPlayer = app.buttons["miniPlayer"]
        XCTAssertTrue(miniPlayer.waitForExistence(timeout: 20))
        miniPlayer.tap()
        XCTAssertTrue(app.descendants(matching: .any)["player.scrubber"].firstMatch.waitForExistence(timeout: 10))
        sleep(12)
        save(app, "4-player")

        // Queue.
        app.buttons[czech ? "Fronta" : "Queue"].tap()
        sleep(2)
        save(app, "5-queue")
        app.buttons[czech ? "Hotovo" : "Done"].tap()

        // Equalizer.
        app.buttons[czech ? "Ekvalizér" : "EQ"].tap()
        let toggle = app.switches["equalizer.enabled"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 5))
        if (toggle.value as? String) != "1" { toggle.switches.firstMatch.tap() }
        app.buttons["equalizer.preset.Loudness"].tap()
        sleep(1)
        save(app, "6-equalizer")
        app.buttons[czech ? "Obnovit" : "Reset"].tap()
        toggle.switches.firstMatch.tap()
        app.buttons[czech ? "Hotovo" : "Done"].tap()
        app.buttons["player.close"].tap()

        // Settings.
        app.buttons[czech ? "Nastavení" : "Settings"].firstMatch.tap()
        sleep(1)
        save(app, "7-settings")
    }

    private func save(_ app: XCUIApplication, _ name: String) {
        let shot = app.screenshot()
        let attachment = XCTAttachment(screenshot: shot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        let directory = URL(fileURLWithPath: env["SCREENSHOT_DIR"]!)
        try? shot.pngRepresentation.write(to: directory.appendingPathComponent("\(name).png"))
    }

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
}
