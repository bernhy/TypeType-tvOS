import XCTest
@testable import TypeTypeTV

final class SabrWireContractTests: XCTestCase {
    func testYouTubeURLParsingAndHostSafety() {
        XCTAssertEqual(VideoAddress.youtubeID("https://www.youtube.com/watch?v=dQw4w9WgXcQ"),
                       "dQw4w9WgXcQ")
        XCTAssertEqual(VideoAddress.youtubeID("https://youtu.be/dQw4w9WgXcQ"), "dQw4w9WgXcQ")
        XCTAssertEqual(VideoAddress.youtubeID("https://www.youtube.com/shorts/dQw4w9WgXcQ"),
                       "dQw4w9WgXcQ")
        XCTAssertNil(VideoAddress.youtubeID("https://youtube.com.evil.invalid/watch?v=dQw4w9WgXcQ"))
        XCTAssertNil(VideoAddress.youtubeID("http://other.invalid/watch?v=123"))
    }

    func testBootstrapAndFormatSelectionPayload() throws {
        let bootstrap = """
        {
          "id":"dQw4w9WgXcQ",
          "videoOnlyStreams":[
            {"itag":137,"codec":"avc1.640028","mimeType":"video/mp4",
             "width":1920,"height":1080,"fps":30,"bitrate":3000000,"deliveryMethod":"sabr"},
            {"itag":248,"codec":"vp09.00.51.08","height":1080,"fps":30,"deliveryMethod":"sabr"}
          ],
          "audioStreams":[{"itag":140,"codec":"mp4a.40.2","mimeType":"audio/mp4",
            "isOriginal":true,"deliveryMethod":"sabr"}]
        }
        """
        let model = try JSONDecoder().decode(SabrBootstrap.self, from: Data(bootstrap.utf8))
        XCTAssertEqual(model.videoOnlyStreams?.first?.itag, 137)
        XCTAssertEqual(model.audioStreams?.first?.itag, 140)
        XCTAssertNil(HardwareCodec.fourCC("not-a-codec"))
        XCTAssertNotNil(HardwareCodec.fourCC("avc1.640028"))
        XCTAssertNotNil(HardwareCodec.fourCC("av01.0.08M.08"))
        // Software override is explicitly opt-in; test independent of simulator decoders.
        XCTAssertEqual(HardwareCodec.choose(from: model, maxHeight: 1080, allowSoftware: true)?.audio.itag, 140)
        XCTAssertNil(HardwareCodec.choose(from: model, maxHeight: 720, allowSoftware: true))
    }

    func testSessionAndWindowWireFormat() throws {
        let bootstrap = SabrBootstrap.Video(itag: 137, codec: "avc1", mimeType: "video/mp4",
                                            width: 1920, height: 1080, fps: 30, bitrate: 123,
                                            deliveryMethod: "sabr")
        let audio = SabrBootstrap.Audio(itag: 140, codec: "mp4a.40.2", mimeType: "audio/mp4",
                                         audioTrackId: nil, audioTrackName: nil, audioLocale: nil,
                                         isOriginal: true, deliveryMethod: "sabr")
        let choice = SabrSelection(video: bootstrap, audio: audio)
        let request = try JSONSerialization.jsonObject(with: JSONEncoder().encode(
            SabrSessionRequest(choice, positionMs: 42000)
        )) as? [String: Any]
        XCTAssertEqual(request?["videoItag"] as? Int, 137)
        XCTAssertEqual(request?["playerTimeMs"] as? Int, 42000)
        XCTAssertEqual(request?["audioOnly"] as? Bool, false)

        let window = try JSONDecoder().decode(SabrWindow.self, from: Data("""
        {"sessionId":"test","generation":4,"ready":true,"durationMs":50000,
          "audio":{"mime":"audio/mp4","initUrl":"sabr/playback/test/140/init?generation=4",
            "segments":[{"url":"sabr/playback/test/140/1?generation=4",
              "startMs":0,"durationMs":4000}]},
          "video":{"mime":"video/mp4","initUrl":"sabr/playback/test/137/init?generation=4",
            "segments":[{"url":"sabr/playback/test/137/1?generation=4",
              "startMs":0,"durationMs":4000}]}}
        """.utf8))
        XCTAssertTrue(window.ready)
        XCTAssertEqual(window.generation, 4)
        XCTAssertEqual(window.audio?.segments.first?.durationMs, 4000)
    }

