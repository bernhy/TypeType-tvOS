import Foundation
import CryptoKit

/// The server (TypeType 1.17) returns a video URL but no persisted title.
/// Retain titles for videos blocked *on this device*; old/server-side blocks
/// fall back to a short ID. Store no bearer token or raw account scope.
enum TVBlockedNameCache {
    private static func storageKey(api: TypeTypeAPI) -> String {
        let digest = SHA256.hash(data: Data(api.metadataCacheScope.utf8))
            .map { String(format: "%02x", $0) }.joined()
        return "typetype.blockTitles." + digest
    }

    static func remember(title: String, url: String, api: TypeTypeAPI) {
        guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let key = storageKey(api: api)
        var names = UserDefaults.standard.dictionary(forKey: key) as? [String: String] ?? [:]
        names[url] = String(title.prefix(200))
        if names.count > 250 {
            names = Dictionary(uniqueKeysWithValues:
                Array(names.sorted { $0.key < $1.key }.prefix(250)))
        }
        UserDefaults.standard.set(names, forKey: key)
    }

    static func title(for url: String, api: TypeTypeAPI) -> String? {
        (UserDefaults.standard.dictionary(forKey: storageKey(api: api))
            as? [String: String])?[url]
    }

    static func remove(url: String, api: TypeTypeAPI) {
        let key = storageKey(api: api)
        var names = UserDefaults.standard.dictionary(forKey: key) as? [String: String] ?? [:]
        names.removeValue(forKey: url)
        UserDefaults.standard.set(names, forKey: key)
    }

    static func shortID(_ url: String, category: TVBlockedCategory) -> String {
        if category == .videos, let id = VideoAddress.youtubeID(url) {
            return id
        }
        if let parts = URLComponents(string: url) {
            if let item = parts.queryItems?.first(where: { $0.name == "v" })?.value {
                return item
            }
            if let last = parts.path.split(separator: "/").last, !last.isEmpty {
                return String(last)
            }
            if let host = parts.host { return host }
        }
        return url.count > 55 ? String(url.prefix(52)) + "…" : url
    }
}
