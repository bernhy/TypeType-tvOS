import Foundation

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
    case incompatibleServer(Int)
    case http(Int, String)
    case unexpectedResponse
    case unavailableFormat

    var errorDescription: String? {
        switch self {
        case .invalidServerAddress:
            return "Bitte eine gültige HTTPS-Adresse der TypeType-Instanz eingeben."
        case .incompatibleServer(let version):
            return "Nicht unterstützte TypeType API-Version: \(version) (erwartet: 1)."
        case .http(let status, let path):
            return "TypeType antwortete mit HTTP \(status) für \(path)."
        case .unexpectedResponse:
            return "Ungültige Antwort des TypeType-Servers."
        case .unavailableFormat:
            return "Kein kompatibles Wiedergabeformat für diesen Anbieter vorhanden."
        }
    }
}

/// The same /api/ v1 JSON contract used by TypeType-TV (Android).
/// No private Apple APIs, authentication token, or TLS bypass.
struct TypeTypeAPI {
    let origin: URL
    private let base: URL

    init(address: String) throws {
        let value = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let components = URLComponents(string: value),
              components.scheme?.lowercased() == "https",
              let host = components.host, !host.isEmpty,
              components.user == nil, components.password == nil,
              components.query == nil, components.fragment == nil,
              components.path.isEmpty || components.path == "/" || components.path == "/api" || components.path == "/api/"
        else { throw TypeTypeError.invalidServerAddress }
        var normalized = URLComponents()
        normalized.scheme = "https"
        normalized.host = host
        normalized.port = components.port
        normalized.path = "/"
        guard let originURL = normalized.url else { throw TypeTypeError.invalidServerAddress }
        origin = originURL
        normalized.path = "/api/"
        guard let apiURL = normalized.url else { throw TypeTypeError.invalidServerAddress }
        base = apiURL
    }

    func relativeMediaURL(_ value: String?) -> URL? {
        guard let value, !value.isEmpty else { return nil }
        if let full = URL(string: value), let scheme = full.scheme {
            return scheme == "https" ? full : nil
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

    func home() async throws -> HomeRecommendations {
        try await get("recommendations/home", query: [
            URLQueryItem(name: "service", value: "0"),
            URLQueryItem(name: "limit", value: "30")
        ])
    }

    func library(_ section: TVLibrarySection) async throws -> [VideoItem] {
        switch section {
        case .history:
            let rows: [TVHistoryDTO] = try await get("history")
            return rows.map(\.video)
        case .favorites:
            let rows: [TVFavoriteDTO] = try await get("favorites")
            return rows.map(\.video)
        case .watchLater:
            let rows: [TVWatchLaterDTO] = try await get("watch-later")
            return rows.map(\.video)
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
            endpoint = "streams/youtube/sabr"
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
        var parts = URLComponents(url: base, resolvingAgainstBaseURL: false)
        parts?.path = base.path + endpoint
        parts?.queryItems = query.isEmpty ? nil : query
        guard let url = parts?.url else { throw TypeTypeError.invalidServerAddress }
        var request = URLRequest(url: url)
        request.setValue("TypeTypeTV-tvOS/0.1", forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let bearer = TypeTypeCredentials.shared.token(for: origin) {
            request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization")
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw TypeTypeError.unexpectedResponse }
        guard (200..<300).contains(response.statusCode) else {
            throw TypeTypeError.http(response.statusCode, endpoint)
        }
        return try JSONDecoder().decode(T.self, from: data)
    }
}
