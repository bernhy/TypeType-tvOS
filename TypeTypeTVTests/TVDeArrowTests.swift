import Foundation
import XCTest
@testable import TypeTypeTV

final class TVDeArrowTests: XCTestCase {
    private let videoID = "abc123def45"

    private func settings(_ json: String) throws -> TVServerSettings {
        try JSONDecoder().decode(TVServerSettings.self, from: Data(json.utf8))
    }

    private func sample() -> TVDeArrowItem {
        TVDeArrowItem(
            videoId: videoID,
            titles: [
                TVDeArrowTitleCandidate(title: "Accepted title", original: false,
                                        votes: 1, locked: false),
                TVDeArrowTitleCandidate(title: "Locked title", original: false,
                                        votes: 0, locked: true),
                TVDeArrowTitleCandidate(title: "Original marker", original: true,
                                        votes: 10, locked: true)
            ],
            thumbnails: [
                TVDeArrowThumbnailCandidate(timestamp: 42, original: false,
                                            votes: 1, locked: false),
                TVDeArrowThumbnailCandidate(timestamp: 84, original: false,
                                            votes: 0, locked: true),
                TVDeArrowThumbnailCandidate(timestamp: 10, original: true,
                                            votes: 10, locked: true)
            ],
            randomTime: 0.5,
            videoDuration: 240
        )
    }

    func testDeArrowIsOffByDefaultAndDoesNotRequireFetch() throws {
        let defaults = try settings("{}")
        XCTAssertFalse(TVDeArrowPolicy.enabled(defaults))
        XCTAssertFalse(TVDeArrowPolicy.requiresLookup(defaults))
        let original = try settings(#"{"deArrowEnabled":true,"deArrowTitleMode":"original","deArrowThumbnailMode":"original"}"#)
        XCTAssertFalse(TVDeArrowPolicy.requiresLookup(original))
    }

    func testAcceptedAndLockedModesChooseDifferentCandidates() throws {
        let origin = URL(string: "https://instance.example/")!
        let accepted = try settings(#"{"deArrowEnabled":true,"deArrowTitleMode":"dearrow","deArrowThumbnailMode":"dearrow","deArrowTrustMode":"accepted"}"#)
        let locked = try settings(#"{"deArrowEnabled":true,"deArrowTitleMode":"dearrow","deArrowThumbnailMode":"dearrow","deArrowTrustMode":"locked"}"#)

        let a = try XCTUnwrap(TVDeArrowPolicy.display(
            sample(), videoID: videoID, origin: origin, settings: accepted
        ))
        let l = try XCTUnwrap(TVDeArrowPolicy.display(
            sample(), videoID: videoID, origin: origin, settings: locked
        ))
        XCTAssertEqual(a.title, "Accepted title")
        XCTAssertEqual(l.title, "Locked title")
        XCTAssertEqual(a.thumbnailURL?.path, "/api/dearrow/thumbnail")
        XCTAssertEqual(a.thumbnailURL?.query, "videoId=abc123def45&time=42.000")
        XCTAssertEqual(l.thumbnailURL?.query, "videoId=abc123def45&time=84.000")
    }

    func testOriginalAndRandomModesDoNotInventArtwork() throws {
        let origin = URL(string: "https://instance.example/")!
        let options = try settings(#"{"deArrowEnabled":true,"deArrowTitleMode":"original","deArrowThumbnailMode":"random"}"#)
        let found = try XCTUnwrap(TVDeArrowPolicy.display(
            sample(), videoID: videoID, origin: origin, settings: options
        ))
        XCTAssertNil(found.title)
        XCTAssertEqual(found.thumbnailURL?.query, "videoId=abc123def45&time=120.000")

        let unavailable = TVDeArrowItem(
            videoId: videoID, titles: [], thumbnails: [],
            randomTime: nil, videoDuration: nil
        )
        XCTAssertNil(TVDeArrowPolicy.display(
            unavailable, videoID: videoID, origin: origin, settings: options
        ))
        XCTAssertNil(TVDeArrowPolicy.display(
            sample(), videoID: "differentId", origin: origin, settings: options
        ))
    }

    func testOriginalArtworkRemainsSecondSourceAfterDeArrow() throws {
        let origin = URL(string: "https://instance.example/")!
        let image = URL(string: "https://instance.example/api/dearrow/thumbnail?videoId=abc123def45&time=42.000")!
        let original = URL(string: "https://cdn.example/artist-cover.webp")!
        let videoURL = "https://www.youtube.com/watch?v=abc123def45"
        let list = TVThumbnailSources.urls(
            primary: image, fallbackPrimary: original,
            videoURL: videoURL, origin: origin
        )
        XCTAssertEqual(list.first, image)
        XCTAssertEqual(list.dropFirst().first, original)
        XCTAssertEqual(list.count, 6)
        XCTAssertEqual(list[2].path, "/api/proxy")
        XCTAssertEqual(list[3].path, "/api/proxy")
        XCTAssertEqual(list.last?.lastPathComponent, "mqdefault.jpg")

        let shelf = TVTopShelfPosterPolicy.candidates(
            primary: image,
            secondary: URL(string: "https://i.ytimg.com/vi/abc123def45/hq720.jpg"),
            videoURL: videoURL, origin: origin
        )
        XCTAssertEqual(shelf.first, image)
        XCTAssertEqual(shelf[1].path, "/api/proxy")
        XCTAssertEqual(shelf.last?.lastPathComponent, "mqdefault.jpg")
    }

    func testAccountScopedCacheKeysChangeWhenOptionsChange() throws {
        let api = try TypeTypeAPI(address: "https://instance.example/")
        let video = VideoItem(
            id: videoID, title: "Original title",
            url: "https://youtu.be/abc123def45", thumbnailUrl: nil,
            uploaderName: nil, duration: 120, isLive: false
        )
        let accepted = try settings(#"{"deArrowEnabled":true,"deArrowTrustMode":"accepted"}"#)
        let locked = try settings(#"{"deArrowEnabled":true,"deArrowTrustMode":"locked"}"#)
        let a = try XCTUnwrap(TVDeArrowPolicy.key(
            video: video, api: api, settings: accepted
        ))
        let b = try XCTUnwrap(TVDeArrowPolicy.key(
            video: video, api: api, settings: locked
        ))
        XCTAssertNotEqual(a, b)
        XCTAssertNil(TVDeArrowPolicy.key(
            video: video, api: api, settings: try settings("{}")
        ))
    }
}
