import Foundation
import Combine

/// Account-scoped shared display preferences. A setting written by the TV or
/// by a different client is read on entry. Library history remains accessible.
/// Canonical ongoing-vs-post-live classification for cards, filtering,
/// playback routing and progress. The server's isLiveContent also covers
/// post-live recordings; isPostLive therefore always takes precedence.
/// Keep the original server setting key for compatibility.
enum TVLiveStreamDisplayPolicy {
    static func isOngoing(_ item: VideoItem) -> Bool {
        item.isPostLive != true &&
        (item.isLive == true || item.isLiveContent == true)
    }

    static func visible(_ items: [VideoItem], hideLiveStreams: Bool) -> [VideoItem] {
        guard hideLiveStreams else { return items }
        return items.filter { !isOngoing($0) }
    }
}

@MainActor
final class TVContentPreferences: ObservableObject {
    static let shared = TVContentPreferences()
    @Published private(set) var settings: TVServerSettings?
    private var scope = ""
    private var loaded = false
    private var fetch: Task<Void, Never>?

    private init() {}

    func ensureLoaded(api: TypeTypeAPI) async {
        let key = api.metadataCacheScope
        if scope != key {
            invalidate()
            scope = key
        }
        if loaded { return }
        if let fetch { await fetch.value; return }
        let task = Task { @MainActor in
            let result = try? await api.accountSettings()
            guard !Task.isCancelled, self.scope == key else { return }
            settings = result
            loaded = result != nil
        }
        fetch = task
        await task.value
        if scope == key { fetch = nil }
    }

    func apply(_ value: TVServerSettings, api: TypeTypeAPI) {
        guard scope.isEmpty || scope == api.metadataCacheScope else { return }
        scope = api.metadataCacheScope
        settings = value
        loaded = true
    }

    func invalidate() {
        fetch?.cancel()
        fetch = nil
        scope = ""
        loaded = false
        settings = nil
    }

    /// Library/public-playlist screens preserve Shorts and members-only
    /// items but respect the user's globally disabled live broadcasts.
    func withoutHiddenLivestreams(_ items: [VideoItem]) -> [VideoItem] {
        TVLiveStreamDisplayPolicy.visible(
            items, hideLiveStreams: settings?.hideSubscriptionLiveStreams == true
        )
    }

    /// The same filters now apply in Home, search, channels and subscriptions.
    func displayed(_ items: [VideoItem]) -> [VideoItem] {
        withoutHiddenLivestreams(items).filter { item in
            if settings?.hideShorts == true && item.isShort { return false }
            if settings?.hideMembersOnlyContent == true && item.requiresMembership == true {
                return false
            }
            return true
        }
    }
}
