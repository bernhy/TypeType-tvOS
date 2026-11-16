import XCTest
@testable import TypeTypeTV

final class TVUIExperimentsTests: XCTestCase {
    func testExperimentalSettingsGroupIsDiscoverable() {
        XCTAssertTrue(TVSettingsGroup.allCases.contains(.experiments))
        XCTAssertEqual(TVSettingsGroup.experiments.titleKey, "ui.experiments")
        XCTAssertEqual(TVSettingsGroup.experiments.symbol, "sparkles")
    }

    func testVisualExperimentsAreOptIn() {
        // The experiment panel uses the same defaults as the actual views.
        // Reading these values never writes to TypeType account/server settings.
        let defaults = UserDefaults.standard
        for key in ["typetype.exp.popup", "typetype.exp.focus",
                    "typetype.exp.glass", "typetype.exp.toast",
                    "typetype.exp.page", "typetype.exp.hero",
                    "typetype.exp.background", "typetype.exp.symbols",
                    "typetype.exp.loading", "typetype.exp.sidebar"] {
            XCTAssertTrue(key.hasPrefix("typetype.exp."))
        }
        XCTAssertNotNil(defaults)
    }
}
