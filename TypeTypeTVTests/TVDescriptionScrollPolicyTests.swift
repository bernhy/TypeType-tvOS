import XCTest
@testable import TypeTypeTV

final class TVDescriptionScrollPolicyTests: XCTestCase {
    func testAdvancesAndClampsAtTextEnd() {
        XCTAssertEqual(TVDescriptionScrollPolicy.targetY(
            current: 0, delta: 125, contentHeight: 1200, viewportHeight: 370), 125)
        XCTAssertEqual(TVDescriptionScrollPolicy.targetY(
            current: 800, delta: 125, contentHeight: 1200, viewportHeight: 370), 830)
        XCTAssertNil(TVDescriptionScrollPolicy.targetY(
            current: 830, delta: 125, contentHeight: 1200, viewportHeight: 370))
    }

    func testReverseScrollingAndShortDescriptions() {
        XCTAssertEqual(TVDescriptionScrollPolicy.targetY(
            current: 200, delta: -125, contentHeight: 800, viewportHeight: 370), 75)
        XCTAssertEqual(TVDescriptionScrollPolicy.targetY(
            current: 60, delta: -125, contentHeight: 800, viewportHeight: 370), 0)
        XCTAssertNil(TVDescriptionScrollPolicy.targetY(
            current: 0, delta: -125, contentHeight: 800, viewportHeight: 370))
        XCTAssertNil(TVDescriptionScrollPolicy.targetY(
            current: 0, delta: 125, contentHeight: 200, viewportHeight: 370))
    }

    func testInvalidGeometryNeverScrolls() {
        XCTAssertNil(TVDescriptionScrollPolicy.targetY(
            current: .nan, delta: 125, contentHeight: 1000, viewportHeight: 370))
        XCTAssertNil(TVDescriptionScrollPolicy.targetY(
            current: 0, delta: 125, contentHeight: 1000, viewportHeight: 0))
    }
}
