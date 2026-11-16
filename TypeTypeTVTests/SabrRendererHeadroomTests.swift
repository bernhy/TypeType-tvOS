import XCTest
@testable import TypeTypeTV

final class SabrRendererHeadroomTests: XCTestCase {
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
}
