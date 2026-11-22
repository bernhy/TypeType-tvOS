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

    func testReusableFormattersPreserveDateAndLanguage() throws {
        var video = VideoItem(
            id: "date", title: "Sample", url: "https://youtu.be/abc123def45",
            thumbnailUrl: nil, uploaderName: "Channel", duration: 120,
            isLive: false
        )
        video.uploadDate = "2026-11-18"
        let parsed = try XCTUnwrap(TVVideoMetadata.publicationDate(for: video))
        let calendar = Calendar(identifier: .gregorian)
        let fields = calendar.dateComponents(in: TimeZone(secondsFromGMT: 0)!, from: parsed)
        XCTAssertEqual(fields.year, 2026)
        XCTAssertEqual(fields.month, 11)
        XCTAssertEqual(fields.day, 18)

        video.viewCount = 18_000
        let now = parsed.addingTimeInterval(2 * 86_400)
        let german = TVVideoMetadata.subtitle(for: video, now: now, language: "de")
        let english = TVVideoMetadata.subtitle(for: video, now: now, language: "en")
        XCTAssertNotNil(german)
        XCTAssertNotNil(english)
        XCTAssertEqual(TVVideoMetadata.subtitle(for: video, now: now, language: "de"), german)
        XCTAssertEqual(TVVideoMetadata.subtitle(for: video, now: now, language: "en"), english)
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

    func testProgressEnrichmentHandlesVeryLargeDurationSafely() {
        var video = VideoItem(
            id: "long", title: "Malformed duration",
            url: "https://youtu.be/abc123def45", thumbnailUrl: nil,
            uploaderName: nil, duration: Int.max, isLive: false
        )
        video.watched = false
        let enriched = video.withProgress(10_000)
        XCTAssertEqual(enriched.watchPositionMs, 10_000)
        XCTAssertFalse(enriched.watched ?? true)
        XCTAssertFalse(TVWatchedState.isWatched(enriched, positionMs: 10_000))

        video.duration = 100
        XCTAssertFalse(video.withProgress(89_999).watched ?? true)
        XCTAssertTrue(video.withProgress(90_000).watched ?? false)
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


    func testResumeReusesLoadedRecommendationsWithoutOverwritingProgress() {
        var history = VideoItem(
            id: "history", title: "History",
            url: "https://www.youtube.com/watch?v=abc123def45",
            thumbnailUrl: nil, uploaderName: "Channel", duration: 180, isLive: false
        )
        history.watchPositionMs = 72_000
        history.watched = false
        var feed = VideoItem(
            id: "abc123def45", title: "Feed", url: "https://youtu.be/abc123def45",
            thumbnailUrl: nil, uploaderName: "Channel", duration: 360, isLive: false
        )
        feed.viewCount = 24_500
        feed.publishedAt = 1_800_000_000_000
        feed.isLiveContent = true
        feed.isPostLive = true

        let actual = TVVideoMetadata.reusingRecommendationMetadata([history], from: [feed])
        XCTAssertEqual(actual.count, 1)
        XCTAssertEqual(actual[0].viewCount, 24_500)
        XCTAssertEqual(actual[0].publishedAt, 1_800_000_000_000)
        XCTAssertEqual(actual[0].watchPositionMs, 72_000)
        XCTAssertEqual(actual[0].duration, 180)
        XCTAssertEqual(actual[0].watched, false)
        XCTAssertEqual(actual[0].title, "History")
        XCTAssertEqual(actual[0].isLiveContent, true)
        XCTAssertEqual(actual[0].isPostLive, true)
        XCTAssertFalse(TVLiveStreamDisplayPolicy.isOngoing(actual[0]))
    }

    func testResumeKeepsServerMetadataAndDoesNotInventMissingFields() {
        var history = VideoItem(
            id: "existing", title: "Existing", url: "https://youtu.be/abc123def45",
            thumbnailUrl: nil, uploaderName: "Channel", duration: 180, isLive: false
        )
        history.viewCount = 3_456
        history.publishedAt = 1_700_000_000_000
        var feed = history
        feed.viewCount = 9_999
        feed.publishedAt = 1_800_000_000_000
        let preserved = TVVideoMetadata.reusingRecommendationMetadata([history], from: [feed])
        XCTAssertEqual(preserved[0].viewCount, 3_456)
        XCTAssertEqual(preserved[0].publishedAt, 1_700_000_000_000)

        let noMatch = VideoItem(
            id: "unrelated", title: "Other",
            url: "https://notyoutube.com/watch?v=abc123def45",
            thumbnailUrl: nil, uploaderName: nil, duration: 30, isLive: false
        )
        XCTAssertEqual(
            TVVideoMetadata.reusingRecommendationMetadata([noMatch], from: [feed]),
            [noMatch]
        )
        XCTAssertEqual(
            TVVideoMetadata.reusingRecommendationMetadata([history], from: []),
            [history]
        )
    }

    func testYouTubeRoutingAgreesWithLiveBadgeAndPostLiveStatus() {
        var stream = VideoItem(
            id: "live", title: "Live", url: "https://youtu.be/abc123def45",
            thumbnailUrl: nil, uploaderName: nil, duration: 300,
            isLive: false
        )
        stream.isLiveContent = true
        XCTAssertTrue(TVLiveStreamDisplayPolicy.isOngoing(stream))
        XCTAssertTrue(TVYouTubeStreamRouting.isLiveHLS(stream))
        XCTAssertEqual(TVYouTubeStreamRouting.endpoint(for: stream),
                       "streams/youtube/live")
        // The live status is the final accessibility component. Checking
        // contains("Live") would also match a video's own title.
        XCTAssertTrue(TTTheme.accessibilityText(for: stream).hasSuffix(
            ", " + TVL10n.value("video.liveAccessibility")
        ))

        stream.isPostLive = true
        XCTAssertFalse(TVLiveStreamDisplayPolicy.isOngoing(stream))
        XCTAssertFalse(TVYouTubeStreamRouting.isLiveHLS(stream))
        XCTAssertEqual(TVYouTubeStreamRouting.endpoint(for: stream),
                       "streams/youtube/sabr")
        // The title is literally "Live", but the post-live status must
        // announce the VOD duration instead of a live accessibility badge.
        XCTAssertEqual(TTTheme.accessibilityText(for: stream),
                       "Live, " + TTTheme.time(300))

        // A stale isLive=true from older API entries must never override
        // the explicit post-live state.
        var stale = VideoItem(
            id: "archive", title: "Archive", url: "https://youtu.be/xyz123def45",
            thumbnailUrl: nil, uploaderName: nil, duration: 600,
            isLive: true
        )
        stale.isLiveContent = true
        stale.isPostLive = true
        XCTAssertEqual(TVYouTubeStreamRouting.endpoint(for: stale),
                       "streams/youtube/sabr")
    }

    func testLiveBadgeUsesOngoingServerClassificationNotOnlyIsLive() {
        var live = VideoItem(
            id: "live", title: "Live", url: "https://youtu.be/abc123def45",
            thumbnailUrl: nil, uploaderName: nil, duration: nil, isLive: false
        )
        live.isLiveContent = true
        XCTAssertTrue(TVLiveStreamDisplayPolicy.isOngoing(live))
        live.isPostLive = true
        XCTAssertFalse(TVLiveStreamDisplayPolicy.isOngoing(live))
        live.isPostLive = false
        XCTAssertTrue(TVLiveStreamDisplayPolicy.isOngoing(live))
    }

}
