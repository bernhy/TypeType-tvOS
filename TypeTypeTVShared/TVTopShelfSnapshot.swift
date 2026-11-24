import Foundation
import CryptoKit

/// Minimal, token-free metadata exchanged with the tvOS Top Shelf extension.
/// The extension never starts an API session or receives account credentials.
enum TVTopShelfSnapshotStore {
    static let maximumItems = 5
    static let scheme = "typetype-tv"
    private static let version = 1
    private static let snapshotName = "resume.json"

    struct Item: Codable, Hashable, Identifiable {
        var id: String { key }
        let key: String
        let videoID: String
        let title: String
        let videoURL: String
        let thumbnailURL: String?
        let imageName: String?
        let duration: Int
        let positionMs: Int64

        var playbackFraction: Double {
            guard duration > 0 else { return 0 }
            return min(1, max(0, Double(positionMs) / (Double(duration) * 1_000)))
        }
    }

    struct Snapshot: Codable, Equatable {
        let version: Int
        let origin: String
        // SHA-256 of the account-specific local scope; never store its token.
        let scopeFingerprint: String
        let items: [Item]
    }

    static func fingerprint(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8))
            .map { String(format: "%02x", $0) }.joined()
    }

    static func key(for videoURL: String) -> String { fingerprint(videoURL) }

    static func container() -> URL? {
        guard let group = Bundle.main.object(forInfoDictionaryKey: "TopShelfAppGroupID")
            as? String, group.hasPrefix("group.") else { return nil }
        return FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group)
    }

    static func imageURL(named name: String, in container: URL) -> URL? {
        let basename = name.dropLast(4)
        guard name.hasSuffix(".jpg"), basename.count == 64,
              basename.allSatisfy({ $0.isHexDigit }) else { return nil }
        return container.appendingPathComponent("images", isDirectory: true)
            .appendingPathComponent(name, isDirectory: false)
    }

    static func read(from container: URL) -> Snapshot? {
        let url = container.appendingPathComponent(snapshotName)
        guard let data = try? Data(contentsOf: url),
              data.count < 128_000,
              let snapshot = try? JSONDecoder().decode(Snapshot.self, from: data),
              snapshot.version == version,
              snapshot.items.count <= maximumItems else { return nil }
        return snapshot
    }

    static func write(_ snapshot: Snapshot, to container: URL) -> Bool {
        guard snapshot.version == version,
              snapshot.items.count <= maximumItems else { return false }
        let data: Data
        do {
            data = try JSONEncoder().encode(snapshot)
        } catch {
            logWriteError("JSON encoding", error: error)
            return false
        }
        do {
            try FileManager.default.createDirectory(at: container,
                                                    withIntermediateDirectories: true)
        } catch {
            // Apple's containerURL API can return a plausible URL even if the
            // app is *not* entitled to access that App Group. In that case
            // the directory cannot actually be created. No group IDs/paths
            // are written to logs.
            logWriteError("shared directory", error: error)
            return false
        }
        do {
            try data.write(to: container.appendingPathComponent(snapshotName),
                           options: .atomic)
            return true
        } catch {
            logWriteError("atomic snapshot", error: error)
            return false
        }
    }

    private static func logWriteError(_ stage: String, error: Error) {
        #if DEBUG
        let ns = error as NSError
        NSLog("TypeType TOPSHELF %@ failed domain=%@ code=%ld; verify that " +
              "TopShelfAppGroupID matches the signed App Groups entitlement",
              stage, ns.domain, ns.code)
        #endif
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
