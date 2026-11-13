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
}
