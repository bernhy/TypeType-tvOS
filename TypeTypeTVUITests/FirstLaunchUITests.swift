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
        let first = app.buttons["home-video-recommendation-0"]
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
    func testHomeScreenLayoutWithoutServer() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-TypeTypeTVPreview", "home", "-typetype.uiLanguage", "de"]
        app.launch()
        XCTAssertTrue(app.staticTexts["FÜR DICH"].waitForExistence(timeout: 20))
        XCTAssertTrue(app.staticTexts["Empfehlungen"].exists)
        XCTAssertTrue(app.staticTexts["Zuletzt angesehen"].exists)
        XCTAssertTrue(app.buttons["Konto"].exists)
        XCTAssertTrue(waitForFocus(app.buttons["home-video-recommendation-0"], timeout: 8),
                      "Home must initially focus the first recommendation, not the rail or history")
        XCTAssertFalse(app.buttons["main-nav-home"].hasFocus)
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "TypeType-tvOS-Startseite"
        attachment.lifetime = .keepAlways
        add(attachment)
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
        XCTAssertTrue(app.buttons["Erneut versuchen"].exists)
        XCTAssertTrue(app.buttons["Zurück"].exists)
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
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "TypeType-tvOS-Suche"
        attachment.lifetime = .keepAlways
        add(attachment)
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

    func testHomeOKFromGlobalRailSelectsFirstRecommendation() throws {
        let app = XCUIApplication()
        app.launchArguments = [
            "-TypeTypeTVPreview", "home", "-typetype.uiLanguage", "de"
        ]
        app.launch()
        focusHomeIcon(app)
        XCUIRemote.shared.press(.select)
        let recommendation = app.buttons["home-video-recommendation-0"]
        XCTAssertTrue(recommendation.waitForExistence(timeout: 8))
        XCTAssertTrue(waitForFocus(recommendation),
                      "OK on Home must enter its recommendations, not stay in the rail")
        XCTAssertFalse(app.buttons["main-nav-home"].hasFocus)
    }

    func testBackFromDeepHomeRecommendationRestoresTileAndThenTopRecommendation() throws {
        let app = XCUIApplication()
        app.launchArguments = [
            "-TypeTypeTVPreview", "home", "-typetype.uiLanguage", "de"
        ]
        app.launch()
        XCTAssertTrue(waitForFocus(app.buttons["home-video-recommendation-0"], timeout: 8),
                      "Home startup must focus the first recommendation")
        for _ in 0..<4 { XCUIRemote.shared.press(.down) }
        // LazyVGrid only instantiates cards near the current viewport.
        // Querying hasFocus on an offscreen, non-existent indexed button can
        // throw an XCTest snapshot exception instead of returning false.
        let visibleRecommendations = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH %@",
                        "home-video-recommendation-")
        ).allElementsBoundByIndex
        let focusedDeep = visibleRecommendations.first { button in
            guard let index = Int(button.identifier.replacingOccurrences(
                of: "home-video-recommendation-", with: ""
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
        let top = app.buttons["home-video-recommendation-0"]
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
        let recommendation = app.buttons["home-video-recommendation-0"]
        XCTAssertTrue(recommendation.waitForExistence(timeout: 20))
        XCTAssertTrue(waitForFocus(recommendation),
                      "Home startup must focus the first recommendation")
        XCUIRemote.shared.press(.select)
        XCTAssertTrue(app.buttons["video-play"].waitForExistence(timeout: 10))
        XCUIRemote.shared.press(.menu)
        XCTAssertTrue(recommendation.waitForExistence(timeout: 10))
        XCTAssertTrue(recommendation.hasFocus,
                      "Back from a video must focus its original list tile")
        XCTAssertFalse(app.buttons["main-nav-home"].hasFocus,
                       "Returning from details must not jump to the global rail")
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

        // The account icon is vertically closest to the About category.
        // It must not receive transient focus before the selected Settings
        // icon; that caused a visible wrong white focus pill.
        XCTAssertFalse(account.hasFocus,
                       "Returning to main navigation must never focus Account")
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
        XCUIRemote.shared.press(.right)
        XCTAssertTrue(waitForFocus(about),
                      "Right must return to the previously chosen Settings group")
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
        XCTAssertTrue(waitForFocus(app.buttons["home-video-recommendation-0"]),
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

    func testVideoDescriptionIsOneFocusableScrollableTextView() throws {
        let app = XCUIApplication()
        app.launchArguments = [
            "-TypeTypeTVPreview", "detail-long", "-typetype.uiLanguage", "de"
        ]
        app.launch()
        // The native UITextView can be represented by a generic accessibility
        // element until its containing SwiftUI scroller enters the viewport.
        let description = app.descendants(matching: .any)
            .matching(identifier: "video-description-scroll").firstMatch
        let play = app.buttons["video-play"]
        let watched = app.buttons["Als angesehen markieren"]
        let descriptionEntry = app.buttons["video-description-entry"]
        XCTAssertTrue(play.hasFocus, "Play must be the initial focused control")
        XCUIRemote.shared.press(.down)
        XCTAssertTrue(watched.hasFocus,
                      "Down from Play should reach the secondary action row")
        XCUIRemote.shared.press(.down)
        XCTAssertTrue(waitForFocus(descriptionEntry),
                      "Another Down must reach the description below the hero")
        XCTAssertGreaterThan(descriptionEntry.frame.minY, 0)
        XCTAssertLessThan(descriptionEntry.frame.midY, app.frame.maxY,
                          "The outer page must scroll description into view")
        XCUIRemote.shared.press(.down)
        let viewport = app.descendants(matching: .any)
            .matching(identifier: "video-description-focus").firstMatch
        XCTAssertTrue(description.waitForExistence(timeout: 8),
                      "The native UITextView must remain accessible after entering its viewport")
        // tvOS exposes the UIViewRepresentable wrapper as a generic element,
        // and .hasFocus may be false even when SwiftUI's focus binding moved.
        // The preview-only label reports the actual FocusState, without
        // weakening the requirement that Down entered descriptionBody.
        let focusedState = app.staticTexts["video-description-focus-state"]
        XCTAssertTrue(waitForLabel(focusedState, expected: "descriptionBody"),
                      "Remote Down must enter the scrollable description body")
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
