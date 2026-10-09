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

        addServer(app)
        openAlbum(app, named: env["SUBSONIC_ALBUM"])

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

    /// Download an album, then start the app with every server unreachable and play it from
    /// Downloads. `TEST_RUNNER_SUBSONIC_DOWNLOAD_ALBUM` picks a small album; without it, the
    /// first one.
    func testDownloadAlbumAndPlayOffline() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-uiTestReset"]
        app.launch()
        addServer(app, screenshots: false)
        openAlbum(app, named: env["SUBSONIC_DOWNLOAD_ALBUM"].flatMap { $0.isEmpty ? nil : $0 }, screenshots: false)

        let download = app.buttons["download.start"]
        XCTAssertTrue(download.waitForExistence(timeout: 10))
        XCTAssertTrue(waitUntil(timeout: 15) { download.isEnabled }, "Download should enable once the songs load")
        download.tap()
        let done = app.buttons["download.done"]
        XCTAssertTrue(done.waitForExistence(timeout: 300), "the album should finish downloading")
        screenshot(app, "10-downloaded")

        app.terminate()
        app.launchArguments = ["-simulateOffline"]
        app.launch()

        let downloadsLink = app.buttons["Downloads"]
        XCTAssertTrue(downloadsLink.waitForExistence(timeout: 15))
        sleep(2)
        screenshot(app, "11-offline-library")
        downloadsLink.tap()

        let collection = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'downloads.album.'")).firstMatch
        XCTAssertTrue(collection.waitForExistence(timeout: 10), "the downloaded album should be listed offline")
        screenshot(app, "12-downloads")
        collection.tap()

        let play = app.buttons["detail.play"]
        XCTAssertTrue(play.waitForExistence(timeout: 10))
        play.tap()

        let miniPlayPause = app.buttons["miniPlayer.playPause"]
        XCTAssertTrue(
            waitUntil(timeout: 15) { miniPlayPause.exists && miniPlayPause.label == "Pause" },
            "a downloaded album should play with no server"
        )
        app.buttons["miniPlayer"].tap()
        let scrubber = app.descendants(matching: .any)["player.scrubber"].firstMatch
        XCTAssertTrue(scrubber.waitForExistence(timeout: 10))
        let firstPosition = scrubber.value as? String ?? ""
        sleep(3)
        XCTAssertNotEqual(scrubber.value as? String ?? "", firstPosition, "offline playback should advance")
        screenshot(app, "13-offline-player")
    }

    /// Needs an album whose first song has ReplayGain tags (track gain -6.5 dB) and synced
    /// lyrics: `TEST_RUNNER_SUBSONIC_LYRICS_ALBUM`. Skipped without it; the real servers used for
    /// testing have neither, so this runs against a local Navidrome with a generated album.
    func testLyricsReplayGainAndEqualizer() throws {
        guard let albumName = env["SUBSONIC_LYRICS_ALBUM"], !albumName.isEmpty else {
            throw XCTSkip("SUBSONIC_LYRICS_ALBUM is not set")
        }
        let app = XCUIApplication()
        app.launchArguments = ["-uiTestReset"]
        app.launch()
        addServer(app, screenshots: false)
        openAlbum(app, named: albumName, screenshots: false)

        let play = app.buttons["detail.play"]
        XCTAssertTrue(play.waitForExistence(timeout: 10))
        XCTAssertTrue(waitUntil(timeout: 10) { play.isEnabled })
        play.tap()
        let miniPlayer = app.buttons["miniPlayer"]
        XCTAssertTrue(miniPlayer.waitForExistence(timeout: 15))
        miniPlayer.tap()

        let gain = app.staticTexts.containing(NSPredicate(format: "label CONTAINS '-6.5 dB'")).firstMatch
        XCTAssertTrue(gain.waitForExistence(timeout: 15), "the player should show the ReplayGain it applies")
        screenshot(app, "20-replaygain")

        app.buttons["Lyrics"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["lyrics.synced"].waitForExistence(timeout: 10), "synced lyrics should load")
        XCTAssertTrue(app.staticTexts["The first line arrives"].waitForExistence(timeout: 5))
        sleep(6)
        screenshot(app, "21-lyrics")
        app.buttons["Done"].tap()

        app.buttons["EQ"].tap()
        let toggle = app.switches["equalizer.enabled"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 5))
        if (toggle.value as? String) != "1" { toggle.switches.firstMatch.tap() }
        app.buttons["equalizer.preset.Bass Boost"].tap()
        sleep(1)
        screenshot(app, "22-equalizer")
        // Back to flat and off, so other runs start clean.
        app.buttons["Reset"].tap()
        toggle.switches.firstMatch.tap()
        app.buttons["Done"].tap()
    }

    /// Walks the main screens in Czech and saves screenshots, to catch untranslated or
    /// clipped text. Finds everything by identifier, so it doesn't depend on the language.
    func testCzechScreens() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-uiTestReset", "-AppleLanguages", "(cs)", "-AppleLocale", "cs_CZ"]
        app.launch()
        let address = app.textFields["addServer.address"]
        XCTAssertTrue(address.waitForExistence(timeout: 10))
        screenshot(app, "cs-01-onboarding")
        address.tap()
        address.typeText(env["SUBSONIC_HOST"]!)
        app.textFields["addServer.username"].tap()
        app.textFields["addServer.username"].typeText(env["SUBSONIC_USER"] ?? "")
        app.secureTextFields["addServer.password"].tap()
        app.secureTextFields["addServer.password"].typeText(env["SUBSONIC_PASSWORD"] ?? "")
        app.buttons["addServer.connect"].tap()
        let albums = app.buttons["Alba"]
        XCTAssertTrue(albums.waitForExistence(timeout: 15))
        dismissSavePasswordPrompt(app)
        sleep(2)
        screenshot(app, "cs-02-library")

        albums.tap()
        let album = app.scrollViews.buttons.firstMatch
        XCTAssertTrue(album.waitForExistence(timeout: 10))
        album.tap()
        let play = app.buttons["detail.play"]
        XCTAssertTrue(play.waitForExistence(timeout: 10))
        XCTAssertTrue(waitUntil(timeout: 10) { play.isEnabled })
        screenshot(app, "cs-03-album")
        play.tap()
        let miniPlayer = app.buttons["miniPlayer"]
        XCTAssertTrue(miniPlayer.waitForExistence(timeout: 20))
        miniPlayer.tap()
        XCTAssertTrue(app.descendants(matching: .any)["player.scrubber"].firstMatch.waitForExistence(timeout: 10))
        sleep(2)
        screenshot(app, "cs-04-player")
        app.buttons["player.close"].tap()

        app.buttons["Nastavení"].firstMatch.tap()
        sleep(1)
        screenshot(app, "cs-05-settings")
    }

    private func addServer(_ app: XCUIApplication, screenshots: Bool = true) {
        let address = app.textFields["addServer.address"]
        XCTAssertTrue(address.waitForExistence(timeout: 10))
        if screenshots { screenshot(app, "01-onboarding") }
        address.tap()
        address.typeText(env["SUBSONIC_HOST"]!)
        app.textFields["addServer.username"].tap()
        app.textFields["addServer.username"].typeText(env["SUBSONIC_USER"] ?? "")
        app.secureTextFields["addServer.password"].tap()
        app.secureTextFields["addServer.password"].typeText(env["SUBSONIC_PASSWORD"] ?? "")
        app.buttons["addServer.connect"].tap()

        XCTAssertTrue(app.buttons["Albums"].waitForExistence(timeout: 15), "the library should open after connecting")
        dismissSavePasswordPrompt(app)
        sleep(2)
        if screenshots { screenshot(app, "02-library") }
    }

    /// Without a name, the first album in the grid.
    private func openAlbum(_ app: XCUIApplication, named name: String?, screenshots: Bool = true) {
        app.buttons["Albums"].tap()
        let album = name.map {
            app.buttons.containing(NSPredicate(format: "label CONTAINS %@", $0)).firstMatch
        } ?? app.scrollViews.buttons.firstMatch
        XCTAssertTrue(album.waitForExistence(timeout: 10))
        sleep(1)
        if screenshots { screenshot(app, "03-albums") }
        album.tap()
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
