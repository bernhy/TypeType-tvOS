import XCTest
@testable import TypeTypeTV

final class SabrRendererWaitBudgetTests: XCTestCase {
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
