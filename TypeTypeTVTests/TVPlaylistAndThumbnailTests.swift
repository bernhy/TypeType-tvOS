import Foundation
import XCTest
@testable import TypeTypeTV

final class TVPlaylistAndThumbnailTests: XCTestCase {
    func testVideoProgressHasNinetyPercentWatchedThreshold() {
        let base = VideoItem(
            id: "sample", title: "Sample", url: "https://youtu.be/abc123def45",
            thumbnailUrl: nil, uploaderName: "Channel", duration: 120, isLive: false
        )
        let partial = base.withProgress(40_000)
        XCTAssertEqual(partial.watchPositionMs, 40_000)
        XCTAssertEqual(partial.watched, false)
        XCTAssertEqual(base.withProgress(108_000).watched, true)
        XCTAssertEqual(base.withProgress(120_000).watched, true)
        XCTAssertEqual(base.withProgress(0).watched, false)
    }

    func testPlaylistVideosPreserveProgressAndChannelMetadata() throws {
        let text = #"""
        {
          "id":"playlist-1","name":"Favorites from home","description":"A list",
          "videoCount":1,
          "videos":[{
            "url":"https://www.youtube.com/watch?v=abc123def45",
            "title":"Sample","thumbnail":"https://img.example/a.jpg",
            "duration":120,"channelName":"Channel",
            "channelUrl":"https://www.youtube.com/@channel",
            "watchPosition":110000,"watched":true
          }]
        }
        """#
        let playlist = try JSONDecoder().decode(
            TVPlaylistDTO.self, from: Data(text.utf8)
        )
        XCTAssertEqual(playlist.name, "Favorites from home")
        XCTAssertEqual(playlist.count, 1)
        let video = try XCTUnwrap(playlist.items.first)
        XCTAssertEqual(video.watchPositionMs, 110_000)
        XCTAssertEqual(video.watched, true)
        XCTAssertEqual(video.uploaderUrl, "https://www.youtube.com/@channel")
        XCTAssertEqual(video.duration, 120)
    }

    func testPlaylistAndChannelBlockPayloadMatchTypeTypeServer() throws {
        var video = VideoItem(
            id: "abc", title: "A video", url: "https://youtu.be/abc123def45",
            thumbnailUrl: "https://img.example/thumb.jpg", uploaderName: "Channel",
            duration: 72, isLive: false
        )
        video.uploaderUrl = "https://www.youtube.com/@thechannel"
        let added = try JSONSerialization.jsonObject(
            with: JSONEncoder().encode(TVPlaylistVideoWrite(video: video))
        ) as? [String: Any]
        XCTAssertEqual(added?["url"] as? String, video.url)
        XCTAssertEqual(added?["channelUrl"] as? String, video.uploaderUrl)
        XCTAssertEqual(added?["duration"] as? Int, 72)

        let blocked = try JSONSerialization.jsonObject(
            with: JSONEncoder().encode(
                TVBlockWrite(url: video.uploaderUrl!, name: video.uploaderName,
                             thumbnailUrl: nil)
            )
        ) as? [String: Any]
        XCTAssertEqual(blocked?["name"] as? String, "Channel")
        XCTAssertNil(blocked?["global"])
        XCTAssertEqual(blocked?["url"] as? String, video.uploaderUrl)
    }
}
