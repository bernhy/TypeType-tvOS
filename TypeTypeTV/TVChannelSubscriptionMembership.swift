import Foundation

/// Compare channels using the same URL normalization rules as TypeType
/// Server's ChannelUrlCanonicalizer. Never infer membership from a channel
/// name: multiple channels can have identical display names.
enum TVChannelSubscriptionMembership {
    static func canonicalURL(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var parts = URLComponents(string: trimmed),
              let host = parts.host, !host.isEmpty else { return trimmed }
        parts.scheme = "https"
        parts.host = host.lowercased()
        if parts.port == 80 || parts.port == 443 { parts.port = nil }
        parts.query = nil
        parts.fragment = nil
        var path = parts.path
        while path.count > 1 && path.hasSuffix("/") { path.removeLast() }
        parts.path = path == "/" ? "" : path
        return parts.url?.absoluteString ?? trimmed
    }

    static func entry(for channelURL: String,
                      in subscriptions: [TVSubscription]) -> TVSubscription? {
        let key = canonicalURL(channelURL)
        return subscriptions.first { canonicalURL($0.channelUrl) == key }
    }

    static func adding(_ item: TVSubscription,
                       to subscriptions: [TVSubscription]) -> [TVSubscription] {
        let key = canonicalURL(item.channelUrl)
        return subscriptions.filter { canonicalURL($0.channelUrl) != key } + [item]
    }

    static func removing(channelURL: String,
                         from subscriptions: [TVSubscription]) -> [TVSubscription] {
        let key = canonicalURL(channelURL)
        return subscriptions.filter { canonicalURL($0.channelUrl) != key }
    }
}
