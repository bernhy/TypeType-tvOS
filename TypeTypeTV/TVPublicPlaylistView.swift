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
    @State private var detailReturnVideoID: String?
    @State private var mutationCursor = TVVideoMutationCursor()
    @StateObject private var videoMenu = TVHomeMenuCoordinator()
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
                    TVSharedVideoGrid(
                        snapshot: TVSharedVideoGridSnapshot(
                            videos: visibleVideos, scope: api.metadataCacheScope,
                            destination: "public-playlist-" + playlistURL,
                            focusPrefix: "",
                            accessibilityPrefix: "public-playlist-video-",
                            columns: columns.count, columnSpacing: 30,
                            rowSpacing: 34, canLoadMore: false, loadAhead: 5,
                            lookupMissingMetadata: false,
                            isWatchLaterEntry: false, playbackQueue: visibleVideos
                        ),
                        api: api, focus: $focusedVideo, menu: videoMenu,
                        onReturnToList: { id in
                            detailReturnVideoID = id
                            focusedVideo = id
                        },
                        onLeftEdge: { _ in },
                        onApproachEnd: {}
                    )
                    .equatable()
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
            .defaultFocus(
                $focusedVideo, detailReturnVideoID,
                priority: detailReturnVideoID == nil ? .automatic : .userInitiated
            )
            .modifier(TVHomeMenuPresentation(model: videoMenu))
            .onReceive(TVVideoMutationCenter.shared.$events) { reconcileMutations($0) }
            .onAppear { reconcileMutations(TVVideoMutationCenter.shared.events) }
            .onChange(of: videoMenu.focusRestoreRequest) { _, _ in
                if let id = videoMenu.focusRestoreTarget,
                   visibleVideos.contains(where: { $0.url == id }) {
                    focusedVideo = id
                }
            }
            .task { await TVWatchLaterMembership.shared.ensureLoaded(api: api) }
            .task {
                async let playlists: Void = TVPlaylistMembership.shared.ensureLoaded(api: api)
                async let favorites: Void = TVFavoriteMembership.shared.ensureLoaded(api: api)
                _ = await (playlists, favorites)
            }
            .task { await contentPreferences.ensureLoaded(api: api) }
            .task(id: playlistURL) {
                // A pushed video detail returning to its playlist must not
                // re-fetch the grid and focus the Back button again.
                guard loadedPlaylistURL != playlistURL else { return }
                loadedPlaylistURL = playlistURL
                focusedBack = true
                await load()
            }
            .onExitCommand {
                if let first = TVVideoGridBackPolicy.firstTarget(
                    focused: focusedVideo, first: visibleVideos.first?.url
                ) {
                    detailReturnVideoID = first
                    var transaction = Transaction()
                    transaction.disablesAnimations = true
                    withTransaction(transaction) {
                        scroll.scrollTo(first, anchor: .top)
                        focusedVideo = first
                    }
                } else {
                    // This is a pushed page, so its parent is the next level.
                    dismiss()
                }
            }
        }
    }

    @MainActor
    private func reconcileMutations(_ events: [TVVideoMutationCenter.Event]) {
        let pending = events.filter {
            $0.id > mutationCursor.lastID && $0.accountScope == api.metadataCacheScope
        }
        mutationCursor.lastID = max(mutationCursor.lastID, events.last?.id ?? 0)
        guard !pending.isEmpty else { return }
        if videos.contains(where: { item in pending.contains { $0.removes(item) } }) {
            videos.removeAll { item in pending.contains { $0.removes(item) } }
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
