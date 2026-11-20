import SwiftUI

/// Newest-first account feed. TypeType's stable cursor snapshot avoids
/// querying every subscribed channel on the Apple TV.
struct TVSubscriptionFeedView: View {
    let api: TypeTypeAPI
    @ObservedObject private var contentPreferences = TVContentPreferences.shared
    var focusRequest = 0
    var fixedLayoutWidth: CGFloat?
    var onRevealMenu: () -> Void = {}

    @State private var videos: [VideoItem] = []
    private var visibleVideos: [VideoItem] {
        contentPreferences.displayed(videos)
    }
    @State private var nextCursor: String?
    @State private var loading = false
    @State private var loadingMore = false
    @State private var preparing = false
    @State private var error: String?
    @State private var pageError: String?
    @State private var requestID = UUID()
    @State private var loadedOnce = false
    @State private var handledFocusRequest: Int?
    @State private var initialGridFocusPending = false
    @FocusState private var focusedVideo: String?
    @State private var railReturnVideoID: String?
    @StateObject private var videoMenu = TVHomeMenuCoordinator()
    private let columns = Array(repeating: GridItem(.flexible(), spacing: 26), count: 4)

    var body: some View {
        GeometryReader { viewport in
        let layoutWidth = fixedLayoutWidth ?? viewport.size.width
        ScrollViewReader { scroll in
            ScrollView {
            VStack(alignment: .leading, spacing: 27) {
                HStack {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("nav.subscriptions")
                            .font(.subheadline.bold()).tracking(2.3)
                            .foregroundStyle(TTTheme.accent)
                        Text("subscriptions.feedTitle")
                            .font(.system(size: 45, weight: .bold))
                    }
                    Spacer()
                    Button("common.refresh") { Task { await reload() } }
                        .buttonStyle(.bordered)
                        .disabled(loading || loadingMore)
                }
                if preparing {
                    ProgressView("subscriptions.feedPreparing")
                        .frame(maxWidth: .infinity, minHeight: 120)
                } else if loading && videos.isEmpty {
                    TVPulsingPlaceholder()
                        .frame(maxWidth: .infinity, minHeight: 180)
                }
                if let error {
                    TVContentMessage(
                        symbol: "wifi.exclamationmark",
                        title: TVL10n.value("subscriptions.feedError"),
                        detail: error,
                        action: { Task { await reload() } },
                        actionTitle: TVL10n.value("subscriptions.feedRetry")
                    )
                } else if !loading && !preparing && visibleVideos.isEmpty {
                    TVContentMessage(
                        symbol: "play.rectangle",
                        title: TVL10n.value("subscriptions.feedEmpty"),
                        detail: TVL10n.value("subscriptions.chooseChannel")
                    )
                } else {
                    TVSharedVideoGrid(
                        snapshot: TVSharedVideoGridSnapshot(
                            videos: visibleVideos, scope: api.metadataCacheScope,
                            destination: "subscriptions-feed",
                            focusPrefix: "",
                            accessibilityPrefix: "subscriptions-video-",
                            columns: columns.count, columnSpacing: 26,
                            rowSpacing: 32, canLoadMore: nextCursor != nil &&
                                !loading && !loadingMore && pageError == nil,
                            loadAhead: columns.count + 1,
                            lookupMissingMetadata: false,
                            isWatchLaterEntry: false, playbackQueue: nil
                        ),
                        api: api, focus: $focusedVideo, menu: videoMenu,
                        onReturnToList: { id in
                            TVVideoFocusReturn.restore(
                                $focusedVideo, id: id, scroll: scroll
                            )
                        },
                        onLeftEdge: { id in
                            railReturnVideoID = id
                            onRevealMenu()
                        },
                        onChanged: { Task { await reload() } },
                        onApproachEnd: { Task { await loadMore() } }
                    )
                    .equatable()
                    if loadingMore {
                        ProgressView("settings.remoteLoading")
                            .frame(maxWidth: .infinity)
                    } else if nextCursor != nil || pageError != nil {
                        Button("subscriptions.feedLoadMore") { Task { await loadMore() } }
                            .buttonStyle(.bordered)
                            .frame(maxWidth: .infinity)
                    }
                    if let pageError {
                        Text(pageError)
                            .font(.callout).foregroundStyle(.orange)
                    }
                }
            }
            .padding(.horizontal, 65)
            .padding(.top, 42)
            .padding(.bottom, 120)
            .frame(width: layoutWidth, alignment: .leading)
            .scaleEffect(
                TVHomeNavigationZoom.scale(
                    visibleWidth: viewport.size.width, layoutWidth: layoutWidth
                ),
                anchor: .topLeading
            )
            .frame(width: viewport.size.width, alignment: .topLeading)
        }
        .frame(width: viewport.size.width, height: viewport.size.height)
        .background(TTTheme.ink)
        .defaultFocus(
            $focusedVideo, railReturnVideoID,
            priority: railReturnVideoID == nil ? .automatic : .userInitiated
        )
        .modifier(TVHomeMenuPresentation(model: videoMenu))
        .task {
            await contentPreferences.ensureLoaded(api: api)
            guard !loadedOnce else { return }
            loadedOnce = true
            await reload()
        }
        .task(id: focusRequest) {
            guard focusRequest > 0,
                  handledFocusRequest != focusRequest else { return }
            handledFocusRequest = focusRequest
            if let saved = railReturnVideoID,
               visibleVideos.contains(where: { $0.url == saved }) {
                initialGridFocusPending = false
                return
            }
            railReturnVideoID = nil
            initialGridFocusPending = true
            await Task.yield()
            if let first = visibleVideos.first {
                initialGridFocusPending = false
                focusedVideo = first.url
            }
        }
        .onChange(of: visibleVideos.map(\.url)) { _, urls in
            guard !urls.isEmpty, focusRequest > 0 else { return }
            if initialGridFocusPending {
                initialGridFocusPending = false
                focusedVideo = urls.first
            } else if let focusedVideo, !urls.contains(focusedVideo) {
                // Only recover a focus target which was actually removed,
                // not a transient nil during NavigationStack pop.
                self.focusedVideo = urls.first
            }
        }
        .onExitCommand {
            railReturnVideoID = focusedVideo
            onRevealMenu()
        }
        }
        } // GeometryReader keeps the grid width constant across menu zoom.
    }

    @MainActor
    private func reload() async {
        guard !loading else { return }
        #if DEBUG
        if api.origin.host == "preview.invalid" {
            videos = TVShowcaseFixtures.videos
            nextCursor = nil
            error = nil
            return
        }
        #endif
        let id = UUID()
        requestID = id
        loading = true
        preparing = false
        error = nil
        pageError = nil
        nextCursor = nil
        defer { if requestID == id { loading = false; preparing = false } }
        do {
            // HTTP 202 is not an empty feed: the server is building its
            // initial snapshot. Keep retries bounded and cancellable.
            for _ in 0..<12 {
                let response = try await api.subscriptionFeed()
                try Task.checkCancellation()
                guard requestID == id else { return }
                if response.code == "subscription_feed_preparing" {
                    preparing = true
                    let ms = min(5_000, max(250, response.retryAfterMs ?? 1_000))
                    try await Task.sleep(nanoseconds: UInt64(ms) * 1_000_000)
                    continue
                }
                preparing = false
                guard let received = response.videos else {
                    throw TypeTypeError.unexpectedResponse
                }
                videos = received
                nextCursor = response.nextpage?.isEmpty == false ? response.nextpage : nil
                let enriched = await api.withProgress(received)
                guard !Task.isCancelled, requestID == id else { return }
                videos = enriched
                return
            }
            error = TVL10n.value("subscriptions.feedPreparing")
        } catch is CancellationError {
            return
        } catch {
            if requestID == id { self.error = error.localizedDescription }
        }
    }

    @MainActor
    private func loadMore() async {
        guard !loading, !loadingMore, let cursor = nextCursor else { return }
        loadingMore = true
        pageError = nil
        let id = requestID
        defer { if requestID == id { loadingMore = false } }
        do {
            let response = try await api.subscriptionFeed(cursor: cursor)
            try Task.checkCancellation()
            guard requestID == id, nextCursor == cursor,
                  let rows = response.videos else { return }
            var known = Set(videos.map(\.url))
            let added = rows.filter { known.insert($0.url).inserted }
            videos.append(contentsOf: added)
            let next = response.nextpage?.isEmpty == false ? response.nextpage : nil
            nextCursor = next == cursor ? nil : next
            let enriched = await api.withProgress(added)
            guard !Task.isCancelled, requestID == id else { return }
            let progress = Dictionary(uniqueKeysWithValues: enriched.map { ($0.url, $0) })
            videos = videos.map { progress[$0.url] ?? $0 }
        } catch is CancellationError {
            return
        } catch {
            if TVServerErrorMapping.httpStatus(error) == 409 {
                // A stale subscription snapshot cursor is recoverable whether
                // the server provided JSON error metadata or a bare status.
                nextCursor = nil
                loadingMore = false
                await reload()
            } else if requestID == id {
                pageError = error.localizedDescription
            }
        }
    }
}
