import Foundation
import Combine

/// One membership snapshot per active server account. Do not issue an
/// independent /watch-later GET for every thumbnail's context menu.
@MainActor
final class TVWatchLaterMembership: ObservableObject {
    static let shared = TVWatchLaterMembership()
    @Published private(set) var urls = Set<String>()
    private var scope = ""
    private var loaded = false
    private var fetch: Task<Void, Never>?
    private var lastFailure: Date?
    // The initial GET may still be in flight when an action saves/removes a
    // video. Never let that older snapshot overwrite a successful mutation.
    private var pendingMutations: [String: (url: String, present: Bool)] = [:]

    private init() {}

    private func scopeKey(for api: TypeTypeAPI) -> String {
        // The token never leaves process memory and is never logged. A
        // different household user must see their own Watch Later entries.
        api.origin.absoluteString + "|" +
            (TypeTypeCredentials.shared.token(for: api.origin) ?? "guest")
    }

    func contains(_ videoURL: String) -> Bool {
        urls.contains { TVVideoIdentity.equivalent($0, videoURL) }
    }

    func ensureLoaded(api: TypeTypeAPI) async {
        let key = scopeKey(for: api)
        if key != scope {
            fetch?.cancel()
            fetch = nil
            scope = key
            urls = []
            loaded = false
            lastFailure = nil
            pendingMutations.removeAll()
        }
        guard !loaded else { return }
        if let lastFailure, Date().timeIntervalSince(lastFailure) < 12 { return }
        if let fetch {
            await fetch.value
            return
        }
        let task = Task { @MainActor in
            do {
                let rows = try await api.library(.watchLater)
                guard !Task.isCancelled, key == scope else { return }
                var snapshot = Set(rows.map(\.url))
                for mutation in pendingMutations.values {
                    snapshot = Set(snapshot.filter {
                        !TVVideoIdentity.equivalent($0, mutation.url)
                    })
                    if mutation.present { snapshot.insert(mutation.url) }
                }
                urls = snapshot
                loaded = true
                lastFailure = nil
                pendingMutations.removeAll()
            } catch {
                if key == scope { lastFailure = Date() }
            }
        }
        fetch = task
        await task.value
        if key == scope {
            fetch = nil
            if loaded { pendingMutations.removeAll() }
        }
    }

    func mark(_ url: String, present: Bool, api: TypeTypeAPI) {
        guard scopeKey(for: api) == scope else { return }
        let identity = VideoAddress.youtubeID(url).map { "yt:" + $0 } ?? "url:" + url
        if !loaded || fetch != nil {
            pendingMutations[identity] = (url: url, present: present)
        }
        urls = Set(urls.filter { !TVVideoIdentity.equivalent($0, url) })
        if present { urls.insert(url) }
        // Do not claim an incomplete membership snapshot is fully loaded:
        // other saved videos must remain discoverable by the next GET.
    }

    func invalidate() {
        fetch?.cancel()
        fetch = nil
        scope = ""
        urls = []
        loaded = false
        lastFailure = nil
        pendingMutations.removeAll()
    }
}
