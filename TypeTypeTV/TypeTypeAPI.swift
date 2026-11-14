import Foundation

private struct TVPasswordLoginRequest: Encodable {
    let identifier: String
    let password: String
}

private struct TVPasswordLoginResponse: Decodable {
    let accessToken: String
}

/// Server identity from GET /auth/me. A token alone is not evidence
/// of a signed-in account: guest tokens use the same Keychain slot.
struct TVAccountIdentity: Decodable {
    let id: String
    let role: String?
    let publicUsername: String?

    var isGuest: Bool { id.hasPrefix("guest:") }
    var visibleName: String? {
        guard let name = publicUsername?.trimmingCharacters(in: .whitespacesAndNewlines),
              !name.isEmpty else { return nil }
        return name
    }
}

struct InstanceInfo: Decodable {
    let name: String
    let version: String
    let apiVersion: Int
    let guestAllowed: Bool?
}

struct VideoItem: Decodable, Hashable, Identifiable {
    let id: String
    let title: String
    let url: String
    let thumbnailUrl: String?
    let uploaderName: String?
    let duration: Int?
    let isLive: Bool?
    var uploaderUrl: String? = nil
    var watchPositionMs: Int64? = nil
    var watched: Bool? = nil

    func withProgress(_ position: Int64) -> VideoItem {
        var result = self
        result.watchPositionMs = max(0, position)
        if let duration, duration > 0 {
            result.watched = position >= Int64(duration) * 900
        }
        return result
    }
}

struct HomeRecommendations: Decodable {
    let items: [VideoItem]
    let nextCursor: String?
    let hasMore: Bool?
}

struct SearchResults: Decodable {
    let items: [VideoItem]
}

struct StreamInfo: Decodable {
    let id: String?
    let title: String?
    let isLive: Bool?
    let hlsUrl: String?
}

enum TypeTypeError: LocalizedError {
    case invalidServerAddress
    case insecureHTTP
    case incompatibleServer(Int)
    case http(Int, String)
    case unexpectedResponse
    case unavailableFormat
    case videoUnavailable
    case retryAfter(Int, String, Int)
    case loginMissingFields
    case loginInvalidCredentials
    case loginDisabled

    var errorDescription: String? {
        switch self {
        case .invalidServerAddress:
            return TVL10n.value("error.serverAddress")
        case .insecureHTTP:
            return TVL10n.value("error.localHTTP")
        case .incompatibleServer(let version):
            return TVL10n.formatted("error.apiVersion", version)
        case .http(let status, let path):
            return TVL10n.formatted("error.http", status, path)
        case .unexpectedResponse:
            return TVL10n.value("error.invalidReply")
        case .unavailableFormat:
            return TVL10n.value("error.noFormat")
        case .videoUnavailable:
            return TVL10n.value("player.videoUnavailable")
        case .retryAfter(let status, let route, let seconds):
            return TVL10n.formatted("error.retryAfter", status, seconds, route)
        case .loginMissingFields:
            return TVL10n.value("login.missingFields")
        case .loginInvalidCredentials:
            return TVL10n.value("login.invalidCredentials")
        case .loginDisabled:
            return TVL10n.value("login.disabled")
        }
    }
}

/// Encode an external video URL as ONE path component, as the Android
/// LibraryWriteApi does. Slashes, queries and percent signs must not become
/// API route structure, especially when deleting favorites or Watch Later.
enum TVLibraryRoutes {
    static func mediaURL(base: URL, collection: String,
                         videoURL: String) throws -> URL {
        guard (collection == "favorites" || collection == "watch-later" ||
               collection == "progress" || collection == "videos"),
              !videoURL.isEmpty else { throw TypeTypeError.invalidServerAddress }
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "/?#%")
        guard let component = videoURL.addingPercentEncoding(withAllowedCharacters: allowed),
              var parts = URLComponents(
                url: base.appendingPathComponent(collection, isDirectory: true),
                resolvingAgainstBaseURL: false
              ) else { throw TypeTypeError.invalidServerAddress }
        parts.percentEncodedPath += component
        guard let url = parts.url else { throw TypeTypeError.invalidServerAddress }
        return url
    }
}

