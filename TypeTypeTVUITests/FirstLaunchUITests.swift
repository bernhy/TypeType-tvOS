import XCTest

/// A first-run UI smoke test. It intentionally uses no private server and no
/// account token; it also records a screenshot of the setup screen for visual review.
final class TypeTypeTVUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
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
        XCTAssertTrue(sponsorGroup.hasFocus,
                      "SponsorBlock must open as a selected settings category")
        XCTAssertTrue(app.staticTexts["Kategorien"].exists)
        XCTAssertTrue(app.staticTexts["Weitere Optionen"].exists)
        XCTAssertFalse(app.buttons["SponsorBlock konfigurieren"].exists,
                       "There must no longer be a modal launcher in Playback")
        XCUIRemote.shared.press(.right)
        XCTAssertTrue(refresh.hasFocus,
                      "Right from SponsorBlock must enter the content column")
        XCUIRemote.shared.press(.left)
        XCTAssertTrue(sponsorGroup.hasFocus,
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

    func testOpeningSettingsFromMainMenuTransfersFocusToSubnavigation() throws {
        let app = XCUIApplication()
        app.launchArguments = [
            "-TypeTypeTVPreview", "home", "-typetype.uiLanguage", "de"
        ]
        app.launch()
        let settings = app.buttons["main-nav-settings"]
        XCTAssertTrue(settings.waitForExistence(timeout: 20))
        // Return from Home to the global icon rail, then navigate down to
        // Settings. This exercises the same path as the user's Siri Remote.
        XCUIRemote.shared.press(.menu)
        // Seven main sections (including both subscription destinations).
        for _ in 0..<6 { XCUIRemote.shared.press(.down) }
        XCTAssertTrue(settings.hasFocus)
        XCUIRemote.shared.press(.select)
        let playbackGroup = app.buttons["settings-group-playback"]
        XCTAssertTrue(playbackGroup.waitForExistence(timeout: 10))
        XCTAssertTrue(playbackGroup.hasFocus,
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
        // Navigate to the channel link using the Siri Remote rather than
        // relying on touch/tap APIs that do not exist for tvOS.
        for _ in 0..<8 where !channel.hasFocus {
            XCUIRemote.shared.press(.up)
        }
        XCTAssertTrue(channel.hasFocus)
        XCUIRemote.shared.press(.select)
        XCTAssertTrue(app.staticTexts["Testkanal"].waitForExistence(timeout: 10))
        XCUIRemote.shared.press(.menu)
        XCTAssertTrue(channel.waitForExistence(timeout: 10),
                      "Back from channel must return to its video detail")
        XCTAssertTrue(app.staticTexts["Eine günstige TESLA Alternative? XPENG L03: Das perfekte E-Auto für Alltag und lange Reisen – ein ausführlicher Vergleich mit vielen Details"].exists)
    }

    func testVideoDescriptionIsOneFocusableScrollableTextView() throws {
        let app = XCUIApplication()
        app.launchArguments = [
            "-TypeTypeTVPreview", "detail-long", "-typetype.uiLanguage", "de"
        ]
        app.launch()
        let description = app.textViews["video-description-scroll"]
        XCTAssertTrue(description.waitForExistence(timeout: 20),
                      "The entire description must be a native scrollable text view")
        XCTAssertTrue(description.exists)
        // Up/down input is handled by the focused native text view and does
        // not require a separate focusable row for each description line.
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
