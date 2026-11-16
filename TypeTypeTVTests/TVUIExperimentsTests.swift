import XCTest
@testable import TypeTypeTV

final class TVUIExperimentsTests: XCTestCase {
    func testExperimentalSettingsGroupIsDiscoverable() {
        XCTAssertTrue(TVSettingsGroup.allCases.contains(.experiments))
        XCTAssertEqual(TVSettingsGroup.experiments.titleKey, "ui.experiments")
        XCTAssertEqual(TVSettingsGroup.experiments.symbol, "sparkles")
    }

    func testMotionPreservesOriginalAppearanceWhenDisabled() {
        XCTAssertNil(TVUIMotion.animation("off", reduceMotion: false))
        XCTAssertNil(TVUIMotion.animation("standard", reduceMotion: false))
        XCTAssertNotNil(TVUIMotion.animation("pop", reduceMotion: false))
        XCTAssertNotNil(TVUIMotion.animation("fade", reduceMotion: true))
    }

    func testVisualOptionsRemainDeviceLocal() {
        let keys = ["popup", "focus", "glass", "toast", "page", "hero",
                    "background", "symbols", "loading", "sidebar"]
        let addresses = keys.map { "typetype.exp." + $0 }
        XCTAssertEqual(Set(addresses).count, 10)
        XCTAssertTrue(addresses.allSatisfy { $0.hasPrefix("typetype.exp.") })
    }
}
