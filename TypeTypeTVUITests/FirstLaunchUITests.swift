import XCTest

/// A first-run UI smoke test. It intentionally uses no private server and no
/// account token; it also records a screenshot of the setup screen for visual review.
final class TypeTypeTVUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    /// tvOS focus changes finish after SwiftUI updates and sometimes after
    /// a lazy grid scroll. Wait for the intended destination, not the transient
    /// focus reported immediately after a Siri Remote press.
    private func waitForFocus(_ target: XCUIElement,
                              timeout: TimeInterval = 5) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if target.exists && target.hasFocus { return true }
            Thread.sleep(forTimeInterval: 0.15)
        } while Date() < deadline
        return target.exists && target.hasFocus
    }

    /// Poll a debug-only, noninteractive FocusState probe when UIKit Pickers
    /// or UIViewRepresentable wrappers do not expose .hasFocus to XCTest.
    private func waitForLabel(_ target: XCUIElement, expected: String,
                              timeout: TimeInterval = 5) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if target.exists && target.label == expected { return true }
            Thread.sleep(forTimeInterval: 0.15)
        } while Date() < deadline
        return target.exists && target.label == expected
    }

    /// Home Back moves from content to the first recommended tile and then
    /// into the global rail. The first press may already reach the rail if
    /// that tile was initially focused by the simulator.
    private func focusHomeIcon(_ app: XCUIApplication) {
        let home = app.buttons["main-nav-home"]
        let first = app.buttons["home-baseline-video-0"]
        if home.hasFocus { return }
        XCUIRemote.shared.press(.menu)
        if waitForFocus(home, timeout: 0.8) { return }
        XCTAssertTrue(waitForFocus(first),
                      "First Home Back must select the top recommendation")
        XCUIRemote.shared.press(.menu)
        XCTAssertTrue(waitForFocus(home),
                      "Second Home Back must select the global Home icon")
    }

    /// Every icon must receive focus in order. Never mask a skipped icon or
    /// an unwanted focus transfer into preview content.
    private func moveDownMainRail(_ app: XCUIApplication, to destination: String) {
        let order = ["search", "subscriptions", "channels",
                     "library", "account", "settings"]
        guard let index = order.firstIndex(of: destination) else {
            XCTFail("Unsupported main navigation destination: \(destination)")
            return
        }
        for item in order.prefix(through: index) {
            XCUIRemote.shared.press(.down)
            XCTAssertTrue(waitForFocus(app.buttons["main-nav-\(item)"]),
                          "Down in main navigation must focus \(item)")
        }
    }

    func testFirstLaunchShowsAccessibleServerSetup() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-typetype.instanceOrigin", "", "-typetype.uiLanguage", "de"]
        app.launch()
        XCTAssertTrue(app.staticTexts["TypeType"].waitForExistence(timeout: 20))
        XCTAssertTrue(app.staticTexts["Serveradresse"].exists)
        XCTAssertTrue(app.textFields.firstMatch.exists)
        XCTAssertTrue(app.buttons["Mit TypeType verbinden"].exists)
        // The domain suffix buttons were removed from the setup screen.
        XCTAssertFalse(app.buttons[".de"].exists)
        XCTAssertFalse(app.buttons[".com"].exists)
        XCTAssertFalse(app.buttons[".org"].exists)
        XCTAssertFalse(app.buttons["www."].exists)

        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "TypeType-tvOS-Servereinrichtung"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }
    func testHomeUsesOptimizedGridWithoutExperimentalMode() throws {
        let app = XCUIApplication()
        app.launchArguments = [
            "-TypeTypeTVPreview", "home", "-typetype.uiLanguage", "de"
        ]
        app.launch()
        let first = app.buttons["home-baseline-video-0"]
        XCTAssertTrue(waitForFocus(first, timeout: 10),
                      "The optimized Home must be the default on a fresh install")
    }

    func testHomeScreenLayoutWithoutServer() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-TypeTypeTVPreview", "home", "-typetype.uiLanguage", "de"]
        app.launch()
        XCTAssertTrue(app.staticTexts["FÜR DICH"].waitForExistence(timeout: 20))
        XCTAssertTrue(app.staticTexts["Empfehlungen"].exists)
        XCTAssertTrue(app.staticTexts["Ansehen fortsetzen"].exists)
        XCTAssertTrue(app.buttons["main-nav-account"].exists)
        XCTAssertTrue(waitForFocus(app.buttons["home-baseline-video-0"], timeout: 8),
                      "Home must initially focus the first recommendation, not the rail or history")
        XCTAssertFalse(app.buttons["main-nav-home"].hasFocus)
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "TypeType-tvOS-Startseite"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testHomeFocusFollowsRepeatedRemoteMovesRatherThanReturningToFirstCard() throws {
        let app = XCUIApplication()
        app.launchArguments = [
            "-TypeTypeTVPreview", "home", "-typetype.uiLanguage", "de"
        ]
        app.launch()
        let first = app.buttons["home-baseline-video-0"]
        let second = app.buttons["home-baseline-video-1"]
        let third = app.buttons["home-baseline-video-2"]
        XCTAssertTrue(waitForFocus(first, timeout: 8))
        XCUIRemote.shared.press(.right)
        XCTAssertTrue(waitForFocus(second), "First Right must focus recommendation 1")
        XCUIRemote.shared.press(.right)
        XCTAssertTrue(waitForFocus(third), "Second Right must focus recommendation 2")
        Thread.sleep(forTimeInterval: 0.9)
        XCTAssertTrue(third.hasFocus,
                      "Delayed startup/scroll restoration must not move focus to item 0")
        XCTAssertFalse(app.buttons["main-nav-home"].hasFocus)
    }

    func testContinueWatchingIsOneScrollableShelfWithMoreThanFourCards() throws {
        let app = XCUIApplication()
        app.launchArguments = [
            "-TypeTypeTVPreview", "home", "-typetype.uiLanguage", "de"
        ]
        app.launch()
        XCTAssertTrue(app.staticTexts["Ansehen fortsetzen"]
            .waitForExistence(timeout: 20))
        let recommendation = app.buttons["home-baseline-video-0"]
        XCTAssertTrue(waitForFocus(recommendation, timeout: 8))
        // The preview contains five partially watched videos separated
        // by completed and never-started history entries.
        XCUIRemote.shared.press(.up)
        XCTAssertTrue(waitForFocus(app.buttons["home-baseline-recent-0"]),
                      "Up from recommendations should enter the resume shelf")
        for index in 1...4 {
            XCUIRemote.shared.press(.right)
            XCTAssertTrue(waitForFocus(app.buttons["home-baseline-recent-\(index)"]),
                          "Right should reach resume item \(index) in the same row")
        }
        XCTAssertFalse(app.buttons["main-nav-home"].hasFocus)
        XCUIRemote.shared.press(.left)
        XCTAssertTrue(waitForFocus(app.buttons["home-baseline-recent-3"]))
    }

    func testBackFromDistantResumeVideoRestoresHorizontalShelfPosition() throws {
        let app = XCUIApplication()
        app.launchArguments = [
            "-TypeTypeTVPreview", "home", "-typetype.uiLanguage", "de"
        ]
        app.launch()
        let recommendation = app.buttons["home-baseline-video-0"]
        XCTAssertTrue(waitForFocus(recommendation, timeout: 10))
        XCUIRemote.shared.press(.up)
        XCTAssertTrue(waitForFocus(app.buttons["home-baseline-recent-0"]))
        for _ in 1...4 { XCUIRemote.shared.press(.right) }
        let distant = app.buttons["home-baseline-recent-4"]
        XCTAssertTrue(waitForFocus(distant), "The horizontal resume shelf must scroll to card 5")
        XCUIRemote.shared.press(.select)
        XCTAssertTrue(app.buttons["video-play"].waitForExistence(timeout: 10))
        XCUIRemote.shared.press(.menu)
        XCTAssertTrue(waitForFocus(distant, timeout: 10),
                      "Back must restore the same horizontal card, not shelf item 1")
    }

    func testExpandedSidebarLayoutWithoutServer() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-TypeTypeTVPreview", "home-expanded", "-typetype.uiLanguage", "de"]
        app.launch()
        XCTAssertTrue(app.buttons["Start"].waitForExistence(timeout: 20))
        XCTAssertFalse(app.buttons["Menü einklappen"].exists,
                       "Sidebar now expands on focus, without a toggle button")
        XCTAssertTrue(app.staticTexts["Empfehlungen"].exists)
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "TypeType-tvOS-Menü-ausgeklappt"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testCollapsedSidebarBackdropReachesBothScreenEdges() throws {
        let app = XCUIApplication()
        app.launchArguments = [
            "-TypeTypeTVPreview", "settings-about", "-typetype.uiLanguage", "de"
        ]
        app.launch()
        XCTAssertTrue(app.staticTexts["App-Informationen"]
            .waitForExistence(timeout: 20))
        let shot = app.screenshot()
        let attachment = XCTAttachment(screenshot: shot)
        attachment.name = "TypeType-tvOS-Seitenleiste-vollstaendige-Hoehe"
        attachment.lifetime = .keepAlways
        add(attachment)

        // Regression for the top/bottom black bands on the 56-point rail.
        // Compare pixel brightness with the black page background at the
        // same height; don't rely on UI frames, which omit tvOS safe areas.
        guard let image = shot.image.cgImage,
              let provider = image.dataProvider,
              let data = provider.data as Data?,
              image.bitsPerPixel >= 24 else {
            throw XCTSkip("Screenshot pixel buffer not available")
        }
        let bytes = [UInt8](data)
        let step = image.bitsPerPixel / 8
        func brightness(x: Int, y: Int) -> Int? {
            guard x >= 0, x < image.width,
                  y >= 0, y < image.height else { return nil }
            let offset = y * image.bytesPerRow + x * step
            guard offset + 3 < bytes.count else { return nil }
            // Channel order is unimportant for a neutral gray background.
            // Sum of four bytes accommodates ARGB and BGRA screenshots.
            return (0..<4).reduce(0) { $0 + Int(bytes[offset + $1]) }
        }
        let leftX = max(8, image.width / 120)
        let pageX = image.width / 2
        for y in [max(8, image.height / 100),
                  image.height - max(8, image.height / 100)] {
            guard let left = brightness(x: leftX, y: y),
                  let page = brightness(x: pageX, y: y) else {
                throw XCTSkip("Cannot sample screenshot pixels")
            }
            XCTAssertGreaterThan(left - page, 20,
                "Collapsed rail must be gray at screen edge, not page black (y=\(y))")
        }
    }

    func testBackFromHomeStaysInsideApp() throws {
        let app = XCUIApplication()
        app.launchArguments = [
            "-TypeTypeTVPreview", "home", "-typetype.uiLanguage", "de"
        ]
        app.launch()
        XCTAssertTrue(app.staticTexts["Empfehlungen"].waitForExistence(timeout: 20))
        // Menu/Back at the root must return to the rail, not Apple TV Home.
        XCUIRemote.shared.press(.menu)
        XCTAssertTrue(app.staticTexts["Empfehlungen"].waitForExistence(timeout: 5))
        XCUIRemote.shared.press(.menu)
        XCTAssertTrue(app.staticTexts["Empfehlungen"].waitForExistence(timeout: 5))
    }

    func testBackFromSettingsUnwindsToHomeAndStaysInApp() throws {
        let app = XCUIApplication()
        app.launchArguments = [
            "-TypeTypeTVPreview", "settings-device", "-typetype.uiLanguage", "de"
        ]
        app.launch()
        XCTAssertTrue(app.staticTexts["Einstellungen"].firstMatch.waitForExistence(timeout: 20))
        XCTAssertTrue(app.staticTexts["Apple TV"].firstMatch.exists)
        // Initial focus is on the Apple TV settings group. Back goes to the
        // global Settings icon, then to Home, and finally becomes a no-op.
        XCUIRemote.shared.press(.menu)
        XCTAssertTrue(app.staticTexts["Einstellungen"].firstMatch.exists)
        XCUIRemote.shared.press(.menu)
        XCTAssertTrue(app.staticTexts["Empfehlungen"].waitForExistence(timeout: 8))
        XCUIRemote.shared.press(.menu)
        XCTAssertTrue(app.staticTexts["Empfehlungen"].waitForExistence(timeout: 5))
    }

    func testBlockedKeywordUnblockButtonReachableFromInput() throws {
        let app = XCUIApplication()
        app.launchArguments = [
            "-TypeTypeTVPreview", "settings-blocked", "-typetype.uiLanguage", "de"
        ]
        app.launch()
        let group = app.buttons["settings-group-blocked"]
        let keywordInput = app.textFields["blocked-keyword-input"]
        let keywordUnblock = app.buttons["blocked-unblock-keywords|Beispielwort Eins"]
        XCTAssertTrue(group.waitForExistence(timeout: 20))
        XCTAssertTrue(keywordInput.waitForExistence(timeout: 10))
        XCTAssertTrue(keywordUnblock.waitForExistence(timeout: 10))
        XCTAssertTrue(waitForFocus(group))
        XCUIRemote.shared.press(.right)
        let refresh = app.buttons["blocked.refresh"]
        XCTAssertTrue(waitForFocus(refresh))
        XCUIRemote.shared.press(.down)
        XCTAssertTrue(waitForFocus(app.buttons["blocked-unblock-videos|https://youtu.be/ABCDEFGHIJK"]))
        XCUIRemote.shared.press(.down)
        XCTAssertTrue(waitForFocus(app.buttons["blocked-unblock-channels|https://www.youtube.com/channel/UC-preview"]))
        XCUIRemote.shared.press(.down)
        XCTAssertTrue(waitForFocus(keywordUnblock),
                      "Keyword Unblock must be directly reachable below the viewport")
        XCUIRemote.shared.press(.up)
        XCTAssertTrue(waitForFocus(keywordInput),
                      "Up from the first keyword should reach the Add keyword field")
    }


    func testContentSettingsLeftFromSubnavigationRevealsMainSettings() throws {
        let app = XCUIApplication()
        app.launchArguments = [
            "-TypeTypeTVPreview", "settings-content", "-typetype.uiLanguage", "de"
        ]
        app.launch()
        let category = app.buttons["settings-group-content"]
        let mainSettings = app.buttons["main-nav-settings"]
        XCTAssertTrue(waitForFocus(category, timeout: 20))
        XCUIRemote.shared.press(.left)
        XCTAssertTrue(waitForFocus(mainSettings),
                      "Left from a Settings group must reveal the main sidebar")
        let first = app.buttons["content.hideHomeRecommendations"]
        XCTAssertTrue(first.waitForExistence(timeout: 10))
        XCUIRemote.shared.press(.right)
        // Native SwiftUI may reopen Settings on the selected category OR
        // directly on its first control. Both are legitimate entry points,
        // but the bidirectional focus path must still work. Do not silently
        // accept a stale global-sidebar focus or the wrong Settings group.
        let returnedToGroup = waitForFocus(category, timeout: 2)
        let returnedToControl = !returnedToGroup && waitForFocus(first, timeout: 3)
        XCTAssertTrue(returnedToGroup || returnedToControl,
                      "Right from the global Settings icon must re-enter the selected Content category or its first control")
        XCTAssertFalse(mainSettings.hasFocus,
                       "Global Settings icon must relinquish focus on Right")
        if returnedToControl {
            XCUIRemote.shared.press(.left)
            XCTAssertTrue(waitForFocus(category),
                          "Left from the first Content control returns to its category")
        }
        XCUIRemote.shared.press(.right)
        XCTAssertTrue(waitForFocus(first),
                      "Right from the selected Content category enters its first control")
    }

    func testContentSettingsNativeFocusCanReachRefreshAndRememberSelection() throws {
        let app = XCUIApplication()
        app.launchArguments = [
            "-TypeTypeTVPreview", "settings-content", "-typetype.uiLanguage", "de"
        ]
        app.launch()
        let category = app.buttons["settings-group-content"]
        let first = app.buttons["content.hideHomeRecommendations"]
        let refresh = app.buttons["settings-content-refresh"]
        XCTAssertTrue(waitForFocus(category, timeout: 20))
        XCTAssertTrue(first.waitForExistence(timeout: 10))
        XCTAssertTrue(refresh.waitForExistence(timeout: 10))
        XCUIRemote.shared.press(.right)
        XCTAssertTrue(waitForFocus(first), "Native Right enters the first content setting")
        // Controls are arranged vertically; descriptions are not focusable.
        // Native ScrollView focuses the offscreen picker and then Refresh.
        for _ in 0..<12 {
            if refresh.hasFocus { break }
            XCUIRemote.shared.press(.down)
        }
        XCTAssertTrue(waitForFocus(refresh),
                      "Refresh must be reachable below the watched-threshold picker")
        XCUIRemote.shared.press(.left)
        XCTAssertTrue(waitForFocus(category),
                      "Native Left returns to the Settings category")
        XCUIRemote.shared.press(.right)
        XCTAssertTrue(waitForFocus(refresh),
                      "Right restores the last Settings control without a timer")
    }

    func testContentChoiceSheetFocusesSelectedValueWithoutScrollingFromTop() throws {
        let app = XCUIApplication()
        app.launchArguments = [
            "-TypeTypeTVPreview", "settings-content",
            "settings-choice-focus-preview", "-typetype.uiLanguage", "de"
        ]
        app.launch()
        let category = app.buttons["settings-group-content"]
        let first = app.buttons["content.hideHomeRecommendations"]
        let watched = app.buttons["content.watchedThreshold"]
        XCTAssertTrue(waitForFocus(category, timeout: 20))
        XCUIRemote.shared.press(.right)
        XCTAssertTrue(waitForFocus(first))
        for _ in 0..<12 {
            if watched.hasFocus { break }
            XCUIRemote.shared.press(.down)
        }
        XCTAssertTrue(waitForFocus(watched),
                      "Content watched picker must remain natively reachable")
        XCUIRemote.shared.press(.select)
        let selected = app.buttons["settings-choice-26"] // 0, 50...74, 75
        XCTAssertTrue(waitForFocus(selected, timeout: 8),
                      "The sheet must initially focus 75%, not the first option")
        XCUIRemote.shared.press(.menu)
        XCTAssertTrue(waitForFocus(watched),
                      "Closing the picker must restore focus to the invoking row")
    }

    func testDisabledDeArrowSuboptionsRemainVisibleAndUnfocusable() throws {
        let app = XCUIApplication()
        app.launchArguments = [
            "-TypeTypeTVPreview", "settings-content", "-typetype.uiLanguage", "de"
        ]
        app.launch()
        let category = app.buttons["settings-group-content"]
        let first = app.buttons["content.hideHomeRecommendations"]
        let master = app.buttons["content.deArrow.enabled"]
        XCTAssertTrue(waitForFocus(category, timeout: 20))
        XCUIRemote.shared.press(.right)
        XCTAssertTrue(waitForFocus(first))
        for _ in 0..<17 {
            if master.hasFocus { break }
            XCUIRemote.shared.press(.down)
        }
        XCTAssertTrue(waitForFocus(master),
                      "DeArrow's master switch must remain reachable")
        for key in ["content.deArrow.title", "content.deArrow.thumbnail",
                    "content.deArrow.trust"] {
            let choice = app.buttons[key]
            XCTAssertTrue(choice.exists, "Disabled choice \(key) remains visible")
            XCTAssertFalse(choice.isEnabled, "Disabled choice \(key) must not activate")
        }
    }

    func testSettingsPlaybackRightOpensControlColumn() throws {
        let app = XCUIApplication()
        app.launchArguments = [
            "-TypeTypeTVPreview", "settings",
            "-typetype.uiLanguage", "de"
        ]
        app.launch()
        XCTAssertTrue(app.staticTexts["Videoqualität"].waitForExistence(timeout: 20))
        let first = app.descendants(matching: .any)["settings-first-playback"]
        XCTAssertTrue(first.exists)
        XCUIRemote.shared.press(.right)
        XCTAssertTrue(first.hasFocus,
                      "Right from Settings/Wiedergabe must focus the actual toggle")
        XCUIRemote.shared.press(.down)
        // The 4K resolution menu is the next control. Do not get trapped in
        // the outer global rail or on an invisible group focus rectangle.
        let selectedGroup = app.buttons["settings-group-playback"]
        XCTAssertFalse(selectedGroup.hasFocus)
    }

    func testSettingsSelectEntersControlsAndLeftReturnsToSelectedGroup() throws {
        let app = XCUIApplication()
        app.launchArguments = [
            "-TypeTypeTVPreview", "settings", "-typetype.uiLanguage", "de"
        ]
        app.launch()
        let group = app.buttons["settings-group-playback"]
        let first = app.buttons["settings-first-playback"]
        XCTAssertTrue(group.waitForExistence(timeout: 20))
        XCTAssertTrue(first.exists)
        XCUIRemote.shared.press(.select)
        XCTAssertTrue(first.hasFocus,
                      "Select on Wiedergabe must enter its content column")
        XCUIRemote.shared.press(.left)
        XCTAssertTrue(group.hasFocus,
                      "Left must return to the selected Settings group")
        XCUIRemote.shared.press(.right)
        XCTAssertTrue(first.hasFocus,
                      "Right must re-enter the same content column")
    }

    func testSponsorBlockIsOwnSettingsNavigationPage() throws {
        let app = XCUIApplication()
        app.launchArguments = [
            "-TypeTypeTVPreview", "settings-sponsor", "-typetype.uiLanguage", "de"
        ]
        app.launch()
        let sponsorGroup = app.buttons["settings-group-sponsor"]
        let playbackGroup = app.buttons["settings-group-playback"]
        let refresh = app.buttons["sponsor-refresh"]
        XCTAssertTrue(sponsorGroup.waitForExistence(timeout: 20))
        XCTAssertTrue(playbackGroup.exists)
        XCTAssertTrue(refresh.waitForExistence(timeout: 10))
        XCTAssertTrue(waitForFocus(sponsorGroup),
                      "SponsorBlock must open as a selected settings category")
        XCTAssertTrue(app.staticTexts["Kategorien"].exists)
        XCTAssertTrue(app.staticTexts["Weitere Optionen"].exists)
        XCTAssertFalse(app.buttons["SponsorBlock konfigurieren"].exists,
                       "There must no longer be a modal launcher in Playback")
        XCUIRemote.shared.press(.right)
        XCTAssertTrue(waitForFocus(refresh),
                      "Right from SponsorBlock must enter the content column")
        // The row exposes both a containing accessibility group and an
        // interactive tvOS Picker button. Only the button receives focus.
        let mode = app.buttons["sponsor.mode"]
        let firstCategory = app.buttons["sponsor.category.sponsor"]
        let focusedState = app.staticTexts["sponsor-focus-state"]
        XCTAssertTrue(focusedState.waitForExistence(timeout: 8))
        XCUIRemote.shared.press(.down)
        XCTAssertTrue(waitForLabel(focusedState, expected: "sponsor.mode"),
                      "Down from Refresh must focus SponsorBlock behavior, not Categories")
        XCUIRemote.shared.press(.up)
        XCTAssertTrue(waitForFocus(refresh),
                      "Up from behavior must return to Refresh")
        XCUIRemote.shared.press(.down)
        XCTAssertTrue(waitForLabel(focusedState, expected: "sponsor.mode"),
                      "First Down must return to SponsorBlock behavior")
        XCUIRemote.shared.press(.down)
        XCTAssertTrue(waitForLabel(focusedState, expected: "sponsor.category.sponsor"),
                      "Next Down from behavior should enter the first category")
        XCUIRemote.shared.press(.up)
        XCTAssertTrue(waitForLabel(focusedState, expected: "sponsor.mode"),
                      "Up from the first category must return to global behavior")
        XCUIRemote.shared.press(.up)
        XCTAssertTrue(waitForFocus(refresh),
                      "Up must return to Refresh before leaving the panel")
        XCUIRemote.shared.press(.left)
        XCTAssertTrue(waitForFocus(sponsorGroup),
                      "Left must return to SponsorBlock in the settings rail")
    }

    func testContentSettingsSwitchesCanBeTraversedIndividually() throws {
        let app = XCUIApplication()
        app.launchArguments = [
            "-TypeTypeTVPreview", "settings-content", "-typetype.uiLanguage", "de"
        ]
        app.launch()
        let recommendations = app.buttons["content.hideHomeRecommendations"]
        let continueWatching = app.buttons["content.hideContinueWatching"]
        XCTAssertTrue(recommendations.waitForExistence(timeout: 20))
        XCUIRemote.shared.press(.right)
        XCTAssertTrue(recommendations.hasFocus,
                      "Content has to enter the first real switch")
        XCUIRemote.shared.press(.down)
        XCTAssertTrue(continueWatching.hasFocus,
                      "Each content switch must have its own focus identity")
    }

    func testMainNavigationUsesSubscriptionsNotDuplicatePlaylists() throws {
        let app = XCUIApplication()
        app.launchArguments = [
            "-TypeTypeTVPreview", "home",
            "-typetype.uiLanguage", "de"
        ]
        app.launch()
        XCTAssertTrue(app.buttons["Abo-Kanäle"].waitForExistence(timeout: 20))
        XCTAssertTrue(app.buttons["Abonnements"].exists)
        XCTAssertFalse(app.buttons["Listen"].exists)
        XCTAssertTrue(app.buttons["Bibliothek"].exists)
    }

    func testSabrFailureDialogAllowsRetryAndBackWithRemote() throws {
        let app = XCUIApplication()
        app.launchArguments = [
            "-TypeTypeTVPreview", "player-error", "-typetype.uiLanguage", "de"
        ]
        app.launch()
        XCTAssertTrue(app.staticTexts["SABR-Wiedergabe fehlgeschlagen"]
            .waitForExistence(timeout: 20))
        let retry = app.buttons["Erneut versuchen"]
        XCTAssertTrue(retry.exists)
        XCTAssertTrue(app.buttons["Zurück"].exists)
        XCTAssertTrue(waitForFocus(retry),
                      "Native defaultFocus must select Retry without delayed correction")
        // The first Select must ACTIVATE Retry, not toggle video playback via
        // the underlying fullscreen UIKit remote responder.
        XCUIRemote.shared.press(.select)
        XCTAssertTrue(app.staticTexts["retry"].waitForExistence(timeout: 8))
        // Left/right navigation must also reach the Back button.
        XCUIRemote.shared.press(.right)
        XCUIRemote.shared.press(.select)
        XCTAssertTrue(app.staticTexts["back"].waitForExistence(timeout: 8))
    }

    func testSearchScreenLayoutWithoutServer() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-TypeTypeTVPreview", "search", "-typetype.uiLanguage", "de"]
        app.launch()
        XCTAssertTrue(app.staticTexts["VIDEOS ENTDECKEN"].waitForExistence(timeout: 20))
        XCTAssertTrue(app.textFields.firstMatch.exists)
        XCTAssertTrue(waitForFocus(app.textFields.firstMatch),
                      "Search preview entry should use native text-field default focus")
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "TypeType-tvOS-Suche"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testVideoDetailUsesNativeActionRowNavigation() throws {
        let app = XCUIApplication()
        app.launchArguments = [
            "-TypeTypeTVPreview", "details", "-typetype.uiLanguage", "de"
        ]
        app.launch()
        let play = app.buttons["video-play"]
        let back = app.buttons["video-detail-back"]
        let watched = app.buttons["video-mark-watched"]
        let playlist = app.buttons["video-add-playlist"]
        let description = app.buttons["video-description-entry"]
        XCTAssertTrue(waitForFocus(play, timeout: 10),
                      "Play is the native initial focus preference")
        XCTAssertTrue(playlist.exists, "Playlist action is available in row two")
        XCUIRemote.shared.press(.right)
        XCTAssertTrue(waitForFocus(back), "Right reaches Back in the first action row")
        XCUIRemote.shared.press(.left)
        XCTAssertTrue(waitForFocus(play), "Left returns to Play")
        XCUIRemote.shared.press(.down)
        XCTAssertTrue(waitForFocus(watched), "Down from Play reaches Mark Watched")
        XCUIRemote.shared.press(.down)
        XCTAssertTrue(waitForFocus(description),
                      "Native focus scrolling reaches the description")
    }

    func testVideoDetailsLayoutWithoutServer() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-TypeTypeTVPreview", "details", "-typetype.uiLanguage", "de"]
        app.launch()
        XCTAssertTrue(app.staticTexts["Neuigkeiten aus der Welt der Technik"].waitForExistence(timeout: 20))
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "TypeType-tvOS-Videodetails"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testEnglishSettingsPreview() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-TypeTypeTVPreview", "settings",
                               "-typetype.uiLanguage", "en"]
        app.launch()
        XCTAssertTrue(app.staticTexts["Settings"].firstMatch.waitForExistence(timeout: 20))
        XCTAssertTrue(app.staticTexts["Language"].firstMatch.exists)
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "TypeType-tvOS-Settings-English"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }

    func testFrenchHomePreview() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-TypeTypeTVPreview", "home",
                               "-typetype.uiLanguage", "fr"]
        app.launch()
        XCTAssertTrue(app.staticTexts["Recommandations"].waitForExistence(timeout: 20))
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "TypeType-tvOS-Accueil-Francais"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }

    func testSpanishSearchPreview() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-TypeTypeTVPreview", "search",
                               "-typetype.uiLanguage", "es"]
        app.launch()
        XCTAssertTrue(app.staticTexts["DESCUBRIR VÍDEOS"].waitForExistence(timeout: 20))
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "TypeType-tvOS-Busqueda-Espanol"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }

    func testGermanSettingsPlaybackPanelScreenshot() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-TypeTypeTVPreview", "settings",
                               "-typetype.uiLanguage", "de"]
        app.launch()
        XCTAssertTrue(app.staticTexts["Wiedergabe"].firstMatch.waitForExistence(timeout: 20))
        XCTAssertTrue(app.staticTexts["Videoqualität"].firstMatch.exists)
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "TypeType-tvOS-Einstellungen-Wiedergabe-DE"
        shot.lifetime = .keepAlways
        add(shot)
    }

    func testGermanSettingsContentPanelScreenshot() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-TypeTypeTVPreview", "settings-content",
                               "-typetype.uiLanguage", "de"]
        app.launch()
        XCTAssertTrue(app.staticTexts["Inhalte"].firstMatch.waitForExistence(timeout: 20))
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "TypeType-tvOS-Einstellungen-Inhalte-DE"
        shot.lifetime = .keepAlways
        add(shot)
    }

    func testGermanSettingsDevicePanelScreenshot() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-TypeTypeTVPreview", "settings-device",
                               "-typetype.uiLanguage", "de"]
        app.launch()
        XCTAssertTrue(app.staticTexts["Apple TV"].firstMatch.waitForExistence(timeout: 20))
        XCTAssertTrue(app.staticTexts["Sanfte Menüanimationen"].firstMatch.exists)
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "TypeType-tvOS-Einstellungen-AppleTV-DE"
        shot.lifetime = .keepAlways
        add(shot)
    }


    func testAccountManagementOpensMethodChoiceInsteadOfInlineLogin() throws {
        let app = XCUIApplication()
        app.launchArguments = [
            "-TypeTypeTVPreview", "settings-account",
            "-typetype.uiLanguage", "de"
        ]
        app.launch()
        XCTAssertTrue(app.staticTexts["Konten"].firstMatch.waitForExistence(timeout: 20))
        XCTAssertTrue(app.staticTexts["Gespeicherte Konten auf diesem Apple TV"].firstMatch.exists)
        XCTAssertFalse(app.secureTextFields.firstMatch.exists,
                       "Passwords must not appear inline on saved accounts list")
        let add = app.buttons["accounts-add"]
        XCTAssertTrue(add.waitForExistence(timeout: 5))
        // tvOS has no XCUIElement.tap(): navigate with the actual Siri Remote.
        // Focus starts on the selected "Konten" settings group.
        XCUIRemote.shared.press(.right)
        XCTAssertTrue(add.hasFocus, "Right from Konten must reach Add Account")
        XCUIRemote.shared.press(.select)
        XCTAssertTrue(app.staticTexts["Konto hinzufügen"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["Benutzername und Passwort"].exists)
        XCTAssertTrue(app.buttons["Mit Gerätecode anmelden"].exists)

        // The method chooser defaults focus to username/password.
        XCUIRemote.shared.press(.select)
        XCTAssertTrue(app.secureTextFields.firstMatch.waitForExistence(timeout: 5))
        XCTAssertTrue(app.textFields.firstMatch.exists)
        XCTAssertTrue(app.buttons["Anmelden"].exists ||
                      app.buttons["Mit Passwort anmelden"].exists)
    }


    func testAccountTopShelfSwitchUsesNativeTwoColumnFocus() throws {
        let app = XCUIApplication()
        app.launchArguments = [
            "-TypeTypeTVPreview", "settings-account-profiles",
            "-typetype.uiLanguage", "de"
        ]
        app.launch()
        let category = app.buttons["settings-group-account"]
        let firstRemove = app.buttons["accounts-remove-ui-profile-a"]
        let firstToggle = app.buttons["accounts-topshelf-ui-profile-a"]
        let secondRemove = app.buttons["accounts-remove-ui-profile-b"]
        let secondToggle = app.buttons["accounts-topshelf-ui-profile-b"]
        XCTAssertTrue(waitForFocus(category, timeout: 20))
        XCTAssertTrue(firstRemove.waitForExistence(timeout: 10))
        XCTAssertTrue(secondRemove.exists)

        // Entering from the left Settings rail must prefer "Konto entfernen",
        // rather than focusing the new switch on the same row.
        XCUIRemote.shared.press(.right)
        XCTAssertTrue(waitForFocus(firstRemove))
        XCUIRemote.shared.press(.left)
        XCTAssertTrue(waitForFocus(firstToggle),
                      "Left from the remove action must reach Top Shelf")

        // Vertical moves stay on the same column; horizontal moves cross the
        // row. No delayed FocusState correction or background polling.
        XCUIRemote.shared.press(.down)
        XCTAssertTrue(waitForFocus(secondToggle))
        XCUIRemote.shared.press(.right)
        XCTAssertTrue(waitForFocus(secondRemove))
        XCUIRemote.shared.press(.up)
        XCTAssertTrue(waitForFocus(firstRemove))
        XCUIRemote.shared.press(.left)
        XCTAssertTrue(waitForFocus(firstToggle))

        let before = firstToggle.value as? String
        XCUIRemote.shared.press(.select)
        XCTAssertNotEqual(firstToggle.value as? String, before,
                          "Select must toggle this profile's local opt-in")
        XCUIRemote.shared.press(.left)
        XCTAssertTrue(waitForFocus(category),
                      "Left from Top Shelf must return directly to Settings")
        XCUIRemote.shared.press(.right)
        XCTAssertTrue(waitForFocus(firstRemove),
                      "Re-entering Accounts should prefer the first remove action")
    }

    func testAccountLastRowMovesDownToAddAndLocalLogoutFromEitherColumn() throws {
        let app = XCUIApplication()
        app.launchArguments = [
            "-TypeTypeTVPreview", "settings-account-profiles",
            "test-account-local-logout", "-typetype.uiLanguage", "de"
        ]
        app.launch()

        let category = app.buttons["settings-group-account"]
        let firstRemove = app.buttons["accounts-remove-ui-profile-a"]
        let lastRemove = app.buttons["accounts-remove-ui-profile-b"]
        let lastToggle = app.buttons["accounts-topshelf-ui-profile-b"]
        let add = app.buttons["accounts-add"]
        let logout = app.buttons["accounts-logout"]

        XCTAssertTrue(waitForFocus(category, timeout: 20))
        XCTAssertTrue(add.waitForExistence(timeout: 10))
        XCTAssertTrue(logout.waitForExistence(timeout: 10))

        // The right column must still be the native Settings entry target.
        XCUIRemote.shared.press(.right)
        XCTAssertTrue(waitForFocus(firstRemove))

        // Vertical focus within saved accounts remains native.
        XCUIRemote.shared.press(.down)
        XCTAssertTrue(waitForFocus(lastRemove))

        // Last row's far-right button must reach the left-aligned footer.
        XCUIRemote.shared.press(.down)
        XCTAssertTrue(waitForFocus(add),
                      "Down from the last Remove must reach Add Account")
        XCUIRemote.shared.press(.down)
        XCTAssertTrue(waitForFocus(logout),
                      "Down from Add Account must reach Local Logout")

        // Reverse navigation returns to the saved account's default action.
        XCUIRemote.shared.press(.up)
        XCTAssertTrue(waitForFocus(add))
        XCUIRemote.shared.press(.up)
        XCTAssertTrue(waitForFocus(lastRemove))

        // Exactly the same exit from the other column, with no timer,
        // scrolling workaround or additional remote movement.
        XCUIRemote.shared.press(.left)
        XCTAssertTrue(waitForFocus(lastToggle))
        XCUIRemote.shared.press(.down)
        XCTAssertTrue(waitForFocus(add),
                      "Down from last Top Shelf must reach Add Account")
        XCUIRemote.shared.press(.down)
        XCTAssertTrue(waitForFocus(logout),
                      "Local Logout must also be reachable from Top Shelf")
    }

    func testChannelTabsReachSubscriptionButtonWithRemote() throws {
        let app = XCUIApplication()
        app.launchArguments = [
            "-TypeTypeTVPreview", "channels", "-typetype.uiLanguage", "de"
        ]
        app.launch()
        let channel = app.buttons["subscription-https://preview.invalid/channel/a"]
        let subscribe = app.buttons["channel-subscription-toggle"]
        let videosTab = app.buttons["Videos"]
        let shortsTab = app.buttons["Shorts"]
        let actions = app.buttons["channel-action-playlists"]
        XCTAssertTrue(waitForFocus(channel, timeout: 20))
        XCTAssertTrue(subscribe.waitForExistence(timeout: 12))
        XCUIRemote.shared.press(.right)
        let firstVideo = app.buttons["subscription-video-0"]
        XCTAssertTrue(waitForFocus(firstVideo, timeout: 10))
        XCUIRemote.shared.press(.up)
        XCTAssertTrue(waitForFocus(actions, timeout: 5),
                      "Up from thumbnails must reach the channel action row")
        XCUIRemote.shared.press(.up)
        XCTAssertTrue(waitForFocus(videosTab, timeout: 5),
                      "Up from actions must reach the Videos/Shorts tabs")
        XCUIRemote.shared.press(.up)
        XCTAssertTrue(waitForFocus(subscribe, timeout: 5),
                      "Up from Videos must reach the subscription button")
        XCUIRemote.shared.press(.down)
        XCTAssertTrue(waitForFocus(videosTab, timeout: 5),
                      "Down must restore the active Videos tab")
        XCUIRemote.shared.press(.right)
        XCTAssertTrue(waitForFocus(shortsTab, timeout: 5),
                      "Right from Videos must remain able to reach Shorts")
        XCUIRemote.shared.press(.right)
        XCTAssertTrue(waitForFocus(subscribe, timeout: 5),
                      "Right from Shorts must reach the subscription button")
    }

    func testChannelVideoFocusReturnsToSavedTileFromBothRails() throws {
        let app = XCUIApplication()
        app.launchArguments = [
            "-TypeTypeTVPreview", "channels", "-typetype.uiLanguage", "de"
        ]
        app.launch()
        let rail = app.buttons["subscription-https://preview.invalid/channel/a"]
        let first = app.buttons["subscription-video-0"]
        let deep = app.buttons["subscription-video-3"]
        let main = app.buttons["main-nav-channels"]

        XCTAssertTrue(waitForFocus(rail, timeout: 20))
        XCUIRemote.shared.press(.right)
        XCTAssertTrue(waitForFocus(first, timeout: 10))
        XCUIRemote.shared.press(.down)
        XCTAssertTrue(waitForFocus(deep, timeout: 5),
                      "The second video row must be reachable")
        XCUIRemote.shared.press(.left)
        XCTAssertTrue(waitForFocus(rail, timeout: 5))
        XCUIRemote.shared.press(.right)
        XCTAssertTrue(waitForFocus(deep, timeout: 5),
                      "Native focus must reenter the second row directly")

        XCUIRemote.shared.press(.left)
        XCTAssertTrue(waitForFocus(rail, timeout: 5))
        XCUIRemote.shared.press(.left)
        XCTAssertTrue(waitForFocus(main, timeout: 5))
        XCUIRemote.shared.press(.right)
        let restoredDirectly = waitForFocus(deep, timeout: 8)
        if !restoredDirectly {
            // Diagnose only on failure: report where UIKit actually placed
            // focus. Do not send a second remote event or accept a wrong tile.
            let actual = app.buttons.allElementsBoundByIndex
                .filter { $0.hasFocus }
                .map { $0.identifier.isEmpty ? $0.label : $0.identifier }
            XCTFail("Global rail must return to the saved tile; actual focused buttons: \(actual)")
        }
    }

    func testChannelPageDisplaysCurrentSubscriptionState() throws {
        let app = XCUIApplication()
        app.launchArguments = [
            "-TypeTypeTVPreview", "channels", "-typetype.uiLanguage", "de"
        ]
        app.launch()
        let channel = app.buttons["subscription-https://preview.invalid/channel/a"]
        XCTAssertTrue(waitForFocus(channel, timeout: 20),
                      "Opening Subscribed Channels should focus its first channel")
        let subscribe = app.buttons["channel-subscription-toggle"]
        XCTAssertTrue(subscribe.waitForExistence(timeout: 12),
                      "Every channel page should expose an account subscription button")
        XCTAssertTrue(subscribe.label.contains("Abonniert"),
                      "An existing subscription must show its active status")
        XCTAssertTrue(subscribe.label.contains("Abo beenden"),
                      "The same control must also explain how to unsubscribe")
        XCUIRemote.shared.press(.right)
        XCTAssertTrue(app.buttons["subscription-video-0"]
            .waitForExistence(timeout: 8),
            "Entering the channel must retain its video grid")
    }

    func testGlobalChannelsPreviewDoesNotTakeFocusUntilRight() throws {
        let app = XCUIApplication()
        app.launchArguments = [
            "-TypeTypeTVPreview", "home", "-typetype.uiLanguage", "de"
        ]
        app.launch()
        focusHomeIcon(app)
        moveDownMainRail(app, to: "channels")
        let mainChannels = app.buttons["main-nav-channels"]
        XCTAssertTrue(waitForFocus(mainChannels))
        let channel = app.buttons["subscription-https://preview.invalid/channel/a"]
        XCTAssertTrue(channel.waitForExistence(timeout: 8))
        Thread.sleep(forTimeInterval: 0.5)
        XCTAssertTrue(waitForFocus(mainChannels),
                      "Preview must not focus the channel subnavigation")
        XCTAssertFalse(channel.hasFocus,
                       "Preview should only render the subscribed channels")
        XCUIRemote.shared.press(.right)
        XCTAssertTrue(waitForFocus(channel),
                      "Right must enter the channel subnavigation")
    }

    func testHomeRightAfterPreviewOfAnotherSectionNeverStartsInResumeShelf() throws {
        let app = XCUIApplication()
        app.launchArguments = [
            "-TypeTypeTVPreview", "home", "-typetype.uiLanguage", "de"
        ]
        app.launch()
        focusHomeIcon(app)
        let search = app.buttons["main-nav-search"]
        XCUIRemote.shared.press(.down)
        XCTAssertTrue(waitForFocus(search))
        // Actually enter a different screen, as reported on the device,
        // then return through the global rail before activating Home.
        XCUIRemote.shared.press(.select)
        XCTAssertTrue(waitForFocus(app.textFields.firstMatch))
        XCUIRemote.shared.press(.menu)
        XCTAssertTrue(waitForFocus(search))
        XCUIRemote.shared.press(.up)
        XCTAssertTrue(waitForFocus(app.buttons["main-nav-home"]))
        let recent = app.buttons["home-baseline-recent-0"]
        let firstRecommendation = app.buttons["home-baseline-video-0"]
        XCTAssertTrue(recent.waitForExistence(timeout: 8))
        XCTAssertTrue(firstRecommendation.waitForExistence(timeout: 8))
        XCUIRemote.shared.press(.right)
        XCTAssertFalse(recent.hasFocus,
                       "Right into loaded Home must never select Continue Watching")
        XCTAssertTrue(waitForFocus(firstRecommendation),
                      "First recommendation must be the native entry target")
    }

    func testHomeOKFromGlobalRailSelectsFirstRecommendation() throws {
        let app = XCUIApplication()
        app.launchArguments = [
            "-TypeTypeTVPreview", "home", "-typetype.uiLanguage", "de"
        ]
        app.launch()
        focusHomeIcon(app)
        XCUIRemote.shared.press(.select)
        let recommendation = app.buttons["home-baseline-video-0"]
        XCTAssertTrue(recommendation.waitForExistence(timeout: 8))
        XCTAssertTrue(waitForFocus(recommendation),
                      "OK on Home must enter its recommendations, not stay in the rail")
        XCTAssertFalse(app.buttons["main-nav-home"].hasFocus)
    }

    func testHomeContextMenuPreservesNavigationFocus() throws {
        let app = XCUIApplication()
        app.launchArguments = [
            "-TypeTypeTVPreview", "home", "-typetype.uiLanguage", "de"
        ]
        app.launch()
        let video = app.buttons["home-baseline-video-0"]
        XCTAssertTrue(waitForFocus(video, timeout: 10))
        Thread.sleep(forTimeInterval: 0.45)
        XCTAssertTrue(video.hasFocus, "Home must not replace the focused tile")
        XCUIRemote.shared.press(.left)
        XCTAssertTrue(waitForFocus(app.buttons["main-nav-home"]))
        XCUIRemote.shared.press(.right)
        XCTAssertTrue(waitForFocus(video), "The saved tile must receive focus directly")
        Thread.sleep(forTimeInterval: 0.45)
        XCTAssertTrue(video.hasFocus, "Focus remains on the original tile")
    }

    func testOptimizedHomeBackMovesToTopThenGlobalNavigation() throws {
        let app = XCUIApplication()
        app.launchArguments = [
            "-TypeTypeTVPreview", "home",
            "-typetype.uiLanguage", "de"
        ]
        app.launch()
        let first = app.buttons["home-baseline-video-0"]
        XCTAssertTrue(waitForFocus(first, timeout: 10))
        XCUIRemote.shared.press(.down)
        XCUIRemote.shared.press(.down)
        let deep = app.buttons["home-baseline-video-8"]
        XCTAssertTrue(waitForFocus(deep),
                      "The initial Home Back test must start below the top row")
        XCUIRemote.shared.press(.menu)
        XCTAssertTrue(waitForFocus(first, timeout: 10),
                      "First Home Back scrolls to the first recommendation")
        XCUIRemote.shared.press(.menu)
        XCTAssertTrue(waitForFocus(app.buttons["main-nav-home"]),
                      "Second Home Back opens the global navigation")
        XCUIRemote.shared.press(.right)
        XCTAssertTrue(waitForFocus(first),
                      "Right must still return to the same native grid")
        XCUIRemote.shared.press(.left)
        XCTAssertTrue(waitForFocus(app.buttons["main-nav-home"]),
                      "Left from first column must keep its direct rail action")
    }

    func testOptimizedHomeMatchesSubscriptionsGridNavigation() throws {
        let app = XCUIApplication()
        app.launchArguments = [
            "-TypeTypeTVPreview", "home",
            "-typetype.uiLanguage", "de"
        ]
        app.launch()
        let first = app.buttons["home-baseline-video-0"]
        XCTAssertTrue(waitForFocus(first, timeout: 10),
                      "Minimal Home must enter its first recommendation")
        XCTAssertTrue(app.staticTexts["Ansehen fortsetzen"].exists,
                      "The fast Home should now display the optional resume shelf")

        XCUIRemote.shared.press(.down)
        let nextRow = app.buttons["home-baseline-video-4"]
        XCTAssertTrue(waitForFocus(nextRow),
                      "Bare LazyVGrid should use native one-row focus movement")
        XCUIRemote.shared.press(.left)
        XCTAssertTrue(waitForFocus(app.buttons["main-nav-home"]),
                      "Left from first column must open global navigation")
        XCUIRemote.shared.press(.right)
        XCTAssertTrue(waitForFocus(nextRow),
                      "Native Home focus priority must return to the previously selected row")
    }

    func testHomeRailRightReturnsDirectlyToTheSavedDeepCard() throws {
        let app = XCUIApplication()
        app.launchArguments = [
            "-TypeTypeTVPreview", "home", "-typetype.uiLanguage", "de"
        ]
        app.launch()
        XCTAssertTrue(waitForFocus(app.buttons["home-baseline-video-0"], timeout: 8))
        XCUIRemote.shared.press(.down)
        XCUIRemote.shared.press(.down)
        let target = app.buttons["home-baseline-video-8"]
        XCTAssertTrue(waitForFocus(target))
        XCUIRemote.shared.press(.left)
        XCTAssertTrue(waitForFocus(app.buttons["main-nav-home"]))
        XCUIRemote.shared.press(.right)
        XCTAssertTrue(waitForFocus(target),
                      "Home must restore the original focus without choosing a nearby tile")
        Thread.sleep(forTimeInterval: 0.5)
        XCTAssertTrue(target.hasFocus,
                      "Focus must remain on the original card after rail animation")
    }

    func testHomeRailExpandKeepsTheVisibleRecommendationRowInPlace() throws {
        let app = XCUIApplication()
        app.launchArguments = [
            "-TypeTypeTVPreview", "home", "-typetype.uiLanguage", "de"
        ]
        app.launch()
        XCTAssertTrue(waitForFocus(app.buttons["home-baseline-video-0"], timeout: 8))
        // Move to a lower recommendation row, where a column-width reflow
        // would otherwise move the visible content vertically.
        XCUIRemote.shared.press(.down)
        XCUIRemote.shared.press(.down)
        let selected = app.buttons["home-baseline-video-8"]
        let neighbor = app.buttons["home-baseline-video-9"]
        XCTAssertTrue(waitForFocus(selected), "Second Down should reach row 3")
        XCTAssertTrue(neighbor.waitForExistence(timeout: 5))
        let before = neighbor.frame.midY
        XCUIRemote.shared.press(.left)
        XCTAssertTrue(waitForFocus(app.buttons["main-nav-home"]))
        let after = neighbor.frame.midY
        // Home intentionally zooms vertically as the rail expands. Allow
        // the resulting proportional movement, but NOT a whole-row jump
        // from a LazyVGrid relayout or focus-driven scroll correction.
        let allowedZoomDisplacement = abs(before) * 0.12 + 40
        XCTAssertLessThan(abs(after - before), allowedZoomDisplacement,
                          "Opening the sidebar must zoom, not reflow the Home grid")
        XCUIRemote.shared.press(.right)
        XCTAssertTrue(waitForFocus(selected),
                      "Re-enter Home on the remembered row without scrolling to top")
        let finalY = neighbor.frame.midY
        XCTAssertLessThan(abs(finalY - before), 50,
                          "Returning from the rail must not re-center the card by a row")
    }

    func testBackFromDeepHomeRecommendationRestoresTileAndThenTopRecommendation() throws {
        let app = XCUIApplication()
        app.launchArguments = [
            "-TypeTypeTVPreview", "home", "-typetype.uiLanguage", "de"
        ]
        app.launch()
        XCTAssertTrue(waitForFocus(app.buttons["home-baseline-video-0"], timeout: 8),
                      "Home startup must focus the first recommendation")
        for _ in 0..<4 { XCUIRemote.shared.press(.down) }
        // LazyVGrid only instantiates cards near the current viewport.
        // Querying hasFocus on an offscreen, non-existent indexed button can
        // throw an XCTest snapshot exception instead of returning false.
        let visibleRecommendations = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH %@",
                        "home-baseline-video-")
        ).allElementsBoundByIndex
        let focusedDeep = visibleRecommendations.first { button in
            guard let index = Int(button.identifier.replacingOccurrences(
                of: "home-baseline-video-", with: ""
            )) else { return false }
            return index >= 8 && button.hasFocus
        }
        XCTAssertNotNil(focusedDeep,
                        "Remote must reach a recommendation below the first viewport")
        guard let focusedDeep else { return }
        XCUIRemote.shared.press(.select)
        XCTAssertTrue(app.buttons["video-play"].waitForExistence(timeout: 10))
        XCUIRemote.shared.press(.menu)
        XCTAssertTrue(focusedDeep.waitForExistence(timeout: 10))
        XCTAssertTrue(waitForFocus(focusedDeep, timeout: 8),
                      "Back from a distant detail must restore that specific tile")
        XCUIRemote.shared.press(.menu)
        let top = app.buttons["home-baseline-video-0"]
        XCTAssertTrue(top.waitForExistence(timeout: 8))
        XCTAssertTrue(waitForFocus(top, timeout: 8),
                      "Back from a scrolled Home grid must scroll to first recommendation")
    }

    func testBackFromVideoDetailsRestoresOriginatingRecommendation() throws {
        let app = XCUIApplication()
        app.launchArguments = [
            "-TypeTypeTVPreview", "home", "-typetype.uiLanguage", "de"
        ]
        app.launch()
        let recommendation = app.buttons["home-baseline-video-0"]
        XCTAssertTrue(recommendation.waitForExistence(timeout: 20))
        XCTAssertTrue(waitForFocus(recommendation),
                      "Home startup must focus the first recommendation")
        XCUIRemote.shared.press(.select)
        XCTAssertTrue(app.buttons["video-play"].waitForExistence(timeout: 10))
        XCUIRemote.shared.press(.menu)
        XCTAssertTrue(recommendation.waitForExistence(timeout: 10))
        XCTAssertTrue(waitForFocus(recommendation),
                      "Back from a video must focus its original list tile")
        XCTAssertFalse(app.buttons["main-nav-home"].hasFocus,
                       "Returning from details must not jump to the global rail")
    }

    func testLeftFromSearchFieldReturnsToGlobalSearchIcon() throws {
        let app = XCUIApplication()
        app.launchArguments = [
            "-TypeTypeTVPreview", "search", "-typetype.uiLanguage", "de"
        ]
        app.launch()
        let field = app.textFields.firstMatch
        let search = app.buttons["main-nav-search"]
        XCTAssertTrue(waitForFocus(field, timeout: 15))
        XCUIRemote.shared.press(.left)
        XCTAssertTrue(waitForFocus(search),
                      "Left from search input must return to its global sidebar icon")
        XCUIRemote.shared.press(.right)
        XCTAssertTrue(waitForFocus(field),
                      "Right from search icon must re-enter the input without a bounce")
    }

    func testLeftFromAccountAddButtonReturnsToGlobalAccountIcon() throws {
        let app = XCUIApplication()
        app.launchArguments = [
            "-TypeTypeTVPreview", "account", "-typetype.uiLanguage", "de"
        ]
        app.launch()
        let add = app.buttons["account-add-profile"]
        let account = app.buttons["main-nav-account"]
        XCTAssertTrue(waitForFocus(add, timeout: 15))
        XCUIRemote.shared.press(.left)
        XCTAssertTrue(waitForFocus(account),
                      "Left from account content must return to the Account icon")
        XCUIRemote.shared.press(.right)
        XCTAssertTrue(waitForFocus(add),
                      "Right from Account must restore its content focus")
    }

    func testSettingsServerRightPrefersRefreshNatively() throws {
        let app = XCUIApplication()
        app.launchArguments = [
            "-TypeTypeTVPreview", "settings-instance", "-typetype.uiLanguage", "de"
        ]
        app.launch()
        let rail = app.buttons["settings-group-instance"]
        let refresh = app.buttons["settings-instance-refresh"]
        XCTAssertTrue(waitForFocus(rail, timeout: 20))
        XCTAssertTrue(refresh.waitForExistence(timeout: 8))
        XCUIRemote.shared.press(.right)
        XCTAssertTrue(waitForFocus(refresh),
                      "Right from Server must enter Refresh as native first focus")
        XCUIRemote.shared.press(.left)
        XCTAssertTrue(waitForFocus(rail))
        XCUIRemote.shared.press(.right)
        XCTAssertTrue(waitForFocus(refresh),
                      "Second Right must not first focus another Server control")
    }

    func testSettingsAboutRightPrefersFirstInfoRow() throws {
        let app = XCUIApplication()
        app.launchArguments = [
            "-TypeTypeTVPreview", "settings-about", "-typetype.uiLanguage", "de"
        ]
        app.launch()
        let rail = app.buttons["settings-group-about"]
        let first = app.descendants(matching: .any)["settings-about-first"].firstMatch
        XCTAssertTrue(waitForFocus(rail, timeout: 20))
        XCTAssertTrue(first.waitForExistence(timeout: 8))
        XCUIRemote.shared.press(.right)
        XCTAssertTrue(waitForFocus(first),
                      "Right from About must directly focus the first information row")
    }

    func testGlobalMenuPreviewsOnFocusAndSelectEntersStably() throws {
        let app = XCUIApplication()
        app.launchArguments = [
            "-TypeTypeTVPreview", "home", "-typetype.uiLanguage", "de"
        ]
        app.launch()
        focusHomeIcon(app)
        let search = app.buttons["main-nav-search"]
        XCUIRemote.shared.press(.down)
        XCTAssertTrue(waitForFocus(search),
                      "Moving Down in the main rail must retain rail focus")
        XCTAssertTrue(app.staticTexts["VIDEOS ENTDECKEN"].waitForExistence(timeout: 8),
                      "Search screen should be previewed before pressing OK")
        XCTAssertTrue(waitForFocus(search),
                      "Preview must not collapse the main navigation")
        XCUIRemote.shared.press(.select)
        XCTAssertTrue(app.textFields.firstMatch.waitForExistence(timeout: 8))
        XCTAssertTrue(waitForFocus(app.textFields.firstMatch),
                      "OK must transfer focus to the new screen")
        Thread.sleep(forTimeInterval: 0.6)
        XCTAssertTrue(waitForFocus(app.textFields.firstMatch),
                      "OK focus must not jump back to the global navigation")
        XCTAssertFalse(search.hasFocus,
                       "The global navigation must release focus after OK")
    }

    func testGlobalMenuRightEntersSearchWithoutFocusBounce() throws {
        let app = XCUIApplication()
        app.launchArguments = [
            "-TypeTypeTVPreview", "home", "-typetype.uiLanguage", "de"
        ]
        app.launch()
        focusHomeIcon(app)
        let search = app.buttons["main-nav-search"]
        XCUIRemote.shared.press(.down)
        XCTAssertTrue(waitForFocus(search),
                      "Previewing Search must keep focus on its menu icon")
        XCUIRemote.shared.press(.right)
        let searchInput = app.textFields.firstMatch
        XCTAssertTrue(searchInput.waitForExistence(timeout: 8))
        XCTAssertTrue(waitForFocus(searchInput),
                      "Right must enter the Search screen, just like OK")
        Thread.sleep(forTimeInterval: 0.6)
        XCTAssertTrue(searchInput.hasFocus,
                      "Right must not bounce focus back into the main rail")
        XCTAssertFalse(search.hasFocus)
    }

    func testLeftFromSettingsSubrailFocusesGlobalSettingsWithoutAccountFlash() throws {
        let app = XCUIApplication()
        app.launchArguments = [
            "-TypeTypeTVPreview", "settings-about",
            "-typetype.uiLanguage", "de"
        ]
        app.launch()

        let about = app.buttons["settings-group-about"]
        let settings = app.buttons["main-nav-settings"]
        let account = app.buttons["main-nav-account"]
        XCTAssertTrue(waitForFocus(about, timeout: 20),
                      "The selected About category should own initial focus")
        XCUIRemote.shared.press(.left)

        // SwiftUI/tvOS may briefly report a geometrically chosen target.
        // The visual-focus policy ensures this NEVER draws a white pill on
        // Account, and the focus restoration must settle on Settings.
        XCTAssertTrue(waitForFocus(settings, timeout: 5),
                      "Left from About must focus the global Settings icon")
        XCTAssertFalse(account.hasFocus)
        Thread.sleep(forTimeInterval: 0.45)
        XCTAssertTrue(settings.hasFocus, "Settings focus must remain stable")
        XCTAssertFalse(account.hasFocus)

        // Releasing the return-only focus restriction must preserve normal
        // Up/Down traversal and re-enter Settings with Right.
        XCUIRemote.shared.press(.up)
        XCTAssertTrue(waitForFocus(account),
                      "Up after returning must reach the Account icon")
        XCUIRemote.shared.press(.down)
        XCTAssertTrue(waitForFocus(settings))
        let first = app.descendants(matching: .any)["settings-about-first"].firstMatch
        XCTAssertTrue(first.waitForExistence(timeout: 10))
        XCUIRemote.shared.press(.right)
        // Native tvOS may enter the selected About group or its first
        // focusable information row. Both are valid; a wrong group or a
        // lingering global-menu focus is not. This parallels the Content
        // Settings regression test already proven on main.
        let returnedToGroup = waitForFocus(about, timeout: 2)
        let returnedToFirstRow = !returnedToGroup && waitForFocus(first, timeout: 3)
        if !returnedToGroup && !returnedToFirstRow {
            // Temporary CI focus diagnosis: no second Siri Remote command.
            // Identify where native tvOS actually landed after Right.
            let focused = app.buttons.allElementsBoundByIndex
                .filter { $0.hasFocus }
                .map { $0.identifier.isEmpty ? $0.label : $0.identifier }
            XCTFail("Wrong Settings re-entry. Focused buttons=\(focused) " +
                    "accountPreview=\(app.staticTexts["Profile wechseln"].exists) " +
                    "aboutPreview=\(app.staticTexts["App-Informationen"].exists) " +
                    "globalSettings=\(settings.hasFocus) accountIcon=\(account.hasFocus) " +
                    "aboutGroup=\(about.hasFocus) infoRow=\(first.hasFocus)")
        }
        XCTAssertFalse(settings.hasFocus,
                       "Global Settings icon must relinquish focus on Right")
        XCTAssertFalse(account.hasFocus,
                       "Account must not steal focus during Settings re-entry")
        if returnedToFirstRow {
            XCUIRemote.shared.press(.left)
            XCTAssertTrue(waitForFocus(about),
                          "Left from first About row must return to About group")
        }
        XCUIRemote.shared.press(.right)
        XCTAssertTrue(waitForFocus(first),
                      "Right from About group must focus the first info row")
    }

    func testImmediateDownAfterReturningToMainRailIsNotSwallowed() throws {
        let app = XCUIApplication()
        app.launchArguments = [
            "-TypeTypeTVPreview", "home", "-typetype.uiLanguage", "de"
        ]
        app.launch()
        focusHomeIcon(app)
        let search = app.buttons["main-nav-search"]
        // A previous 360 ms .disabled guard kept neighboring icons from
        // accepting focus immediately after returning from page content.
        XCUIRemote.shared.press(.down)
        XCTAssertTrue(waitForFocus(search, timeout: 5),
                      "Immediate Down after Back must move to Search")
    }

    func testRightFromMainSettingsIconEntersSettingsWithoutBounce() throws {
        let app = XCUIApplication()
        app.launchArguments = [
            "-TypeTypeTVPreview", "home", "-typetype.uiLanguage", "de"
        ]
        app.launch()
        focusHomeIcon(app)
        moveDownMainRail(app, to: "settings")
        let settings = app.buttons["main-nav-settings"]
        XCTAssertTrue(waitForFocus(settings))
        XCUIRemote.shared.press(.right)
        let playbackGroup = app.buttons["settings-group-playback"]
        XCTAssertTrue(playbackGroup.waitForExistence(timeout: 10))
        XCTAssertTrue(waitForFocus(playbackGroup),
                      "Right on main Settings should focus the Settings subnavigation")
        Thread.sleep(forTimeInterval: 0.6)
        XCTAssertTrue(waitForFocus(playbackGroup),
                      "Settings must retain focus after the main rail collapses")
        XCTAssertFalse(settings.hasFocus,
                       "The main rail must not reclaim focus after Right")
    }

    func testOpeningSettingsFromMainMenuTransfersFocusToSubnavigation() throws {
        let app = XCUIApplication()
        app.launchArguments = [
            "-TypeTypeTVPreview", "home", "-typetype.uiLanguage", "de"
        ]
        app.launch()
        let settings = app.buttons["main-nav-settings"]
        XCTAssertTrue(settings.waitForExistence(timeout: 20))
        // Startup is already in the first recommendation. Back once
        // returns to the global icon rail, without selecting Recent.
        XCTAssertTrue(waitForFocus(app.buttons["home-baseline-video-0"]),
                      "Home startup must choose top recommendation, not Recent")
        XCUIRemote.shared.press(.menu)
        XCTAssertTrue(waitForFocus(app.buttons["main-nav-home"]),
                      "Second Back must return to the global Home icon")
        moveDownMainRail(app, to: "settings")
        XCTAssertTrue(waitForFocus(settings))
        XCUIRemote.shared.press(.select)
        let playbackGroup = app.buttons["settings-group-playback"]
        XCTAssertTrue(playbackGroup.waitForExistence(timeout: 10))
        XCTAssertTrue(waitForFocus(playbackGroup),
                      "Opening Settings must focus its selected subnavigation, not the main rail")
    }

    func testLongVideoTitleDoesNotHideSecondActionRowOrProgress() throws {
        let app = XCUIApplication()
        app.launchArguments = [
            "-TypeTypeTVPreview", "detail-long", "-typetype.uiLanguage", "de"
        ]
        app.launch()
        let play = app.buttons["Abspielen"]
        let watched = app.staticTexts["Angesehen"]
        let marked = app.buttons["Als angesehen markieren"]
        XCTAssertTrue(play.waitForExistence(timeout: 20))
        XCTAssertTrue(marked.exists,
                      "Long titles must not clip the second action row")
        XCTAssertTrue(watched.exists)
        XCTAssertGreaterThan(watched.frame.minX, play.frame.maxX,
                             "The watch progress belongs beside the primary buttons")
        XCTAssertGreaterThan(marked.frame.minY, play.frame.minY,
                             "The mark-watched action must be in its own row")
        XCTAssertLessThan(marked.frame.minY, watched.frame.maxY + 160,
                          "The secondary action should remain near the primary buttons")
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "TypeType-tvOS-Videodetail-Langer-Titel"
        shot.lifetime = .keepAlways
        add(shot)
    }

    func testVideoChannelLinkOpensChannelAndBackReturnsToVideo() throws {
        let app = XCUIApplication()
        app.launchArguments = [
            "-TypeTypeTVPreview", "detail-long", "-typetype.uiLanguage", "de"
        ]
        app.launch()
        let channel = app.buttons["video-open-channel"]
        XCTAssertTrue(channel.waitForExistence(timeout: 20),
                      "A video with a channel URL must offer a channel link")
        let play = app.buttons["video-play"]
        XCTAssertTrue(play.hasFocus,
                      "Play must receive initial focus rather than the channel")
        XCUIRemote.shared.press(.up)
        XCTAssertTrue(channel.hasFocus,
                      "One Up from Play should reach the channel")
        XCUIRemote.shared.press(.select)
        XCTAssertTrue(app.staticTexts["Testkanal"].waitForExistence(timeout: 10))
        // Regression: opening a channel from a video detail must populate
        // its Videos grid immediately, without switching to Shorts and back.
        XCTAssertTrue(app.buttons["subscription-video-0"].waitForExistence(timeout: 10),
                      "Directly opened channels must load videos on first appearance")
        XCUIRemote.shared.press(.menu)
        XCTAssertTrue(channel.waitForExistence(timeout: 10),
                      "Back from channel must return to its video detail")
        // XCTest rejects identifier-string queries longer than 128 characters.
        // Locate by a short prefix, then still validate the complete title.
        let title = app.staticTexts.matching(
            NSPredicate(format: "label BEGINSWITH %@", "Eine günstige TESLA Alternative?")
        ).firstMatch
        XCTAssertTrue(title.waitForExistence(timeout: 8))
        XCTAssertEqual(title.label,
            "Eine günstige TESLA Alternative? XPENG L03: Das perfekte E-Auto für Alltag und lange Reisen – ein ausführlicher Vergleich mit vielen Details")
    }

    func testVideoDescriptionOpensFullTextWithoutLeavingDetails() throws {
        let app = XCUIApplication()
        app.launchArguments = [
            "-TypeTypeTVPreview", "detail-long", "-typetype.uiLanguage", "de"
        ]
        app.launch()
        let play = app.buttons["video-play"]
        let watched = app.buttons["Als angesehen markieren"]
        let entry = app.buttons["video-description-entry"]
        XCTAssertTrue(play.hasFocus)
        XCUIRemote.shared.press(.down)
        XCTAssertTrue(watched.hasFocus)
        XCUIRemote.shared.press(.down)
        XCTAssertTrue(waitForFocus(entry))
        XCUIRemote.shared.press(.down)
        let excerpt = app.buttons["video-description-focus"]
        XCTAssertTrue(waitForFocus(excerpt))
        XCUIRemote.shared.press(.select)
        let close = app.buttons["video-full-description-close"]
        XCTAssertTrue(close.waitForExistence(timeout: 8),
                      "Full description must open in a separate popup")
        let scroll = app.descendants(matching: .any)
            .matching(identifier: "video-full-description-scroll").firstMatch
        XCTAssertTrue(scroll.waitForExistence(timeout: 8))
        XCUIRemote.shared.press(.menu)
        XCTAssertTrue(excerpt.waitForExistence(timeout: 8),
                      "Back must return to the detail page")
    }

    func testLibraryOpensDirectlyOnSelectedSubnavigation() throws {
        let app = XCUIApplication()
        app.launchArguments = [
            "-TypeTypeTVPreview", "library", "-typetype.uiLanguage", "de"
        ]
        app.launch()
        let first = app.buttons["library-nav-watch-later"]
        XCTAssertTrue(first.waitForExistence(timeout: 20))
        XCTAssertTrue(first.hasFocus, "Library must enter its own left rail")
        XCUIRemote.shared.press(.menu)
        XCTAssertTrue(app.buttons["main-nav-library"].hasFocus,
                      "Back from Library rail must go to Library icon")
    }

    func testSubscriptionsFocusChainAndRemoteBack() throws {
        let app = XCUIApplication()
        app.launchArguments = [
            "-TypeTypeTVPreview", "channels", "-typetype.uiLanguage", "de"
        ]
        app.launch()
        let first = app.buttons["subscription-https://preview.invalid/channel/a"]
        let firstVideo = app.buttons["subscription-video-0"]
        XCTAssertTrue(first.waitForExistence(timeout: 20))
        XCTAssertTrue(first.hasFocus, "Subscriptions must select the first channel")
        XCUIRemote.shared.press(.select)
        XCTAssertTrue(firstVideo.waitForExistence(timeout: 8))
        XCTAssertTrue(firstVideo.hasFocus,
                      "Selecting a subscription must enter its video grid")
        XCUIRemote.shared.press(.menu)
        XCTAssertTrue(first.hasFocus,
                      "Back from channel videos must return to channel rail")
        XCUIRemote.shared.press(.menu)
        XCTAssertTrue(app.buttons["main-nav-channels"].hasFocus,
                      "A second Back must select the subscriptions main icon")
    }

}
