import Foundation
import XCTest
@testable import TypeTypeTV

final class TVVideoMetadataTests: XCTestCase {
    func testTypeTypeRecommendationPreservesViewsAndMillisecondPublicationTime() throws {
        let json = Data(#"""
        {"id":"abc123def45","title":"Video","url":"https://youtu.be/abc123def45",
         "thumbnailUrl":"https://example.com/t.jpg","uploaderName":"Channel",
         "duration":180,"isLive":false,"viewCount":135400,
         "publishedAt":1800000000000,"uploaded":-1}
        """#.utf8)
        let video = try JSONDecoder().decode(VideoItem.self, from: json)
        XCTAssertEqual(video.viewCount, 135_400)
        XCTAssertEqual(video.publishedAt, 1_800_000_000_000)
        XCTAssertEqual(TVVideoMetadata.publicationDate(for: video)?
                       .timeIntervalSince1970, 1_800_000_000)
        XCTAssertEqual(TVVideoMetadata.viewLabel(135_400, language: "de"),
                       "135K Aufrufe")
        let now = Date(timeIntervalSince1970: 1_800_000_000 + 86_400)
        let text = try XCTUnwrap(TVVideoMetadata.subtitle(
            for: video, now: now, language: "de"
        ))
        XCTAssertTrue(text.contains("135K Aufrufe"))
        XCTAssertTrue(text.contains(" · "))
    }

    func testUnknownViewsAndPublicationDateNeverInvented() throws {
        let json = Data(#"""
        {"id":"abc123def45","title":"Video","url":"https://youtu.be/abc123def45",
         "duration":120,"isLive":false}
        """#.utf8)
        let video = try JSONDecoder().decode(VideoItem.self, from: json)
        XCTAssertNil(TVVideoMetadata.subtitle(for: video, language: "de"))
        XCTAssertNil(video.viewCount)
    }

    func testZeroViewsAreShownButNegativeUnknownViewsAreHidden() {
        XCTAssertEqual(TVVideoMetadata.viewLabel(0, language: "de"), "0 Aufrufe")
        XCTAssertNil(TVVideoMetadata.viewLabel(-1, language: "de"))
    }
}
