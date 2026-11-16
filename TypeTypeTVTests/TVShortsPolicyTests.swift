import XCTest
@testable import TypeTypeTV

final class TVShortsPolicyTests: XCTestCase {
    private func item(url: String, duration: Int? = nil,
                      isShortFormContent: Bool? = nil) -> VideoItem {
        var video = VideoItem(
            id: "dQw4w9WgXcQ", title: "Example", url: url,
            thumbnailUrl: nil, uploaderName: nil,
            duration: duration, isLive: false
        )
        video.isShortFormContent = isShortFormContent
        return video
    }

    func testServerShortsFlagWorksWithNormalWatchURL() {
        let flagged = item(
            url: "https://www.youtube.com/watch?v=dQw4w9WgXcQ",
            duration: nil, isShortFormContent: true)
        XCTAssertTrue(flagged.isShort)
        XCTAssertEqual(
            TVShortsPolicy.startPositionMs(
                video: flagged, explicitPositionMs: nil,
                savedPositionMs: 59_000),
            0, "A Short without a duration must never resume at its end")
    }

    func testOnlyGenuineShortsURLsUseURLClassification() {
        XCTAssertTrue(item(
            url: "https://www.youtube.com/shorts/dQw4w9WgXcQ").isShort)
        XCTAssertTrue(item(
            url: "https://m.youtube.com/shorts/dQw4w9WgXcQ").isShort)
        XCTAssertFalse(item(
            url: "https://youtube.com.evil.invalid/shorts/dQw4w9WgXcQ").isShort)
        XCTAssertFalse(item(
            url: "https://www.youtube.com/watch?v=dQw4w9WgXcQ",
            duration: 25).isShort,
            "A short runtime is not proof of Shorts classification")
    }

    func testExplicitSeekWithinShortsIsStillAllowed() {
        let short = item(
            url: "https://www.youtube.com/shorts/dQw4w9WgXcQ",
            duration: nil)
        XCTAssertEqual(TVShortsPolicy.startPositionMs(
            video: short, explicitPositionMs: 12_000, savedPositionMs: 50_000
        ), 12_000)
        XCTAssertEqual(TVShortsPolicy.startPositionMs(
            video: short, explicitPositionMs: 0, savedPositionMs: 50_000
        ), 0)
        let normal = item(
            url: "https://www.youtube.com/watch?v=dQw4w9WgXcQ",
            duration: 120)
        XCTAssertEqual(TVShortsPolicy.startPositionMs(
            video: normal, explicitPositionMs: nil, savedPositionMs: 50_000
        ), 50_000)
    }

    func testStreamEnrichesMissingShortsDurationAndFlag() throws {
        let raw = Data(#"""
        {"id":"dQw4w9WgXcQ", "title":"Example",
         "url":"https://www.youtube.com/watch?v=dQw4w9WgXcQ",
         "duration":null,"isLive":false,"isShortFormContent":true}
        """#.utf8)
        let item = try JSONDecoder().decode(VideoItem.self, from: raw)
        XCTAssertTrue(item.isShort)
        XCTAssertNil(item.duration)
        let stream = try JSONDecoder().decode(StreamInfo.self, from: Data(#"""
        {"duration":57, "isShortFormContent":true}
        """#.utf8))
        let combined = TVVideoMetadata.merged(item, stream: stream)
        XCTAssertTrue(combined.isShort)
        XCTAssertEqual(combined.duration, 57)
        XCTAssertEqual(TVShortsPolicy.knownDurationSeconds(
            video: item, stream: stream), 57)
    }

    func testNewHistoryRowsOmitShortsFlagButRetainShortURL() throws {
        // The current server's /history format has no isShortFormContent,
        // including entries created today; this is not a legacy migration.
        let row = try JSONDecoder().decode(TVHistoryDTO.self, from: Data(#"""
        {"id":"id","url":"https://www.youtube.com/shorts/dQw4w9WgXcQ",
         "title":"Short","thumbnail":"","channelName":"Author",
         "duration":0,"progress":58,"channelUrl":""}
        """#.utf8))
        XCTAssertTrue(row.video.isShort)
        XCTAssertEqual(TVShortsPolicy.startPositionMs(
            video: row.video, explicitPositionMs: nil,
            savedPositionMs: row.video.watchPositionMs), 0)
    }

    func testUnknownDurationDoesNotBecomeAnInventedNumber() {
        let video = item(
            url: "https://www.youtube.com/shorts/dQw4w9WgXcQ")
        XCTAssertNil(TVShortsPolicy.knownDurationSeconds(video: video, stream: nil))
    }
}
