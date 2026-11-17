import XCTest
@testable import TypeTypeTV

final class TVSearchHistoryPresentationTests: XCTestCase {
    func testServerHistoryIsTrimmedDeduplicatedAndBoundedWithoutChangingIDs() {
        let source = [
            TVSearchHistoryItem(id: "new", term: "  Audi  ", searchedAt: 50),
            TVSearchHistoryItem(id: "repeat", term: "audi", searchedAt: 40),
            TVSearchHistoryItem(id: "empty", term: "  ", searchedAt: 30)
        ] + (0..<10).map {
            TVSearchHistoryItem(id: "id-\($0)", term: "term-\($0)",
                                searchedAt: Int64($0))
        }
        let rows = TVSearchHistoryPresentation.visible(source)
        XCTAssertEqual(rows.count, 8)
        XCTAssertEqual(rows.first?.id, "new")
        XCTAssertEqual(rows.first?.term, "Audi")
        XCTAssertEqual(rows.last?.term, "term-6")
    }

    func testEmptyServerHistoryHasNoLocalFallback() {
        XCTAssertEqual(TVSearchHistoryPresentation.visible([]), [])
    }
}
