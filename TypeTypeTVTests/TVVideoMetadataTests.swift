import Foundation
import XCTest
@testable import TypeTypeTV

final class TVVideoMetadataTests: XCTestCase {
    func testChannelURLUsesProvidedVideoOrStreamMetadataAndRejectsUnsafeLinks() throws {
        var video = VideoItem(
            id: "abc", title: "Sample", url: "https://youtu.be/abc",
            thumbnailUrl: nil, uploaderName: "Creator", duration: 120, isLive: false
        )
        XCTAssertNil(TVVideoMetadata.channelURL(for: video, stream: nil))
        let metadata = try JSONDecoder().decode(
            StreamInfo.self,
            from: Data(#"{"uploaderUrl":"https://www.youtube.com/@creator/videos"}"#.utf8)
        )
        XCTAssertEqual(
            TVVideoMetadata.channelURL(for: video, stream: metadata),
            "https://www.youtube.com/@creator/videos"
        )
        video.uploaderUrl = "https://www.youtube.com/channel/UC123"
        XCTAssertEqual(
            TVVideoMetadata.channelURL(for: video, stream: metadata),
            video.uploaderUrl
        )
        for invalid in ["javascript:alert(1)", "file:///etc/passwd", "/channel/abc",
                        "https://user:secret@example.com/channel"] {
            video.uploaderUrl = invalid
            XCTAssertEqual(
                TVVideoMetadata.channelURL(for: video, stream: metadata),
                metadata.uploaderUrl
            )
        }
        video.uploaderUrl = ""
        XCTAssertNil(TVVideoMetadata.channelURL(for: video, stream: nil))
    }

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
    func testPlaylistPreservesServerViewsAndPublicationDate() throws {
        let data = Data(#"""
        {"url":"https://www.youtube.com/watch?v=abc123def45",
         "title":"Example","thumbnail":"","duration":120,
         "channelName":"Author","watchPosition":55000,
         "watched":false,"viewCount":99122,"publishedAt":1800000000000}
        """#.utf8)
        let row = try JSONDecoder().decode(TVPlaylistVideoDTO.self, from: data).video
        XCTAssertEqual(row.viewCount, 99_122)
        XCTAssertEqual(row.publishedAt, 1_800_000_000_000)
        XCTAssertEqual(row.watchPositionMs, 55_000)
    }

    func testYoutubeAliasesShareTheSameIdentityButSpoofedHostsDoNot() {
        XCTAssertTrue(TVVideoIdentity.equivalent(
            "https://youtu.be/abc123def45",
            "https://www.youtube.com/watch?v=abc123def45"))
        XCTAssertFalse(TVVideoIdentity.equivalent(
            "https://notyoutube.com/watch?v=abc123def45",
            "https://youtu.be/abc123def45"))
        XCTAssertFalse(TVVideoIdentity.equivalent("", ""))
    }

    func testExplicitZeroProgressOverridesWatchedFlag() {
        var video = VideoItem(
            id: "abc123def45", title: "Example",
            url: "https://youtu.be/abc123def45", thumbnailUrl: nil,
            uploaderName: nil, duration: 120, isLive: false
        )
        video.watched = true
        XCTAssertTrue(TVWatchedState.isWatched(video, positionMs: nil))
        XCTAssertFalse(TVWatchedState.isWatched(video, positionMs: 0))
        XCTAssertFalse(TVWatchedState.isWatched(video, positionMs: 107_000))
        XCTAssertTrue(TVWatchedState.isWatched(video, positionMs: 108_000))
    }

    @MainActor
    func testLocalProgressPropagatesAcrossYoutubeURLAliases() {
        let progress = TVLocalProgress.shared
        progress.clear()
        progress.record("https://www.youtube.com/watch?v=abc123def45", positionMs: 0)
        XCTAssertEqual(progress.position(for: "https://youtu.be/abc123def45"), 0)
        progress.record("https://youtu.be/abc123def45", positionMs: 117_000)
        XCTAssertEqual(progress.position(for: "https://www.youtube.com/watch?v=abc123def45"), 117_000)
        progress.clear()
        XCTAssertNil(progress.position(for: "https://youtu.be/abc123def45"))
    }

    func testStreamMetadataReplacesUnknownZeroFromLegacyLibraryEntries() throws {
        var video = VideoItem(
            id: "abc123def45", title: "Example",
            url: "https://youtu.be/abc123def45", thumbnailUrl: nil,
            uploaderName: "Channel", duration: 120, isLive: false
        )
        video.viewCount = 0
        video.publishedAt = -1
        let stream = try JSONDecoder().decode(StreamInfo.self, from: Data(#"""
        {"viewCount":31505,"publishedAt":1800000000000,
         "uploadDate":"2027-01-01","uploaderUrl":"https://www.youtube.com/@creator"}
        """#.utf8))
        let merged = TVVideoMetadata.merged(video, stream: stream)
        XCTAssertEqual(merged.viewCount, 31_505)
        XCTAssertEqual(merged.publishedAt, 1_800_000_000_000)
        XCTAssertEqual(merged.uploaderUrl, "https://www.youtube.com/@creator")
    }

}
