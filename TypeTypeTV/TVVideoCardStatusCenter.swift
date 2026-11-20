import Foundation
import Combine

/// A single cheap observable token per canonical video/account, not four
/// global ObservableObject subscriptions for every visible thumbnail.
/// A membership/progress mutation invalidates exactly the affected video's
/// badge/position. First-time membership loading refreshes all *visible*
/// tokens once so existing badges can appear without per-card network work.
@MainActor
final class TVVideoCardStatusSignal: ObservableObject {
    @Published private(set) var revision = 0
    func notifyChanged() { revision &+= 1 }
}

@MainActor
enum TVVideoCardStatusCenter {
    private final class WeakToken {
        weak var value: TVVideoCardStatusSignal?
        init(_ value: TVVideoCardStatusSignal) { self.value = value }
    }

    private static var tokens: [String: [String: WeakToken]] = [:]

    static func signal(url: String, scope: String) -> TVVideoCardStatusSignal {
        let identity = TVPlaylistMembership.videoKey(url)
        if let existing = tokens[scope]?[identity]?.value { return existing }
        let result = TVVideoCardStatusSignal()
        tokens[scope, default: [:]][identity] = WeakToken(result)
        // Weak tokens cannot keep scrolled-off cells alive indefinitely.
        if tokens[scope, default: [:]].count > 1024 {
            tokens[scope] = tokens[scope]?.filter { $0.value.value != nil }
        }
        return result
    }

    static func changed(videoURL: String, scope: String? = nil) {
        let identity = TVPlaylistMembership.videoKey(videoURL)
        if let scope {
            tokens[scope]?[identity]?.value?.notifyChanged()
        } else {
            for rows in tokens.values {
                rows[identity]?.value?.notifyChanged()
            }
        }
    }

    static func changedAll(scope: String? = nil) {
        // Do not mutate the token dictionary while iterating its values.
        // Dead weak entries are pruned on future signal acquisition.
        for (account, rows) in tokens where scope == nil || account == scope {
            for weakToken in rows.values {
                weakToken.value?.notifyChanged()
            }
        }
    }
}