/// History is an event feed on some TypeType Server versions. A viewer
/// should see each video once, in most-recent-first order, even if it was
/// started repeatedly during testing. YouTube URL variants share one ID.
enum TVHistoryDeduplicator {
    static func unique(_ videos: [VideoItem]) -> [VideoItem] {
        var seen = Set<String>()
        return videos.filter { video in
            let key = VideoAddress.youtubeID(video.url).map { "yt:" + $0 }
                ?? (!video.url.isEmpty ? "url:" + video.url : "id:" + video.id)
            return seen.insert(key).inserted
        }
    }
}

struct TVWatchLaterWrite: Encodable {
    let url: String
    let title: String
    let thumbnail: String
    let duration: Int
    let channelName: String
    let channelUrl: String
    let channelAvatar: String

    init(video: VideoItem) {
        url = video.url
        title = video.title
        thumbnail = video.thumbnailUrl ?? ""
        duration = max(0, video.duration ?? 0)
        channelName = video.uploaderName ?? ""
        channelUrl = video.uploaderUrl ?? ""
        channelAvatar = ""
    }
}

/// The same /api/ v1 JSON contract used by TypeType-TV (Android).
/// No private Apple APIs, authentication token, or TLS bypass.
struct TypeTypeAPI {
    let origin: URL
    private let base: URL
    private let session: URLSession
    private let injectedToken: String?
    private var accountToken: String? {
        injectedToken ?? TypeTypeCredentials.shared.token(for: origin)
    }

    init(address: String, session injectedSession: URLSession? = nil, token injectedToken: String? = nil) throws {
        let text = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let scheme = URLComponents(string: text)?.scheme?.lowercased(),
              let mode = TVConnectionMode(rawValue: scheme) else {
            throw TypeTypeError.invalidServerAddress
        }
        origin = try TVServerAddress.make(hostInput: text, mode: mode)
        base = origin.appendingPathComponent("api", isDirectory: true)
        session = injectedSession ?? TVNetwork.session(for: origin)
        self.injectedToken = injectedToken
    }

    func relativeMediaURL(_ value: String?) -> URL? {
        guard let value, !value.isEmpty else { return nil }
        if let full = URL(string: value), let scheme = full.scheme {
            if scheme == "https" { return full }
            if scheme == "http", let host = full.host,
               TVServerAddress.isLocalHost(host) { return full }
            return nil
        }
        // TypeType generally emits absolute or origin-relative paths.
        return URL(string: value, relativeTo: origin)?.absoluteURL
    }

    func instance() async throws -> InstanceInfo {
        try await get("instance")
    }

    func validate() async throws {
        let info = try await instance()
        guard info.apiVersion == 1 else { throw TypeTypeError.incompatibleServer(info.apiVersion) }
    }

