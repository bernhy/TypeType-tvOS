import XCTest
@testable import TypeTypeTV

final class TVHomeCardEqualityTests: XCTestCase {
    func testHomeViewportStaysStableAcrossMainRailExpansion() {
        // 158pt narrower navigation content must not shrink its 4-column
        // thumbnails or accumulate per-row vertical drift.
        let collapsed = CGFloat(1650)
        let expanded = CGFloat(1492)
        let widest = TVHomeViewportPolicy.widest(0, measured: collapsed)
        XCTAssertEqual(TVHomeViewportPolicy.contentWidth(
            available: expanded, widest: widest
        ), collapsed)
        XCTAssertEqual(TVHomeViewportPolicy.contentWidth(
            available: collapsed, widest: widest
        ), collapsed)
        XCTAssertEqual(TVHomeViewportPolicy.widest(widest, measured: expanded),
                       collapsed)
        XCTAssertEqual(TVHomeViewportPolicy.widest(widest, measured: .nan), collapsed)
    }

    func testReturningFromRailDoesNotRecenterAlreadyVisibleCard() {
        let deep = "recommendation-deep"
        XCTAssertFalse(TVHomeViewportPolicy.shouldScrollToRestore(
            savedRailCard: deep, target: deep
        ))
        XCTAssertTrue(TVHomeViewportPolicy.shouldScrollToRestore(
            savedRailCard: deep, target: "recommendation-first"
        ))
        XCTAssertTrue(TVHomeViewportPolicy.shouldScrollToRestore(
            savedRailCard: nil, target: deep
        ))
    }

    func testHomeCardEqualityOnlySkipsIdenticalVisualInputs() throws {
        let api = try TypeTypeAPI(address: "https://example.com")
        let other = try TypeTypeAPI(address: "https://other.example.com")
        let video = VideoItem(
            id: "one", title: "Original", url: "https://youtu.be/ABCDEFGHIJK",
            thumbnailUrl: "https://img.example.com/one.jpg",
            uploaderName: "Channel", duration: 120, isLive: false
        )
        var changed = video
        changed.viewCount = 100

        let a = TVHomeCardContent(api: api, video: video)
        XCTAssertEqual(a, TVHomeCardContent(api: api, video: video))
        XCTAssertNotEqual(a, TVHomeCardContent(api: other, video: video))
        XCTAssertNotEqual(a, TVHomeCardContent(api: api, video: changed))
        XCTAssertNotEqual(a, TVHomeCardContent(
            api: api, video: video, lookupMissingMetadata: true
        ))
    }
}
