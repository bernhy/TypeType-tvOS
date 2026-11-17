import XCTest
@testable import TypeTypeTV

final class SabrStartupMetricsTests: XCTestCase {
    func testFirstMilestoneWins() {
        var metrics = SabrStartupMetrics()
        XCTAssertNil(metrics.elapsedMs(for: .bootstrap))
        metrics.record(.bootstrap, elapsedMs: -2)
        XCTAssertNil(metrics.elapsedMs(for: .bootstrap))
        metrics.record(.bootstrap, elapsedMs: 450)
        metrics.record(.bootstrap, elapsedMs: 800)
        XCTAssertEqual(metrics.elapsedMs(for: .bootstrap), 450)
    }

    func testEachStageIsIndependent() {
        var metrics = SabrStartupMetrics()
        metrics.record(.session, elapsedMs: 600)
        metrics.record(.audioQueued, elapsedMs: 730)
        metrics.record(.videoQueued, elapsedMs: 760)
        metrics.record(.clockStarted, elapsedMs: 770)
        metrics.record(.displayReady, elapsedMs: 820)
        XCTAssertNil(metrics.elapsedMs(for: .bootstrap))
        XCTAssertEqual(metrics.elapsedMs(for: .session), 600)
        XCTAssertEqual(metrics.elapsedMs(for: .audioQueued), 730)
        XCTAssertEqual(metrics.elapsedMs(for: .videoQueued), 760)
        XCTAssertEqual(metrics.elapsedMs(for: .clockStarted), 770)
        XCTAssertEqual(metrics.elapsedMs(for: .displayReady), 820)
    }
}
