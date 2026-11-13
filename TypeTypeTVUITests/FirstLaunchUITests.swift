import XCTest

/// A first-run UI smoke test. It intentionally uses no private server and no
/// account token; it also records a screenshot of the setup screen for visual review.
final class TypeTypeTVUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testFirstLaunchShowsAccessibleServerSetup() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-typetype.instanceOrigin", ""]
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
        app.launchArguments = ["-TypeTypeTVPreview", "home"]
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
        app.launchArguments = ["-TypeTypeTVPreview", "home-expanded"]
        app.launch()
        XCTAssertTrue(app.buttons["Menü einklappen"].waitForExistence(timeout: 20))
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "TypeType-tvOS-Menü-ausgeklappt"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testSearchScreenLayoutWithoutServer() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-TypeTypeTVPreview", "search"]
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
        app.launchArguments = ["-TypeTypeTVPreview", "details"]
        app.launch()
        XCTAssertTrue(app.staticTexts["Neuigkeiten aus der Welt der Technik"].waitForExistence(timeout: 20))
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "TypeType-tvOS-Videodetails"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

}
