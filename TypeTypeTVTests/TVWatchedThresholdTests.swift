import XCTest
@testable import TypeTypeTV

final class TVWatchedThresholdTests: XCTestCase {
    private func video(_ duration: Int = 120, live: Bool = false) -> VideoItem {
        VideoItem(
            id: "threshold-video", title: "Test",
            url: "https://youtu.be/abcdefghijk",
            thumbnailUrl: nil, uploaderName: "Channel",
            duration: duration, isLive: live
        )
    }

    func testServerValueIsAuthoritativeButMissingDefaultsTo90Percent() throws {
        XCTAssertEqual(TVWatchedThresholdPolicy.resolved(nil), 90)
        XCTAssertEqual(TVWatchedThresholdPolicy.resolved(0), 0)
        XCTAssertEqual(TVWatchedThresholdPolicy.resolved(50), 50)
        XCTAssertEqual(TVWatchedThresholdPolicy.resolved(100), 100)
        XCTAssertEqual(TVWatchedThresholdPolicy.resolved(49), 90)
        XCTAssertEqual(TVWatchedThresholdPolicy.resolved(101), 90)
        XCTAssertEqual(TVWatchedThresholdPolicy.resolved(-1), 90)
        let missing = try JSONDecoder().decode(TVServerSettings.self, from: Data("{}".utf8))
        XCTAssertEqual(missing.effectiveWatchedThresholdPercent, 90)
        let lastMinute = try JSONDecoder().decode(TVServerSettings.self,
                                                   from: Data(#"{"watchedThresholdPercent":0}"#.utf8))
        XCTAssertEqual(lastMinute.effectiveWatchedThresholdPercent, 0)
        let configured = try JSONDecoder().decode(TVServerSettings.self,
                                                  from: Data(#"{"watchedThresholdPercent":75}"#.utf8))
        XCTAssertEqual(configured.effectiveWatchedThresholdPercent, 75)
    }

    func testTypeTypeLastMinuteRuleForNormalAndShortVideos() {
        // A two-minute video: last minute starts at 01:00, not 90%.
        XCTAssertFalse(TVWatchedThresholdPolicy.isComplete(
            durationSeconds: 120, positionMs: 59_999, thresholdPercent: 0))
        XCTAssertTrue(TVWatchedThresholdPolicy.isComplete(
            durationSeconds: 120, positionMs: 60_000, thresholdPercent: 0))
        // A 20-minute video: 19:00.
        XCTAssertTrue(TVWatchedThresholdPolicy.isComplete(
            durationSeconds: 1200, positionMs: 1_140_000, thresholdPercent: 0))
        // Exactly 60 seconds: 90% rather than immediate completion.
        XCTAssertFalse(TVWatchedThresholdPolicy.isComplete(
            durationSeconds: 60, positionMs: 53_999, thresholdPercent: 0))
        XCTAssertTrue(TVWatchedThresholdPolicy.isComplete(
            durationSeconds: 60, positionMs: 54_000, thresholdPercent: 0))
        XCTAssertTrue(TVWatchedThresholdPolicy.isComplete(
            durationSeconds: 10, positionMs: 9_000, thresholdPercent: 0))
    }

    func testConfigurablePercentControlsBadgesResumeAndProgressEnrichment() {
        let item = video()
        XCTAssertFalse(TVWatchedState.isWatched(item, positionMs: 107_999))
        XCTAssertTrue(TVWatchedState.isWatched(item, positionMs: 108_000))
        XCTAssertTrue(TVWatchedState.isWatched(
            item, positionMs: 96_000, thresholdPercent: 80))
        XCTAssertFalse(TVContinueWatchingPolicy.isEligible(
            item, positionMs: 96_000, thresholdPercent: 80))
        XCTAssertTrue(TVContinueWatchingPolicy.isEligible(
            item, positionMs: 96_000, thresholdPercent: 90))
        XCTAssertEqual(item.withProgress(96_000, thresholdPercent: 80).watched, true)
        XCTAssertEqual(item.withProgress(96_000, thresholdPercent: 90).watched, false)
    }

    func testExplicitZeroLiveAndOverflowStaySafe() {
        var item = video()
        item.watched = true
        XCTAssertTrue(TVWatchedState.isWatched(item, positionMs: nil))
        XCTAssertFalse(TVWatchedState.isWatched(
            item, positionMs: 0, thresholdPercent: 0))
        XCTAssertFalse(TVWatchedState.isWatched(
            video(live: true), positionMs: 120_000, thresholdPercent: 0))
        XCTAssertFalse(TVWatchedThresholdPolicy.isComplete(
            durationSeconds: Int.max, positionMs: 10_000, thresholdPercent: 100))
        XCTAssertFalse(TVWatchedThresholdPolicy.isComplete(
            durationSeconds: 0, positionMs: 10_000, thresholdPercent: 0))
    }

    func testSabrAndHlsRestartUseSameConfiguredRule() {
        let item = video()
        XCTAssertFalse(TVWatchedState.isWatched(item, positionMs: 59_999,
                                                thresholdPercent: 0))
        XCTAssertTrue(TVWatchedState.isWatched(item, positionMs: 60_000,
                                               thresholdPercent: 0))
        XCTAssertEqual(TVHLSResumePolicy.startSeconds(
            savedPositionMs: 60_000, durationSeconds: 120, isLive: false,
            thresholdPercent: 0), 0)
        XCTAssertEqual(TVHLSResumePolicy.startSeconds(
            savedPositionMs: 60_000, durationSeconds: 120, isLive: false,
            thresholdPercent: 90), 60)
        XCTAssertEqual(TVHLSResumePolicy.startSeconds(
            savedPositionMs: 96_000, durationSeconds: 120, isLive: false,
            thresholdPercent: 80), 0)
        XCTAssertEqual(TVHLSResumePolicy.startSeconds(
            savedPositionMs: 120_000, durationSeconds: 120, isLive: true,
            thresholdPercent: 90), 0)
    }

    func testLocalResumePromotionUsesAccountThreshold() {
        let item = video(120)
        XCTAssertEqual(TVContinueWatchingLocalUpdate.applying(
            [], video: item, positionMs: 96_000, thresholdPercent: 90).count, 1)
        XCTAssertTrue(TVContinueWatchingLocalUpdate.applying(
            [], video: item, positionMs: 96_000, thresholdPercent: 80).isEmpty)
    }
}
