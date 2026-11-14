import Foundation
import XCTest
@testable import TypeTypeTV

private final class TVAPIWireProtocol: URLProtocol {
    static let lock = NSLock()
    static var resolvers: [String: (URLRequest) -> (Int, Data)] = [:]
    static var headers: [String: [String: String]] = [:]

    static func install(
        host: String, headers responseHeaders: [String: String] = [:],
        _ next: @escaping (URLRequest) -> (Int, Data)
    ) {
        lock.lock()
        resolvers[host] = next
        headers[host] = responseHeaders
        lock.unlock()
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    /// URLSession may turn an upload's httpBody into httpBodyStream before
    /// forwarding it to a custom URLProtocol on Apple's tvOS simulator.
    /// Preserve the bytes so contract tests can check the actual JSON body.
    private func requestWithMaterializedBody() -> URLRequest {
        var copy = request
        guard copy.httpBody == nil, let stream = copy.httpBodyStream else {
            return copy
        }
        stream.open()
        defer { stream.close() }
        var payload = Data()
        var chunk = [UInt8](repeating: 0, count: 8_192)
        while payload.count < 1_048_576 {
            let length = chunk.withUnsafeMutableBufferPointer {
                stream.read($0.baseAddress!, maxLength: $0.count)
            }
            if length <= 0 { break }
            payload.append(contentsOf: chunk.prefix(length))
        }
        copy.httpBody = payload
        return copy
    }

    override func startLoading() {
        Self.lock.lock()
        let callback = request.url?.host.flatMap { Self.resolvers[$0] }
        let extraHeaders = request.url?.host.flatMap { Self.headers[$0] } ?? [:]
        Self.lock.unlock()
        guard let url = request.url, let callback else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        let observedRequest = requestWithMaterializedBody()
        let (status, body) = callback(observedRequest)
        print("TVWIRE \(request.httpMethod ?? "?") \(url.path) status \(status) bytes \(body.count) requestBytes \(observedRequest.httpBody?.count ?? -1)")
        let response = HTTPURLResponse(
            url: url, statusCode: status, httpVersion: "HTTP/1.1",
            headerFields: [
                "Content-Type": "application/json",
                "Content-Length": String(body.count),
                "Cache-Control": "no-store"
            ].merging(extraHeaders) { _, new in new }
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }
}

final class TVAPIWireTests: XCTestCase {
    private func fixtureAPI(host: String) throws -> TypeTypeAPI {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [TVAPIWireProtocol.self]
        return try TypeTypeAPI(
            address: "https://\(host)", session: URLSession(configuration: config),
            token: "fixture-token"
        )
    }

    func testPasswordLoginUsesIdentifierWithoutGuestBearer() async throws {
        let lock = NSLock()
        var captured: (String, String, String?, Data?)?
        TVAPIWireProtocol.install(host: "password-login.example") { request in
            lock.withLock {
                captured = (request.httpMethod ?? "", request.url?.path ?? "",
                            request.value(forHTTPHeaderField: "Authorization"), request.httpBody)
            }
            return (200, Data(#"{"accessToken":"account-access-token"}"#.utf8))
        }
        let api = try fixtureAPI(host: "password-login.example")
        let token = try await api.passwordLogin(
            identifier: "  member@example.com  ", password: "sample-password"
        )
        XCTAssertEqual(token, "account-access-token")
        let recorded = lock.withLock { captured }
        XCTAssertEqual(recorded?.0, "POST")
        XCTAssertEqual(recorded?.1, "/api/auth/login")
        XCTAssertNil(recorded?.2, "Existing guest bearer must not accompany password login")
        let json = try JSONSerialization.jsonObject(
            with: try XCTUnwrap(recorded?.3)
        ) as? [String: String]
        XCTAssertEqual(json?["identifier"], "member@example.com")
        XCTAssertEqual(json?["password"], "sample-password")
    }

    func testWatchedTogglePersistsExactMillisecondsOnTypeTypeServer() async throws {
        let lock = NSLock()
        var writes: [(String, String?, Int64)] = []
        TVAPIWireProtocol.install(host: "watched-progress.example") { request in
            let json = (try? JSONSerialization.jsonObject(
                with: request.httpBody ?? Data()
            )) as? [String: Int64]
            lock.withLock {
                writes.append((
                    request.httpMethod ?? "",
                    request.url?.query,
                    json?["position"] ?? -1
                ))
            }
            return (200, Data(#"{"videoUrl":"unused","position":0}"#.utf8))
        }
        let video = VideoItem(id: "video-1", title: "Sample",
                              url: "https://www.youtube.com/watch?v=abc123def45",
                              thumbnailUrl: nil, uploaderName: nil,
                              duration: 87, isLive: false)
        let api = try fixtureAPI(host: "watched-progress.example")
        try await api.setWatched(true, video: video)
        try await api.setWatched(false, video: video)
        let recorded = lock.withLock { writes }
        XCTAssertEqual(recorded.count, 2)
        XCTAssertEqual(recorded.map { $0.0 }, ["PUT", "PUT"])
        XCTAssertEqual(recorded.map { $0.2 }, [87_000, 0])
        XCTAssertTrue(recorded.allSatisfy { $0.1?.contains("url=") == true })
    }

    func testSubscriptionsAndChannelPagesUseCanonicalServerRoutes() async throws {
        let lock = NSLock()
        var requests: [(String, String, String?)] = []
        let channelURL = "https://www.youtube.com/channel/UCE_M8A5yxnLfW0KghEeajjw"
        TVAPIWireProtocol.install(host: "channels-list.example") { request in
            let path = request.url?.path ?? ""
            let params = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?
                .queryItems ?? []
            let channel = params.first(where: { $0.name == "url" })?.value
            lock.withLock { requests.append((request.httpMethod ?? "", path, channel)) }
            if path == "/api/subscriptions" {
                return (200, Data(
                    #"[{"channelUrl":"https://www.youtube.com/channel/UCE_M8A5yxnLfW0KghEeajjw","name":"Apple","avatarUrl":"","subscribedAt":100}]"#.utf8
                ))
            }
            if path == "/api/channel" {
                return (200, Data(
                    #"{"name":"Apple","description":"Tech","avatarUrl":"","bannerUrl":"","videos":[{"id":"v1","url":"https://youtu.be/abc123def45","title":"News","viewCount":135000,"publishedAt":1800000000000,"requiresMembership":true}],"nextpage":"page2"}"#.utf8
                ))
            }
            return (404, Data())
        }
        let api = try fixtureAPI(host: "channels-list.example")
        let subscriptions = try await api.subscriptions()
        XCTAssertEqual(subscriptions.count, 1)
        XCTAssertEqual(subscriptions[0].channelUrl, channelURL)
        let channel = try await api.channel(channelURL)
        XCTAssertEqual(channel.name, "Apple")
        XCTAssertEqual(channel.videos.first?.requiresMembership, true)
        XCTAssertEqual(channel.nextpage, "page2")
        _ = try await api.channel(channelURL, nextpage: "page2")
        let recorded = lock.withLock { requests }
        XCTAssertEqual(recorded.map { $0.1 },
                       ["/api/subscriptions", "/api/channel", "/api/channel"])
        XCTAssertEqual(recorded[1].2, channelURL)
        XCTAssertEqual(recorded[2].2, channelURL)
    }

    func testRecommendationsForwardServerCursor() async throws {
        let lock = NSLock()
        var queries: [String] = []
        TVAPIWireProtocol.install(host: "recommendations-page.example") { request in
            lock.withLock { queries.append(request.url?.query ?? "") }
            return (200, Data(
                #"{"items":[{"id":"vid","title":"Video","url":"https://youtu.be/abc123def45"}],"nextCursor":"third-page","hasMore":true}"#.utf8
            ))
        }
        let api = try fixtureAPI(host: "recommendations-page.example")
        let page = try await api.home(cursor: "second-page", limit: 30)
        XCTAssertEqual(page.items.count, 1)
        XCTAssertEqual(page.nextCursor, "third-page")
        XCTAssertEqual(page.hasMore, true)
        let query = try XCTUnwrap(lock.withLock { queries.last })
        let parameters = URLComponents(string: "https://example.invalid/?" + query)?.queryItems ?? []
        XCTAssertEqual(parameters.first(where: { $0.name == "cursor" })?.value, "second-page")
        XCTAssertEqual(parameters.first(where: { $0.name == "limit" })?.value, "30")
    }

    func testPasswordLoginRejectsIncorrectCredentials() async throws {
        TVAPIWireProtocol.install(host: "password-reject.example") { _ in
            (401, Data(#"{"error":"Invalid credentials"}"#.utf8))
        }
        let api = try fixtureAPI(host: "password-reject.example")
        do {
            _ = try await api.passwordLogin(identifier: "member", password: "wrong")
            XCTFail("Unauthorized login should fail")
        } catch TypeTypeError.loginInvalidCredentials {
            // Expected.
        }
    }

    func testCurrentAccountDistinguishesGuestFromSignedInUser() async throws {
        let lock = NSLock()
        var captured: [(String, String?)] = []
        TVAPIWireProtocol.install(host: "guest-identity.example") { request in
            lock.lock()
            captured.append((request.url?.path ?? "",
                             request.value(forHTTPHeaderField: "Authorization")))
            lock.unlock()
            return (200, Data(#"{"id":"guest:opaque","role":"guest","publicUsername":null}"#.utf8))
        }
        TVAPIWireProtocol.install(host: "member-identity.example") { request in
            lock.lock()
            captured.append((request.url?.path ?? "",
                             request.value(forHTTPHeaderField: "Authorization")))
            lock.unlock()
            return (200, Data(#"{"id":"member-42","role":"user","publicUsername":"tester"}"#.utf8))
        }
        let guest = try await fixtureAPI(host: "guest-identity.example").currentAccount()
        XCTAssertEqual(guest?.isGuest, true)
        XCTAssertNil(guest?.visibleName)
        let member = try await fixtureAPI(host: "member-identity.example").currentAccount()
        XCTAssertEqual(member?.isGuest, false)
        XCTAssertEqual(member?.visibleName, "tester")
        lock.lock()
        let observed = captured
        lock.unlock()
        XCTAssertEqual(observed.count, 2)
        XCTAssertTrue(observed.allSatisfy {
            $0.0 == "/api/auth/me" && $0.1 == "Bearer fixture-token"
        })
    }

    func testCurrentAccountDoesNotTreatExpiredTokenAsGuest() async throws {
        TVAPIWireProtocol.install(host: "expired-identity.example") { _ in
            (401, Data(#"{"error":"Invalid token"}"#.utf8))
        }
        do {
            _ = try await fixtureAPI(host: "expired-identity.example").currentAccount()
            XCTFail("Expired account sessions must not be displayed as guests")
        } catch TypeTypeError.http(let status, let path) {
            XCTAssertEqual(status, 401)
            XCTAssertEqual(path, "auth/me")
        }
    }

    func testSettingsAndProgressUseRealServerMethods() async throws {
        let lock = NSLock()
        var records: [(String, String, String, String?, Data?)] = []
        TVAPIWireProtocol.install(host: "settings.example") { request in
            let url = request.url!
            lock.lock()
            records.append((
                request.httpMethod ?? "", url.path, url.absoluteString,
                request.value(forHTTPHeaderField: "Authorization"), request.httpBody
            ))
            lock.unlock()
            if url.path == "/api/settings" {
                return (200, Data(
                    #"{"disableWatchHistory":false,"subtitlesEnabled":true,"defaultQuality":"1080p"}"#.utf8
                ))
            }
            if request.httpMethod == "GET" {
                return (200, Data(#"{"videoUrl":"v","position":87654}"#.utf8))
            }
            return (200, Data("{}".utf8))
        }
        let api = try fixtureAPI(host: "settings.example")
        let loaded = try await api.accountSettings()
        XCTAssertEqual(loaded.defaultQuality, "1080p")
        XCTAssertEqual(loaded.subtitlesEnabled, true)
        _ = try await api.setAccountSetting("hideShorts", value: .boolean(true))
        let videoURL = "https://www.youtube.com/watch?v=abc123def45"
        let resumed = try await api.savedPosition(videoURL: videoURL)
        XCTAssertEqual(resumed, 87_654)
        try await api.savePosition(videoURL: videoURL, milliseconds: 90_500)
        let video = VideoItem(
            id: videoURL, title: "Video", url: videoURL,
            thumbnailUrl: nil, uploaderName: nil, duration: 300, isLive: false
        )
        try await api.addHistory(video: video, milliseconds: 90_500)
        lock.lock()
        let captured = records
        lock.unlock()
        XCTAssertEqual(captured.map { $0.0 }, ["GET","PUT","GET","PUT","POST"])
        XCTAssertTrue(captured.allSatisfy { $0.3 == "Bearer fixture-token" })
        XCTAssertEqual(captured[0].1, "/api/settings")
        XCTAssertEqual(captured[1].1, "/api/settings")
        XCTAssertTrue(captured[2].2.contains("%3Fv="))
        XCTAssertTrue(captured[3].2.contains("progress?url="))
        XCTAssertEqual(captured[4].1, "/api/history")
        let settingsBody = try JSONSerialization.jsonObject(
            with: captured[1].4 ?? Data()
        ) as? [String: Any]
        XCTAssertEqual(settingsBody?["hideShorts"] as? Bool, true)
        let progressBody = try JSONSerialization.jsonObject(
            with: captured[3].4 ?? Data()
        ) as? [String: Any]
        XCTAssertEqual(progressBody?["position"] as? Int, 90_500)
    }
    func testInstanceHomeAndSearchPathsUseApiDirectory() async throws {
        TVAPIWireProtocol.install(host: "browse.example") { request in
            guard request.httpMethod == "GET" else { return (405, Data()) }
            guard let url = request.url,
                  let parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
                return (400, Data())
            }
            switch url.path {
            case "/api/instance":
                return (200, Data(
                    #"{"name":"TypeType","version":"1","apiVersion":1}"#.utf8
                ))
            case "/api/recommendations/home":
                guard parts.queryItems?.contains(where: {
                    $0.name == "service" && $0.value == "0"
                }) == true else { return (400, Data()) }
                return (200, Data(#"{"items":[]}"#.utf8))
            case "/api/search":
                guard parts.queryItems?.contains(where: {
                    $0.name == "q" && $0.value == "test"
                }) == true else { return (400, Data()) }
                return (200, Data(#"{"items":[]}"#.utf8))
            default: return (404, Data())
            }
        }
        let api = try fixtureAPI(host: "browse.example")
        try await api.validate()
        let home = try await api.home()
        XCTAssertTrue(home.items.isEmpty)
        let results = try await api.search("test")
        XCTAssertTrue(results.items.isEmpty)
    }

    func testFavoritesAndWatchLaterUseAuthenticatedWrites() async throws {
        let lock = NSLock()
        var requests: [(String, String, String?)] = []
        TVAPIWireProtocol.install(host: "actions.example") { request in
            guard let url = request.url else { return (400, Data()) }
            lock.lock()
            requests.append((
                request.httpMethod ?? "",
                URLComponents(url: url, resolvingAgainstBaseURL: false)?
                    .percentEncodedPath ?? "",
                request.value(forHTTPHeaderField: "Authorization")
            ))
            lock.unlock()
            guard request.value(forHTTPHeaderField: "Authorization") == "Bearer fixture-token"
            else { return (401, Data()) }
            if request.httpMethod == "GET",
               url.path == "/api/watch-later" {
                return (200, Data("[]".utf8))
            }
            return (204, Data())
        }
        let api = try fixtureAPI(host: "actions.example")
        let url = "https://www.youtube.com/watch?v=abc123def45"
        let video = VideoItem(id: url, title: "Video", url: url,
            thumbnailUrl: nil, uploaderName: nil, duration: 120, isLive: false)
        try await api.setFavorite(videoURL: url, enabled: true)
        try await api.setFavorite(videoURL: url, enabled: false)
        try await api.setWatchLater(video: video, enabled: true)
        try await api.setWatchLater(video: video, enabled: false)
        lock.lock()
        let logged = requests
        lock.unlock()
        XCTAssertEqual(logged.map { $0.0 }, ["POST", "DELETE", "GET", "POST", "DELETE"])
        XCTAssertTrue(logged.allSatisfy { $0.2 == "Bearer fixture-token" })
        XCTAssertTrue(logged[0].1.hasPrefix("/api/favorites/"))
        XCTAssertTrue(logged[1].1.contains("%3Fv="))
        XCTAssertEqual(logged[2].1, "/api/watch-later")
        XCTAssertEqual(logged[3].1, "/api/watch-later")
        XCTAssertTrue(logged[4].1.hasPrefix("/api/watch-later/"))
    }

    func testWatchLaterDuplicateNeverRepostsAndDoesNotTriggerServer500() async throws {
        let lock = NSLock()
        var requests: [String] = []
        let videoURL = "https://www.youtube.com/watch?v=abc123def45"
        TVAPIWireProtocol.install(host: "existing-watch-later.example") { request in
            let action = "\(request.httpMethod ?? "") \(request.url?.path ?? "")"
            lock.withLock { requests.append(action) }
            if action == "GET /api/watch-later" {
                return (200, Data(
                    #" [{"url":"https://www.youtube.com/watch?v=abc123def45","title":"Already saved","thumbnail":"","channelName":"Owner","duration":300}] "#.utf8
                ))
            }
            // Mirror the real server's unique (user, URL) constraint.
            return (500, Data(#"{"error":"duplicate key"}"#.utf8))
        }
        let video = VideoItem(id: videoURL, title: "Already saved", url: videoURL,
                              thumbnailUrl: nil, uploaderName: "Owner",
                              duration: 300, isLive: false)
        let api = try fixtureAPI(host: "existing-watch-later.example")
        try await api.setWatchLater(video: video, enabled: true)
        XCTAssertEqual(lock.withLock { requests }, ["GET /api/watch-later"])
    }

    func testPlaylistsProgressBatchAndAccountBlocksUseExpectedRoutes() async throws {
        let lock = NSLock()
        var requests: [(String, String, Data?)] = []
        let videoURL = "https://www.youtube.com/watch?v=abc123def45"
        TVAPIWireProtocol.install(host: "collections.example") { request in
            let path = request.url?.path ?? ""
            lock.lock()
            requests.append((request.httpMethod ?? "", path, request.httpBody))
            lock.unlock()
            switch (request.httpMethod ?? "", path) {
            case ("GET", "/api/playlists"):
                return (200, Data(
                    #"[{"id":"one","name":"My list","videoCount":1}]"#.utf8
                ))
            case ("GET", "/api/playlists/one"):
                return (200, Data(
                    #"{"id":"one","name":"My list","videos":[]}"#.utf8
                ))
            case ("POST", "/api/progress/batch"):
                return (200, Data(
                    #"[{"videoUrl":"https://www.youtube.com/watch?v=abc123def45","position":68000}]"#.utf8
                ))
            case ("POST", "/api/playlists"):
                return (201, Data(
                    #"{"id":"new","name":"New list","videos":[]}"#.utf8
                ))
            default:
                return (201, Data("{}".utf8))
            }
        }
        let api = try fixtureAPI(host: "collections.example")
        let lists = try await api.playlists()
        XCTAssertEqual(lists.first?.id, "one")
        let opened = try await api.playlist("one")
        XCTAssertEqual(opened.name, "My list")
        let created = try await api.createPlaylist(name: "New list")
        XCTAssertEqual(created.id, "new")
        var video = VideoItem(
            id: videoURL, title: "Example", url: videoURL,
            thumbnailUrl: nil, uploaderName: "Channel",
            duration: 120, isLive: false
        )
        video.uploaderUrl = "https://www.youtube.com/@channel"
        try await api.addToPlaylist(lists[0].id, video: video)
        try await api.renamePlaylist("one", name: "Renamed", description: "Details")
        try await api.removeFromPlaylist("one", videoURL: video.url)
        try await api.deletePlaylist("one")
        try await api.blockVideo(video)
        try await api.blockChannel(video)
        let decorated = await api.withProgress([video])
        XCTAssertEqual(decorated.first?.watchPositionMs, 68_000)
        lock.lock()
        let items = requests
        lock.unlock()
        XCTAssertTrue(items.contains { $0.0 == "POST" && $0.1 == "/api/playlists/one/videos" })
        XCTAssertTrue(items.contains { $0.0 == "PUT" && $0.1 == "/api/playlists/one" })
        XCTAssertTrue(items.contains { $0.0 == "DELETE" && $0.1 == "/api/playlists/one" })
        XCTAssertTrue(items.contains { $0.0 == "DELETE" &&
            $0.1.hasPrefix("/api/playlists/one/videos/") })
        XCTAssertTrue(items.contains { $0.0 == "POST" && $0.1 == "/api/blocked/videos" })
        XCTAssertTrue(items.contains { $0.0 == "POST" && $0.1 == "/api/blocked/channels" })
        XCTAssertTrue(items.contains { $0.0 == "POST" && $0.1 == "/api/progress/batch" })
        let addPayload = items.first { $0.1 == "/api/playlists/one/videos" }?.2 ?? Data()
        let parsed = try JSONSerialization.jsonObject(with: addPayload) as? [String: Any]
        XCTAssertEqual(parsed?["channelUrl"] as? String, video.uploaderUrl)
        let renameBody = items.first { $0.0 == "PUT" && $0.1 == "/api/playlists/one" }?.2 ?? Data()
        let rename = try JSONSerialization.jsonObject(with: renameBody) as? [String: Any]
        XCTAssertEqual(rename?["name"] as? String, "Renamed")
        XCTAssertEqual(rename?["description"] as? String, "Details")
    }

    func testYoutubeLiveUsesNativeHLSRouteAndVODRemainsSabr() async throws {
        TVAPIWireProtocol.install(host: "livestream.example") { request in
            let path = request.url?.path ?? ""
            switch path {
            case "/api/streams/youtube/live":
                return (200, Data(
                    #"{"hlsUrl":"/media/live.m3u8","isLive":true}"#.utf8
                ))
            case "/api/streams/youtube/sabr":
                return (200, Data(
                    #"{"hlsUrl":"/media/vod.m3u8","isLive":false}"#.utf8
                ))
            default:
                return (404, Data())
            }
        }
        let api = try fixtureAPI(host: "livestream.example")
        let url = "https://www.youtube.com/watch?v=abc123def45"
        let live = VideoItem(
            id: url, title: "Live", url: url, thumbnailUrl: nil,
            uploaderName: nil, duration: nil, isLive: true
        )
        let vod = VideoItem(
            id: url, title: "VOD", url: url, thumbnailUrl: nil,
            uploaderName: nil, duration: 120, isLive: false
        )
        let response = try await api.stream(for: live)
        XCTAssertEqual(response.hlsUrl, "/media/live.m3u8")
        let vodResponse = try await api.stream(for: vod)
        XCTAssertEqual(vodResponse.hlsUrl, "/media/vod.m3u8")
    }

    @MainActor
    func testPlaybackPresenceStartProgressStopContract() async throws {
        let lock = NSLock()
        var calls: [(method: String, path: String, body: Data?,
                     auth: String?)] = []
        TVAPIWireProtocol.install(host: "presence.example") { request in
            lock.lock()
            calls.append((request.httpMethod ?? "",
                          request.url?.path ?? "", request.httpBody,
                          request.value(forHTTPHeaderField: "Authorization")))
            lock.unlock()
            return (204, Data())
        }
        let api = try fixtureAPI(host: "presence.example")
        let video = VideoItem(
            id: "presence", title: "Test playback",
            url: "https://www.youtube.com/watch?v=abc123def45",
            thumbnailUrl: "https://img.example/one.jpg",
            uploaderName: "Example", duration: 123, isLive: false
        )
        let identity = TVPlaybackPresenceIdentity(
            clientName: "TypeType tvOS", clientVersion: "test",
            deviceId: "stable-test-device", deviceName: "Apple TV",
            deviceType: "apple_tv"
        )
        let reporter = TVPlaybackPresenceReporter(identity: identity)
        let owner = UUID()
        reporter.start(owner: owner, api: api, video: video,
                       positionMs: 25_000, paused: false)
        reporter.progress(owner: owner, video: video,
                          positionMs: 41_700, paused: true)
        reporter.stop(owner: owner)
        reporter.stop(owner: owner)
        await reporter.flush()

        lock.lock()
        let captured = calls
        lock.unlock()
        XCTAssertEqual(captured.map { $0.method }, ["POST", "POST", "POST"])
        XCTAssertEqual(captured.map { $0.path }, [
            "/api/sessions/playback/start",
            "/api/sessions/playback/progress",
            "/api/sessions/playback/stop"
        ])
        XCTAssertTrue(captured.allSatisfy { $0.auth == "Bearer fixture-token" })
        let started = try XCTUnwrap(JSONSerialization.jsonObject(
            with: try XCTUnwrap(captured[0].body)
        ) as? [String: Any])
        XCTAssertEqual(started["videoUrl"] as? String, video.url)
        XCTAssertEqual(started["durationMs"] as? Int, 123_000)
        XCTAssertEqual(started["positionMs"] as? Int, 25_000)
        XCTAssertEqual(started["deviceType"] as? String, "apple_tv")
        let progress = try XCTUnwrap(JSONSerialization.jsonObject(
            with: try XCTUnwrap(captured[1].body)
        ) as? [String: Any])
        XCTAssertEqual(progress["positionMs"] as? Int, 41_700)
        XCTAssertEqual(progress["paused"] as? Bool, true)
        let stopped = try XCTUnwrap(JSONSerialization.jsonObject(
            with: try XCTUnwrap(captured[2].body)
        ) as? [String: Any])
        XCTAssertEqual(stopped["deviceId"] as? String, "stable-test-device")
        XCTAssertNil(stopped["videoUrl"])
    }

    @MainActor
    func testStalePlayerStopDoesNotClearNewPlayingSession() async throws {
        let lock = NSLock()
        var paths: [String] = []
        TVAPIWireProtocol.install(host: "switch.example") { request in
            lock.lock()
            paths.append(request.url?.path ?? "")
            lock.unlock()
            return (204, Data())
        }
        let api = try fixtureAPI(host: "switch.example")
        let identity = TVPlaybackPresenceIdentity(
            clientName: "TypeType tvOS", clientVersion: "test",
            deviceId: "other-device", deviceName: "Apple TV",
            deviceType: "apple_tv"
        )
        let reporter = TVPlaybackPresenceReporter(identity: identity)
        let old = UUID()
        let next = UUID()
        let first = VideoItem(
            id: "a", title: "A", url: "https://youtu.be/abc123def45",
            thumbnailUrl: nil, uploaderName: nil, duration: 60, isLive: false
        )
        let second = VideoItem(
            id: "b", title: "B", url: "https://youtu.be/12345678901",
            thumbnailUrl: nil, uploaderName: nil, duration: 80, isLive: false
        )
        reporter.start(owner: old, api: api, video: first,
                       positionMs: 0, paused: false)
        reporter.start(owner: next, api: api, video: second,
                       positionMs: 500, paused: false)
        reporter.stop(owner: old)
        reporter.progress(owner: old, video: first, positionMs: 800, paused: false)
        reporter.stop(owner: next)
        await reporter.flush()
        lock.lock()
        let captured = paths
        lock.unlock()
        XCTAssertEqual(captured, [
            "/api/sessions/playback/start",
            "/api/sessions/playback/start",
            "/api/sessions/playback/stop"
        ])
    }

    func testNonYoutubeUnplayableStreamReturnsDistinctError() async throws {
        TVAPIWireProtocol.install(host: "unplayable.example") { request in
            guard request.url?.path == "/api/streams/bilibili" else {
                return (404, Data())
            }
            return (422, Data(
                #"{"error":"No compatible stream is available for this video","code":"no_playable_streams"}"#.utf8
            ))
        }
        let api = try fixtureAPI(host: "unplayable.example")
        let video = VideoItem(
            id: "bili", title: "Video",
            url: "https://www.bilibili.com/video/BV1xx411c7mD",
            thumbnailUrl: nil, uploaderName: nil, duration: 120,
            isLive: false
        )
        do {
            _ = try await api.stream(for: video)
            XCTFail("Server-declared unavailable video must return a distinct error")
        } catch TypeTypeError.videoUnavailable {
            // Expected.
        }
    }

    func testYoutube404ContentUnavailableIsNotTreatedAsExpiredSession() async throws {
        TVAPIWireProtocol.install(host: "gone.example") { request in
            guard request.url?.path == "/api/streams/youtube/sabr" else {
                return (404, Data())
            }
            return (404, Data(
                #"{"error":"This content is not available","code":"content_unavailable"}"#.utf8
            ))
        }
        let api = try fixtureAPI(host: "gone.example")
        let url = "https://www.youtube.com/watch?v=abc123def45"
        let video = VideoItem(
            id: url, title: "Unavailable", url: url,
            thumbnailUrl: nil, uploaderName: nil, duration: 120, isLive: false
        )
        do {
            _ = try await api.stream(for: video)
            XCTFail("Structured permanent 404 must not become generic HTTP error")
        } catch TypeTypeError.videoUnavailable {
            // Expected.
        }
    }

    func testHLSBootstrapPreservesServerRetryAfterHeader() async throws {
        TVAPIWireProtocol.install(
            host: "busy.example",
            headers: ["Retry-After": "35"]
        ) { request in
            guard request.url?.path == "/api/streams/bilibili" else {
                return (404, Data())
            }
            return (503, Data(
                #"{"error":"Provider is rate limited","code":"provider_rate_limited"}"#.utf8
            ))
        }
        let api = try fixtureAPI(host: "busy.example")
        let video = VideoItem(
            id: "busy", title: "Sample",
            url: "https://www.bilibili.com/video/BV1xx411c7mD",
            thumbnailUrl: nil, uploaderName: nil,
            duration: 180, isLive: false
        )
        do {
            _ = try await api.stream(for: video)
            XCTFail("503 must preserve backoff instead of returning generic HTTP error")
        } catch TypeTypeError.retryAfter(let status, let route, let seconds) {
            XCTAssertEqual(status, 503)
            XCTAssertEqual(route, "streams/bilibili")
            XCTAssertEqual(seconds, 35)
        }
    }

}
