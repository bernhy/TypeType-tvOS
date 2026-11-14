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

    private init() {}

    private func scopeKey(for api: TypeTypeAPI) -> String {
        // The token never leaves process memory and is never logged. A
        // different household user must see their own Watch Later entries.
        api.origin.absoluteString + "|" +
            (TypeTypeCredentials.shared.token(for: api.origin) ?? "guest")
    }

    func contains(_ videoURL: String) -> Bool {
        if urls.contains(videoURL) { return true }
        guard let id = VideoAddress.youtubeID(videoURL) else { return false }
        return urls.contains { VideoAddress.youtubeID($0) == id }
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
                urls = Set(rows.map(\.url))
                loaded = true
                lastFailure = nil
            } catch {
                if key == scope { lastFailure = Date() }
            }
        }
        fetch = task
        await task.value
        if key == scope { fetch = nil }
    }

    func mark(_ url: String, present: Bool, api: TypeTypeAPI) {
        guard scopeKey(for: api) == scope else { return }
        if present {
            urls.insert(url)
        } else {
            urls.remove(url)
            if let id = VideoAddress.youtubeID(url) {
                urls = Set(urls.filter { VideoAddress.youtubeID($0) != id })
            }
        }
        loaded = true
    }

    func invalidate() {
        fetch?.cancel()
        fetch = nil
        scope = ""
        urls = []
        loaded = false
        lastFailure = nil
    }
}
