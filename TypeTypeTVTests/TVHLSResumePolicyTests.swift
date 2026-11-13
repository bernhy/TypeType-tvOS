import XCTest
@testable import TypeTypeTV

final class TVHLSResumePolicyTests: XCTestCase {
    func testResumeInMilliseconds() {
        XCTAssertEqual(TVHLSResumePolicy.startSeconds(
            savedPositionMs: 97_250, durationSeconds: 300, isLive: false
        ), 97.25)
    }

    func testNeverResumeAfterEndOrForLiveStreams() {
        XCTAssertEqual(TVHLSResumePolicy.startSeconds(
            savedPositionMs: 297_500, durationSeconds: 300, isLive: false
        ), 0)
        XCTAssertEqual(TVHLSResumePolicy.startSeconds(
            savedPositionMs: 200_000, durationSeconds: 300, isLive: true
        ), 0)
        XCTAssertEqual(TVHLSResumePolicy.startSeconds(
            savedPositionMs: nil, durationSeconds: nil, isLive: false
        ), 0)
    }
}