    func testInvalidServerAddresses() {
        XCTAssertThrowsError(try TypeTypeAPI(address: "http://insecure.example"))
        XCTAssertThrowsError(try TypeTypeAPI(address: "https://user:password@example.org"))
        XCTAssertNoThrow(try TypeTypeAPI(address: "https://example.org"))
    }

    func testSabrURLValidationRejectsExternalMedia() async throws {
        let api = try TypeTypeAPI(address: "https://instance.example")
        let service = SabrService(api: api)
        do {
            _ = try await service.fragmentData("https://attacker.invalid/video.m4s",
                                               sessionId: "session", itag: 137, generation: 1)
            XCTFail("External media URL should never be requested")
        } catch SabrFailure.invalidResponse {
            // expected, before any network operation
        }
    }
    func testLargeBufferSettingsAndSabrPayload() throws {
        let defaults = SabrBufferSettings()
        XCTAssertEqual(defaults.forwardSeconds, 180)
        XCTAssertEqual(defaults.backSeconds, 120)
        XCTAssertEqual(defaults.cacheMiB, 512)
        XCTAssertEqual(defaults.forwardMilliseconds, 180_000)
        XCTAssertEqual(defaults.backMilliseconds, 120_000)

        let maxed = SabrBufferSettings(forwardSeconds: 999, backSeconds: 999,
                                       cacheMiB: 9999)
        XCTAssertEqual(maxed.forwardSeconds, 600)
        XCTAssertEqual(maxed.backSeconds, 300)
        XCTAssertEqual(maxed.cacheMiB, 1024)

        let live = SabrBufferSettings(forwardSeconds: 600, backSeconds: 300,
                                      cacheMiB: 512, live: true)
        XCTAssertEqual(live.forwardSeconds, 12)
        XCTAssertEqual(live.backSeconds, 15)

        let video = SabrBootstrap.Video(itag: 137, codec: "avc1", mimeType: "video/mp4",
                                        width: 1920, height: 1080, fps: 30, bitrate: 1000000,
                                        deliveryMethod: "sabr")
        let audio = SabrBootstrap.Audio(itag: 140, codec: "mp4a.40.2", mimeType: "audio/mp4",
                                        audioTrackId: nil, audioTrackName: nil, audioLocale: nil,
                                        isOriginal: true, deliveryMethod: "sabr")
        let request = SabrWindowRequest(
            SabrSelection(video: video, audio: audio), generation: 3,
            positionMs: 2_000, ranges: [], buffer: defaults
        )
        let json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(request))
            as? [String: Any]
        XCTAssertEqual(json?["bufferGoalMs"] as? Int, 180_000)
        XCTAssertEqual(json?["backBufferMs"] as? Int, 120_000)
        XCTAssertEqual(json?["generation"] as? Int, 3)
    }

    func testDiskCacheReusesSegmentAndClearsTemporaryFiles() async throws {
        let cache = SabrFragmentCache(maxMiB: 64)
        let original = Data([0, 1, 2, 3, 4, 5])
        let first = try await cache.data(for: "first-fragment") { original }
        let second = try await cache.data(for: "first-fragment") {
            Data([99, 98, 97])
        }
        XCTAssertEqual(first, original)
        XCTAssertEqual(second, original)
        let bytes = await cache.bytesInUse
        XCTAssertEqual(bytes, original.count)
        let items = await cache.itemCount
        XCTAssertEqual(items, 1)
        await cache.clear()
        let empty = await cache.bytesInUse
        XCTAssertEqual(empty, 0)
        do {
            _ = try await cache.data(for: "first-fragment") { original }
            XCTFail("closed SABR session cache must be invalid")
        } catch is CancellationError {
            // Expected; don't carry old session media into a new generation.
        }
    }

    func testSabrCoverageNeverSkipsLaggingAudioOrVideo() throws {
        var coverage = SabrPlaybackCoverage(audioItag: 140, videoItag: 137, positionMs: 0)
        XCTAssertEqual(coverage.safeEndMs, 0)
        try coverage.acceptVideo(SabrFragment(url: "v1", startMs: 0, durationMs: 8000))
        XCTAssertEqual(coverage.safeEndMs, 0, "Do not advance while audio is missing")
        try coverage.acceptAudio(SabrFragment(url: "a1", startMs: 0, durationMs: 4000))
        XCTAssertEqual(coverage.safeEndMs, 4000)
        try coverage.acceptAudio(SabrFragment(url: "a2", startMs: 4000, durationMs: 4000))
        XCTAssertEqual(coverage.safeEndMs, 8000)
        XCTAssertEqual(coverage.requestRanges.count, 2)
        XCTAssertEqual(coverage.requestRanges.first { $0.itag == 137 }?.endMs, 8000)
        XCTAssertThrowsError(try coverage.acceptVideo(
            SabrFragment(url: "gap", startMs: 15000, durationMs: 4000)
        ), "Do not announce non-contiguous media as buffered")
    }

    func testSabrCoverageAllowsOverlapAndSeekStart() throws {
        var coverage = SabrPlaybackCoverage(audioItag: 140, videoItag: 137, positionMs: 30000)
        try coverage.acceptAudio(SabrFragment(url: "a", startMs: 29000, durationMs: 5000))
        try coverage.acceptVideo(SabrFragment(url: "v", startMs: 29000, durationMs: 5000))
        XCTAssertEqual(coverage.safeEndMs, 34000)
        XCTAssertEqual(coverage.requestRanges.first?.startMs, 30000)
        try coverage.acceptVideo(SabrFragment(url: "vdup", startMs: 31000, durationMs: 3000))
        XCTAssertEqual(coverage.safeEndMs, 34000)
    }

    func testSabrRangeRetentionClampsOldBufferedHistory() throws {
        var progress = SabrPlaybackCoverage(audioItag: 140, videoItag: 137, positionMs: 10_000)
        try progress.acceptAudio(SabrFragment(url: "a", startMs: 10_000, durationMs: 20_000))
        try progress.acceptVideo(SabrFragment(url: "v", startMs: 10_000, durationMs: 20_000))
        let ranges = progress.requestRanges(retainFromMs: 18_000)
        XCTAssertEqual(ranges.count, 2)
        XCTAssertEqual(ranges.map(\.startMs), [18_000, 18_000])
        XCTAssertEqual(ranges.map(\.endMs), [30_000, 30_000])
        XCTAssertTrue(progress.requestRanges(retainFromMs: 31_000).isEmpty)
    }

    func testLibraryWireContractsForAllThreeSections() throws {
        let history = try JSONDecoder().decode([TVHistoryDTO].self, from: Data("""
        [{"id":"h1","url":"https://youtu.be/dQw4w9WgXcQ",
          "title":"Verlauf","thumbnail":"/image.jpg","channelName":"Kanal",
          "duration":3661,"progress":11,"watchedAt":900}]
        """.utf8))
        XCTAssertEqual(history.first?.video.url, "https://youtu.be/dQw4w9WgXcQ")
        XCTAssertEqual(history.first?.video.duration, 3661)

        let favorites = try JSONDecoder().decode([TVFavoriteDTO].self, from: Data("""
        [{"videoUrl":"https://www.youtube.com/watch?v=dQw4w9WgXcQ",
          "title":"Favorit","thumbnail":"/favorite.jpg","channelName":"Kanal",
          "duration":27,"favoritedAt":900}]
        """.utf8))
        XCTAssertEqual(favorites.first?.video.title, "Favorit")
        XCTAssertEqual(favorites.first?.video.url,
                       "https://www.youtube.com/watch?v=dQw4w9WgXcQ")

        let later = try JSONDecoder().decode([TVWatchLaterDTO].self, from: Data("""
        [{"url":"https://youtu.be/12345678901","title":"Später",
          "thumbnail":"/later.jpg","channelName":"Kanal","duration":240,"addedAt":900}]
        """.utf8))
        XCTAssertEqual(later.first?.video.url, "https://youtu.be/12345678901")
        XCTAssertEqual(TVLibrarySection.watchLater.rawValue, "watch-later")
    }

    func testHumanReadableDurations() {
        XCTAssertEqual(TTTheme.time(0), "0:00")
        XCTAssertEqual(TTTheme.time(65), "1:05")
        XCTAssertEqual(TTTheme.time(3661), "1:01:01")
        XCTAssertEqual(TTTheme.time(-15), "0:00")
    }

}
