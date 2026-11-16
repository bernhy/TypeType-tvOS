import XCTest
@testable import TypeTypeTV

final class TVSearchFilterTextsTests: XCTestCase {
    func testDefaultFilterChoicesAreNotDuplicated() {
        let options = [
            TVSearchFilterOption(value: "date|1|all", label: "all", isDefault: true),
            TVSearchFilterOption(value: "date|2|past_week", label: "past_week", isDefault: false),
            TVSearchFilterOption(value: "sort|1|sort_relevance", label: "sort_relevance", isDefault: true),
            TVSearchFilterOption(value: "sort|2|sort_view", label: "sort_view", isDefault: false)
        ]
        let list = TVSearchFilterTexts.choices(options)
        XCTAssertEqual(list.map(\.value), ["date|2|past_week", "sort|2|sort_view"])
        XCTAssertEqual(TVSearchFilterTexts.groupID("sortby|12"), "sortby")
    }

    func testKnownServerIdentifiersHaveLocalizedLabels() {
        XCTAssertEqual(TVSearchFilterTexts.group("upload_date"),
                       TVL10n.value("search.filterUploadDate"))
        XCTAssertEqual(TVSearchFilterTexts.option("past_week"),
                       TVL10n.value("search.filterPastWeek"))
        XCTAssertEqual(TVSearchFilterTexts.option("features: HD"),
                       TVL10n.value("search.filterHD"))
    }
}
