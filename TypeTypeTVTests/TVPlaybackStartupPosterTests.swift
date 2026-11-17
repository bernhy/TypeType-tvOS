import XCTest
@testable import TypeTypeTV

final class TVPlaybackStartupPosterTests: XCTestCase {
    func testSabrRequiresClockAndDisplayReady() {
        XCTAssertFalse(TVPlaybackStartupPosterPolicy.sabrReady(
            displayReady: false, clockRunning: false
        ))
        XCTAssertFalse(TVPlaybackStartupPosterPolicy.sabrReady(
            displayReady: true, clockRunning: false
        ))
        XCTAssertFalse(TVPlaybackStartupPosterPolicy.sabrReady(
            displayReady: false, clockRunning: true
        ))
        XCTAssertTrue(TVPlaybackStartupPosterPolicy.sabrReady(
            displayReady: true, clockRunning: true
        ))
    }

    func testHLSWaitsForActualClockAdvancement() {
        XCTAssertFalse(TVPlaybackStartupPosterPolicy.hlsAdvanced(
            previous: nil, current: 12, playing: true
        ))
        XCTAssertFalse(TVPlaybackStartupPosterPolicy.hlsAdvanced(
            previous: 12, current: 12.01, playing: true
        ))
        XCTAssertFalse(TVPlaybackStartupPosterPolicy.hlsAdvanced(
            previous: 12, current: 12.5, playing: false
        ))
        XCTAssertTrue(TVPlaybackStartupPosterPolicy.hlsAdvanced(
            previous: 12, current: 12.2, playing: true
        ))
        XCTAssertFalse(TVPlaybackStartupPosterPolicy.hlsAdvanced(
            previous: .nan, current: 12.2, playing: true
        ))
    }
}
