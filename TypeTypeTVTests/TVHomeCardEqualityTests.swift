import XCTest
@testable import TypeTypeTV

final class TVHomeCardEqualityTests: XCTestCase {
    func testHomeCardEqualityOnlySkipsIdenticalVisualInputs() throws {
        let api = try TypeTypeAPI(address: "https://example.com")
        let other = try TypeTypeAPI(address: "https://other.example.com")
        let video = VideoItem(
            id: "one", title: "Original", url: "https://youtu.be/ABCDEFGHIJK",
            thumbnailUrl: "https://img.example.com/one.jpg",
            uploaderName: "Channel", duration: 120, isLive: false
        )
        var changed = video
        changed.viewCount = 100

        let a = TVHomeCardContent(api: api, video: video)
        XCTAssertEqual(a, TVHomeCardContent(api: api, video: video))
        XCTAssertNotEqual(a, TVHomeCardContent(api: other, video: video))
        XCTAssertNotEqual(a, TVHomeCardContent(api: api, video: changed))
        XCTAssertNotEqual(a, TVHomeCardContent(
            api: api, video: video, lookupMissingMetadata: true
        ))
    }
}
