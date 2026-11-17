import XCTest
@testable import TypeTypeTV

final class TVEndScreenTests: XCTestCase {
    private let json = #"""
    [
      {"id":"a","type":"video","title":"Next","url":"https://www.youtube.com/watch?v=ABCDEFGHIJK",
       "thumbnailUrl":"https://i.ytimg.com/vi/ABCDEFGHIJK/hqdefault.jpg",
       "startMs":590000,"endMs":610000,"left":0.60,"top":0.12,"width":0.34,"aspectRatio":1.77778},
      {"id":"b","type":"poll","title":"Other","url":"https://www.youtube.com",
       "thumbnailUrl":"","startMs":0,"endMs":10000,"left":0.12,"top":0.12,"width":0.3,"aspectRatio":1},
      {"id":"c","type":"website","title":"External","url":"https://example.com",
       "thumbnailUrl":"","startMs":0,"endMs":10000,"left":0.12,"top":0.12,"width":0.3,"aspectRatio":1}
    ]
    """#

    func testServerElementsAreTimeBoundedAndUnsupportedKindsIgnored() throws {
        let result = try JSONDecoder().decode([TVEndScreenElement].self,
                                               from: Data(json.utf8))
        XCTAssertEqual(result.count, 3)
        XCTAssertTrue(result[0].isUsable)
        XCTAssertTrue(result[0].visible(at: 590_000))
        XCTAssertFalse(result[0].visible(at: 610_000))
        XCTAssertFalse(result[1].isUsable)
        XCTAssertFalse(result[2].isUsable)
    }

    func testLetterboxedGeometryStaysInsideVideo() throws {
        let entry = try XCTUnwrap(JSONDecoder().decode(
            [TVEndScreenElement].self, from: Data(json.utf8)).first)
        let picture = TVEndScreenGeometry.picture(
            in: CGSize(width: 1920, height: 1200), aspectRatio: 16.0 / 9.0
        )
        XCTAssertEqual(picture.minY, 60, accuracy: 0.001)
        XCTAssertEqual(picture.width, 1920, accuracy: 0.001)
        let card = TVEndScreenGeometry.card(entry, in: picture)
        XCTAssertGreaterThan(card.width, 0)
        XCTAssertGreaterThanOrEqual(card.minX, picture.minX)
        XCTAssertLessThanOrEqual(card.maxX, picture.maxX)
        XCTAssertLessThanOrEqual(card.maxY, picture.maxY)
    }

    func testBothServerPayloadsDecodeWithoutEndScreenField() throws {
        let bootstrap = try JSONDecoder().decode(
            SabrBootstrap.self, from: Data(#"{"id":"test"}"#.utf8)
        )
        XCTAssertNil(bootstrap.endScreenElements)
        let details = try JSONDecoder().decode(
            StreamInfo.self, from: Data(#"{}"#.utf8)
        )
        XCTAssertNil(details.endScreenElements)
    }
}
