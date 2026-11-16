import XCTest
@testable import TypeTypeTV

final class SabrPrefetchOrderTests: XCTestCase {
    private func media(_ itag: Int, _ sequence: Int, _ startMS: Int64) -> SabrMediaReference {
        SabrMediaReference(
            url: "https://example.org/sabr/playback/test/\(itag)/segment/\(sequence)?generation=1",
            itag: itag, startMs: startMS, durationMs: 3_000
        )
    }

    func testPreservesSameTrackSequenceWhenServerTimestampsRunBackwards() {
        // Observed server metadata: video seq 33 precedes seq 32 by startMs.
        let input = [
            media(137, 34, 185_952),
            media(137, 33, 181_482),
            media(137, 32, 183_683),
            media(140, 9, 180_000),
            media(140, 10, 190_000),
        ]
        let batches = SabrPrefetchOrder.batches(input)
        XCTAssertTrue(batches.allSatisfy { $0.count <= 2 })
        let all = batches.flatMap { $0 }
        XCTAssertEqual(all.count, input.count)
        XCTAssertEqual(Set(all.map(\.url)).count, input.count)
        XCTAssertEqual(
            all.filter { $0.itag == 137 }.compactMap { SabrSequenceOrder.sequence($0.url) },
            [32, 33, 34]
        )
        XCTAssertEqual(
            all.filter { $0.itag == 140 }.compactMap { SabrSequenceOrder.sequence($0.url) },
            [9, 10]
        )
    }

    func testInterleavesDifferentDurationAudioAndVideoAtTheFrontier() {
        let references = [
            media(137, 4, 15_000),
            media(137, 1, 0),
            media(140, 1, 0),
            media(137, 3, 10_000),
            media(140, 2, 10_000),
            media(137, 2, 5_000),
        ]
        let batches = SabrPrefetchOrder.batches(references)
        XCTAssertEqual(batches.map(\.count), [2, 2, 2])
        XCTAssertEqual(Set(batches[0].map(\.itag)), Set([137, 140]))
        let ordered = batches.flatMap { $0 }
        XCTAssertEqual(
            ordered.filter { $0.itag == 137 }.compactMap { SabrSequenceOrder.sequence($0.url) },
            [1, 2, 3, 4]
        )
        XCTAssertEqual(
            ordered.filter { $0.itag == 140 }.compactMap { SabrSequenceOrder.sequence($0.url) },
            [1, 2]
        )
    }

    func testFallbackWithoutSequenceAndSingleTrack() {
        let a = SabrMediaReference(url: "a", itag: 140, startMs: 2_000, durationMs: 2_000)
        let b = SabrMediaReference(url: "b", itag: 140, startMs: 0, durationMs: 2_000)
        let c = SabrMediaReference(url: "c", itag: 140, startMs: 4_000, durationMs: 2_000)
        XCTAssertEqual(SabrPrefetchOrder.batches([a, c, b]).flatMap { $0 }.map(\.url), ["b", "a", "c"])
        XCTAssertTrue(SabrPrefetchOrder.batches([]).isEmpty)
    }
}
