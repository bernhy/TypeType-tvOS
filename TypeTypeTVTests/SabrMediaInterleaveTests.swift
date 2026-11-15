import XCTest
@testable import TypeTypeTV

final class SabrMediaInterleaveTests: XCTestCase {
    func testUsesEarlierPresentationTimestampAcrossTracks() {
        XCTAssertEqual(SabrMediaInterleave.next(audioSeconds: 1.00, videoSeconds: 1.04), .audio)
        XCTAssertEqual(SabrMediaInterleave.next(audioSeconds: 1.06, videoSeconds: 1.04), .video)
        XCTAssertEqual(SabrMediaInterleave.next(audioSeconds: 1.00, videoSeconds: 1.00), .audio)
    }

    func testLowAudioLeadFeedsReadyAACBeforeVideoBackpressure() {
        XCTAssertEqual(SabrMediaInterleave.next(
            audioSeconds: 11.00, videoSeconds: 10.20,
            playbackSeconds: 10.00, queuedAudioEndSeconds: 11.00,
            audioRendererReady: true, playbackRunning: true
        ), .audio)
    }

    func testEnoughAudioLeadKeepsChronologicalInterleave() {
        XCTAssertEqual(SabrMediaInterleave.next(
            audioSeconds: 11.00, videoSeconds: 10.20,
            playbackSeconds: 10.00, queuedAudioEndSeconds: 11.30,
            audioRendererReady: true, playbackRunning: true
        ), .video)
    }

    func testDoesNotPullFarFutureAudioOrJumpAcrossGap() {
        XCTAssertEqual(SabrMediaInterleave.next(
            audioSeconds: 14.00, videoSeconds: 10.20,
            playbackSeconds: 10.00, queuedAudioEndSeconds: 11.00,
            audioRendererReady: true, playbackRunning: true
        ), .video)
        XCTAssertEqual(SabrMediaInterleave.next(
            audioSeconds: 11.30, videoSeconds: 10.00,
            playbackSeconds: 10.00, queuedAudioEndSeconds: 10.80,
            audioRendererReady: true, playbackRunning: true
        ), .video)
    }

    func testPausedOrUnreadyAudioIsNotReordered() {
        XCTAssertEqual(SabrMediaInterleave.next(
            audioSeconds: 11.00, videoSeconds: 10.20,
            playbackSeconds: 10.00, queuedAudioEndSeconds: 11.00,
            audioRendererReady: false, playbackRunning: true
        ), .video)
        XCTAssertEqual(SabrMediaInterleave.next(
            audioSeconds: 11.00, videoSeconds: 10.20,
            playbackSeconds: 10.00, queuedAudioEndSeconds: 11.00,
            audioRendererReady: true, playbackRunning: false
        ), .video)
    }

    func testHandlesExhaustedTracks() {
        XCTAssertEqual(SabrMediaInterleave.next(audioSeconds: nil, videoSeconds: 1.5), .video)
        XCTAssertEqual(SabrMediaInterleave.next(audioSeconds: 1.5, videoSeconds: nil), .audio)
        XCTAssertNil(SabrMediaInterleave.next(audioSeconds: nil, videoSeconds: nil))
    }

    func testInvalidTimestampsDoNotStallPlayback() {
        XCTAssertEqual(SabrMediaInterleave.next(audioSeconds: .nan, videoSeconds: 2), .audio)
        XCTAssertEqual(SabrMediaInterleave.next(audioSeconds: 2, videoSeconds: .infinity), .video)
    }
}
