import Foundation
import CryptoKit

/// Token-free metadata shared with the independent tvOS Top Shelf extension.
/// One small encoded Data value replaces the whole snapshot atomically at the
/// API level. Images and credentials are never placed in UserDefaults.
enum TVTopShelfSnapshotStore {
    static let maximumItems = 5
    static let scheme = "typetype-tv"
    static let maximumBytes = 64 * 1024
    private static let version = 2
    private static let snapshotKey = "typetype.topShelf.resume.v2"

    struct Item: Codable, Hashable, Identifiable {
        var id: String { key }
        let key: String
        let videoID: String
        let title: String
        // The server supplies the uploader name with the history video;
        // no additional channel request is necessary.
        let channelName: String?
        let videoURL: String
        let thumbnailURL: String?
        let duration: Int
        let positionMs: Int64

        var playbackFraction: Double {
            guard duration > 0 else { return 0 }
            return min(1, max(0, Double(positionMs) / (Double(duration) * 1_000)))
        }

        /// A one-item TVTopShelfItemCollection can expose its channel in the
        /// native section heading, leaving the original video title intact.
        /// Missing channels keep the original section title.
        var sectionTitle: String {
            guard let channel = channelName?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !channel.isEmpty else { return "Ansehen fortsetzen" }
            return "Ansehen fortsetzen · " + channel
        }
    }

    struct Snapshot: Codable, Equatable {
        let version: Int
        let origin: String
        let scopeFingerprint: String
        let items: [Item]
    }

    static func fingerprint(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8))
            .map { String(format: "%02x", $0) }.joined()
    }

    static func key(for videoURL: String) -> String { fingerprint(videoURL) }

    static func sharedDefaults() -> UserDefaults? {
        guard let group = Bundle.main.object(forInfoDictionaryKey: "TopShelfAppGroupID")
            as? String, group.hasPrefix("group.") else { return nil }
        return UserDefaults(suiteName: group)
    }

    static func read(using supplied: UserDefaults? = nil) -> Snapshot? {
        guard let defaults = supplied ?? sharedDefaults(),
              let data = defaults.data(forKey: snapshotKey),
              data.count <= maximumBytes,
              let snapshot = try? JSONDecoder().decode(Snapshot.self, from: data),
              snapshot.version == version,
              snapshot.items.count <= maximumItems else { return nil }
        return snapshot
    }

    @discardableResult
    static func write(_ snapshot: Snapshot,
                      using supplied: UserDefaults? = nil) -> Bool {
        guard snapshot.version == version,
              snapshot.items.count <= maximumItems,
              let defaults = supplied ?? sharedDefaults(),
              let data = try? JSONEncoder().encode(snapshot),
              data.count <= maximumBytes else { return false }
        defaults.set(data, forKey: snapshotKey)
        // Same-process readback is a basic sanity check. Cross-process
        // UserDefaults(suiteName:) was verified on physical Apple TV hardware.
        return defaults.data(forKey: snapshotKey) == data
    }

    @discardableResult
    static func clear(using supplied: UserDefaults? = nil) -> Bool {
        guard let defaults = supplied ?? sharedDefaults(),
              defaults.object(forKey: snapshotKey) != nil else { return false }
        defaults.removeObject(forKey: snapshotKey)
        return true
    }

    static func make(origin: String, scopeFingerprint: String, items: [Item]) -> Snapshot {
        Snapshot(version: version, origin: origin,
                 scopeFingerprint: scopeFingerprint,
                 items: Array(items.prefix(maximumItems)))
    }

    static func actionURL(for key: String) -> URL? {
        guard key.count == 64, key.allSatisfy({ $0.isHexDigit }) else { return nil }
        var parts = URLComponents()
        parts.scheme = scheme
        parts.host = "resume"
        parts.queryItems = [URLQueryItem(name: "key", value: key)]
        return parts.url
    }

    static func item(for action: URL, in snapshot: Snapshot,
                     origin: String, scopeFingerprint: String) -> Item? {
        guard snapshot.origin == origin,
              snapshot.scopeFingerprint == scopeFingerprint,
              let url = URLComponents(url: action, resolvingAgainstBaseURL: false),
              url.scheme == scheme, url.host == "resume",
              url.user == nil, url.password == nil, url.port == nil,
              url.fragment == nil, url.path.isEmpty,
              let query = url.queryItems, query.count == 1,
              query[0].name == "key", let key = query[0].value,
              key.count == 64, key.allSatisfy({ $0.isHexDigit }) else {
            return nil
        }
        return snapshot.items.first(where: {
            $0.key == key && $0.key == Self.key(for: $0.videoURL)
        })
    }
}
