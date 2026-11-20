import XCTest
@testable import TypeTypeTV

final class TVRailVisualFocusTests: XCTestCase {
    func testMainNavigationKeepsOriginalSidebarWidthAndFixedPageLayout() {
        XCTAssertEqual(TVMainNavigationLayout.duration, 0.28)
        XCTAssertEqual(TVMainNavigationLayout.width(expanded: false), 56)
        XCTAssertEqual(TVMainNavigationLayout.width(expanded: true), 214)
        let viewportWidth: CGFloat = 1920
        let fixedPageWidth = viewportWidth - TVMainNavigationLayout.collapsedWidth

        for section in TVSection.allCases {
            let closedScale = TVMainNavigationLayout.contentScale(
                viewportWidth: viewportWidth, expanded: false
            )
            let openScale = TVMainNavigationLayout.contentScale(
                viewportWidth: viewportWidth, expanded: true
            )
            XCTAssertEqual(closedScale, 1, "\(section)")
            XCTAssertLessThan(openScale, 1, "\(section): content zooms out")
            // The original HStack still measures the sidebar at 214 points.
            // The fixed page remains 1864 layout points in BOTH states.
            XCTAssertEqual(fixedPageWidth, 1864)
            XCTAssertEqual(
                TVMainNavigationLayout.width(expanded: false) +
                    fixedPageWidth * closedScale,
                viewportWidth,
                accuracy: 0.0001, "\(section): closed page fills viewport"
            )
            XCTAssertEqual(
                TVMainNavigationLayout.width(expanded: true) +
                    fixedPageWidth * openScale,
                viewportWidth,
                accuracy: 0.0001, "\(section): zoomed page fits beside rail"
            )
        }
        XCTAssertEqual(
            TVMainNavigationLayout.contentScale(viewportWidth: 0, expanded: true),
            1
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

    func testRepeatedHomeRailRoundTripsCannotDriftTowardFirstRow() {
        let original = "recommendation-row-4"
        let available: Set<String> = [
            "recommendation-row-0", "recommendation-row-4",
            "recommendation-row-8"
        ]
        var current = original
        for _ in 0..<12 {
            current = TVHomeReturnFocusPolicy.target(
                saved: current,
                visibleIDs: available,
                fallback: "recommendation-row-0"
            )
            XCTAssertEqual(current, original)
        }
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
