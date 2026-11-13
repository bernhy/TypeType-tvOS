import XCTest
@testable import TypeTypeTV

final class TVPlaylistAdvanceTests: XCTestCase {
    func testNextAndEnd() {
        XCTAssertEqual(TVPlaylistAdvancePolicy.nextIndex(after: 0, count: 3), 1)
        XCTAssertEqual(TVPlaylistAdvancePolicy.nextIndex(after: 1, count: 3), 2)
        XCTAssertNil(TVPlaylistAdvancePolicy.nextIndex(after: 2, count: 3))
        XCTAssertNil(TVPlaylistAdvancePolicy.nextIndex(after: 0, count: 1))
    }
    func testInvalidIndicesAndEmptyList() {
        XCTAssertNil(TVPlaylistAdvancePolicy.validIndex(0, count: 0))
        XCTAssertNil(TVPlaylistAdvancePolicy.validIndex(-1, count: 4))
        XCTAssertNil(TVPlaylistAdvancePolicy.validIndex(4, count: 4))
        XCTAssertEqual(TVPlaylistAdvancePolicy.validIndex(2, count: 4), 2)
        XCTAssertNil(TVPlaylistAdvancePolicy.nextIndex(after: -1, count: 4))
    }
}
