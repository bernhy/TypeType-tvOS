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
        let bounded = SabrWindowRequest(
            SabrSelection(video: video, audio: audio), generation: 3,
            positionMs: 2_000, ranges: [], buffer: defaults,
            requestedBufferGoalMs: 20_000
        )
        let boundedJSON = try JSONSerialization.jsonObject(
            with: JSONEncoder().encode(bounded)) as? [String: Any]
        XCTAssertEqual(boundedJSON?["bufferGoalMs"] as? Int, 20_000,
                       "Server must not request 180s when the local producer only buffers 20s")
        let excessive = SabrWindowRequest(
            SabrSelection(video: video, audio: audio), generation: 3,
            positionMs: 2_000, ranges: [], buffer: defaults,
            requestedBufferGoalMs: 300_000
        )
        XCTAssertEqual(excessive.bufferGoalMs, 180_000)
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

    func testConsecutiveSabrVideoSequenceCanContainBoundedTimestampJumps() throws {
        // Real hardware traces on itag 137 had 367 ms at ~24 s and
        // 3035 ms at ~47 s. Adjacent sequence numbers are not missing
        // fragments; metadata duration can disagree with the next PTS.
        var coverage = SabrPlaybackCoverage(
            audioItag: 140, videoItag: 137, positionMs: 0, stage: "test"
        )
        func fragment(_ seq: Int, _ start: Int64, _ duration: Int64) -> SabrFragment {
            SabrFragment(
                url: "https://example.org/api/sabr/playback/session/137/segment/\(seq)?generation=0",
                startMs: start, durationMs: duration
            )
        }
        try coverage.acceptVideo(fragment(11, 0, 24_391))
        try coverage.acceptVideo(fragment(12, 24_758, 3_404))
        try coverage.acceptVideo(fragment(13, 28_162, 19_120))
        try coverage.acceptVideo(fragment(14, 50_317, 6_774))
        XCTAssertEqual(coverage.videoEndMs, 57_091)
    }

    func testMissingSabrSequenceStillTriggersRecoveryEvenForShortGap() throws {
        var coverage = SabrPlaybackCoverage(audioItag: 140, videoItag: 137, positionMs: 0)
        try coverage.acceptVideo(SabrFragment(
            url: "https://example.org/137/segment/11?generation=0",
            startMs: 0, durationMs: 24_391
        ))
        XCTAssertThrowsError(try coverage.acceptVideo(SabrFragment(
            url: "https://example.org/137/segment/13?generation=0",
            startMs: 24_758, durationMs: 3_404
        )))
    }

    func testLargeTimestampHoleStillFailsEvenWithConsecutiveSequences() throws {
        var coverage = SabrPlaybackCoverage(audioItag: 140, videoItag: 137, positionMs: 0)
        try coverage.acceptVideo(SabrFragment(
            url: "https://example.org/137/segment/11?generation=0",
            startMs: 0, durationMs: 24_391
        ))
        XCTAssertThrowsError(try coverage.acceptVideo(SabrFragment(
            url: "https://example.org/137/segment/12?generation=0",
            startMs: 31_000, durationMs: 4_000
        )))
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

    func testRecentSearchHistoryIsUniqueBoundedAndLocal() {
        let seed = (1...11).map { "Frage \($0)" }
        let encoded = TVRecentQueries.encode(seed)
        XCTAssertEqual(TVRecentQueries.decode(encoded).count, 8)

        let newer = TVRecentQueries.add("  frage 3  ", to: TVRecentQueries.decode(encoded))
        XCTAssertEqual(newer.count, 8)
        XCTAssertEqual(newer.first, "frage 3")
        XCTAssertEqual(newer.filter { $0.localizedCaseInsensitiveCompare("frage 3") == .orderedSame }.count, 1)
        XCTAssertEqual(TVRecentQueries.decode("not-json"), [])
        XCTAssertEqual(TVRecentQueries.add(" ", to: newer), newer)
        XCTAssertEqual(TVRecentQueries.add(String(repeating: "X", count: 97), to: newer), newer)
    }

    func testExplicitLocalHTTPOriginPolicy() throws {
        let tests = ["192.168.0.129:8080", "10.46.104.2:8000",
                     "172.17.0.1", "home.local:8888", "svacsa09:8080",
                     "[fd00::1]:8080", "localhost:80"]
        for address in tests {
            let origin = try TVServerAddress.make(hostInput: address, mode: .http)
            XCTAssertEqual(origin.scheme, "http")
            XCTAssertNotNil(try? TypeTypeAPI(address: origin.absoluteString))
        }
        XCTAssertThrowsError(try TVServerAddress.make(
            hostInput: "example.com", mode: .http))
        XCTAssertThrowsError(try TVServerAddress.make(
            hostInput: "8.8.8.8", mode: .http))
        XCTAssertThrowsError(try TVServerAddress.make(
            hostInput: "host.example.com", mode: .http))
        XCTAssertThrowsError(try TVServerAddress.make(
            hostInput: "https://home.local", mode: .http))
    }

    func testHTTPSOriginAndHostOnlyInput() throws {
        let actual = try TVServerAddress.make(
            hostInput: "typetype.example.org:443", mode: .https)
        XCTAssertEqual(actual.scheme, "https")
        XCTAssertEqual(actual.host, "typetype.example.org")
        XCTAssertEqual(TVServerAddress.hostInput(from: actual.absoluteString),
                       "typetype.example.org:443")
        XCTAssertThrowsError(try TVServerAddress.make(
            hostInput: "someone:password@server.local", mode: .https))
        XCTAssertThrowsError(try TVServerAddress.make(
            hostInput: "somewhere.local?session=secret", mode: .https))
    }

    func testCertificateFingerprintDisplayAndLocalScope() {
        let report = TVCertificateReport(origin: URL(string: "https://nas.local:8443")!,
             fingerprint: "0123456789ABCDEF", subject: "nas.local",
             chain: ["nas.local", "Private CA"], problem: "Untrusted")
        XCTAssertEqual(report.formattedFingerprint, "01:23:45:67:89:AB:CD:EF")
        XCTAssertEqual(report.chain.count, 2)
        XCTAssertTrue(TVServerAddress.isLocalHost("192.168.1.1"))
        XCTAssertFalse(TVServerAddress.isLocalHost("1.1.1.1"))
    }
    func testCatalogSupportsMoreThanTwoLanguages() {
        XCTAssertEqual(TVL10n.value("nav.home", language: "de"), "Start")
        XCTAssertEqual(TVL10n.value("nav.home", language: "en"), "Home")
        XCTAssertEqual(TVL10n.value("nav.home", language: "fr"), "Accueil")
        XCTAssertEqual(TVL10n.value("nav.home", language: "es"), "Inicio")
        for code in ["de", "en", "fr", "es"] {
            XCTAssertTrue(TVLanguages.available.contains(code),
                          "Missing compiled language resource \(code)")
        }
        XCTAssertEqual(TVL10n.value("nav.home", language: "unknown"), "Start")
    }

    func testAccountSettingsWireFlagsAndServerPatch() throws {
        let data = Data(#"{"hideHomeRecommendations":true,"hideShorts":false,"disableWatchHistory":true,"autoplay":true}"#.utf8)
        var settings = try JSONDecoder().decode(TVServerSettings.self, from: data)
        XCTAssertFalse(settings.enabled(.recommendations))
        XCTAssertTrue(settings.enabled(.shorts))
        XCTAssertFalse(settings.enabled(.watchHistory))
        settings.setEnabled(.recommendations, true)
        XCTAssertTrue(settings.enabled(.recommendations))
        XCTAssertEqual(settings.hideHomeRecommendations, false)
        settings.setEnabled(.watchHistory, true)
        XCTAssertEqual(settings.disableWatchHistory, false)
        let request = try JSONEncoder().encode(["hideShorts": TVSettingValue.boolean(true)])
        let json = try JSONSerialization.jsonObject(with: request) as? [String: Any]
        XCTAssertEqual(json?["hideShorts"] as? Bool, true)
    }

    func testSettingsCategoryRailHasAndroidInspiredGroups() {
        let all = TVSettingsGroup.allCases
        XCTAssertEqual(all.first, .playback)
        XCTAssertTrue(all.contains(.content))
        XCTAssertTrue(all.contains(.device))
        XCTAssertTrue(all.contains(.language))
        XCTAssertTrue(all.contains(.instance))
        XCTAssertEqual(all.last, .about)
    }

    func testPackagedLanguagesAndRuntimeTranslations() {
        let expected: Set<String> = ["de", "en", "fr", "es"]
        XCTAssertTrue(expected.isSubset(of: Set(TVLanguages.available)))
        XCTAssertEqual(TVL10n.value("nav.search", language: "de"), "Suche")
        XCTAssertEqual(TVL10n.value("nav.search", language: "en"), "Search")
        XCTAssertEqual(TVL10n.value("nav.search", language: "fr"), "Recherche")
        XCTAssertEqual(TVL10n.value("nav.search", language: "es"), "Buscar")
        XCTAssertEqual(TVL10n.value("home.recommendations", language: "fr"), "Recommandations")
        XCTAssertEqual(TVL10n.value("home.recommendations", language: "es"), "Recomendaciones")
    }

    func testLookaheadPolicyRespectsBufferAndBitrate() {
        let defaultSettings = SabrBufferSettings()
        XCTAssertEqual(SabrLookaheadPolicy.targetMilliseconds(
            defaultSettings, videoBitrate: 6_000_000
        ), 20_000, "Client must respect the 24 MiB server-side throttle")
        XCTAssertEqual(SabrLookaheadPolicy.targetMilliseconds(
            defaultSettings, videoBitrate: nil
        ), 12_000, "Unknown bitrate must not fill the server cache blindly")
        let veryHighRate = SabrLookaheadPolicy.targetMilliseconds(
            defaultSettings, videoBitrate: 100_000_000
        )
        XCTAssertGreaterThanOrEqual(veryHighRate, 10_000)
        XCTAssertLessThan(veryHighRate, 180_000)
        XCTAssertLessThanOrEqual(SabrLookaheadPolicy.targetMilliseconds(
            SabrBufferSettings(forwardSeconds: 600, backSeconds: 300, cacheMiB: 1024),
            videoBitrate: 6_000_000
        ), 20_000, "More local disk must not raise the server's memory limit")
        XCTAssertTrue(SabrLookaheadPolicy.shouldRequestMore(
            cachedThroughMs: 42_000, playheadMs: 8_000, targetMs: 180_000
        ))
        XCTAssertFalse(SabrLookaheadPolicy.shouldRequestMore(
            cachedThroughMs: 198_000, playheadMs: 8_000, targetMs: 180_000
        ))
    }

    func testSabrMailboxIsOrderedAndDrainsBeforeFinishing() async throws {
        let mailbox = SabrWindowMailbox(capacity: 2)
        let first = try JSONDecoder().decode(SabrWindow.self, from: Data(
            #"{"ready":true,"generation":1,"durationMs":20000}"#.utf8
        ))
        let second = try JSONDecoder().decode(SabrWindow.self, from: Data(
            #"{"ready":true,"generation":2,"durationMs":30000}"#.utf8
        ))
        try await mailbox.offer(first)
        try await mailbox.offer(second)
        await mailbox.finish()
        let a = try await mailbox.next()
        let b = try await mailbox.next()
        let done = try await mailbox.next()
        XCTAssertEqual(a?.generation, 1)
        XCTAssertEqual(b?.generation, 2)
        XCTAssertNil(done)
    }

    func testSabrMailboxAppliesBackpressureWithoutDroppingWindows() async throws {
        let mailbox = SabrWindowMailbox(capacity: 1)
        let first = try JSONDecoder().decode(SabrWindow.self, from: Data(
            #"{"ready":true,"generation":3}"#.utf8
        ))
        let second = try JSONDecoder().decode(SabrWindow.self, from: Data(
            #"{"ready":true,"generation":4}"#.utf8
        ))
        try await mailbox.offer(first)
        let producer = Task { try await mailbox.offer(second) }
        try await Task.sleep(nanoseconds: 150_000_000)
        let pendingCount = await mailbox.queuedCount
        XCTAssertEqual(pendingCount, 1, "A full mailbox must not grow past capacity")
        let received = try await mailbox.next()
        XCTAssertEqual(received?.generation, 3)
        try await producer.value
        let remaining = try await mailbox.next()
        XCTAssertEqual(remaining?.generation, 4)
        await mailbox.finish()
    }

    func testSabrMailboxPropagatesFailureAfterBufferedWindows() async throws {
        let mailbox = SabrWindowMailbox()
        let item = try JSONDecoder().decode(SabrWindow.self, from: Data(
            #"{"ready":true,"generation":8}"#.utf8
        ))
        try await mailbox.offer(item)
        await mailbox.finish(error: SabrFailure.invalidResponse("network stopped"))
        let played = try await mailbox.next()
        XCTAssertEqual(played?.generation, 8)
        do {
            _ = try await mailbox.next()
            XCTFail("Expected failed producer to be reported")
        } catch SabrFailure.invalidResponse(let message) {
            XCTAssertEqual(message, "network stopped")
        }
    }

}
