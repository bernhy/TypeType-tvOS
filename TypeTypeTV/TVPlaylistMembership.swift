import Foundation
import Combine

/// Process-local, account-scoped playlist membership for thumbnail badges.
/// GET /playlists only contains summaries, so each playlist's videos must be
/// read once with GET /playlists/{id}. Reuse this index for all visible cards.
/// Never persist one account's memberships in another account's device data.
@MainActor
final class TVPlaylistMembership: ObservableObject {
    static let shared = TVPlaylistMembership()

    @Published private(set) var playlistIDsByVideo: [String: Set<String>] = [:]
    @Published private(set) var playlists: [TVPlaylistDTO] = []
    // The server removes entries by their *stored* URL, not by YouTube ID.
    // Preserve that exact URL when the currently viewed video uses a different
    // but equivalent youtube.com / youtu.be representation.
    private var storedURLByVideoAndPlaylist: [String: [String: String]] = [:]
    @Published private(set) var loading = false
    @Published private(set) var error: String?

    private var loaded = false
    private var scope: String?
    private var loadTask: Task<Void, Never>?

    static func videoKey(_ url: String) -> String {
        if let id = VideoAddress.youtubeID(url) { return "yt:" + id }
        return "url:" + url
    }

    func count(for videoURL: String) -> Int {
        playlistIDsByVideo[Self.videoKey(videoURL)]?.count ?? 0
    }

    func contains(_ videoURL: String, in playlistID: String) -> Bool {
        playlistIDsByVideo[Self.videoKey(videoURL)]?.contains(playlistID) == true
    }

    func storedURL(_ videoURL: String, in playlistID: String) -> String {
        storedURLByVideoAndPlaylist[Self.videoKey(videoURL)]?[playlistID] ?? videoURL
    }

    /// One shared network request chain even when many thumbnails appear at
    /// once. A failed load remains retryable; never present empty membership
    /// as confirmed if any playlist detail could not be retrieved.
    func ensureLoaded(api: TypeTypeAPI) async {
        let account = api.metadataCacheScope
        if scope != account {
            loadTask?.cancel()
            loadTask = nil
            scope = account
            loaded = false
            playlists = []
            playlistIDsByVideo = [:]
            storedURLByVideoAndPlaylist = [:]
            error = nil
            loading = false
        }
        if loaded { return }
        if let loadTask {
            await loadTask.value
            return
        }
        loading = true
        let task = Task { @MainActor in
            do {
                let summaries = try await api.playlists()
                var result: [String: Set<String>] = [:]
                var storedURLs: [String: [String: String]] = [:]
                for playlist in summaries where playlist.count > 0 {
                    try Task.checkCancellation()
                    let detail = try await api.playlist(playlist.id)
                    for video in detail.items {
                        let key = Self.videoKey(video.url)
                        result[key, default: []].insert(playlist.id)
                        storedURLs[key, default: [:]][playlist.id] = video.url
                    }
                }
                try Task.checkCancellation()
                guard self.scope == account else { return }
                self.playlists = summaries
                self.playlistIDsByVideo = result
                self.storedURLByVideoAndPlaylist = storedURLs
                self.loaded = true
                self.error = nil
            } catch is CancellationError {
                return
            } catch {
                guard self.scope == account else { return }
                self.error = error.localizedDescription
                self.loaded = false
            }
            if self.scope == account {
                self.loading = false
            }
        }
        loadTask = task
        await task.value
        if scope == account { loadTask = nil }
    }

    func retry(api: TypeTypeAPI) async {
        loaded = false
        loadTask?.cancel()
        loadTask = nil
        await ensureLoaded(api: api)
    }

    func markAdded(videoURL: String, playlist: TVPlaylistDTO, api: TypeTypeAPI) {
        guard scope == api.metadataCacheScope else { return }
        playlistIDsByVideo[Self.videoKey(videoURL), default: []].insert(playlist.id)
        storedURLByVideoAndPlaylist[Self.videoKey(videoURL), default: [:]][playlist.id] =
            videoURL
        if !playlists.contains(where: { $0.id == playlist.id }) {
            playlists.append(playlist)
        }
    }

    func markRemoved(videoURL: String, playlistID: String, api: TypeTypeAPI) {
        guard scope == api.metadataCacheScope else { return }
        playlistIDsByVideo[Self.videoKey(videoURL)]?.remove(playlistID)
        storedURLByVideoAndPlaylist[Self.videoKey(videoURL)]?.removeValue(
            forKey: playlistID
        )
        if storedURLByVideoAndPlaylist[Self.videoKey(videoURL)]?.isEmpty == true {
            storedURLByVideoAndPlaylist.removeValue(forKey: Self.videoKey(videoURL))
        }
        if playlistIDsByVideo[Self.videoKey(videoURL)]?.isEmpty == true {
            playlistIDsByVideo.removeValue(forKey: Self.videoKey(videoURL))
        }
    }

    func invalidate(api: TypeTypeAPI) {
        guard scope == api.metadataCacheScope else { return }
        loaded = false
        loadTask?.cancel()
        loadTask = nil
    }
}
