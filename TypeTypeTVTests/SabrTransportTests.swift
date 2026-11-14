import Foundation
import XCTest
@testable import TypeTypeTV

/// In-process SABR HTTP simulator. No public YouTube/TypeType endpoint, account
/// credentials or Apple TV is required for these transport contract tests.
private final class MockSabrProtocol: URLProtocol {
    static let lock = NSLock()
    static var handler: ((URLRequest) -> (Int, Data))?

    static func use(_ next: @escaping (URLRequest) -> (Int, Data)) {
        lock.lock()
        handler = next
        lock.unlock()
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.lock()
        let resolve = Self.handler
        Self.lock.unlock()
        guard let resolve, let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        let (status, bytes) = resolve(request)
        let response = HTTPURLResponse(
            url: url, statusCode: status, httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if !bytes.isEmpty { client?.urlProtocol(self, didLoad: bytes) }
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

final class SabrTransportTests: XCTestCase {
    private func fixtureService() throws -> SabrService {
        let api = try TypeTypeAPI(address: "https://mock.local")
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockSabrProtocol.self]
        let session = URLSession(configuration: configuration)
        return SabrService(api: api, session: session)
    }

    private func fixtureSelection() -> SabrSelection {
        SabrSelection(
            video: SabrBootstrap.Video(
                itag: 137, codec: "avc1", mimeType: "video/mp4",
                width: 1920, height: 1080, fps: 30, bitrate: 6_000_000,
                deliveryMethod: "sabr"
            ),
            audio: SabrBootstrap.Audio(
                itag: 140, codec: "mp4a.40.2", mimeType: "audio/mp4",
                audioTrackId: nil, audioTrackName: nil, audioLocale: nil,
                isOriginal: true, deliveryMethod: "sabr"
            )
        )
    }

    func testActualSabrPositionPrefetchSegmentsSequence() async throws {
        let lock = NSLock()
        var paths: [String] = []
        MockSabrProtocol.use { request in
            let path = request.url?.path ?? ""
            lock.lock()
            paths.append(path)
            lock.unlock()
            if path.hasSuffix("/segments") {
                return (200, Data("""
                {
                  "sessionId":"example","generation":7,"ready":true,
                  "durationMs":120000,"endOfStream":false,
                  "audio":{"initUrl":"sabr/playback/example/140/init?generation=7",
                           "segments":[{"url":"sabr/playback/example/140/segment/1?generation=7",
                                        "startMs":5000,"durationMs":4000}]},
                  "video":{"initUrl":"sabr/playback/example/137/init?generation=7",
                           "segments":[{"url":"sabr/playback/example/137/segment/1?generation=7",
                                        "startMs":5000,"durationMs":4000}]}
                }
                """.utf8))
            }
            if path.hasSuffix("/position") { return (204, Data()) }
            if path.hasSuffix("/prefetch") { return (202, Data()) }
            return (404, Data())
        }
        let service = try fixtureService()
        let received = try await service.window(
            sessionId: "example", selection: fixtureSelection(), generation: 7,
            positionMs: 5_000,
            ranges: [
                SabrBufferedRange(itag: 140, startMs: 5_000, endMs: 9_000),
                SabrBufferedRange(itag: 137, startMs: 5_000, endMs: 9_000)
            ],
            buffer: SabrBufferSettings()
        )
        XCTAssertTrue(received.ready)
        XCTAssertEqual(received.generation, 7)
        XCTAssertEqual(received.video?.segments.first?.startMs, 5_000)
        let requests = lock.withLock { paths }
        XCTAssertEqual(requests.count, 3)
        XCTAssertTrue(requests[0].hasSuffix("/position"))
        XCTAssertTrue(requests[1].hasSuffix("/prefetch"))
        XCTAssertTrue(requests[2].hasSuffix("/segments"))
    }

    func testWindowReissuesTargetedPrefetchWhenLaterTrackRemainsPending() async throws {
        // Server 1.17.1: /prefetch registers missing segment demands;
        // /segments only polls the cache. The next missing track can appear
        // after the first /prefetch completes its forward seek.
        let lock = NSLock()
        var paths: [String] = []
        var prefetched = 0
        MockSabrProtocol.use { request in
            let path = request.url?.path ?? ""
            lock.lock()
            paths.append(path)
            if path.hasSuffix("/prefetch") { prefetched += 1 }
            let count = prefetched
            lock.unlock()
            if path.hasSuffix("/position") { return (204, Data()) }
            if path.hasSuffix("/prefetch") { return (202, Data()) }
            if path.hasSuffix("/segments") {
                if count < 2 {
                    return (202, Data(
                        #"{"ready":false,"generation":4,"status":"repositioning","retryAfterMs":150}"#.utf8))
                }
                return (200, Data("""
                {
                  "sessionId":"example","generation":4,"ready":true,
                  "audio":{"initUrl":"sabr/playback/example/140/init?generation=4","segments":[]},
                  "video":{"initUrl":"sabr/playback/example/137/init?generation=4","segments":[]}
                }
                """.utf8))
            }
            return (404, Data())
        }
        let api = try TypeTypeAPI(address: "https://mock.local")
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockSabrProtocol.self]
        let service = SabrService(
            api: api, session: URLSession(configuration: configuration),
            prefetchInterval: 0.05
        )
        let received = try await service.window(
            sessionId: "example", selection: fixtureSelection(), generation: 4,
            positionMs: 58_907
        )
        XCTAssertTrue(received.ready)
        let actual = lock.withLock { paths }
        XCTAssertEqual(actual.count, 5)
        XCTAssertTrue(actual[0].hasSuffix("/position"))
        XCTAssertTrue(actual[1].hasSuffix("/prefetch"))
        XCTAssertTrue(actual[2].hasSuffix("/segments"))
        XCTAssertTrue(actual[3].hasSuffix("/prefetch"))
        XCTAssertTrue(actual[4].hasSuffix("/segments"))
    }

    func testPrefetchIntervalIsBoundedAndDoesNotFloodServer() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        XCTAssertTrue(SabrWindowPrefetchPolicy.shouldRefresh(last: nil, now: now))
        XCTAssertFalse(SabrWindowPrefetchPolicy.shouldRefresh(
            last: now, now: now.addingTimeInterval(4.99)))
        XCTAssertTrue(SabrWindowPrefetchPolicy.shouldRefresh(
            last: now, now: now.addingTimeInterval(5.01)))
        XCTAssertFalse(SabrWindowPrefetchPolicy.shouldRefresh(
            last: now, now: now.addingTimeInterval(0.04), interval: 0.01))
        // Foundation Date stores floating-point seconds; avoid asserting at
        // an exact 50-ms boundary that can round to 49.999... ms.
        XCTAssertTrue(SabrWindowPrefetchPolicy.shouldRefresh(
            last: now, now: now.addingTimeInterval(0.06), interval: 0.01))
    }

    func testProgressiveFragmentHeartbeatUsesPrefetchWithoutNewPositionOrSession() async throws {
        // A ready /segments window can still describe an as-yet-unreadable
        // media fragment. Its refresh must not reset the seek position, nor
        // create a new token or bypass /prefetch's targeted-demand behavior.
        let lock = NSLock()
        var requests: [(String, String)] = []
        MockSabrProtocol.use { request in
            lock.lock()
            requests.append((request.httpMethod ?? "", request.url?.path ?? ""))
            lock.unlock()
            return (202, Data(#"{"ready":false,"status":"repositioning"}"#.utf8))
        }
        let service = try fixtureService()
        try await service.refreshMediaPrefetch(
            sessionId: "example", selection: fixtureSelection(),
            generation: 7, positionMs: 58_907,
            buffer: SabrBufferSettings(), requestedBufferGoalMs: 20_000
        )
        let captured = lock.withLock { requests }
        XCTAssertEqual(captured.count, 1)
        XCTAssertEqual(captured.first?.0, "POST")
        XCTAssertEqual(captured.first?.1,
                       "/api/sabr/playback/example/prefetch")
    }

    func testPreloadedSegmentsReusedFromDiskAndBounded() async throws {
        let lock = NSLock()
        var calls = 0
        MockSabrProtocol.use { request in
            lock.lock()
            calls += 1
            lock.unlock()
            guard request.httpMethod == "GET",
                  request.url?.path.contains("/sabr/playback/example/") == true else {
                return (400, Data())
            }
            return (200, Data(repeating: 0xAB, count: 1_024))
        }
        let cache = SabrFragmentCache(maxMiB: 64)
        let service = try fixtureService()
        let url1 = "sabr/playback/example/140/segment/1?generation=7"
        let url2 = "sabr/playback/example/137/segment/1?generation=7"
        try await cache.preloadFully([
            SabrMediaReference(url: url1, itag: 140, startMs: 0, durationMs: 4_000),
            SabrMediaReference(url: url2, itag: 137, startMs: 0, durationMs: 4_000)
        ], service: service, sessionId: "example", generation: 7)
        let cached = try await cache.data(for: url1) {
            XCTFail("A previously prefetched fragment must not be requested again")
            return Data()
        }
        XCTAssertEqual(cached.count, 1024)
        let count = await cache.itemCount
        let used = await cache.bytesInUse
        XCTAssertEqual(count, 2)
        XCTAssertEqual(used, 2_048)
        let hits = lock.withLock { calls }
        XCTAssertEqual(hits, 2)
        await cache.clear()
    }

    func test202PreparingSegmentRetriesAndReturnsOnlyMedia() async throws {
        let lock = NSLock()
        var requests = 0
        let expected = Data([0, 0, 0, 8, 0x6d, 0x64, 0x61, 0x74])
        MockSabrProtocol.use { request in
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertEqual(request.url?.path,
                           "/api/sabr/playback/example/137/segment/1")
            lock.lock()
            requests += 1
            let index = requests
            lock.unlock()
            if index <= 2 {
                return (202, Data(#"{"status":"preparing","retryAfterMs":150}"#.utf8))
            }
            return (200, expected)
        }
        let result = try await fixtureService().fragmentData(
            "sabr/playback/example/137/segment/1?generation=7",
            sessionId: "example", itag: 137, generation: 7
        )
        XCTAssertEqual(result, expected, "202 JSON must never reach MP4 decoding")
        let hits = lock.withLock { requests }
        XCTAssertEqual(hits, 3)
    }

    func testDownloadFailureDoesNotPopulateCache() async throws {
        MockSabrProtocol.use { _ in (503, Data(#"{"error":"unavailable"}"#.utf8)) }
        let cache = SabrFragmentCache(maxMiB: 64)
        let service = try fixtureService()
        let url = "sabr/playback/example/137/segment/1?generation=7"
        do {
            try await cache.preloadFully([
                SabrMediaReference(url: url, itag: 137, startMs: 0, durationMs: 4_000)
            ], service: service, sessionId: "example", generation: 7)
            XCTFail("A failed download must not be advertised as cached")
        } catch SabrFailure.server(let code, _) {
            XCTAssertEqual(code, 503)
        }
        let count = await cache.itemCount
        XCTAssertEqual(count, 0)
        await cache.clear()
    }
    func testServer1171ReleaseImmediatelyFreesSabrSession() async throws {
        let lock = NSLock()
        var requests: [(String, String)] = []
        MockSabrProtocol.use { request in
            lock.lock()
            requests.append((request.httpMethod ?? "", request.url?.path ?? ""))
            lock.unlock()
            // The new server release endpoint is idempotent (HTTP 204).
            return (204, Data())
        }
        let service = try fixtureService()
        try await service.release(sessionId: "session-token")
        try await service.release(sessionId: "session-token")
        try await service.release(sessionId: "")
        let captured = lock.withLock { requests }
        XCTAssertEqual(captured.count, 2)
        XCTAssertTrue(captured.allSatisfy { $0.0 == "DELETE" })
        XCTAssertTrue(captured.allSatisfy {
            $0.1 == "/api/sabr/playback/session-token"
        })
    }

    func testUnplayableSabrBootstrapIsTerminalNotNetworkRetry() async throws {
        MockSabrProtocol.use { request in
            if request.url?.path == "/api/streams/youtube/sabr/bootstrap" {
                return (422, Data(
                    #"{"error":"No compatible stream is available for this video","code":"no_playable_streams"}"#.utf8
                ))
            }
            return (404, Data())
        }
        let service = try fixtureService()
        do {
            _ = try await service.bootstrap(
                videoURL: "https://www.youtube.com/watch?v=abc123def45"
            )
            XCTFail("Permanently unavailable video must not be retried")
        } catch SabrFailure.unavailable {
            // Expected: do not hammer the server for media it cannot serve.
        }
    }

    func testPermanent404ContentUnavailableDoesNotTriggerNewSabrSession() async throws {
        MockSabrProtocol.use { _ in
            (404, Data(
                #"{"error":"This content is not available","code":"content_unavailable"}"#.utf8
            ))
        }
        let service = try fixtureService()
        do {
            _ = try await service.bootstrap(
                videoURL: "https://www.youtube.com/watch?v=abc123def45"
            )
            XCTFail("Content-unavailable response must be terminal")
        } catch SabrFailure.unavailable {
            // Expected. Only structured 404 content_unavailable is terminal;
            // unstructured 404 is still eligible for session recovery.
        }
    }

}
