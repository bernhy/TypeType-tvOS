import Foundation
import ImageIO

/// Server-first, token-free artwork selection for native tvOS Top Shelf.
///
/// The main app validates a small number of URLs on an already-active Home
/// publishing event. The extension itself never performs a network request,
/// and the resulting URL remains the only value passed to TVServices.
enum TVTopShelfPosterPolicy {
    struct Check: Sendable {
        let identity: String
        let candidates: [URL]
    }

    /// Public TypeType artwork, then canonical YouTube variants through the
    /// TypeType image proxy, and finally direct YouTube as a last resort.
    static func candidates(
        primary: URL?, videoURL: String, origin: URL,
        variants: [String] = ["hqdefault", "mqdefault"],
        highResolutionFirst: Bool = false
    ) -> [URL] {
        var urls: [URL] = []
        // Standard cards and Top Shelf prefer the server-provided artwork.
        // A fullscreen hero instead tries maxres first when the primary is
        // standard YouTube artwork; custom/DeArrow art retains its priority.
        if let primary, (!highResolutionFirst || !isYouTubeArtwork(primary)),
           let preferred = publicServerURL(primary, origin: origin) {
            urls.append(preferred)
        }
        if let id = VideoAddress.youtubeID(videoURL) {
            for variant in variants {
                guard let remote = URL(
                    string: "https://i.ytimg.com/vi/\(id)/\(variant).jpg"
                ) else { continue }
                if let proxied = proxyURL(for: remote, origin: origin) {
                    urls.append(proxied)
                }
            }
            for variant in variants {
                if let direct = URL(
                    string: "https://i.ytimg.com/vi/\(id)/\(variant).jpg"
                ) {
                    urls.append(direct)
                }
            }
        }
        var unique: [URL] = []
        for candidate in urls where !unique.contains(candidate) {
            unique.append(candidate)
        }
        return unique
    }

    static func identity(for videoURL: String, primary: URL?, origin: URL) -> String {
        TVTopShelfSnapshotStore.fingerprint(
            origin.absoluteString + "\n" + videoURL + "\n" +
                (primary?.absoluteString ?? "")
        )
    }

    /// A remote primary is only used through the server's allowlisted proxy.
    /// Local TypeType paths are restricted to explicitly public image routes.
    /// Never put access tokens, arbitrary server paths or private media URLs
    /// in the App Group preferences consumed by the independent extension.
    static func publicServerURL(_ primary: URL, origin: URL) -> URL? {
        guard origin.scheme == "https",
              primary.scheme == "https",
              primary.user == nil, primary.password == nil,
              primary.fragment == nil else { return nil }
        if primary.host?.lowercased() == origin.host?.lowercased(),
           primary.port == origin.port {
            let path = primary.path
            if path == "/dearrow/thumbnail" || path == "/api/dearrow/thumbnail" {
                let parts = URLComponents(url: primary, resolvingAgainstBaseURL: false)
                guard let items = parts?.queryItems,
                      items.count == 2,
                      Set(items.map(\.name)) == Set(["videoId", "time"]),
                      items.allSatisfy({ !$0.value.orEmpty.isEmpty }) else { return nil }
                // TypeType Server routes sit under /api on this client.
                return path == "/dearrow/thumbnail"
                    ? apiURL(path: "dearrow/thumbnail", origin: origin,
                             queryItems: items)
                    : primary
            }
            if path == "/proxy" || path == "/api/proxy" {
                let parts = URLComponents(url: primary, resolvingAgainstBaseURL: false)
                guard let items = parts?.queryItems, items.count == 1,
                      items[0].name == "url",
                      let raw = items[0].value, let remote = URL(string: raw),
                      isSupportedRemoteImage(remote) else { return nil }
                return proxyURL(for: remote, origin: origin)
            }
            return nil
        }
        return proxyURL(for: primary, origin: origin)
    }

    private static func proxyURL(for remote: URL, origin: URL) -> URL? {
        guard origin.scheme == "https", isSupportedRemoteImage(remote) else {
            return nil
        }
        return apiURL(
            path: "proxy", origin: origin,
            queryItems: [URLQueryItem(name: "url", value: remote.absoluteString)]
        )
    }

    private static func apiURL(path: String, origin: URL,
                               queryItems: [URLQueryItem]) -> URL? {
        guard var parts = URLComponents(
            url: origin, resolvingAgainstBaseURL: false
        ), parts.user == nil, parts.password == nil else { return nil }
        parts.path = "/api/" + path
        parts.queryItems = queryItems
        return parts.url
    }

