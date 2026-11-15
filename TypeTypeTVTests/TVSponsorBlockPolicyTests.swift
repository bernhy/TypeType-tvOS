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
 
    func testNonSkipActionTypesNeverTriggerAutomaticSeek() throws {
        let config = try settings()
        for action in ["mute", "poi", "chapter", "full"] {
            let marker = TVSponsorBlockSegment(
                startTime: 10, endTime: 20, category: "sponsor", action: action
            )
            XCTAssertNil(TVSponsorBlock.target(
                segments: [marker], settings: config, position: 12,
                duration: 300, streamCategory: nil
            ), "Action type \(action) must never trigger a seek")
        }
    }

    func testSponsorNoticeActiveSegmentRespectsDisplayPolicy() throws {
        let config = try settings()
        let paid = segment(10, 25)
        let active = TVSponsorBlock.activeSegment(
            segments: [paid], settings: config, position: 12, duration: 300
        )
        XCTAssertEqual(active?.category, "sponsor")
        XCTAssertEqual(active?.endTime, 25)
        XCTAssertNotNil(active?.id)
        XCTAssertNil(TVSponsorBlock.activeSegment(
            segments: [paid], settings: config, position: 25, duration: 300
        ))
        let chapter = segment(30, 55, category: "chapter")
        let chapters = try settings(#"{"sponsorBlockShowChapters":true}"#)
        XCTAssertEqual(TVSponsorBlock.activeSegment(
            segments: [chapter], settings: chapters, position: 32, duration: 300
        )?.endTime, 55)
        XCTAssertNil(TVSponsorBlock.target(
            segments: [chapter], settings: chapters, position: 32,
            duration: 300, streamCategory: nil
        ))
        XCTAssertNil(TVSponsorBlock.activeSegment(
            segments: [paid],
            settings: try settings(#"{"sponsorBlockShowCurrentSegment":false}"#),
            position: 12, duration: 300
        ))
        XCTAssertNil(TVSponsorBlock.activeSegment(
            segments: [paid], settings: config, position: .nan, duration: 300
        ))
    }

    func testInvalidNumbersCannotTriggerSeek() throws {
        XCTAssertNil(TVSponsorBlock.target(segments: [segment(.nan, .infinity)],
            settings: try settings(), position: 20, duration: 300, streamCategory: nil))
    }
}