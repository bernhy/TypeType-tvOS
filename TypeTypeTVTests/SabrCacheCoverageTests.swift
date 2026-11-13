import XCTest
@testable import TypeTypeTV

final class SabrCacheCoverageTests: XCTestCase {
    private func fragment(_ itag: Int, _ start: Int64, _ duration: Int64, _ url: String) -> SabrMediaReference {
        SabrMediaReference(url: url, itag: itag, startMs: start, durationMs: duration)
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
}
