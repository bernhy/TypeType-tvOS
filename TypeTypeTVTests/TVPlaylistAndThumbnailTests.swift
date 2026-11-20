import Foundation
import XCTest
import UIKit
@testable import TypeTypeTV

final class TVPlaylistAndThumbnailTests: XCTestCase {
    func testThumbnailDecoderPreservesShapeWithinPixelBudget() throws {
        let originalSize = CGSize(width: 64, height: 32)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let png = UIGraphicsImageRenderer(size: originalSize, format: format).pngData { context in
            UIColor.red.setFill()
            context.fill(CGRect(origin: .zero, size: originalSize))
        }
        let decoded = try XCTUnwrap(TVThumbnailDecoder.decode(png)?.cgImage)
        XCTAssertLessThanOrEqual(decoded.width, TVThumbnailDecoder.maximumPixelDimension)
        XCTAssertLessThanOrEqual(decoded.height, TVThumbnailDecoder.maximumPixelDimension)
        XCTAssertEqual(decoded.width, 64)
        XCTAssertEqual(decoded.height, 32)
    }

    func testThumbnailSizingAndSharedPublicImageKeys() throws {
        let image = try XCTUnwrap(URL(string: "https://typetype.example/api/files/image"))
        let sameURL = try XCTUnwrap(URL(string: "https://typetype.example/api/files/image"))
        let otherServer = try XCTUnwrap(URL(string: "https://other.example/api/files/image"))
        let external = try XCTUnwrap(URL(string: "https://cdn.example/image"))

        XCTAssertEqual(TVThumbnailRequestPolicy.pixelLimit(1), 64)
        XCTAssertEqual(TVThumbnailRequestPolicy.pixelLimit(1_024), 1_024)
        XCTAssertEqual(TVThumbnailRequestPolicy.pixelLimit(9_999), 2_048)

        // The same public image is shared regardless of which account
        // discovered it, including a public image proxied by TypeType.
        let key = TVThumbnailRequestPolicy.cacheKey(url: image, pixels: 1_024)
        XCTAssertEqual(key, TVThumbnailRequestPolicy.cacheKey(url: sameURL, pixels: 1_024))
        XCTAssertEqual(key.count, 64)
        XCTAssertFalse(key.contains("typetype.example"))

        // Different delivered images and different decode sizes remain
        // separate; publicly available CDN thumbnails share the same key.
        XCTAssertNotEqual(key, TVThumbnailRequestPolicy.cacheKey(url: otherServer, pixels: 1_024))
        XCTAssertNotEqual(key, TVThumbnailRequestPolicy.cacheKey(url: image, pixels: 2_048))
        XCTAssertEqual(
            TVThumbnailRequestPolicy.cacheKey(url: external, pixels: 1_024),
            TVThumbnailRequestPolicy.cacheKey(url: external, pixels: 1_024)
        )
    }

    func testThumbnailDecoderDownsamplesButPreservesAspectRatio() throws {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let data = UIGraphicsImageRenderer(
            size: CGSize(width: 800, height: 400), format: format
        ).pngData { context in
            UIColor.red.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 800, height: 400))
        }
        let image = try XCTUnwrap(
            TVThumbnailDecoder.decode(data, maximumDimension: 128)?.cgImage
        )
        XCTAssertLessThanOrEqual(image.width, 128)
        XCTAssertLessThanOrEqual(image.height, 128)
        XCTAssertEqual(Double(image.width) / Double(image.height), 2, accuracy: 0.02)
    }

    func testMediaURLsCannotEscapeOriginViaProtocolRelativePath() throws {
        let https = try TypeTypeAPI(address: "https://typetype.example")
        XCTAssertEqual(
            https.relativeMediaURL("/api/files/image.jpg")?.absoluteString,
            "https://typetype.example/api/files/image.jpg"
        )
        XCTAssertEqual(
            https.relativeMediaURL("media/segment.m4s")?.absoluteString,
            "https://typetype.example/media/segment.m4s"
        )
        XCTAssertEqual(
            https.relativeMediaURL("https://cdn.example/thumb.jpg")?.absoluteString,
            "https://cdn.example/thumb.jpg"
        )
        XCTAssertNil(https.relativeMediaURL("//untrusted.example/thumb.jpg"))
        XCTAssertNil(https.relativeMediaURL("javascript:alert(1)"))
        XCTAssertNil(https.relativeMediaURL("http://untrusted.example/thumb.jpg"))

        let local = try TypeTypeAPI(address: "http://192.168.0.42:8080")
        XCTAssertNil(local.relativeMediaURL("//untrusted.example/segment.m4s"))
        XCTAssertEqual(
            local.relativeMediaURL("/media/segment.m4s")?.absoluteString,
            "http://192.168.0.42:8080/media/segment.m4s"
        )
    }

    func testOversizedHistoryProgressCannotOverflowMilliseconds() throws {
        let raw = Data(#"""
        {"id":"history1","url":"https://youtu.be/abc123def45",
         "title":"Example","thumbnail":"","channelName":"Channel",
         "duration":120,"progress":9223372036854775807}
        """#.utf8)
        let entry = try JSONDecoder().decode(TVHistoryDTO.self, from: raw)
        XCTAssertEqual(entry.video.watchPositionMs,
                       (Int64.max / 1_000) * 1_000)
    }

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
