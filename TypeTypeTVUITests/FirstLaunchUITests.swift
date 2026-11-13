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
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "TypeType-tvOS-Startseite"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testExpandedSidebarLayoutWithoutServer() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-TypeTypeTVPreview", "home-expanded", "-typetype.uiLanguage", "de"]
        app.launch()
        XCTAssertTrue(app.buttons["Menü einklappen"].waitForExistence(timeout: 20))
        XCTAssertTrue(app.staticTexts["Empfehlungen"].exists)
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "TypeType-tvOS-Menü-ausgeklappt"
        attachment.lifetime = .keepAlways
        add(attachment)
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

    func testGermanSettingsPerformancePanelScreenshot() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-TypeTypeTVPreview", "settings-performance",
                               "-typetype.uiLanguage", "de"]
        app.launch()
        XCTAssertTrue(app.staticTexts["Leistung"].firstMatch.waitForExistence(timeout: 20))
        XCTAssertTrue(app.staticTexts["Sanfte Menüanimationen"].firstMatch.exists)
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "TypeType-tvOS-Einstellungen-Leistung-DE"
        shot.lifetime = .keepAlways
        add(shot)
    }


}
