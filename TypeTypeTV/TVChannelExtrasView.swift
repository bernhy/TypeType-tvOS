import SwiftUI

enum TVChannelExtraKind: String {
    case playlists, community, podcasts, courses
    var labelKey: String { "channels." + rawValue }
}

/// Standalone channel subpages keep the existing channel rail/focus intact.
struct TVChannelExtrasView: View {
    let api: TypeTypeAPI
    let channelURL: String
    let kind: TVChannelExtraKind
    @Environment(\.dismiss) private var dismiss
    @FocusState private var focusedBack: Bool
    @FocusState private var focusedCard: String?
    @FocusState private var focusedEpisode: String?
    @State private var detailReturnVideoID: String?
    @State private var mutationCursor = TVVideoMutationCursor()
    @StateObject private var videoMenu = TVHomeMenuCoordinator()
    @State private var unsupported = false
    @State private var playlists: [TVPublicPlaylistSummary] = []
    @State private var episodes: [VideoItem] = []
    @ObservedObject private var contentPreferences = TVContentPreferences.shared
    private var visibleEpisodes: [VideoItem] {
        contentPreferences.withoutHiddenLivestreams(episodes)
    }
    @State private var posts: [TVCommunityPost] = []
    @State private var nextPage: String?
    @State private var loadedExtraKey: String?
    @State private var loading = false
    @State private var error: String?
    private let columns = Array(repeating: GridItem(.flexible(), spacing: 26), count: 3)

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                HStack(spacing: 18) {
                    Button { dismiss() } label: {
                        Label("common.back", systemImage: "chevron.left")
                    }
                    .buttonStyle(.bordered)
                    .focused($focusedBack)
                    .accessibilityIdentifier("channel-extra-back")
                    Text(TVL10n.value(kind.labelKey)).font(.largeTitle.bold())
                }
                .focusSection()
                if unsupported {
                    Label("channels.notSupportedByServer", systemImage: "info.circle")
                        .foregroundStyle(TTTheme.muted)
                }
                if loading { ProgressView("settings.remoteLoading") }
                if let error, !unsupported {
                    Text(error).foregroundStyle(.orange)
                    Button("common.retry") { Task { await fetch(append: false) } }
                        .buttonStyle(.bordered)
                }
                if !playlists.isEmpty {
                    LazyVGrid(columns: columns, spacing: 30) {
                        ForEach(playlists) { playlist in
                            NavigationLink {
                                TVPublicPlaylistView(
                                    api: api, playlistURL: playlist.url,
                                    startingTitle: playlist.title,
                                    isPodcast: kind == .podcasts
                                )
                            } label: {
                                TVChannelPlaylistTile(
                                    api: api, playlist: playlist,
                                    focused: focusedCard == playlist.url
                                )
                            }
                            .buttonStyle(TVRailButtonStyle())
                            .focusEffectDisabled(true)
                            .focused($focusedCard, equals: playlist.url)
                            .zIndex(focusedCard == playlist.url ? 5 : 0)
                        }
                    }
                    .focusSection()
                }
                if !visibleEpisodes.isEmpty {
                    TVSharedVideoGrid(
                        snapshot: TVSharedVideoGridSnapshot(
                            videos: visibleEpisodes, scope: api.metadataCacheScope,
                            destination: "channel-extra-" + channelURL + "-" + kind.rawValue,
                            focusPrefix: "",
                            accessibilityPrefix: "channel-extra-episode-",
                            columns: columns.count, columnSpacing: 26,
                            rowSpacing: 30, canLoadMore: false, loadAhead: 4,
                            lookupMissingMetadata: false,
                            isWatchLaterEntry: false, playbackQueue: nil
                        ),
                        api: api, focus: $focusedEpisode, menu: videoMenu,
                        onReturnToList: { id in
                            detailReturnVideoID = id
                            focusedEpisode = id
                        },
                        onLeftEdge: { _ in },
                        onApproachEnd: {}
                    )
                    .equatable()
                }
                ForEach(posts) { post in
                    TVCommunityPostCard(api: api, post: post)
                }
                if !loading && playlists.isEmpty && visibleEpisodes.isEmpty &&
                   posts.isEmpty && error == nil && !unsupported {
                    Text("channels.emptyExtra").foregroundStyle(TTTheme.muted)
                }
                if nextPage != nil {
                    Button("search.loadMore") { Task { await fetch(append: true) } }
                        .buttonStyle(.bordered)
                        .disabled(loading)
                }
            }
            .padding(70)
        }
        .background(TTTheme.ink)
        .defaultFocus(
            $focusedEpisode, detailReturnVideoID,
            priority: detailReturnVideoID == nil ? .automatic : .userInitiated
        )
        .modifier(TVHomeMenuPresentation(model: videoMenu))
        .onReceive(TVVideoMutationCenter.shared.$events) { reconcileMutations($0) }
        .onAppear { reconcileMutations(TVVideoMutationCenter.shared.events) }
        .onChange(of: videoMenu.focusRestoreRequest) { _, _ in
            if let id = videoMenu.focusRestoreTarget,
               visibleEpisodes.contains(where: { $0.url == id }) {
                focusedEpisode = id
            }
        }
        .task { await TVWatchLaterMembership.shared.ensureLoaded(api: api) }
        .task {
            async let playlists: Void = TVPlaylistMembership.shared.ensureLoaded(api: api)
            async let favorites: Void = TVFavoriteMembership.shared.ensureLoaded(api: api)
            _ = await (playlists, favorites)
        }
        .task { await contentPreferences.ensureLoaded(api: api) }
        .task(id: channelURL + kind.rawValue) {
            let key = channelURL + "|" + kind.rawValue
            // NavigationStack can re-enter this task after popping details.
            // Leave the playlist/video tiles and their focus where they were.
            guard loadedExtraKey != key else { return }
            loadedExtraKey = key
            focusedBack = true
            await fetch(append: false)
        }
        .onExitCommand { dismiss() }
    }

    @MainActor
    private func reconcileMutations(_ events: [TVVideoMutationCenter.Event]) {
        let pending = events.filter {
            $0.id > mutationCursor.lastID && $0.accountScope == api.metadataCacheScope
        }
        mutationCursor.lastID = max(mutationCursor.lastID, events.last?.id ?? 0)
        guard !pending.isEmpty else { return }
        if episodes.contains(where: { video in pending.contains { $0.removes(video) } }) {
            episodes.removeAll { video in pending.contains { $0.removes(video) } }
        }
    }

    @MainActor
    private func fetch(append: Bool) async {
        guard !loading else { return }
        let cursor = append ? nextPage : nil
        if append && cursor == nil { return }
        loading = true
        error = nil
        if !append { unsupported = false }
        defer { loading = false }
        do {
            switch kind {
            case .playlists, .courses:
                let page = try await api.channelPlaylists(
                    channelURL, tab: kind.rawValue, nextpage: cursor)
                if append { playlists += page.playlists }
                else { playlists = page.playlists }
                nextPage = page.nextpage == cursor ? nil : page.nextpage
            case .community:
                let page = try await api.channelPosts(channelURL, nextpage: cursor)
                if append { posts += page.posts } else { posts = page.posts }
                nextPage = page.nextpage == cursor ? nil : page.nextpage
            case .podcasts:
                let page = try await api.channelPodcasts(channelURL, nextpage: cursor)
                if append {
                    playlists += page.podcasts
                    episodes += page.episodes
                } else {
                    playlists = page.podcasts
                    episodes = page.episodes
                }
                nextPage = page.nextpage == cursor ? nil : page.nextpage
            }
        } catch is CancellationError {
            return
        } catch {
            if [404, 501].contains(TVServerErrorMapping.httpStatus(error) ?? -1) {
                unsupported = true
                self.error = nil
            } else {
                self.error = error.localizedDescription
            }
        }
    }
}