    /// TypeType's existing local account endpoint. Only the returned access
    /// token is persisted by the caller; the password is never saved.
    func passwordLogin(identifier: String, password: String) async throws -> String {
        let cleanIdentifier = identifier.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanIdentifier.isEmpty, !password.isEmpty else {
            throw TypeTypeError.loginMissingFields
        }
        var request = URLRequest(url: base.appendingPathComponent("auth/login"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("TypeTypeTV-tvOS/0.3", forHTTPHeaderField: "User-Agent")
        request.httpBody = try JSONEncoder().encode(
            TVPasswordLoginRequest(identifier: cleanIdentifier, password: password)
        )
        // No guest/account bearer token on this credential-based endpoint.
        let (data, result) = try await session.data(for: request)
        guard let response = result as? HTTPURLResponse else {
            throw TypeTypeError.unexpectedResponse
        }
        switch response.statusCode {
        case 200: break
        case 401: throw TypeTypeError.loginInvalidCredentials
        case 403: throw TypeTypeError.loginDisabled
        default: throw TypeTypeError.http(response.statusCode, "auth/login")
        }
        let reply = try JSONDecoder().decode(TVPasswordLoginResponse.self, from: data)
        guard !reply.accessToken.isEmpty else { throw TypeTypeError.unexpectedResponse }
        return reply.accessToken
    }

    /// Resolve the actual signed-in account, or distinguish a guest token.
    /// This lookup is repeated when opening Account so a previous app launch
    /// can restore the correct visible identity from the existing Keychain token.
    func currentAccount() async throws -> TVAccountIdentity? {
        guard let bearer = accountToken, !bearer.isEmpty else { return nil }
        var request = URLRequest(url: base.appendingPathComponent("auth/me"))
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("TypeTypeTV-tvOS/0.3", forHTTPHeaderField: "User-Agent")
        request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization")
        let (data, result) = try await session.data(for: request)
        guard let response = result as? HTTPURLResponse else {
            throw TypeTypeError.unexpectedResponse
        }
        guard response.statusCode == 200 else {
            throw TypeTypeError.http(response.statusCode, "auth/me")
        }
        return try JSONDecoder().decode(TVAccountIdentity.self, from: data)
    }

    func home() async throws -> HomeRecommendations {
        try await get("recommendations/home", query: [
            URLQueryItem(name: "service", value: "0"),
            URLQueryItem(name: "limit", value: "30")
        ])
    }

    /// These are account-level preferences shared with the Android and web clients.
    /// TypeType Server merges and validates the PUT payload with current settings.
    func accountSettings() async throws -> TVServerSettings {
        try await get("settings")
    }

    func setAccountSetting(_ field: String, value: TVSettingValue) async throws -> TVServerSettings {
        guard let url = URLComponents(url: base.appendingPathComponent("settings"), resolvingAgainstBaseURL: false)?.url else {
            throw TypeTypeError.invalidServerAddress
        }
        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("TypeTypeTV-tvOS/0.1", forHTTPHeaderField: "User-Agent")
        guard let token = accountToken, !token.isEmpty else {
            throw TypeTypeError.http(401, "settings")
        }
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONEncoder().encode([field: value])
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else {
            throw TypeTypeError.unexpectedResponse
        }
        guard (200..<300).contains(response.statusCode) else {
            throw TypeTypeError.http(response.statusCode, "settings")
        }
        return try JSONDecoder().decode(TVServerSettings.self, from: data)
    }

    /// Active playback presence from TypeType Server 1.17.1.
    /// Unlike saved /progress these calls are ephemeral now-playing signals.
    /// They are never required for decoding and tolerate older servers.
    func sessionPlaybackStart(_ payload: TVPlaybackPresenceVideo) async throws {
        try await writeLibrary(
            base.appendingPathComponent("sessions/playback/start"),
            method: "POST", body: try JSONEncoder().encode(payload)
        )
    }

    func sessionPlaybackProgress(_ payload: TVPlaybackPresenceVideo) async throws {
        try await writeLibrary(
            base.appendingPathComponent("sessions/playback/progress"),
            method: "POST", body: try JSONEncoder().encode(payload)
        )
    }

    func sessionPlaybackStop(_ identity: TVPlaybackPresenceIdentity) async throws {
        try await writeLibrary(
            base.appendingPathComponent("sessions/playback/stop"),
            method: "POST", body: try JSONEncoder().encode(identity)
        )
    }

    /// Progress is a separate account endpoint. Fetching it in batches avoids
    /// 30-60 independent network requests while browsing a thumbnail grid.
    func withProgress(_ videos: [VideoItem]) async -> [VideoItem] {
        let uniqueURLs = Array(Set(videos.map(\.url).filter { !$0.isEmpty }))
        guard !uniqueURLs.isEmpty, accountToken != nil else { return videos }
        var values: [String: Int64] = [:]
        for start in stride(from: 0, to: uniqueURLs.count, by: 100) {
            let group = Array(uniqueURLs[start..<min(start + 100, uniqueURLs.count)])
            do {
                let result: [TVProgressDTO] = try await postJSON(
                    "progress/batch", payload: TVProgressBatchWrite(videoUrls: group)
                )
                for item in result {
                    if let url = item.videoUrl { values[url] = max(0, item.position) }
                }
            } catch {
                // Progress is optional decoration. Do not hide videos when the
                // server/account cannot provide saved progress.
                return videos
            }
        }
        return videos.map { row in
            values[row.url].map { row.withProgress($0) } ?? row
        }
    }

    func playlists() async throws -> [TVPlaylistDTO] {
        try await get("playlists")
    }

    func playlist(_ id: String) async throws -> TVPlaylistDTO {
        try await get("playlists/\(id)")
    }

    func createPlaylist(name: String) async throws -> TVPlaylistDTO {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { throw TypeTypeError.unexpectedResponse }
        return try await postJSON("playlists", payload: TVCreatePlaylistWrite(name: clean))
    }

    private func validatedPlaylistID(_ id: String) throws -> String {
        guard !id.isEmpty,
              id.range(of: "^[a-zA-Z0-9_-]+$", options: .regularExpression) != nil
        else { throw TypeTypeError.invalidServerAddress }
        return id
    }

    func renamePlaylist(_ id: String, name: String,
                        description: String = "") async throws {
        let id = try validatedPlaylistID(id)
        let next = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !next.isEmpty else { throw TypeTypeError.invalidServerAddress }
        try await writeLibrary(
            base.appendingPathComponent("playlists/\(id)"),
            method: "PUT", body: try JSONEncoder().encode(
                TVUpdatePlaylistWrite(name: next, description: description)
            )
        )
    }

    func deletePlaylist(_ id: String) async throws {
        let id = try validatedPlaylistID(id)
        try await writeLibrary(base.appendingPathComponent("playlists/\(id)"),
                               method: "DELETE", body: nil)
    }

    func removeFromPlaylist(_ id: String, videoURL: String) async throws {
        let id = try validatedPlaylistID(id)
        let path = base.appendingPathComponent(
            "playlists/\(id)/videos", isDirectory: true
        )
        let url = try TVLibraryRoutes.mediaURL(
            base: path.deletingLastPathComponent(),
            collection: path.lastPathComponent, videoURL: videoURL
        )
        try await writeLibrary(url, method: "DELETE", body: nil)
    }

    func addToPlaylist(_ id: String, video: VideoItem) async throws {
        let id = try validatedPlaylistID(id)
        let payload = TVPlaylistVideoWrite(video: video)
        try await writeLibrary(base.appendingPathComponent("playlists/\(id)/videos"),
                               method: "POST", body: try JSONEncoder().encode(payload))
    }

    func blockVideo(_ video: VideoItem) async throws {
        try await writeLibrary(
            base.appendingPathComponent("blocked/videos"), method: "POST",
            body: try JSONEncoder().encode(TVBlockWrite(url: video.url, name: nil,
                                                        thumbnailUrl: nil))
        )
    }

    func blockChannel(_ video: VideoItem) async throws {
        guard let channel = video.uploaderUrl, !channel.isEmpty else {
            throw TypeTypeError.unavailableFormat
        }
        try await writeLibrary(
            base.appendingPathComponent("blocked/channels"), method: "POST",
            body: try JSONEncoder().encode(
                TVBlockWrite(url: channel, name: video.uploaderName,
                             thumbnailUrl: nil)
            )
        )
    }

    private func postJSON<Reply: Decodable, Payload: Encodable>(
        _ path: String, payload: Payload
    ) async throws -> Reply {
        var request = authorizedRequest(base.appendingPathComponent(path), method: "POST")
        guard accountToken != nil else { throw TypeTypeError.http(401, path) }
        request.httpBody = try JSONEncoder().encode(payload)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw TypeTypeError.unexpectedResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            throw TypeTypeError.http(http.statusCode, path)
        }
        return try JSONDecoder().decode(Reply.self, from: data)
    }

    func library(_ section: TVLibrarySection) async throws -> [VideoItem] {
        switch section {
        case .history:
            let rows: [TVHistoryDTO] = try await get("history")
            return TVHistoryDeduplicator.unique(rows.map(\.video))
        case .favorites:
            let rows: [TVFavoriteDTO] = try await get("favorites")
            return rows.map(\.video)
        case .watchLater:
            let rows: [TVWatchLaterDTO] = try await get("watch-later")
            return rows.map(\.video)
        }
    }

    /// Mutate the same server-side library as the Android TV app. No
    /// tvOS-local shadow favorites and no optimistic write without rollback.
    func setFavorite(videoURL: String, enabled: Bool) async throws {
        let url = try TVLibraryRoutes.mediaURL(
            base: base, collection: "favorites", videoURL: videoURL
        )
        try await writeLibrary(url, method: enabled ? "POST" : "DELETE", body: nil)
    }

    func setWatchLater(video: VideoItem, enabled: Bool) async throws {
        let url: URL
        let body: Data?
        if enabled {
            url = base.appendingPathComponent("watch-later")
            body = try JSONEncoder().encode(TVWatchLaterWrite(video: video))
        } else {
            url = try TVLibraryRoutes.mediaURL(
                base: base, collection: "watch-later", videoURL: video.url
            )
            body = nil
        }
        try await writeLibrary(url, method: enabled ? "POST" : "DELETE", body: body)
    }


    /// Android's library/progress API contract: GET progress/<encoded-video-url>,
    /// PUT progress?url=<video-url> with {"position": milliseconds}.
    /// HTTP 404 means no saved position. No token means no account progress.
    func savedPosition(videoURL: String) async throws -> Int64? {
        guard accountToken != nil else { return nil }
        let url = try TVLibraryRoutes.mediaURL(
            base: base, collection: "progress", videoURL: videoURL
        )
        var request = authorizedRequest(url, method: "GET")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw TypeTypeError.unexpectedResponse
        }
        if http.statusCode == 404 { return nil }
        guard (200..<300).contains(http.statusCode) else {
            throw TypeTypeError.http(http.statusCode, "progress")
        }
        return max(0, try JSONDecoder().decode(TVProgressDTO.self, from: data).position)
    }

