import XCTest
@testable import TypeTypeTV

final class SabrCacheCoverageTests: XCTestCase {
    private func fragment(_ itag: Int, _ start: Int64, _ duration: Int64, _ url: String) -> SabrMediaReference {
        SabrMediaReference(url: url, itag: itag, startMs: start, durationMs: duration)
    }

    func testIncomingVideoSegmentsSortBySequenceNotIncorrectMetadataStart() {
        // Observed seq 32 was advertised at 183.683s although its native
        // fMP4 decode start was 176.643s; seq 33 starts before that advertised
        // timestamp. Sorting by startMs skips it in the decoder's timeline.
        func segment(_ number: Int, _ start: Int64, _ duration: Int64) -> SabrFragment {
            SabrFragment(
                url: "https://example.org/sabr/playback/s/137/segment/\(number)",
                startMs: start, durationMs: duration
            )
        }
        let incoming = [
            segment(34, 185_952, 6_741),
            segment(32, 183_683, 3_003),
            segment(33, 181_482, 4_470)
        ]
        XCTAssertEqual(
            SabrSequenceOrder.ordered(incoming).compactMap {
                SabrSequenceOrder.sequence($0.url)
            },
            [32, 33, 34]
        )
        let fallback = [
            SabrFragment(url: "https://example.org/unknown", startMs: 20, durationMs: 10),
            SabrFragment(url: "https://example.org/other", startMs: 10, durationMs: 10)
        ]
        XCTAssertEqual(SabrSequenceOrder.ordered(fallback).map(\.startMs), [10, 20])
    }