    /// Treat a TypeType-proxied YouTube primary like a direct YouTube primary:
    /// fullscreen heroes may try higher-resolution variants before it.
    private static func isYouTubeArtwork(_ url: URL) -> Bool {
        let remote: URL
        if url.path == "/api/proxy" || url.path == "/proxy",
           let raw = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?.first(where: { $0.name == "url" })?.value,
           let wrapped = URL(string: raw) {
            remote = wrapped
        } else {
            remote = url
        }
        let host = remote.host?.lowercased() ?? ""
        return host == "ytimg.com" || host.hasSuffix(".ytimg.com") ||
            host == "img.youtube.com"
    }

    private static func isSupportedRemoteImage(_ url: URL) -> Bool {
        guard url.scheme == "https", url.user == nil, url.password == nil,
              url.fragment == nil, url.port == nil,
              let host = url.host?.lowercased() else { return false }
        // Some upstream media URLs include short-lived signed parameters.
        // Never persist apparent credentials in shared preferences.
        let sensitiveKeys: Set<String> = [
            "token", "access_token", "auth", "authorization", "jwt",
            "session", "password", "signature", "sig", "key"
        ]
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems ?? []
        guard !query.contains(where: {
            sensitiveKeys.contains($0.name.lowercased())
        }) else { return false }
        let suffixes = [
            "ytimg.com", "ggpht.com", "hdslb.com", "bilivideo.com",
            "bilivideo.cn", "nimg.jp", "nicovideo.jp"
        ]
        return suffixes.contains(where: { host == $0 || host.hasSuffix("." + $0) }) ||
            ["yt3.googleusercontent.com", "static-cdn.jtvnw.net"].contains(host)
    }

    /// The probe is sequential *per video*: only on a failed image does it
    /// touch the next candidate. Callers run at most five videos concurrently.
    static func firstReachable(
        candidates: [URL], probe: @escaping @Sendable (URL) async -> Bool
    ) async -> URL? {
        for url in candidates {
            guard !Task.isCancelled else { return nil }
            if await probe(url) { return url }
        }
        return nil
    }

    static func firstReachable(candidates: [URL], origin: URL) async -> URL? {
        await firstReachable(candidates: candidates) { url in
            await isReadableImage(url, origin: origin)
        }
    }

    /// GET rather than HEAD: some image endpoints reject HEAD or return a
    /// successful HTML/error placeholder. The actual bytes must be an image.
    /// Does not attach user credentials. First-party requests reuse TypeType's
    /// certificate verification/pinning.
    private static func isReadableImage(_ url: URL, origin: URL) async -> Bool {
        guard !Task.isCancelled else { return false }
        let firstParty = url.scheme == origin.scheme &&
            url.host?.lowercased() == origin.host?.lowercased() &&
            url.port == origin.port
        var request = URLRequest(url: url, timeoutInterval: 6)
        // This must be a truly anonymous probe, including when the shared
        // TypeType URLSession has handled authenticated API requests.
        request.httpShouldHandleCookies = false
        request.setValue("image/avif,image/webp,image/png,image/jpeg,*/*",
                         forHTTPHeaderField: "Accept")
        do {
            let session = firstParty
                ? TVNetwork.session(for: origin) : URLSession.shared
            let (data, response) = try await session.data(for: request)
            guard !Task.isCancelled,
                  let http = response as? HTTPURLResponse,
                  http.statusCode == 200,
                  let mime = http.mimeType?.lowercased(),
                  mime.hasPrefix("image/"),
                  data.count > 64, data.count <= 4 * 1_048_576,
                  let source = CGImageSourceCreateWithData(data as CFData, nil),
                  CGImageSourceGetCount(source) > 0,
                  let properties = CGImageSourceCopyPropertiesAtIndex(
                      source, 0, nil
                  ) as? [CFString: Any],
                  let width = properties[kCGImagePropertyPixelWidth] as? NSNumber,
                  let height = properties[kCGImagePropertyPixelHeight] as? NSNumber,
                  width.intValue >= 160, height.intValue >= 90
            else { return false }
            return true
        } catch {
            return false
        }
    }
}

private extension Optional where Wrapped == String {
    var orEmpty: String { self ?? "" }
}
