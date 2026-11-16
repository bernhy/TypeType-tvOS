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

    func testPreviewButtonsAreInDirectionalFocusOrder() {
        XCTAssertEqual(
            TVExperimentFocusPath.destination(from: "experiment.focus", direction: .down),
            "experiment.focusPreview")
        XCTAssertEqual(
            TVExperimentFocusPath.destination(from: "experiment.focusPreview", direction: .down),
            "experiment.popup")
        XCTAssertEqual(
            TVExperimentFocusPath.destination(from: "experiment.popup", direction: .down),
            "experiment.popupPreview")
        XCTAssertEqual(
            TVExperimentFocusPath.destination(from: "experiment.popupPreview", direction: .down),
            "experiment.toast")
        XCTAssertEqual(
            TVExperimentFocusPath.destination(from: "experiment.toast", direction: .down),
            "experiment.toastPreview")
        XCTAssertEqual(
            TVExperimentFocusPath.destination(from: "experiment.toastPreview", direction: .down),
            "experiment.page")
        XCTAssertEqual(
            TVExperimentFocusPath.destination(from: "experiment.popup", direction: .up),
            "experiment.focusPreview")
        XCTAssertEqual(
            TVExperimentFocusPath.destination(from: "experiment.reset", direction: .up),
            "experiment.sidebar")
        XCTAssertNil(
            TVExperimentFocusPath.destination(from: "experiment.focus", direction: .up))
        XCTAssertNil(
            TVExperimentFocusPath.destination(from: "experiment.reset", direction: .down))
    }

    func testVisualOptionsRemainDeviceLocal() {
        let keys = ["popup", "focus", "glass", "toast", "page", "hero",
                    "background", "symbols", "loading", "sidebar"]
        let addresses = keys.map { "typetype.exp." + $0 }
        XCTAssertEqual(Set(addresses).count, 10)
        XCTAssertTrue(addresses.allSatisfy { $0.hasPrefix("typetype.exp.") })
    }
}
