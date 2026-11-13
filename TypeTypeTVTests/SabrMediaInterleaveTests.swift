import XCTest
@testable import TypeTypeTV

final class SabrMediaInterleaveTests: XCTestCase {
    func testUsesEarlierPresentationTimestampAcrossTracks() {
        XCTAssertEqual(SabrMediaInterleave.next(audioSeconds: 1.00, videoSeconds: 1.04), .audio)
        XCTAssertEqual(SabrMediaInterleave.next(audioSeconds: 1.06, videoSeconds: 1.04), .video)
        XCTAssertEqual(SabrMediaInterleave.next(audioSeconds: 1.00, videoSeconds: 1.00), .audio)
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
