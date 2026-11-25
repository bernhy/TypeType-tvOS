import XCTest
@testable import TypeTypeTV

final class TVDirectPlaybackTests: XCTestCase {
    private func video(_ id: String) -> VideoItem {
        VideoItem(
            id: id, title: "Video " + id,
            url: "https://www.youtube.com/watch?v=" + id,
            thumbnailUrl: nil, duration: 300, isLive: false
        )
    }

    func testSelectedPlaylistTileStartsAtItsOwnIndex() {
        let a = video("abc123def45")
        let b = video("uvw123abc45")
        let c = video("xyz123abc45")
        let queue = [a, b, c]
        XCTAssertEqual(TVDirectPlaybackPolicy.queueIndex(for: b, in: queue), 1)
        XCTAssertEqual(TVDirectPlaybackPolicy.queueIndex(for: a, in: queue), 0)
        XCTAssertEqual(TVDirectPlaybackPolicy.queueIndex(for: c, in: queue), 2)
        XCTAssertNil(TVDirectPlaybackPolicy.queueIndex(for: a, in: nil))
        XCTAssertNil(TVDirectPlaybackPolicy.queueIndex(
            for: video("notinqueue1"), in: queue
        ))
    }

    func testDirectPlaybackRequestsHaveIndependentNavigationIdentity() {
        let item = video("abc123def45")
        let first = TVDirectPlaybackRequest(
            video: item, playbackQueue: nil, onReturnedVideo: nil
        )
        let second = TVDirectPlaybackRequest(
            video: item, playbackQueue: nil, onReturnedVideo: nil
        )
        XCTAssertNotEqual(first, second)
        XCTAssertEqual(Set([first, second]).count, 2)
    }

    func testPlaybackActionForwardsSelectionQueueAndReturnCallback() {
        let a = video("abc123def45")
        let b = video("uvw123abc45")
        var capturedVideo: VideoItem?
        var capturedQueue: [VideoItem]?
        var callbackVideo: VideoItem?
        let action = TVDirectPlaybackAction { video, queue, onReturn in
            capturedVideo = video
            capturedQueue = queue
            onReturn?(video)
        }
        action(b, playbackQueue: [a, b]) { callbackVideo = $0 }
        XCTAssertEqual(capturedVideo?.url, b.url)
        XCTAssertEqual(capturedQueue?.map(\.url), [a.url, b.url])
        XCTAssertEqual(callbackVideo?.url, b.url)
    }
}
