import XCTest
@testable import TypeTypeTV

final class SabrCacheCoverageTests: XCTestCase {
    private func fragment(_ itag: Int, _ start: Int64, _ duration: Int64, _ url: String) -> SabrMediaReference {
        SabrMediaReference(url: url, itag: itag, startMs: start, durationMs: duration)
    }

    func testServerWindowDiscoveryDoesNotSkipAheadToCached121Seconds() {
        // The server uses bufferedEndFor to jump to the end of a reported
        // range. With [0,121_000] the old client skipped media descriptors
        // even though the renderer had only reached ~23 seconds.
        let downloaded: [SabrBufferedRange] = [
            SabrBufferedRange(itag: 137, startMs: 0, endMs: 121_000),
            SabrBufferedRange(itag: 140, startMs: 0, endMs: 121_000)
        ]
        XCTAssertEqual(downloaded.count, 2)
        XCTAssertTrue(SabrSequentialWindowPolicy.advertisedRanges.isEmpty)
        XCTAssertEqual(SabrSequentialWindowPolicy.requestPosition(
            first: true, startMs: 0, continuousEndMs: 0
        ), 0)
        XCTAssertEqual(SabrSequentialWindowPolicy.requestPosition(
            first: false, startMs: 0, continuousEndMs: 23_000
        ), 23_000)
        XCTAssertEqual(SabrSequentialWindowPolicy.requestPosition(
            first: false, startMs: 0, continuousEndMs: 48_000
        ), 48_000)
    }

    func testWindowDiscoveryUsesCommonMediaFrontierNotPlayhead() {
        let coverage = SabrPlaybackCoverage(
            audioItag: 140, videoItag: 137, positionMs: 0
        )
        // No track can be skipped before its first completed segment.
        XCTAssertEqual(SabrSequentialWindowPolicy.requestPosition(
            first: false, startMs: 0, continuousEndMs: coverage.safeEndMs
        ), 0)
    }

    func testNeverAdvertiseEvictedAudioAsFullyBufferedVideo() {
        // The audio fragment between 4 and 8 seconds was evicted; its
        // absence must not be hidden behind the video high-water mark.
        let pieces = [
            fragment(140, 0, 4_000, "a0"),
            fragment(140, 8_000, 4_000, "a8"),
            fragment(137, 0, 4_000, "v0"),
            fragment(137, 4_000, 4_000, "v4"),
            fragment(137, 8_000, 4_000, "v8")
        ]
        let ranges = SabrCachedRangePlanner.ranges(from: pieces, retainFromMs: 0)
        XCTAssertEqual(ranges.filter { $0.itag == 140 }.count, 2)
        XCTAssertEqual(SabrCachedRangePlanner.cachedThrough(
            ranges, audioItag: 140, videoItag: 137, positionMs: 2_000
        ), 4_000)
        XCTAssertEqual(SabrCachedRangePlanner.cachedThrough(
            ranges, audioItag: 140, videoItag: 137, positionMs: 6_000
        ), 6_000)
        XCTAssertEqual(SabrCachedRangePlanner.cachedThrough(
            ranges, audioItag: 140, videoItag: 137, positionMs: 9_000
        ), 12_000)
    }

    func testClampsOldRangesAndMergesOnlyTrulyContiguousBytes() {
        let pieces = [
            fragment(140, 0, 4_000, "a0"),
            fragment(140, 4_000, 4_000, "a4"),
            fragment(140, 8_100, 3_900, "a8"),
            fragment(137, 0, 8_000, "v0")
        ]
        let ranges = SabrCachedRangePlanner.ranges(from: pieces, retainFromMs: 2_000)
        let audio = ranges.filter { $0.itag == 140 }
        XCTAssertEqual(audio.count, 2)
        XCTAssertEqual(audio[0].startMs, 2_000)
        XCTAssertEqual(audio[0].endMs, 8_000)
        XCTAssertEqual(audio[1].startMs, 8_100)
        XCTAssertEqual(SabrCachedRangePlanner.cachedThrough(
            ranges, audioItag: 140, videoItag: 137, positionMs: 2_000
        ), 8_000)
        XCTAssertTrue(SabrCachedRangePlanner.ranges(from: pieces, retainFromMs: 13_000).isEmpty)
    }

    func testInvalidTimestampCannotOverflowBufferedRanges() {
        let ranges = SabrCachedRangePlanner.ranges(from: [
            fragment(140, Int64.max - 2, 10, "overflow"),
            fragment(140, -1, 4_000, "negative"),
            fragment(140, 1_000, 0, "zero")
        ], retainFromMs: 0)
        XCTAssertTrue(ranges.isEmpty)
    }
    func testRendererUnderflowUsesActualEnqueuedSamplesNotNetworkCoverage() {
        // The server can already report 120 seconds on disk while the
        // audio/video renderers have only received 11 and 8 seconds.
        XCTAssertFalse(SabrRendererCoverage.shouldPause(
            clockMs: 2_000, audioEndMs: 0, videoEndMs: 0))
        XCTAssertFalse(SabrRendererCoverage.shouldPause(
            clockMs: 5_000, audioEndMs: 11_000, videoEndMs: 8_000))
        XCTAssertTrue(SabrRendererCoverage.shouldPause(
            clockMs: 7_600, audioEndMs: 11_000, videoEndMs: 8_000))
        XCTAssertFalse(SabrRendererCoverage.shouldPause(
            clockMs: 7_600, audioEndMs: 11_000, videoEndMs: 9_000))
        XCTAssertEqual(SabrRendererCoverage.commonEnd(
            audioEndMs: 11_000, videoEndMs: 8_000), 8_000)
    }

    func testPlaybackHUDDoesNotOverrunBeforeDurationIsKnown() {
        // Resume at 49.654 seconds before the first SABR response advertises
        // the total duration: ProgressView must not be given value > total.
        XCTAssertEqual(SabrProgressDisplay.total(durationMs: 0), 1)
        XCTAssertEqual(SabrProgressDisplay.value(49.654, durationMs: 0), 1)
        XCTAssertEqual(SabrProgressDisplay.value(49.654, durationMs: 100_000), 49.654)
        XCTAssertEqual(SabrProgressDisplay.value(200, durationMs: 100_000), 100)
        XCTAssertEqual(SabrProgressDisplay.value(-2, durationMs: 100_000), 0)
        XCTAssertEqual(SabrProgressDisplay.value(.infinity, durationMs: 100_000), 0)
    }

}