    func savePosition(videoURL: String, milliseconds: Int64) async throws {
        guard accountToken != nil else { return }
        guard var parts = URLComponents(
            url: base.appendingPathComponent("progress"),
            resolvingAgainstBaseURL: false
        ) else { throw TypeTypeError.invalidServerAddress }
        parts.queryItems = [URLQueryItem(name: "url", value: videoURL)]
        guard let url = parts.url else { throw TypeTypeError.invalidServerAddress }
        let body = try JSONEncoder().encode(TVSaveProgressWrite(
            position: max(0, milliseconds)
        ))
        try await writeLibrary(url, method: "PUT", body: body)
    }

    func addHistory(video: VideoItem, milliseconds: Int64) async throws {
        guard accountToken != nil else { return }
        try await writeLibrary(
            base.appendingPathComponent("history"), method: "POST",
            body: try JSONEncoder().encode(
                TVHistoryWrite(video: video, positionMs: milliseconds)
            )
        )
    }

    private func authorizedRequest(_ url: URL, method: String) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("TypeTypeTV-tvOS/0.3", forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let token = accountToken {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        return request
    }

    private func writeLibrary(_ url: URL, method: String,
                              body: Data?) async throws {
        guard let token = accountToken, !token.isEmpty else {
            throw TypeTypeError.http(401, "library")
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("TypeTypeTV-tvOS/0.2", forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (_, result) = try await session.data(for: request)
        guard let response = result as? HTTPURLResponse else {
            throw TypeTypeError.unexpectedResponse
        }
        guard (200..<300).contains(response.statusCode) else {
            throw TypeTypeError.http(response.statusCode, "library")
        }
    }

    func search(_ term: String) async throws -> SearchResults {
        try await get("search", query: [
            URLQueryItem(name: "q", value: term),
            URLQueryItem(name: "service", value: "0")
        ])
    }

    func stream(for video: VideoItem) async throws -> StreamInfo {
        let endpoint: String
        if video.url.contains("youtube.com") || video.url.contains("youtu.be") {
            endpoint = video.isLive == true ?
                "streams/youtube/live" : "streams/youtube/sabr"
        } else if video.url.contains("bilibili.com") || video.url.contains("b23.tv") {
            endpoint = "streams/bilibili"
        } else if video.url.contains("nicovideo.jp") || video.url.contains("nico.ms") {
            endpoint = "streams/niconico"
        } else {
            throw TypeTypeError.unavailableFormat
        }
        return try await get(endpoint, query: [URLQueryItem(name: "url", value: video.url)])
    }

    private func get<T: Decodable>(_ endpoint: String, query: [URLQueryItem] = []) async throws -> T {
        var parts = URLComponents(url: base.appendingPathComponent(endpoint), resolvingAgainstBaseURL: false)
        parts?.queryItems = query.isEmpty ? nil : query
        guard let url = parts?.url else { throw TypeTypeError.invalidServerAddress }
        var request = URLRequest(url: url)
        request.setValue("TypeTypeTV-tvOS/0.1", forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let bearer = accountToken {
            request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization")
        }
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw TypeTypeError.unexpectedResponse }
        guard (200..<300).contains(response.statusCode) else {
            if [404, 410, 422].contains(response.statusCode),
               let issue = try? JSONDecoder().decode(TVStreamProblem.self, from: data),
               issue.isPermanentlyUnavailable {
                throw TypeTypeError.videoUnavailable
            }
            if [429, 503, 504].contains(response.statusCode),
               let seconds = SabrRetryAfter.seconds(
                   response.value(forHTTPHeaderField: "Retry-After")
               ) {
                throw TypeTypeError.retryAfter(response.statusCode, endpoint, seconds)
            }
            throw TypeTypeError.http(response.statusCode, endpoint)
        }
        return try JSONDecoder().decode(T.self, from: data)
    }
}
