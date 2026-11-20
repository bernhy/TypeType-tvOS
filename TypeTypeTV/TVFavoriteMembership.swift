import Foundation
import Combine

/// Process-local favorites for thumbnail indicators, scoped to one server
/// account. Canonical video keys allow constant-time membership checks for
/// large thumbnail grids without repeated YouTube URL comparisons.
@MainActor
final class TVFavoriteMembership: ObservableObject {
    static let shared = TVFavoriteMembership()

    @Published private(set) var videoKeys = Set<String>()
    private var scope = ""
    private var loaded = false
    private var fetch: Task<Void, Never>?
    private var lastFailure: Date?
    // Changes during the initial GET must override its potentially older data.
    private var pendingMutations: [String: Bool] = [:]

    private init() {}

    static func videoKey(_ url: String) -> String {
        TVPlaylistMembership.videoKey(url)
    }

    func contains(_ videoURL: String) -> Bool {
        videoKeys.contains(Self.videoKey(videoURL))
    }

    func ensureLoaded(api: TypeTypeAPI) async {
        let key = api.metadataCacheScope
        if key != scope {
            invalidate()
            scope = key
        }
        guard !loaded else { return }
        if let lastFailure, Date().timeIntervalSince(lastFailure) < 12 { return }
        if let fetch {
            await fetch.value
            return
        }

        let task = Task { @MainActor in
            do {
                let items = try await api.library(.favorites)
                guard !Task.isCancelled, scope == key else { return }
                var snapshot = Set(items.map { Self.videoKey($0.url) })
                for (videoKey, present) in pendingMutations {
                    if present { snapshot.insert(videoKey) }
                    else { snapshot.remove(videoKey) }
                }
                videoKeys = snapshot
                loaded = true
                TVVideoCardStatusCenter.changedAll(scope: key)
                lastFailure = nil
                pendingMutations.removeAll()
            } catch is CancellationError {
                return
            } catch {
                if !Task.isCancelled && scope == key {
                    lastFailure = Date()
                }
            }
        }
        fetch = task
        await task.value
        if scope == key {
            fetch = nil
            if loaded { pendingMutations.removeAll() }
        }
    }

    func mark(_ url: String, present: Bool, api: TypeTypeAPI) {
        guard api.metadataCacheScope == scope else { return }
        let key = Self.videoKey(url)
        if !loaded || fetch != nil {
            pendingMutations[key] = present
        }
        if present { videoKeys.insert(key) }
        else { videoKeys.remove(key) }
        TVVideoCardStatusCenter.changed(videoURL: url, scope: scope)
    }

    func invalidate() {
        TVVideoCardStatusCenter.changedAll(scope: scope)
        fetch?.cancel()
        fetch = nil
        scope = ""
        videoKeys = []
        loaded = false
        lastFailure = nil
        pendingMutations.removeAll()
    }
}
