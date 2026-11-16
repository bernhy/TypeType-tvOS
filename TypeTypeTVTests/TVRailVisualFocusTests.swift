import XCTest
@testable import TypeTypeTV

final class TVRailVisualFocusTests: XCTestCase {
    func testReturningFromAboutDoesNotPaintNearbyAccountInMainRail() {
        // tvOS may first report Account because it lies next to About.
        // The app must paint the white pill on the current Settings icon.
        XCTAssertTrue(TVRailVisualFocus.highlights(
            TVSection.settings, focused: .account, selected: .settings))
        XCTAssertFalse(TVRailVisualFocus.highlights(
            TVSection.account, focused: .account, selected: .settings))
    }

    func testSettingsControlReturnOnlyPaintsSelectedCategory() {
        XCTAssertTrue(TVRailVisualFocus.highlights(
            TVSettingsGroup.about, focused: .account, selected: .about))
        XCTAssertFalse(TVRailVisualFocus.highlights(
            TVSettingsGroup.account, focused: .account, selected: .about))
    }

    func testLibraryAndChannelsIgnoreWrongFirstRailFocus() {
        XCTAssertTrue(TVRailVisualFocus.highlights(
            "playlist-a", focused: "playlist-b", selected: "playlist-a"))
        XCTAssertFalse(TVRailVisualFocus.highlights(
            "playlist-b", focused: "playlist-b", selected: "playlist-a"))
        XCTAssertTrue(TVRailVisualFocus.highlights(
            "channel-a", focused: "channel-b", selected: "channel-a"))
        XCTAssertFalse(TVRailVisualFocus.highlights(
            "channel-b", focused: "channel-b", selected: "channel-a"))
    }

    func testVerticalRailTraversalStillFollowsRealFocus() {
        XCTAssertTrue(TVRailVisualFocus.highlights(
            "playlist-b", focused: "playlist-b", selected: "playlist-a",
            browsingWithinRail: true))
        XCTAssertFalse(TVRailVisualFocus.highlights(
            "playlist-a", focused: "playlist-b", selected: "playlist-a",
            browsingWithinRail: true))
    }

    func testNoWhitePillWhileFocusIsInContent() {
        XCTAssertFalse(TVRailVisualFocus.highlights(
            TVSection.settings, focused: nil, selected: .settings))
        XCTAssertFalse(TVRailVisualFocus.highlights(
            "channel-a", focused: nil, selected: "channel-a",
            browsingWithinRail: true))
    }
}
