import SwiftUI

/// Newest-first account feed. TypeType's stable cursor snapshot avoids
/// querying every subscribed channel on the Apple TV.
struct TVSubscriptionFeedView: View {
    let api: TypeTypeAPI
    var focusRequest = 0
    var onRevealMenu: () -> Void = {}

    @State private var videos: [VideoItem] = []
    @State private var nextCursor: String?
    @State private var loading = false
    @State private var loadingMore = false
    @State private var preparing = false
    @State private var error: String?
    @State private var pageError: String?
    @State private var requestID = UUID()
    @FocusState private var focusedVideo: String?
    private let columns = Array(repeating: GridItem(.flexible(), spacing: 26), count: 4)

    var body: some View {
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
                    ProgressView("settings.remoteLoading")
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
                } else if !loading && !preparing && videos.isEmpty {
                    TVContentMessage(
                        symbol: "play.rectangle",
                        title: TVL10n.value("subscriptions.feedEmpty"),
                        detail: TVL10n.value("subscriptions.chooseChannel")
                    )
                } else {
                    LazyVGrid(columns: columns, spacing: 32) {
                        ForEach(Array(videos.enumerated()), id: \.offset) { index, video in
                            NavigationLink {
                                VideoDetailView(api: api, video: video)
                            } label: {
                                VideoCard(api: api, video: video)
                            }
                            .buttonStyle(TVRailButtonStyle())
                            .focusEffectDisabled(true)
                            .zIndex(focusedVideo == video.url ? 5 : 0)
                            .videoActions(api: api, video: video, onChanged: {},
                                          focus: $focusedVideo, focusID: video.url)
                            .onMoveCommand { direction in
                                if direction == .left && index % columns.count == 0 {
                                    onRevealMenu()
                                }
                            }
                            .onAppear {
                                if index >= videos.count - columns.count - 1,
                                   nextCursor != nil && !loading && !loadingMore &&
                                   pageError == nil {
                                    Task { await loadMore() }
                                }
                            }
                        }
                    }
                    .focusSection()
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
        }
        .background(TTTheme.ink)
        .task { await reload() }
        .task(id: focusRequest) {
            guard focusRequest > 0 else { return }
            await Task.yield()
            focusedVideo = videos.first?.url
        }
        .onChange(of: videos.map(\.url)) { _, urls in
            guard !urls.isEmpty, focusRequest > 0,
                  !urls.contains(focusedVideo ?? "") else { return }
            Task { @MainActor in
                await Task.yield()
                focusedVideo = videos.first?.url
            }
        }
        .onExitCommand { onRevealMenu() }
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
        } catch TypeTypeError.http(let code, _) where code == 409 {
            nextCursor = nil
            loadingMore = false
            await reload()
        } catch is CancellationError {
            return
        } catch {
            if requestID == id { pageError = error.localizedDescription }
        }
    }
}