    func testCachedLookaheadKeepsSequenceOrderDespiteMetadataReversal() {
        let references: [SabrMediaReference] = [
            fragment(137, 183_683, 3_003, "https://example.org/s/137/32"),
            fragment(137, 181_482, 200, "https://example.org/s/137/33"),
            fragment(137, 185_952, 6_741, "https://example.org/s/137/34")
        ]
        let ranges = SabrCachedRangePlanner.playableRanges(
            from: references, retainFromMs: 181_000
        )
        XCTAssertEqual(ranges.count, 1)
        XCTAssertEqual(ranges[0].startMs, 181_482)
        XCTAssertEqual(ranges[0].endMs, 192_693)
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

    func testPlayableCacheLookaheadBridgesOnlyConsecutiveSabrSequenceGaps() {
        // Exact intervals must remain separate for server bufferedRanges,
        // but local lookahead needs to follow the same confirmed sequence
        // continuity that the SABR decoder accepts.
        func v(_ sequence: Int, _ start: Int64, _ duration: Int64) -> SabrMediaReference {
            fragment(137, start, duration,
                     "https://example.org/sabr/playback/test/137/segment/\(sequence)?generation=0")
        }
        func a(_ sequence: Int, _ start: Int64, _ duration: Int64) -> SabrMediaReference {
            fragment(140, start, duration,
                     "https://example.org/sabr/playback/test/140/segment/\(sequence)?generation=0")
        }
        let pieces = [
            v(4, 0, 24_391),
            v(5, 24_758, 3_404),
            v(6, 28_162, 3_404),
            v(7, 35_168, 4_638),
            v(8, 39_806, 7_476),
            v(10, 50_317, 6_774),
            a(1, 0, 20_000),
            a(2, 20_000, 20_000),
            a(3, 40_000, 20_000)
        ]
        let exact = SabrCachedRangePlanner.ranges(from: pieces, retainFromMs: 0)
        XCTAssertGreaterThan(exact.filter { $0.itag == 137 }.count, 1)
        let playable = SabrCachedRangePlanner.playableRanges(from: pieces, retainFromMs: 0)
        XCTAssertEqual(SabrCachedRangePlanner.cachedThrough(
            playable, audioItag: 140, videoItag: 137, positionMs: 0), 47_282)
        // Confirmed *missing* sequence 9 must not be bridged, even though
        // there are cached video bytes after it.
        XCTAssertEqual(SabrCachedRangePlanner.cachedThrough(
            playable, audioItag: 140, videoItag: 137, positionMs: 30_000), 47_282)
        // Separate example with strictly ordered sequence 9->10, including
        // the observed 3,035-ms metadata gap.
        let chain = [
            v(9, 0, 47_282),
            v(10, 50_317, 6_774),
            a(1, 0, 60_000)
        ]
        let joined = SabrCachedRangePlanner.playableRanges(from: chain, retainFromMs: 0)
        XCTAssertEqual(SabrCachedRangePlanner.cachedThrough(
            joined, audioItag: 140, videoItag: 137, positionMs: 0), 57_091)
    }

    func testRealVodSequentialTimestampJumpsAreAcceptedByPlayerAndCache() throws {
        // 2026-11-14 device trace: itag=137, seq 118->119 at ~10:20.
        // Both media fragments are present, but the second one starts 4.370s
        // after the first fragment's *declared* end. Reopening the SABR
        // session returned identical metadata and could never fix this.
        func video(_ seq: Int, _ start: Int64, _ duration: Int64) -> SabrFragment {
            SabrFragment(
                url: "https://example.org/sabr/playback/session/137/segment/\(seq)",
                startMs: start, durationMs: duration
            )
        }
        let first = video(118, 620_486, 19_820)
        let second = video(119, 644_676, 4_438)
        var coverage = SabrPlaybackCoverage(audioItag: 140, videoItag: 137,
                                            positionMs: 620_486, stage: "test")
        try coverage.acceptVideo(first)
        try coverage.acceptVideo(second)
        XCTAssertEqual(coverage.videoEndMs, 649_114)

        let pieces = [
            fragment(137, first.startMs, first.durationMs, first.url),
            fragment(137, second.startMs, second.durationMs, second.url),
            fragment(140, 620_486, 30_000,
                     "https://example.org/sabr/playback/session/140/segment/63")
        ]
        let playable = SabrCachedRangePlanner.playableRanges(
            from: pieces, retainFromMs: 620_486
        )
        XCTAssertEqual(SabrCachedRangePlanner.cachedThrough(
            playable, audioItag: 140, videoItag: 137, positionMs: 620_486
        ), 649_114)

        // A previous incident at ~2:42 had 7.040s between seq 31->32.
        var earlier = SabrPlaybackCoverage(audioItag: 140, videoItag: 137,
                                            positionMs: 170_000, stage: "test")
        try earlier.acceptVideo(video(31, 170_000, 6_643))
        try earlier.acceptVideo(video(32, 183_683, 3_003))
        XCTAssertEqual(earlier.videoEndMs, 186_686)
    }

    func testLargeOrMissingSequenceVODGapStillFails() throws {
        func video(_ seq: Int, _ start: Int64, _ duration: Int64) -> SabrFragment {
            SabrFragment(
                url: "https://example.org/sabr/playback/session/137/segment/\(seq)",
                startMs: start, durationMs: duration
            )
        }
        var missing = SabrPlaybackCoverage(audioItag: 140, videoItag: 137,
                                            positionMs: 620_486)
        try missing.acceptVideo(video(118, 620_486, 19_820))
        XCTAssertThrowsError(
            try missing.acceptVideo(video(120, 644_676, 4_438))
        )

        var excessive = SabrPlaybackCoverage(audioItag: 140, videoItag: 137,
                                              positionMs: 620_486)
        try excessive.acceptVideo(video(118, 620_486, 19_820))
        XCTAssertThrowsError(
            try excessive.acceptVideo(video(119, 648_307, 4_438))
        )
    }

    func testUnidentifiedOrMissingSequenceCannotBridgeFourSecondGap() {
        let a = fragment(140, 0, 60_000, "https://example.org/140/segment/1")
        for next in [13, 16] {
            let parts = [
                fragment(137, 0, 24_391, "https://example.org/137/segment/11"),
                fragment(137, 24_758, 3_404, "https://example.org/137/segment/\(next)"),
                a
            ]
            let playable = SabrCachedRangePlanner.playableRanges(
                from: parts, retainFromMs: 0)
            XCTAssertEqual(SabrCachedRangePlanner.cachedThrough(
                playable, audioItag: 140, videoItag: 137, positionMs: 0), 24_391)
        }
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
