import XCTest
@testable import TypeTypeTV

final class SabrSeekPrerollTests: XCTestCase {
    func testStartAndSeekBehaveDifferently() {
        XCTAssertEqual(SabrSeekPreroll.requestStart(targetMs: 120_000, explicit: false), 120_000)
        XCTAssertEqual(SabrSeekPreroll.requestStart(targetMs: 120_000, explicit: true), 115_000)
        XCTAssertEqual(SabrSeekPreroll.requestStart(targetMs: 9_000, explicit: true), 4_000)
        XCTAssertEqual(SabrSeekPreroll.requestStart(targetMs: 0, explicit: true), 0)
        XCTAssertEqual(SabrSeekPreroll.requestStart(targetMs: 3_000, explicit: true), 0)
    }

    func testChooseLatestActualRAPBeforeTarget() {
        let samples: [MP4Sample] = [
            MP4Sample(offset: 0, size: 1, decodeTime: 0,
                      duration: 1_000, compositionOffset: 0, isSync: true),
            MP4Sample(offset: 1, size: 1, decodeTime: 1_000,
                      duration: 1_000, compositionOffset: 0, isSync: false),
            MP4Sample(offset: 2, size: 1, decodeTime: 2_000,
                      duration: 1_000, compositionOffset: 0, isSync: true),
            MP4Sample(offset: 3, size: 1, decodeTime: 3_000,
                      duration: 1_000, compositionOffset: 0, isSync: false)
        ]
        XCTAssertEqual(SabrSeekPreroll.lastReliableSyncBeforeTarget(
            samples: samples, timescale: 1_000, targetMs: 2_500), 2)
        XCTAssertEqual(SabrSeekPreroll.lastReliableSyncBeforeTarget(
            samples: samples, timescale: 1_000, targetMs: 1_500), 0)
        XCTAssertNil(SabrSeekPreroll.lastReliableSyncBeforeTarget(
            samples: samples, timescale: 1_000, targetMs: 0))
    }

    func testUnreliableAllSyncFlagsAreNotUsedForTrimming() {
        let samples = (0..<4).map {
            MP4Sample(offset: $0, size: 1, decodeTime: Int64($0 * 1_000),
                      duration: 1_000, compositionOffset: 0, isSync: true)
        }
        XCTAssertNil(SabrSeekPreroll.lastReliableSyncBeforeTarget(
            samples: samples, timescale: 1_000, targetMs: 2_500))
    }

    func testAACBeforeTargetIsRemovedButIntersectingPacketIsKept() {
        XCTAssertTrue(SabrSeekPreroll.isBeforePresentation(
            sampleStartTicks: 44_100, durationTicks: 1_024,
            timescale: 44_100, targetMs: 1_100
        ))
        XCTAssertFalse(SabrSeekPreroll.isBeforePresentation(
            sampleStartTicks: 44_100, durationTicks: 1_024,
            timescale: 44_100, targetMs: 1_010
        ))
    }
}