/// Match the Home video cards: scale the whole tile and brighten only its
/// lower information panel. No white focus border or outline.
private struct TVChannelPlaylistTile: View {
    let api: TypeTypeAPI
    let playlist: TVPublicPlaylistSummary
    let focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ZStack {
                TVThumbnail(
                    url: api.relativeMediaURL(playlist.thumbnailUrl),
                    origin: api.origin, contentMode: .fit
                )
                Image(systemName: "list.bullet.rectangle")
                    .font(.system(size: 37, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(15)
                    .background(.black.opacity(0.68),
                                in: RoundedRectangle(cornerRadius: 16))
            }
            .aspectRatio(16.0 / 9.0, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            VStack(alignment: .leading, spacing: 7) {
                Text(playlist.title)
                    .font(.system(size: 21, weight: .semibold))
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, minHeight: 54, alignment: .topLeading)
                Text(playlist.uploaderName ?? " ")
                    .font(.system(size: 17))
                    .foregroundStyle(TTTheme.muted)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, minHeight: 23, alignment: .topLeading)
            }
            .padding(.horizontal, 14)
            .padding(.top, 11)
            .padding(.bottom, 13)
            .background(focused
                ? Color(red: 0.15, green: 0.15, blue: 0.165)
                : TTTheme.surface)
        }
        .background(TTTheme.surface)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .scaleEffect(focused ? 1.065 : 1)
        .shadow(color: focused ? Color.black.opacity(0.55) : .clear,
                radius: 19, y: 10)
        .animation(.easeOut(duration: 0.13), value: focused)
        .foregroundStyle(.white)
    }
}

struct TVCommunityPostCard: View {
    let api: TypeTypeAPI
    let post: TVCommunityPost

    var body: some View {
        VStack(alignment: .leading, spacing: 15) {
            HStack {
                Text(post.authorName ?? "").font(.headline)
                Spacer()
                Text(post.publishedTime ?? "")
                    .font(.caption).foregroundStyle(TTTheme.muted)
            }
            let plain = (post.text ?? "").replacingOccurrences(
                of: "<[^>]+>", with: "", options: .regularExpression)
            if !plain.isEmpty { Text(plain).font(.body) }
            ForEach((post.images ?? []).prefix(4), id: \.self) { image in
                TVThumbnail(url: api.relativeMediaURL(image), origin: api.origin)
                    .frame(maxWidth: 850, minHeight: 230, maxHeight: 350)
            }
            if let poll = post.poll {
                ForEach(poll.choices ?? []) { choice in
                    Label(choice.text, systemImage: "circle")
                        .font(.callout)
                }
                Text(poll.textualVoteCount ?? "")
                    .font(.caption).foregroundStyle(TTTheme.muted)
            }
            if let video = post.video {
                NavigationLink {
                    VideoDetailView(api: api, video: video.videoItem(author: post.authorName))
                } label: {
                    Label(video.title, systemImage: "play.rectangle")
                }
                .buttonStyle(.bordered)
            }
            HStack(spacing: 20) {
                Text(post.textualLikeCount ?? "")
                Label(post.textualCommentCount ?? "", systemImage: "text.bubble")
            }
            .font(.caption).foregroundStyle(TTTheme.muted)
        }
        .padding(30)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(TTTheme.surface, in: RoundedRectangle(cornerRadius: 20))
    }
}
