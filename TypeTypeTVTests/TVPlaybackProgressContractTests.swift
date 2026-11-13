import XCTest
import Foundation
@testable import TypeTypeTV

final class TVPlaybackProgressContractTests: XCTestCase {
    func testProgressPayloadUsesMillisecondsAndHistorySeconds() throws {
        let video = VideoItem(
            id: "abc", title: "Title", url: "https://youtu.be/abc123def45",
            thumbnailUrl: nil, uploaderName: "Channel",
            duration: 300, isLive: false
        )
        let progress = try JSONSerialization.jsonObject(
            with: JSONEncoder().encode(TVSaveProgressWrite(position: 98_765))
        ) as? [String: Any]
        XCTAssertEqual(progress?["position"] as? Int, 98_765)

        let history = try JSONSerialization.jsonObject(
            with: JSONEncoder().encode(
                TVHistoryWrite(video: video, positionMs: 98_765)
            )
        ) as? [String: Any]
        XCTAssertEqual(history?["progress"] as? Int, 98)
        XCTAssertEqual(history?["duration"] as? Int, 300)
        XCTAssertEqual(history?["url"] as? String, video.url)
    }

    func testGetProgressPathEncodesVideoURL() throws {
        let url = try TVLibraryRoutes.mediaURL(
            base: URL(string: "https://example.com/api/")!,
            collection: "progress",
            videoURL: "https://youtube.com/watch?v=abc123def45&t=5"
        )
        XCTAssertEqual(url.host, "example.com")
        XCTAssertNil(url.query)
        XCTAssertTrue(url.absoluteString.contains("/progress/https:%2F%2F"))
        XCTAssertTrue(url.absoluteString.contains("%3Fv="))
    }

    func testProgressResponseUsesMilliseconds() throws {
        let result = try JSONDecoder().decode(
            TVProgressDTO.self, from: Data(
                #"{"videoUrl":"v","position":100237}"#.utf8
            )
        )
        XCTAssertEqual(result.position, 100_237)
    }
    @MainActor
    func testLocalProgressIsClearedOnAccountSwitch() {
        let cache = TVLocalProgress.shared
        cache.clear()
        cache.record("https://youtu.be/abc123def45", positionMs: 45_000)
        XCTAssertEqual(cache.positions["https://youtu.be/abc123def45"], 45_000)
        cache.clear()
        XCTAssertTrue(cache.positions.isEmpty)
    }

}
