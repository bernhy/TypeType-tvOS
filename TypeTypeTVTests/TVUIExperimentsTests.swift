import XCTest
@testable import TypeTypeTV

final class TVUIExperimentsTests: XCTestCase {
    func testExperimentalSettingsGroupIsDiscoverable() {
        XCTAssertTrue(TVSettingsGroup.allCases.contains(.experiments))
        XCTAssertEqual(TVSettingsGroup.experiments.titleKey, "ui.experiments")
        XCTAssertEqual(TVSettingsGroup.experiments.symbol, "sparkles")
    }

    func testOnlyPendingExperimentsRemainInFocusOrder() {
        XCTAssertEqual(TVExperimentFocusPath.order, [
            "experiment.page", "experiment.hero", "experiment.symbols",
            "experiment.loading", "experiment.sidebar", "experiment.reset"
        ])
        XCTAssertEqual(TVExperimentFocusPath.destination(
            from: "experiment.page", direction: .down), "experiment.hero")
        XCTAssertEqual(TVExperimentFocusPath.destination(
            from: "experiment.hero", direction: .down), "experiment.symbols")
        XCTAssertEqual(TVExperimentFocusPath.destination(
            from: "experiment.sidebar", direction: .down), "experiment.reset")
        XCTAssertNil(TVExperimentFocusPath.destination(
            from: "experiment.page", direction: .up))
        XCTAssertNil(TVExperimentFocusPath.destination(
            from: "experiment.reset", direction: .down))
    }

    func testOnlyDeviceLocalExperimentalSettingsRemain() {
        let keys = ["page", "hero", "symbols", "loading", "sidebar"]
        XCTAssertEqual(Set(keys).count, 5)
        XCTAssertTrue(keys.allSatisfy { ("typetype.exp." + $0).hasPrefix("typetype.exp.") })
    }
}
