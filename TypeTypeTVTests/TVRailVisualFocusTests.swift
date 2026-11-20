import XCTest
@testable import TypeTypeTV

final class TVRailVisualFocusTests: XCTestCase {
    func testMainNavigationSharesOneWidthTransitionAcrossAllSections() {
        // The rail's width is the only layout input. The adjacent page
        // receives its remaining width in the same animated HStack pass,
        // instead of reserving 214 points through a second completion phase.
        XCTAssertEqual(TVMainNavigationLayout.duration, 0.28)
        for destination in TVSection.allCases {
            XCTAssertEqual(TVMainNavigationLayout.width(expanded: true),
                           214, "\(destination): menu open")
            XCTAssertEqual(TVMainNavigationLayout.width(expanded: false),
                           56, "\(destination): menu closed")
            XCTAssertEqual(
                TVMainNavigationLayout.width(expanded: true) -
                TVMainNavigationLayout.width(expanded: false),
                158, "\(destination): content gains the same freed width"
            )
        }
    }

    func testExpandingMainRailDoesNotResizeTheVideoGrid() {
        XCTAssertEqual(TVMainNavigationLayout.pageShift(expanded: false), 0)
        XCTAssertEqual(TVMainNavigationLayout.pageShift(expanded: true), 158)
        XCTAssertEqual(
            TVMainNavigationLayout.pageShift(expanded: true),
            TVMainNavigationLayout.expandedWidth - TVMainNavigationLayout.collapsedWidth
        )
    }

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

    func testHomeLeftRailReentryRestoresCardButBackKeepsFirst() {
        let first = "recommendation-first"
        let middle = "recommendation-middle"
        let recent = "recent-resume"
        let visible: Set<String> = [first, middle, recent]
        XCTAssertEqual(TVHomeReturnFocusPolicy.target(
            saved: middle, visibleIDs: visible, fallback: first), middle)
        XCTAssertEqual(TVHomeReturnFocusPolicy.target(
            saved: recent, visibleIDs: visible, fallback: first), recent)
        XCTAssertEqual(TVHomeReturnFocusPolicy.target(
            saved: nil, visibleIDs: visible, fallback: first), first)
        XCTAssertEqual(TVHomeReturnFocusPolicy.target(
            saved: "recommendation-deleted", visibleIDs: visible, fallback: first), first)
    }

    func testNoWhitePillWhileFocusIsInContent() {
        XCTAssertFalse(TVRailVisualFocus.highlights(
            TVSection.settings, focused: nil, selected: .settings))
        XCTAssertFalse(TVRailVisualFocus.highlights(
            "channel-a", focused: nil, selected: "channel-a",
            browsingWithinRail: true))
    }
}
