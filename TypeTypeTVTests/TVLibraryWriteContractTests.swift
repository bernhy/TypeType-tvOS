import Foundation
import XCTest
@testable import TypeTypeTV

final class TVLibraryWriteContractTests: XCTestCase {
    func testForeignVideoURLStaysInsideOneEncodedRouteSegment() throws {
        let base = URL(string: "https://instance.example/api/")!
        let target = "https://www.youtube.com/watch?v=abc123def45&t=35%23#sample"
        for path in ["favorites", "watch-later"] {
            let uri = try TVLibraryRoutes.mediaURL(
                base: base, collection: path, videoURL: target
            )
            XCTAssertEqual(uri.host, "instance.example")
            XCTAssertNil(uri.query)
            XCTAssertNil(uri.fragment)
            let parsed = URLComponents(url: uri, resolvingAgainstBaseURL: false)!
            XCTAssertTrue(parsed.percentEncodedPath.hasPrefix("/api/\(path)/"))
            XCTAssertTrue(parsed.percentEncodedPath.contains("%2F%2Fwww.youtube.com%2Fwatch"))
            XCTAssertTrue(parsed.percentEncodedPath.contains("%3Fv="))
            XCTAssertTrue(parsed.percentEncodedPath.contains("%23sample"))
        }
    }

    func testWatchLaterPayloadMatchesAndroidServerContract() throws {
        let video = VideoItem(
            id: "test", title: "Example", url: "https://youtu.be/abc123def45",
            thumbnailUrl: "https://i.ytimg.com/example.jpg",
            uploaderName: "Channel", duration: 123, isLive: false
        )
        let body = try JSONSerialization.jsonObject(with: JSONEncoder().encode(
            TVWatchLaterWrite(video: video)
        )) as? [String: Any]
        XCTAssertEqual(body?["url"] as? String, video.url)
        XCTAssertEqual(body?["duration"] as? Int, 123)
        XCTAssertEqual(body?["channelName"] as? String, "Channel")
        XCTAssertEqual(body?["channelUrl"] as? String, "")
    }
}
