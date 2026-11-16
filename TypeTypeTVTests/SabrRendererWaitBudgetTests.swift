import XCTest
@testable import TypeTypeTV

final class SabrRendererWaitBudgetTests: XCTestCase {
    func testCriticalHeadroomDetectsEitherAudioOrVideoStarvation() {
        XCTAssertFalse(SabrRendererHeadroom.shouldReport(
            audioAheadMs: 2_000, videoAheadMs: 300,
            running: true, buffering: false
        ))
        XCTAssertTrue(SabrRendererHeadroom.shouldReport(
            audioAheadMs: 2_000, videoAheadMs: 90,
            running: true, buffering: false
        ))
        XCTAssertTrue(SabrRendererHeadroom.shouldReport(
            audioAheadMs: 50, videoAheadMs: 500,
            running: true, buffering: false
        ))
        XCTAssertFalse(SabrRendererHeadroom.shouldReport(
            audioAheadMs: -100, videoAheadMs: 0,
            running: false, buffering: false
        ))
        XCTAssertFalse(SabrRendererHeadroom.shouldReport(
            audioAheadMs: -100, videoAheadMs: 0,
            running: true, buffering: true
        ))
    }

    func testRendererPollIntervalLeavesRoomWithinThirtyFpsFrame() {
        XCTAssertEqual(SabrRendererPolling.milliseconds, 5)
        XCTAssertLessThan(SabrRendererPolling.milliseconds, 33)
        XCTAssertEqual(SabrRendererPolling.nanoseconds, 5_000_000)
    }

    func testLongPauseCannotBeMisclassifiedAsRendererStall() {
        var budget = SabrRendererWaitBudget()
        for _ in 0..<5_000 {
            XCTAssertTrue(budget.shouldContinue(paused: true, stepMilliseconds: 20))
        }
        XCTAssertEqual(budget.milliseconds, 0)
        XCTAssertTrue(budget.shouldContinue(paused: false, stepMilliseconds: 20))
    }

    func testRunningRendererStillHasFiniteDeadline() {
        var budget = SabrRendererWaitBudget()
        for _ in 0..<750 {
            XCTAssertTrue(budget.shouldContinue(paused: false, stepMilliseconds: 20))
        }
        XCTAssertFalse(budget.shouldContinue(paused: false, stepMilliseconds: 20))
    }

    func testPauseResetsPartialStallBudget() {
        var budget = SabrRendererWaitBudget()
        for _ in 0..<650 {
            XCTAssertTrue(budget.shouldContinue(paused: false, stepMilliseconds: 20))
        }
        XCTAssertEqual(budget.milliseconds, 13_000)
        XCTAssertTrue(budget.shouldContinue(paused: true, stepMilliseconds: 20))
        XCTAssertEqual(budget.milliseconds, 0)
        XCTAssertTrue(budget.shouldContinue(paused: false, stepMilliseconds: 20))
    }
}
