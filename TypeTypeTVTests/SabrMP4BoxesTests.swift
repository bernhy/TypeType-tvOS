import Foundation
import XCTest
@testable import TypeTypeTV

final class SabrMP4BoxesTests: XCTestCase {
    private func box(_ name: String, payload: [UInt8] = []) -> Data {
        let length = 8 + payload.count
        let prefix: [UInt8] = [
            UInt8((length >> 24) & 255), UInt8((length >> 16) & 255),
            UInt8((length >> 8) & 255), UInt8(length & 255)
        ]
        return Data(prefix + Array(name.utf8) + payload)
    }

    func testAcceptsInitAndFragmentWithOptionalBoxes() throws {
        let initData = box("ftyp") + box("moov", payload: [0, 0, 0, 0])
        let fragment = box("styp") + box("moof") + box("mdat", payload: [1, 2, 3])
        XCTAssertNoThrow(try SabrMP4Boxes.validate(initialization: initData, fragment: fragment))
        XCTAssertEqual(try SabrMP4Boxes.types(in: fragment), Set(["styp", "moof", "mdat"]))
    }

    func testRejectsMissingMovieAndTruncatedMedia() {
        XCTAssertThrowsError(try SabrMP4Boxes.validate(
            initialization: box("ftyp"), fragment: box("moof") + box("mdat")
        ))
        XCTAssertThrowsError(try SabrMP4Boxes.types(in: Data([0, 0, 0, 12, 109, 111, 111, 102])))
        XCTAssertThrowsError(try SabrMP4Boxes.types(in: Data([0, 0, 0, 1, 109, 100, 97, 116])))
    }

    func testSupportsExtendedSizeAndToEndBoxes() throws {
        let extended = Data([
            0, 0, 0, 1, 109, 111, 111, 118,
            0, 0, 0, 0, 0, 0, 0, 16
        ])
        XCTAssertTrue(try SabrMP4Boxes.types(in: extended).contains("moov"))
        let toEOF = Data([0, 0, 0, 0, 109, 100, 97, 116, 1, 2, 3])
        XCTAssertTrue(try SabrMP4Boxes.types(in: toEOF).contains("mdat"))
    }
}
