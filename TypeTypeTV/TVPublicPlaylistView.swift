import SwiftUI

/// Public YouTube playlist, not a user-owned /playlists collection.
struct TVPublicPlaylistView: View {
    let api: TypeTypeAPI
    let playlistURL: String
    let startingTitle: String
    @State private var videos: [VideoItem] = []
    @State private var title = ""
    @State private var nextPage: String?
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
                    Text(title.isEmpty ? startingTitle : title)
                        .font(.largeTitle.bold())
                    if !videos.isEmpty {
                        NavigationLink {
                            TVPlaylistPlaybackView(api: api, videos: videos)
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
                        ForEach(videos) { video in
                            NavigationLink {
                                VideoDetailView(
                                    api: api, video: video, playbackQueue: videos,
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
            .task(id: playlistURL) { await load() }
        }
    }

    @MainActor
    private func load() async {
        guard !loading else { return }
        loading = true
        error = nil
        defer { loading = false }
        do {
            let result = try await api.publicPlaylist(playlistURL)
            try Task.checkCancellation()
            title = result.playlist?.title ?? startingTitle
            videos = result.videos
            nextPage = result.nextpage
            videos = await api.withProgress(videos)
        } catch {
            self.error = error.localizedDescription
        }
    }

    @MainActor
    private func appendPage() async {
        guard !loadingMore, let cursor = nextPage else { return }
        loadingMore = true
        pageError = nil
        defer { loadingMore = false }
        do {
            let result = try await api.publicPlaylist(playlistURL, nextpage: cursor)
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
