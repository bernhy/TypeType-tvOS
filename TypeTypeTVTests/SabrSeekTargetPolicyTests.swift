import XCTest
@testable import TypeTypeTV

final class SabrSeekTargetPolicyTests: XCTestCase {
    func testConfiguredTenSecondStepsAccumulate() {
        let first = SabrSeekTargetPolicy.target(
            anchorMs: 4_395, offsetMs: 10_000, durationMs: 200_000
        )
        XCTAssertEqual(first, 14_395)
        XCTAssertEqual(SabrSeekTargetPolicy.target(
            anchorMs: first, offsetMs: 10_000, durationMs: 200_000
        ), 24_395)
    }

    func testSeekClampsAtBoundsAndDoesNotOverflow() {
        XCTAssertEqual(SabrSeekTargetPolicy.target(
            anchorMs: 2_000, offsetMs: -10_000, durationMs: 20_000), 0)
        XCTAssertEqual(SabrSeekTargetPolicy.target(
            anchorMs: 19_000, offsetMs: 10_000, durationMs: 20_000), 19_000)
        XCTAssertEqual(SabrSeekTargetPolicy.target(
            anchorMs: Int64.max - 10, offsetMs: 10_000,
            durationMs: 0), Int64.max)
    }

    func testRecoveryNeverFallsBackToTransportBeforeFirstPicture() {
        XCTAssertEqual(SabrSeekTargetPolicy.recoveryPresentation(
            desiredMs: 56_243, transportMs: 51_243,
            initialized: false), 56_243)
        XCTAssertEqual(SabrSeekTargetPolicy.recoveryPresentation(
            desiredMs: 56_243, transportMs: 52_000,
            initialized: true), 52_000)
    }
}
