import XCTest
@testable import TypeTypeTV

final class TVContinueWatchingPolicyTests: XCTestCase {
    private func video(duration: Int? = 300, isLive: Bool = false) -> VideoItem {
        VideoItem(
            id: "resume-test", title: "Resume test",
            url: "https://youtu.be/abcdefghijk",
            thumbnailUrl: nil, uploaderName: "Channel",
            duration: duration, isLive: isLive
        )
    }

    func testOnlyStartedUnfinishedVideosAreEligible() {
        let item = video()
        XCTAssertFalse(TVContinueWatchingPolicy.isEligible(item, positionMs: nil))
        XCTAssertFalse(TVContinueWatchingPolicy.isEligible(item, positionMs: 0))
        XCTAssertTrue(TVContinueWatchingPolicy.isEligible(item, positionMs: 1_000))
        XCTAssertTrue(TVContinueWatchingPolicy.isEligible(item, positionMs: 269_999))
        // Same 90-percent completion rule as the watched badge.
        XCTAssertFalse(TVContinueWatchingPolicy.isEligible(item, positionMs: 270_000))
        XCTAssertFalse(TVContinueWatchingPolicy.isEligible(item, positionMs: 300_000))
    }

    func testLiveAndUnknownDurationAreNotResumable() {
        XCTAssertFalse(TVContinueWatchingPolicy.isEligible(
            video(isLive: true), positionMs: 30_000
        ))
        XCTAssertFalse(TVContinueWatchingPolicy.isEligible(
            video(duration: nil), positionMs: 30_000
        ))
        XCTAssertFalse(TVContinueWatchingPolicy.isEligible(
            video(duration: 0), positionMs: 30_000
        ))
    }

    func testSavedPositionOverridesStaleWatchedFlag() {
        var item = video()
        item.watched = true
        // An explicit saved position can mark this as unfinished again.
        XCTAssertTrue(TVContinueWatchingPolicy.isEligible(item, positionMs: 10_000))
    }
}
