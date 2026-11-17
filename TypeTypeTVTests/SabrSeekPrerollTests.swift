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
