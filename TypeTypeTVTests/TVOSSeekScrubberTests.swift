import XCTest
@testable import TypeTypeTV

final class TVOSSeekScrubberTests: XCTestCase {
    func testScrubClampsDragToVideoDuration() {
        XCTAssertEqual(TVOSSeekScrubPolicy.seconds(at: -60, width: 300, duration: 120), 0)
        XCTAssertEqual(TVOSSeekScrubPolicy.seconds(at: 150, width: 300, duration: 120), 60)
        XCTAssertEqual(TVOSSeekScrubPolicy.seconds(at: 400, width: 300, duration: 120), 120)
    }

    func testRemoteStepHonorsGlobalSkipLength() {
        XCTAssertEqual(TVOSSeekScrubPolicy.stepped(33, direction: 1,
                                                    stepSeconds: 15, duration: 100), 48)
        XCTAssertEqual(TVOSSeekScrubPolicy.stepped(2, direction: -1,
                                                    stepSeconds: 20, duration: 100), 0)
        XCTAssertEqual(TVOSSeekScrubPolicy.stepped(99, direction: 1,
                                                    stepSeconds: 10, duration: 100), 100)
    }

    func testInvalidDurationNeverRequestsSeek() {
        XCTAssertEqual(TVOSSeekScrubPolicy.seconds(at: 150, width: 0, duration: 120), 0)
        XCTAssertEqual(TVOSSeekScrubPolicy.seconds(at: 150, width: 300, duration: 0), 0)
        XCTAssertEqual(TVOSSeekScrubPolicy.clamp(.nan, duration: 120), 0)
    }
}
