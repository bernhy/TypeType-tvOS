import SwiftUI

/// Diagnostic baseline built from the subscriptions screen's ordinary grid.
/// Deliberately NO Home-specific focus restoration, focusScope, preferred
/// focus for each card, row-width freezing, resume rail, or custom menu logic.
/// Uses the SAME /recommendations/home + progress APIs and VideoCard/context
/// actions as regular browsing. Never enabled outside the experiment branch.
private struct TVHomeBaselineGridEntry: Identifiable {
    let index: Int
    let video: VideoItem
    var id: String { video.url }
}

struct TVHomeSubscriptionsBaselineView: View {
    let api: TypeTypeAPI
    let previewVideos: [VideoItem]?
    var focusRequest = 0
    var onRevealMenu: () -> Void = {}
    var onInitialFocusReady: () -> Void = {}

    @ObservedObject private var contentPreferences = TVContentPreferences.shared
    @AppStorage("typetype.experiment.homeDiagnosticMode")
    private var diagnosticModeRaw = TVHomeExperimentMode.full.rawValue
    @State private var videos: [VideoItem]
    @State private var nextCursor: String?
    @State private var loading = false
    @State private var loadingMore = false
    @State private var error: String?
    @State private var pageError: String?
    @State private var loadedOnce = false
    @State private var handledFocusRequest: Int?
    @State private var initialFocusPending = false
    @FocusState private var focusedVideo: String?

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 26), count: 4)
    private var visibleVideos: [VideoItem] { contentPreferences.displayed(videos) }

    init(api: TypeTypeAPI, previewVideos: [VideoItem]? = nil,
         focusRequest: Int = 0, onRevealMenu: @escaping () -> Void = {},
         onInitialFocusReady: @escaping () -> Void = {}) {
        self.api = api
        self.previewVideos = previewVideos
        self.focusRequest = focusRequest
        self.onRevealMenu = onRevealMenu
        self.onInitialFocusReady = onInitialFocusReady
        _videos = State(initialValue: previewVideos ?? [])
        _loadedOnce = State(initialValue: previewVideos != nil)
    }

    var body: some View {
        ScrollViewReader { scroll in
            ScrollView {
                VStack(alignment: .leading, spacing: 27) {
                    HStack {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("home.forYou")
                                .font(.subheadline.bold()).tracking(2.3)
                                .foregroundStyle(TTTheme.accent)
                            Text("home.recommendations")
                                .font(.system(size: 45, weight: .bold))
                        }
                        Spacer()
                        Button {
                            diagnosticModeRaw =
                                TVHomeExperimentMode.fullLightweightStableFocus.rawValue
                        } label: {
                            Label("Home-Test: zurück zum Vergleich",
                                  systemImage: "arrow.uturn.backward")
                        }
                        .buttonStyle(.bordered)
                        .accessibilityIdentifier("home-baseline-switch-back")
                        Button("common.refresh") { Task { await reload() } }
                            .buttonStyle(.bordered)
                            .disabled(loading || loadingMore)
                    }
                    if loading && videos.isEmpty {
                        TVPulsingPlaceholder()
                            .frame(maxWidth: .infinity, minHeight: 180)
                    }
                    if let error {
                        TVContentMessage(
                            symbol: "wifi.exclamationmark",
                            title: TVL10n.value("home.serverUnavailable"),
                            detail: error,
                            action: { Task { await reload() } }
                        )
                    } else if !loading && visibleVideos.isEmpty {
                        TVContentMessage(
                            symbol: "play.rectangle",
                            title: TVL10n.value("home.noRecommendations"),
                            detail: TVL10n.value("home.emptyHelp")
                        )
                    } else {
                        LazyVGrid(columns: columns, spacing: 32) {
                            ForEach(visibleVideos.enumerated().map {
                                TVHomeBaselineGridEntry(index: $0.offset, video: $0.element)
                            }) { entry in
                                let index = entry.index
                                let video = entry.video
                                NavigationLink {
                                    VideoDetailView(
                                        api: api, video: video,
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
                                .zIndex(focusedVideo == video.url ? 5 : 0)
                                .id(video.url)
                                .videoActions(api: api, video: video,
                                              onChanged: { Task { await reload() } },
                                              focus: $focusedVideo, focusID: video.url)
                                .onMoveCommand { direction in
                                    if direction == .left && index % columns.count == 0 {
                                        onRevealMenu()
                                    }
                                }
                                .accessibilityIdentifier("home-baseline-video-\(index)")
                                .onAppear {
                                    if index >= visibleVideos.count - columns.count - 1,
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
                            Button("home.loadMore") { Task { await loadMore() } }
                                .buttonStyle(.bordered)
                                .frame(maxWidth: .infinity)
                        }
                        if let pageError {
                            Text(pageError).font(.callout).foregroundStyle(.orange)
                        }
                    }
                }
                .padding(.horizontal, 65)
                .padding(.top, 42)
                .padding(.bottom, 120)
            }
            .background(TTTheme.ink)
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
                initialFocusPending = true
                await Task.yield()
                if let first = visibleVideos.first {
                    initialFocusPending = false
                    focusedVideo = first.url
                    onInitialFocusReady()
                }
            }
            .onChange(of: visibleVideos.map(\.url)) { _, urls in
                guard !urls.isEmpty, focusRequest > 0 else { return }
                if initialFocusPending {
                    initialFocusPending = false
                    focusedVideo = urls.first
                    onInitialFocusReady()
                } else if let focusedVideo, !urls.contains(focusedVideo) {
                    self.focusedVideo = urls.first
                }
            }
            .onChange(of: loading) { _, stillLoading in
                if !stillLoading && visibleVideos.isEmpty {
                    onInitialFocusReady()
                }
            }
            .onExitCommand { onRevealMenu() }
        }
    }

    @MainActor
    private func reload() async {
        guard !loading else { return }
        loading = true
        error = nil
        pageError = nil
        nextCursor = nil
        defer { loading = false }
        #if DEBUG
        if api.origin.host == "preview.invalid" {
            videos = TVShowcaseFixtures.videos
            return
        }
        #endif
        do {
            let page = try await api.home()
            try Task.checkCancellation()
            videos = page.items
            nextCursor = page.nextCursor?.isEmpty == false ? page.nextCursor : nil
            let enriched = await api.withProgress(page.items)
            guard !Task.isCancelled else { return }
            videos = enriched
        } catch is CancellationError {
            return
        } catch {
            error = error.localizedDescription
        }
    }

    @MainActor
    private func loadMore() async {
        guard !loading && !loadingMore, let cursor = nextCursor else { return }
        loadingMore = true
        pageError = nil
        defer { loadingMore = false }
        do {
            let page = try await api.home(cursor: cursor)
            try Task.checkCancellation()
            guard nextCursor == cursor else { return }
            var known = Set(videos.map(\.url))
            let added = page.items.filter { known.insert($0.url).inserted }
            nextCursor = page.nextCursor?.isEmpty == false &&
                page.nextCursor != cursor ? page.nextCursor : nil
            videos.append(contentsOf: added)
            let enriched = await api.withProgress(added)
            guard !Task.isCancelled else { return }
            let latest = Dictionary(uniqueKeysWithValues: enriched.map { ($0.url, $0) })
            videos = videos.map { latest[$0.url] ?? $0 }
        } catch is CancellationError {
            return
        } catch {
            pageError = error.localizedDescription
        }
    }
}
