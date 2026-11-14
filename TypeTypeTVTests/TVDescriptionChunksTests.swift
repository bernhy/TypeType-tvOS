import XCTest
@testable import TypeTypeTV

final class TVDescriptionChunksTests: XCTestCase {
    func testVeryLongParagraphCanBeNavigatedAsShortFocusableRows() {
        let source = Array(repeating: "Ein längerer Satz zu einem Video", count: 90).joined(separator: " ")
        let chunks = TVDescriptionChunks.make(source)
        XCTAssertGreaterThan(chunks.count, 10)
        XCTAssertTrue(chunks.allSatisfy { $0.count <= 170 })
        XCTAssertEqual(chunks.joined(separator: " "), source)
    }

    func testMultipleParagraphsDoNotMergeIntoOneGiantFocusTarget() {
        let chunks = TVDescriptionChunks.make("Absatz eins.\n\nAbsatz zwei.\nAbsatz drei.")
        XCTAssertEqual(chunks, ["Absatz eins.", "Absatz zwei.", "Absatz drei."])
    }
}
