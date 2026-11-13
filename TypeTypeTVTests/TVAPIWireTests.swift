import Foundation
import XCTest
@testable import TypeTypeTV

private final class TVAPIWireProtocol: URLProtocol {
    static let lock = NSLock()
    static var resolver: ((URLRequest) -> (Int, Data))?

    static func install(_ next: @escaping (URLRequest) -> (Int, Data)) {
        lock.lock()
        resolver = next
        lock.unlock()
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        Self.lock.lock()
        let callback = Self.resolver
        Self.lock.unlock()
        guard let url = request.url, let callback else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        let (status, body) = callback(request)
        let response = HTTPURLResponse(
            url: url, statusCode: status, httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }
}

final class TVAPIWireTests: XCTestCase {
    private func fixtureAPI() throws -> TypeTypeAPI {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [TVAPIWireProtocol.self]
        return try TypeTypeAPI(
            address: "https://tv.example", session: URLSession(configuration: config),
            token: "fixture-token"
        )
    }

    func testSettingsAndProgressUseRealServerMethods() async throws {
        let lock = NSLock()
        var records: [(String, String, String, String?, Data?)] = []
        TVAPIWireProtocol.install { request in
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
        let api = try fixtureAPI()
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
        TVAPIWireProtocol.install { request in
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
        let api = try fixtureAPI()
        try await api.validate()
        let home = try await api.home()
        XCTAssertTrue(home.items.isEmpty)
        let results = try await api.search("test")
        XCTAssertTrue(results.items.isEmpty)
    }

    func testFavoritesAndWatchLaterUseAuthenticatedWrites() async throws {
        let lock = NSLock()
        var requests: [(String, String, String?)] = []
        TVAPIWireProtocol.install { request in
            guard let url = request.url else { return (400, Data()) }
            lock.lock()
            requests.append((
                request.httpMethod ?? "",
                URLComponents(url: url, resolvingAgainstBaseURL: false)?
                    .percentEncodedPath ?? "",
                request.value(forHTTPHeaderField: "Authorization")
            ))
            lock.unlock()
            return request.value(forHTTPHeaderField: "Authorization") == "Bearer fixture-token"
                ? (204, Data()) : (401, Data())
        }
        let api = try fixtureAPI()
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
        XCTAssertEqual(logged.map { $0.0 }, ["POST", "DELETE", "POST", "DELETE"])
        XCTAssertTrue(logged.allSatisfy { $0.2 == "Bearer fixture-token" })
        XCTAssertTrue(logged[0].1.hasPrefix("/api/favorites/"))
        XCTAssertTrue(logged[1].1.contains("%3Fv="))
        XCTAssertEqual(logged[2].1, "/api/watch-later")
        XCTAssertTrue(logged[3].1.hasPrefix("/api/watch-later/"))
    }

}
