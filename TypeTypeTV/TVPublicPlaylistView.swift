import SwiftUI

/// Public YouTube playlist, not a user-owned /playlists collection.
struct TVPublicPlaylistView: View {
    let api: TypeTypeAPI
    let playlistURL: String
    let startingTitle: String
    var isPodcast = false
    @Environment(\.dismiss) private var dismiss
    @FocusState private var focusedBack: Bool
    @State private var videos: [VideoItem] = []
    @ObservedObject private var contentPreferences = TVContentPreferences.shared
    private var visibleVideos: [VideoItem] {
        contentPreferences.withoutHiddenLivestreams(videos)
    }
    @State private var title = ""
    @State private var nextPage: String?
    @State private var loadedPlaylistURL: String?
    @State private var loading = false
    @State private var loadingMore = false
    @State private var error: String?
    @State private var pageError: String?
    @FocusState private var focusedVideo: String?
    private let columns = Array(repeating: GridItem(.flexible(), spacing: 30), count: 4)

    var body: some View {
        ScrollViewReader { scroll in
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    HStack(spacing: 18) {
                        Button { dismiss() } label: {
                            Label("common.back", systemImage: "chevron.left")
                        }
                        .buttonStyle(.bordered)
                        .focused($focusedBack)
                        .accessibilityIdentifier("public-playlist-back")
                        Text(title.isEmpty ? startingTitle : title)
                            .font(.largeTitle.bold())
                    }
                    .focusSection()
                    if !visibleVideos.isEmpty {
                        NavigationLink {
                            TVPlaylistPlaybackView(api: api, videos: visibleVideos)
                        } label: {
                            Label("playlist.playAll", systemImage: "play.fill")
                        }
                        .buttonStyle(.borderedProminent)
                    }
                    if loading && videos.isEmpty {
                        ProgressView("settings.remoteLoading")
                    } else if let error {
                        Text(error).foregroundStyle(.orange)
                        Button("common.retry") { Task { await load() } }
                            .buttonStyle(.bordered)
                    }
                    LazyVGrid(columns: columns, spacing: 34) {
                        ForEach(visibleVideos) { video in
                            NavigationLink {
                                VideoDetailView(
                                    api: api, video: video, playbackQueue: visibleVideos,
                                    onReturnToList: {
                                        TVVideoFocusReturn.restore(
                                            $focusedVideo, id: video.url, scroll: scroll
                                        )
                                    }
                                )
                            } label: {
                                VideoCard(api: api, video: video)
                            }
                            .buttonStyle(TVRailButtonStyle())
                            .focusEffectDisabled(true)
                            .focused($focusedVideo, equals: video.url)
                            .zIndex(focusedVideo == video.url ? 5 : 0)
                            .videoActions(api: api, video: video,
                                          focus: $focusedVideo, focusID: video.url)
                        }
                    }
                    .focusSection()
                    if loadingMore {
                        ProgressView("search.loadingMore")
                    } else if nextPage != nil {
                        Button("search.loadMore") { Task { await appendPage() } }
                            .buttonStyle(.bordered)
                    }
                    if let pageError {
                        Text(pageError).foregroundStyle(.orange)
                    }
                }
                .padding(75)
            }
            .background(TTTheme.ink)
            .task { await contentPreferences.ensureLoaded(api: api) }
            .task(id: playlistURL) {
                // A pushed video detail returning to its playlist must not
                // re-fetch the grid and focus the Back button again.
                guard loadedPlaylistURL != playlistURL else { return }
                loadedPlaylistURL = playlistURL
                focusedBack = true
                await load()
            }
            .onExitCommand { dismiss() }
        }
    }

    @MainActor
    private func load() async {
        guard !loading else { return }
        loading = true
        error = nil
        defer { loading = false }
        do {
            let result = try await fetchPage()
            try Task.checkCancellation()
            title = result.playlist?.title ?? startingTitle
            videos = result.videos
            nextPage = result.nextpage
            videos = await api.withProgress(videos)
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func fetchPage(nextpage: String? = nil) async throws -> TVPublicPlaylistPage {
        if isPodcast {
            let response = try await api.podcastEpisodes(playlistURL, nextpage: nextpage)
            return TVPublicPlaylistPage(playlist: response.podcast, videos: response.episodes,
                                        nextpage: response.nextpage)
        }
        return try await api.publicPlaylist(playlistURL, nextpage: nextpage)
    }

    @MainActor
    private func appendPage() async {
        guard !loadingMore, let cursor = nextPage else { return }
        loadingMore = true
        pageError = nil
        defer { loadingMore = false }
        do {
            let result = try await fetchPage(nextpage: cursor)
            try Task.checkCancellation()
            let existing = Set(videos.map(\.url))
            let fresh = result.videos.filter { !existing.contains($0.url) }
            videos += fresh
            nextPage = result.nextpage == cursor ? nil : result.nextpage
            let enriched = await api.withProgress(fresh)
            let byURL = Dictionary(uniqueKeysWithValues: enriched.map { ($0.url, $0) })
            videos = videos.map { byURL[$0.url] ?? $0 }
        } catch {
            pageError = error.localizedDescription
        }
    }
}
