import Foundation
import XCTest
@testable import TypeTypeTV

final class TVSponsorBlockPolicyTests: XCTestCase {
    private func segment(_ start: Double, _ end: Double,
                         category: String = "sponsor") -> TVSponsorBlockSegment {
        TVSponsorBlockSegment(startTime: start, endTime: end,
                              category: category, action: "skip")
    }
    private func settings(_ json: String = "{}") throws -> TVServerSettings {
        try JSONDecoder().decode(TVServerSettings.self, from: Data(json.utf8))
    }

    func testDefaultSponsorAutoSkipAndChapterMarkOnly() throws {
        let config = try settings()
        XCTAssertEqual(TVSponsorBlock.target(segments: [segment(10, 25)],
            settings: config, position: 11, duration: 300, streamCategory: nil), 25)
        XCTAssertNil(TVSponsorBlock.target(segments: [segment(10, 25, category: "chapter")],
            settings: config, position: 11, duration: 300, streamCategory: nil))
    }

    func testDisabledModeAndLongSegmentGuard() throws {
        XCTAssertNil(TVSponsorBlock.target(segments: [segment(10, 25)],
            settings: try settings(#"{"sponsorBlockMode":"disabled"}"#),
            position: 11, duration: 300, streamCategory: nil))
        XCTAssertNil(TVSponsorBlock.target(segments: [segment(0, 190)],
            settings: try settings(), position: 11, duration: 300, streamCategory: nil))
    }

    func testMillisecondsNormalizationAndMinimumDuration() throws {
        let config = try settings(#"{"sponsorBlockMinimumDuration":5}"#)
        XCTAssertEqual(TVSponsorBlock.target(segments: [segment(10_000, 20_000)],
            settings: config, position: 15, duration: 300, streamCategory: nil), 20)
        XCTAssertNil(TVSponsorBlock.target(segments: [segment(10, 13)],
            settings: config, position: 11, duration: 300, streamCategory: nil))
    }

    func testInvalidNumbersCannotTriggerSeek() throws {
        XCTAssertNil(TVSponsorBlock.target(segments: [segment(.nan, .infinity)],
            settings: try settings(), position: 20, duration: 300, streamCategory: nil))
    }
}