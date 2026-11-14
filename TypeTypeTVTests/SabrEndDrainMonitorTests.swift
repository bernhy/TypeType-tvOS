import XCTest
@testable import TypeTypeTV

final class SabrEndDrainMonitorTests: XCTestCase {
    func testStationaryPlaybackClockTimesOut() {
        var monitor = SabrEndDrainMonitor(timeoutSeconds: 20)
        let start = Date(timeIntervalSince1970: 100)
        XCTAssertFalse(monitor.isStalled(positionMs: 8_000, paused: false, now: start))
        XCTAssertFalse(monitor.isStalled(positionMs: 8_000, paused: false,
                                         now: start.addingTimeInterval(19)))
        XCTAssertTrue(monitor.isStalled(positionMs: 8_000, paused: false,
                                        now: start.addingTimeInterval(21)))
    }

    func testProgressAndPauseResetStallBudget() {
        var monitor = SabrEndDrainMonitor(timeoutSeconds: 20)
        let start = Date(timeIntervalSince1970: 100)
        XCTAssertFalse(monitor.isStalled(positionMs: 1_000, paused: false, now: start))
        XCTAssertFalse(monitor.isStalled(positionMs: 1_300, paused: false,
                                         now: start.addingTimeInterval(18)))
        XCTAssertFalse(monitor.isStalled(positionMs: 1_300, paused: true,
                                         now: start.addingTimeInterval(60)))
        XCTAssertFalse(monitor.isStalled(positionMs: 1_300, paused: false,
                                         now: start.addingTimeInterval(90)))
        XCTAssertFalse(monitor.isStalled(positionMs: 1_300, paused: false,
                                         now: start.addingTimeInterval(109)))
        XCTAssertTrue(monitor.isStalled(positionMs: 1_300, paused: false,
                                        now: start.addingTimeInterval(111)))
    }
}
