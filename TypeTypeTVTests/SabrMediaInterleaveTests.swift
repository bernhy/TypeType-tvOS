import XCTest
@testable import TypeTypeTV

final class SabrMediaInterleaveTests: XCTestCase {
    func testUsesEarlierPresentationTimestampAcrossTracks() {
        XCTAssertEqual(SabrMediaInterleave.next(audioSeconds: 1.00, videoSeconds: 1.04), .audio)
        XCTAssertEqual(SabrMediaInterleave.next(audioSeconds: 1.06, videoSeconds: 1.04), .video)
        XCTAssertEqual(SabrMediaInterleave.next(audioSeconds: 1.00, videoSeconds: 1.00), .audio)
    }

    func testQueuesAvailableAudioEarlyWhenRendererIsRunningLow() {
        // Four AAC buffers may each span almost three seconds. With strict
        // PTS ordering the next one waits behind video backpressure until
        // the audio renderer has dangerously little remaining headroom.
        XCTAssertEqual(SabrMediaInterleave.next(
            audioSeconds: 11.0, videoSeconds: 10.2,
            playbackSeconds: 10.0, queuedAudioEndSeconds: 11.0,
            audioRendererReady: true, playbackRunning: true
        ), .audio)
    }

    func testNormalInterleaveWhenAudioAlreadyHasHeadroom() {
        XCTAssertEqual(SabrMediaInterleave.next(
            audioSeconds: 11.0, videoSeconds: 10.2,
            playbackSeconds: 10.0, queuedAudioEndSeconds: 13.1,
            audioRendererReady: true, playbackRunning: true
        ), .video)
    }

    func testDoesNotSkipLargeAudioTimestampGap() {
        XCTAssertEqual(SabrMediaInterleave.next(
            audioSeconds: 14.0, videoSeconds: 10.2,
            playbackSeconds: 10.0, queuedAudioEndSeconds: 11.0,
            audioRendererReady: true, playbackRunning: true
        ), .video)
    }

    func testDoesNotWaitOnUnreadyAudioOrPrioritizeAtStartup() {
        XCTAssertEqual(SabrMediaInterleave.next(
            audioSeconds: 11.0, videoSeconds: 10.2,
            playbackSeconds: 10.0, queuedAudioEndSeconds: 11.0,
            audioRendererReady: false, playbackRunning: true
        ), .video)
        XCTAssertEqual(SabrMediaInterleave.next(
            audioSeconds: 11.0, videoSeconds: 10.2,
            playbackSeconds: 10.0, queuedAudioEndSeconds: 11.0,
            audioRendererReady: true, playbackRunning: false
        ), .video)
    }

    func testAudioPriorityKeepsMissingOrInvalidTimestampFallbacks() {
        XCTAssertEqual(SabrMediaInterleave.next(
            audioSeconds: nil, videoSeconds: 10.2,
            playbackSeconds: 10.0, queuedAudioEndSeconds: 11.0,
            audioRendererReady: true, playbackRunning: true
        ), .video)
        XCTAssertEqual(SabrMediaInterleave.next(
            audioSeconds: .nan, videoSeconds: 10.2,
            playbackSeconds: 10.0, queuedAudioEndSeconds: 11.0,
            audioRendererReady: true, playbackRunning: true
        ), .audio)
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
