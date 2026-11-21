import SwiftUI

/// Native subscriptions-style Home with an optional horizontal resume shelf.
/// Recommendations use TVSharedVideoGrid. The horizontal resume rail keeps
/// its lazy layout while sharing the same video card and lightweight menu.
private struct TVHomeBaselineGridEntry: Identifiable {
    let index: Int
    let video: VideoItem
    var id: String { video.url }
}

/**
 A stable focus-isolated tile. The parent Home no longer reads the global
 focus value to assign zIndex for every LazyVGrid cell on each remote move.
 Only this tile evaluates focus.wrappedValue for its own layering. The
 NavigationLink, focus binding and lazy context menu stay exactly as before.
 */
private struct TVHomeBaselineTile: View {
    let api: TypeTypeAPI
    let entry: TVHomeBaselineGridEntry
    let focus: FocusState<String?>.Binding
    let homeMenu: TVHomeMenuCoordinator
    let onRevealMenu: (String) -> Void
    let onReturnToList: () -> Void
    let onNavigation: () -> Void

    private var focusID: String { "recent-" + entry.video.url }

    var body: some View {
        let video = entry.video
        let id = focusID
        // Keep focus isolation local to this tile, not in the Home parent.
        let activeFocusID = focus.wrappedValue
        NavigationLink {
            VideoDetailView(
                api: api, video: video,
                onReturnToList: onReturnToList
            )
        } label: {
            VideoCard(api: api, video: video)
        }
        .buttonStyle(TVRailButtonStyle())
        .focusEffectDisabled(true)
        .zIndex(activeFocusID == id ? 5 : 0)
        .id(id)
        .modifier(TVHomeLightweightVideoActions(
            api: api, video: video, model: homeMenu,
            focus: focus, focusID: id
        ))
        .onMoveCommand { direction in
            // No SwiftUI state change: just defer metadata-driven row updates
            // while remote navigation is active.
            onNavigation()
            if direction == .left && entry.index == 0 { onRevealMenu(id) }
        }
        .accessibilityIdentifier("home-baseline-recent-\(entry.index)")
        .containerRelativeFrame(.horizontal, count: 4, spacing: 26)
    }
}

/// A real data snapshot for SwiftUI's EquatableView. Equality intentionally
/// ignores focus position, which is a *dynamic* binding in each existing tile.
/// Playlist/status/local progress changes still reach VideoCard through its
/// own @ObservedObject dependencies, independently of this snapshot.
struct TVHomeCollectionSnapshot: Equatable {
    let items: [VideoItem]
    let scope: String
    let resume: Bool
    let columns: Int
    let canLoadMore: Bool
}

/// The Home parent owns @FocusState and is reevaluated on each navigation
/// step. Crucially, the card factory is now inside an .equatable() content
/// boundary: it is NOT reexecuted for every visible cell on focus changes.
/// Only the horizontal resume rail needs TVHomeBaselineTile; recommendation
/// cards are owned by TVSharedVideoGrid.
private struct TVHomeBaselineVideoCollection: View, Equatable {
    let snapshot: TVHomeCollectionSnapshot
    let api: TypeTypeAPI
    let focus: FocusState<String?>.Binding
    let homeMenu: TVHomeMenuCoordinator
    let onRevealMenu: (String) -> Void
    let onReturnToList: (String, ScrollViewProxy?) -> Void
    let onApproachEnd: () -> Void
    let onResumeAppear: (Int, [VideoItem]) -> Void
    let onResumeDisappear: (VideoItem) -> Void
    let onNavigation: () -> Void

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.snapshot == rhs.snapshot && lhs.homeMenu === rhs.homeMenu
    }

    @ViewBuilder
    var body: some View {
        if snapshot.resume {
            ScrollViewReader { railScroll in
                ScrollView(.horizontal) {
                    LazyHStack(alignment: .center, spacing: 26) {
                        entries(railScroll: railScroll)
                    }
                    .padding(.vertical, 20)
                    .scrollTargetLayout()
                }
                .scrollIndicators(.hidden)
                .scrollClipDisabled()
                .scrollTargetBehavior(.viewAligned)
                .frame(height: 445)
                .id("home-continue-watching-row")
                .focusSection()
            }
        } else {
            // Exactly the same video grid, focus-isolated tiles and lazy
            // context-menu host used by subscriptions, search and library.
            TVSharedVideoGrid(
                snapshot: TVSharedVideoGridSnapshot(
                    videos: snapshot.items, scope: snapshot.scope,
                    destination: "home", focusPrefix: "recommendation-",
                    accessibilityPrefix: "home-baseline-video-",
                    columns: snapshot.columns, columnSpacing: 26,
                    rowSpacing: 32, canLoadMore: snapshot.canLoadMore,
                    loadAhead: snapshot.columns + 1,
                    lookupMissingMetadata: false, isWatchLaterEntry: false,
                    playbackQueue: nil
                ),
                api: api, focus: focus, menu: homeMenu,
                onReturnToList: { onReturnToList($0, nil) },
                onLeftEdge: onRevealMenu,
                onApproachEnd: onApproachEnd,
                onNavigation: onNavigation
            )
            .equatable()
        }
    }

    private func entries(railScroll: ScrollViewProxy? = nil) -> some View {
        ForEach(snapshot.items.enumerated().map {
            TVHomeBaselineGridEntry(index: $0.offset, video: $0.element)
        }) { entry in
            let id = "recent-" + entry.video.url
            TVHomeBaselineTile(
                api: api, entry: entry,
                focus: focus, homeMenu: homeMenu,
                onRevealMenu: onRevealMenu,
                onReturnToList: { onReturnToList(id, railScroll) },
                onNavigation: onNavigation
            )
            .onAppear {
                onResumeAppear(entry.index, snapshot.items)
                if snapshot.canLoadMore &&
                    entry.index >= snapshot.items.count - 2 {
                    onApproachEnd()
                }
            }
            .onDisappear {
                onResumeDisappear(entry.video)
            }
        }
    }
}


/// Mirrors the server's hasMore flag, including older servers that omit it.
/// Never keep fetching a cursor when the server says pagination is complete
/// or repeats the cursor we just requested.
enum TVHomePagingPolicy {
    static func nextCursor(_ page: HomeRecommendations,
                           after previous: String? = nil) -> String? {
        guard page.hasMore != false,
              let cursor = page.nextCursor, !cursor.isEmpty,
              cursor != previous else { return nil }
        return cursor
    }
}

/// The sidebar keeps its native HStack layout. The Home grid's width comes
/// from the OUTER viewport (not from its animating sibling): this prevents
/// even intermediate 280-ms animation frames from reflowing the grid.
/// ScrollView, alerts, context-menu hosts and their height remain unscaled.
enum TVHomeNavigationZoom {
    static func layoutWidth(outerWidth: CGFloat) -> CGFloat {
        max(0, outerWidth - TVMainNavigationLayout.collapsedWidth)
    }

    static func scale(visibleWidth: CGFloat, layoutWidth: CGFloat) -> CGFloat {
        guard visibleWidth > 0, layoutWidth > 0 else { return 1 }
        return min(1, visibleWidth / layoutWidth)
    }
}

struct TVHomeSubscriptionsBaselineView: View {
    let api: TypeTypeAPI
    let previewVideos: [VideoItem]?
    // Measured once per parent layout, from the outer screen width.
    // This stays stable while the sidebar's own width animates.
    var fixedLayoutWidth: CGFloat?
    var focusRequest = 0
    var onRevealMenu: () -> Void = {}
    var onOpenAccount: () -> Void = {}
    var onInitialFocusReady: () -> Void = {}

    @ObservedObject private var contentPreferences = TVContentPreferences.shared
    @ObservedObject private var localProgress = TVLocalProgress.shared
    // One shared state host for Home menu dialogs/actions. Every card keeps
    // the same NavigationLink + FocusState chain throughout focus movement.
    @StateObject private var homeMenu = TVHomeMenuCoordinator()
    // Reference state is intentionally not observable: queue activity must
    // never invalidate Home or its Equatable card collections.
    @State private var resumeMetadata = TVHomeResumeMetadataLoader()
    // Updated once on leaving Home for the sidebar, never on each focus move.
    // The same card becomes the target when pressing Right to return.
    @State private var railReturnCardID: String?
    // Native tvOS default-focus priority while the pushed details pop.
    @State private var detailReturnCardID: String?
    @State private var mutationCursor = TVVideoMutationCursor()
    @State private var videos: [VideoItem]
    @State private var recentVideos: [VideoItem]
    @State private var historyLoadedOnce = false
    @State private var loadingRecent = false
    @State private var historyHasMore = false
    @State private var historyLoadingMore = false
    @State private var historyOffset = 0
    @State private var historyRequestID = UUID()
    @State private var recentError: String?
    @State private var recentNeedsLogin = false
    @State private var nextCursor: String?
    @State private var loading = false
    @State private var loadingMore = false
    @State private var error: String?
    @State private var pageError: String?
    @State private var loadedOnce = false
    @State private var recommendationsLoaded = false
    @State private var handledFocusRequest: Int?
    @State private var initialFocusPending = false
    @FocusState private var focusedVideo: String?

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 26), count: 4)
    private let historyPageSize = 100
    private var showRecent: Bool {
        contentPreferences.settings?.hideContinueWatching != true
    }
    private var showRecommendations: Bool {
        contentPreferences.settings?.hideHomeRecommendations != true
    }
    private var visibleVideos: [VideoItem] {
        contentPreferences.displayed(videos)
    }
    private var visibleRecent: [VideoItem] {
        filteredRecent()
    }
    private func filteredRecent() -> [VideoItem] {
        // Shared 90% threshold, finished-video logic and local progress override.
        contentPreferences.displayed(recentVideos).filter {
            TVContinueWatchingPolicy.isEligible(
                $0, positionMs: localProgress.position(for: $0.url) ?? $0.watchPositionMs
            )
        }
    }
    private var visibleCardIDs: [String] {
        buildCardIDs()
    }
    private func buildCardIDs() -> [String] {
        visibleVideos.map { cardID($0, resume: false) } +
            (showRecent ? visibleRecent.map { cardID($0, resume: true) } : [])
    }

    private func cardID(_ video: VideoItem, resume: Bool) -> String {
        (resume ? "recent-" : "recommendation-") + video.url
    }

    private var firstCardID: String? {
        if showRecommendations {
            if let first = visibleVideos.first {
                return cardID(first, resume: false)
            }
            if !recommendationsLoaded { return nil }
        }
        if showRecent, let first = visibleRecent.first {
            return cardID(first, resume: true)
        }
        return nil
    }

    init(api: TypeTypeAPI, previewVideos: [VideoItem]? = nil,
         fixedLayoutWidth: CGFloat? = nil,
         focusRequest: Int = 0, onRevealMenu: @escaping () -> Void = {},
         onOpenAccount: @escaping () -> Void = {},
         onInitialFocusReady: @escaping () -> Void = {}) {
        self.api = api
        self.previewVideos = previewVideos
        self.fixedLayoutWidth = fixedLayoutWidth
        self.focusRequest = focusRequest
        self.onRevealMenu = onRevealMenu
        self.onOpenAccount = onOpenAccount
        self.onInitialFocusReady = onInitialFocusReady
        _videos = State(initialValue: previewVideos ?? [])
        _recentVideos = State(initialValue: previewVideos ?? [])
        _loadedOnce = State(initialValue: previewVideos != nil)
        _historyLoadedOnce = State(initialValue: previewVideos != nil)
        _recommendationsLoaded = State(initialValue: previewVideos != nil)
    }

    var body: some View {
        GeometryReader { viewport in
        let layoutWidth = fixedLayoutWidth ?? viewport.size.width
        ScrollViewReader { scroll in
            ScrollView {
                VStack(alignment: .leading, spacing: 27) {
                    HStack {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("home.forYou")
                                .font(.subheadline.bold()).tracking(2.3)
                                .foregroundStyle(TTTheme.accent)
                            Text("nav.home")
                                .font(.system(size: 45, weight: .bold))
                        }
                        Spacer()
                        Button("common.refresh") { Task { await refresh() } }
                            .buttonStyle(.bordered)
                            .disabled(loading || loadingMore || loadingRecent ||
                                      historyLoadingMore)
                    }

                    if showRecent {
                        VStack(alignment: .leading, spacing: 19) {
                            Text("home.continueWatching")
                                .font(.system(size: 35, weight: .bold))
                            if loadingRecent && recentVideos.isEmpty {
                                TVPulsingPlaceholder()
                                    .frame(maxWidth: .infinity, minHeight: 135)
                            } else if !visibleRecent.isEmpty {
                                videoCollection(visibleRecent, resume: true, scroll: scroll)
                            } else if recentNeedsLogin {
                                VStack(alignment: .leading, spacing: 15) {
                                    Text("home.signInForHistory")
                                        .foregroundStyle(TTTheme.muted)
                                    Button {
                                        onOpenAccount()
                                    } label: {
                                        Label("settings.pair",
                                              systemImage: "person.crop.circle")
                                    }
                                    .buttonStyle(.borderedProminent)
                                }
                            } else if !loadingRecent {
                                Text(recentError ??
                                     TVL10n.value("home.continueWatchingEmpty"))
                                    .foregroundStyle(TTTheme.muted)
                                    .font(.callout)
                            }
                        }
                    }

                    if showRecommendations {
                        if showRecent { Divider().padding(.vertical, 6) }
                        VStack(alignment: .leading, spacing: 19) {
                            Text("home.recommendations")
                                .font(.system(size: 35, weight: .bold))
                            if loading && videos.isEmpty {
                                TVPulsingPlaceholder()
                                    .frame(maxWidth: .infinity, minHeight: 180)
                            } else if let error, visibleVideos.isEmpty {
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
                                videoCollection(visibleVideos, resume: false,
                                                scroll: scroll)
                                if loadingMore {
                                    ProgressView("settings.remoteLoading")
                                        .frame(maxWidth: .infinity)
                                } else if nextCursor != nil || pageError != nil {
                                    Button("home.loadMore") {
                                        Task { await loadMore() }
                                    }
                                    .buttonStyle(.bordered)
                                    .frame(maxWidth: .infinity)
                                }
                                if let pageError {
                                    Text(pageError)
                                        .font(.callout).foregroundStyle(.orange)
                                }
                                // Preserve the existing feed on a failed
                                // manual refresh, and report the error below
                                // the cards without disrupting scroll/focus.
                                if let error {
                                    Text(error)
                                        .font(.callout).foregroundStyle(.orange)
                                }
                            }
                        }
                    }
                }
                .padding(.horizontal, 65)
                .padding(.top, 42)
                .padding(.bottom, 120)
                // The entire grid keeps the collapsed-rail width throughout
                // the sidebar animation. This layout value is constant;
                // only the presentation transform changes frame by frame.
                .frame(width: layoutWidth, alignment: .leading)
                .scaleEffect(
                    TVHomeNavigationZoom.scale(
                        visibleWidth: viewport.size.width,
                        layoutWidth: layoutWidth
                    ),
                    anchor: .topLeading
                )
                // The transformed scroll content fits the real viewport.
                // Critically, the ScrollView and its clipping/scroll height
                // are NOT scaled: no black strip at the bottom.
                .frame(width: viewport.size.width, alignment: .topLeading)
            }
            .frame(width: viewport.size.width, height: viewport.size.height)
            .background(TTTheme.ink)
            // tvOS can choose the saved tile on the first user-initiated
            // Right movement from the main rail. Do not allow geometric
            // focus search to pick an adjacent tile first, then overwrite it.
            // No per-card observer, Task or focus-state rewrite is required.
            .defaultFocus(
                $focusedVideo, detailReturnCardID ?? railReturnCardID,
                priority: detailReturnCardID == nil && railReturnCardID == nil
                    ? .automatic : .userInitiated
            )
            // Shared by BOTH sources. No per-card dialog or toast state.
            .modifier(TVHomeMenuPresentation(model: homeMenu))
            .onReceive(TVVideoMutationCenter.shared.$events) { reconcileMutations($0) }
            .onAppear { reconcileMutations(TVVideoMutationCenter.shared.events) }
            .onChange(of: homeMenu.focusRestoreRequest) { _, _ in
                if let id = homeMenu.focusRestoreTarget,
                   visibleCardIDs.contains(id) {
                    focusedVideo = id
                }
            }
            .task {
                await TVWatchLaterMembership.shared.ensureLoaded(api: api)
            }
            .task {
                async let playlists: Void = TVPlaylistMembership.shared.ensureLoaded(api: api)
                async let favorites: Void = TVFavoriteMembership.shared.ensureLoaded(api: api)
                _ = await (playlists, favorites)
            }
            .task {
                // Do not fetch /history before the settings have arrived.
                await contentPreferences.ensureLoaded(api: api)
                guard !loadedOnce else { return }
                loadedOnce = true
                await refresh()
            }
            .onChange(of: showRecent) { _, enabled in
                if !enabled { resumeMetadata.stop() }
                if enabled && !historyLoadedOnce && previewVideos == nil {
                    Task { await loadHistory() }
                }
            }
            .onChange(of: showRecommendations) { _, enabled in
                if !enabled {
                    // An intentionally hidden source must never keep Home's
                    // startup focus gate waiting on a request we did not make.
                    recommendationsLoaded = true
                    claimInitialFocus()
                } else if videos.isEmpty && loadedOnce && previewVideos == nil {
                    Task { await reload() }
                }
            }
            .task(id: focusRequest) {
                guard focusRequest > 0,
                      handledFocusRequest != focusRequest else { return }
                handledFocusRequest = focusRequest
                if let saved = railReturnCardID {
                    // Default focus is already installed BEFORE UIKit begins
                    // navigating Right into Home. A later focus assignment
                    // would visibly jump from its geometric first choice.
                    // Check availability only on an explicit rail entry,
                    // never on each ordinary card-to-card focus movement.
                    if visibleCardIDs.contains(saved) {
                        initialFocusPending = false
                        onInitialFocusReady()
                        return
                    }
                    // The saved item was removed/hidden while the menu was
                    // open; retain the original first-card fallback instead.
                    railReturnCardID = nil
                }
                initialFocusPending = true
                await Task.yield()
                claimInitialFocus()
            }
            .onChange(of: visibleCardIDs) { _, ids in
                if initialFocusPending {
                    claimInitialFocus()
                } else if let current = focusedVideo, !ids.contains(current),
                          let firstCardID {
                    focusedVideo = firstCardID
                }
            }
            .onChange(of: loading) { _, _ in claimInitialFocus() }
            .onChange(of: loadingRecent) { _, _ in claimInitialFocus() }
            .onChange(of: recommendationsLoaded) { _, _ in claimInitialFocus() }
            .onExitCommand { handleHomeBack(scroll: scroll) }
            .onDisappear { resumeMetadata.stop() }
        }
        } // GeometryReader: original ScrollView height; zoom its content only.
    }

    /// The only Home entrypoint for recommendation and resume tiles.
    /// .equatable() prevents rebuilding the entire lazy card factory when
    /// @FocusState changes, while each tile's own focus binding and badges
    /// continue updating normally. Never compare closure identities.
    private func videoCollection(_ items: [VideoItem], resume: Bool,
                                 scroll: ScrollViewProxy) -> some View {
        let snapshot = TVHomeCollectionSnapshot(
            items: items, scope: api.metadataCacheScope, resume: resume,
            columns: columns.count,
            canLoadMore: resume
                ? (historyHasMore && !loadingRecent && !historyLoadingMore)
                : (nextCursor != nil && !loading && !loadingMore && pageError == nil)
        )
        return TVHomeBaselineVideoCollection(
            snapshot: snapshot, api: api, focus: $focusedVideo,
            homeMenu: homeMenu,
            onRevealMenu: { id in
                detailReturnCardID = nil
                railReturnCardID = id
                onRevealMenu()
            },
            onReturnToList: { id, railScroll in
                if let video = items.first(where: { cardID($0, resume: resume) == id }) {
                    updateResumeAfterDetail(video)
                }
                // SwiftUI restores the native saved focus on detail pop.
                // The mounted recommendation grid keeps its scroll offset;
                // only a horizontal resume card needs its two rails revealed.
                let target = visibleCardIDs.contains(id) ? id : firstCardID
                detailReturnCardID = target
                var transaction = Transaction()
                transaction.disablesAnimations = true
                withTransaction(transaction) {
                    if resume, target == id {
                        scroll.scrollTo("home-continue-watching-row", anchor: .center)
                        railScroll?.scrollTo(id, anchor: .center)
                    }
                    focusedVideo = target
                }
            },
            onApproachEnd: {
                Task {
                    if resume { await loadMoreHistory() }
                    else { await loadMore() }
                }
            },
            onResumeAppear: { index, items in
                guard previewVideos == nil else { return }
                resumeMetadata.cardAppeared(
                    at: index, visibleHistory: items, api: api,
                    onBatch: { details in applyResumeMetadata(details) }
                )
            },
            onResumeDisappear: { video in
                resumeMetadata.disappear(video)
            },
            onNavigation: { resumeMetadata.noteNavigation() }
        )
        .equatable()
    }

    // Local SABR/HLS progress is recorded on player stop. Promote just this
    // video into Continue Watching, without fetching /history or touching
    // Home recommendations. No change is emitted when progress is unchanged.
    @MainActor
    private func updateResumeAfterDetail(_ video: VideoItem) {
        guard previewVideos == nil, showRecent else { return }
        let updated = TVContinueWatchingLocalUpdate.applying(
            recentVideos, video: video,
            positionMs: TVLocalProgress.shared.position(for: video.url)
        )
        guard updated != recentVideos else { return }
        recentVideos = updated
        resumeMetadata.reconcile(with: updated)
    }

    @MainActor
    private func claimInitialFocus() {
        guard initialFocusPending else { return }
        if let firstCardID {
            initialFocusPending = false
            // Re-enter the exact row/card we left; use the first only if
            // that video disappeared from the newly loaded collection.
            focusedVideo = TVHomeReturnFocusPolicy.target(
                saved: railReturnCardID,
                visibleIDs: Set(visibleCardIDs),
                fallback: firstCardID
            )
            onInitialFocusReady()
        } else if recommendationsLoaded &&
                  (!showRecent || (!loadingRecent && historyLoadedOnce)) {
            initialFocusPending = false
            onInitialFocusReady()
        }
    }

    @MainActor
    private func handleHomeBack(scroll: ScrollViewProxy) {
        guard let firstCardID else { onRevealMenu(); return }
        if focusedVideo == firstCardID {
            detailReturnCardID = nil
            railReturnCardID = firstCardID
            onRevealMenu()
        } else {
            detailReturnCardID = firstCardID
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                scroll.scrollTo(
                    firstCardID.hasPrefix("recent-")
                        ? "home-continue-watching-row" : firstCardID,
                    anchor: .center
                )
                focusedVideo = firstCardID
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
        if recentVideos.contains(where: { item in pending.contains { $0.removes(item) } }) {
            recentVideos.removeAll { item in pending.contains { $0.removes(item) } }
            resumeMetadata.reconcile(with: recentVideos)
        }
    }

    @MainActor
    private func refresh() async {
        await contentPreferences.ensureLoaded(api: api)
        if !showRecommendations {
            // Honor the setting without ever querying /recommendations/home.
            recommendationsLoaded = true
        }
        if showRecent && showRecommendations {
            async let recommendations: Void = reload()
            async let history: Void = loadHistory()
            _ = await (recommendations, history)
        } else if showRecent {
            await loadHistory()
        } else if showRecommendations {
            await reload()
        }
    }

    // One data mutation per idle metadata batch. This runs only after
    // background extraction and never from the focus/event rendering path.
    @MainActor
    private func applyResumeMetadata(_ details: [String: StreamInfo]) {
        guard !details.isEmpty, showRecent else { return }
        let updated = recentVideos.map { video in
            guard let stream = details[TVHistoryDeduplicator.key(for: video)] else {
                return video
            }
            return TVVideoMetadata.merged(video, stream: stream)
        }
        if updated != recentVideos { recentVideos = updated }
    }

    @MainActor
    private func reload() async {
        guard !loading else { return }
        loading = true
        error = nil
        pageError = nil
        // Keep the old cursor until the replacement feed succeeds. A
        // transient refresh failure must not disable paging existing cards.
        defer {
            loading = false
            recommendationsLoaded = true
        }
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
            nextCursor = TVHomePagingPolicy.nextCursor(page)
            let enriched = await api.withProgress(page.items)
            guard !Task.isCancelled else { return }
            videos = enriched
            // A feed can finish after history: enrich only on completed loads.
            let updated = TVVideoMetadata.reusingRecommendationMetadata(
                recentVideos, from: enriched
            )
            if updated != recentVideos {
                recentVideos = updated
                resumeMetadata.reconcile(with: updated)
            }
        } catch is CancellationError {
            return
        } catch {
            self.error = error.localizedDescription
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
            // Avoid TWO full LazyVGrid updates for every page. First
            // resolve progress off the UI path, then append only the new
            // video rows in a single state mutation. Existing cards and
            // their focus/thumbnail state are never replaced.
            var known = Set(videos.map(\.url))
            let added = page.items.filter { known.insert($0.url).inserted }
            let enriched = await api.withProgress(added)
            // A manual refresh or another navigation may invalidate this
            // request while the progress/batch endpoint is in flight.
            guard !Task.isCancelled, !loading, nextCursor == cursor else { return }
            nextCursor = TVHomePagingPolicy.nextCursor(page, after: cursor)
            videos.append(contentsOf: enriched)
            // Paginated recommendations may match older resume entries.
            let updated = TVVideoMetadata.reusingRecommendationMetadata(
                recentVideos, from: enriched
            )
            if updated != recentVideos {
                recentVideos = updated
                resumeMetadata.reconcile(with: updated)
            }
        } catch is CancellationError {
            return
        } catch {
            pageError = error.localizedDescription
        }
    }

    // History is entirely opt-in. Its data source is independent of
    // recommendation pagination and never causes a per-card network call.
    @MainActor
    private func loadHistory() async {
        guard previewVideos == nil && showRecent && !loadingRecent else { return }
        let request = UUID()
        historyRequestID = request
        historyLoadedOnce = true
        loadingRecent = true
        historyHasMore = false
        defer {
            if historyRequestID == request { loadingRecent = false }
        }
        do {
            let raw = try await api.historyPage(offset: 0, limit: historyPageSize)
            guard !Task.isCancelled && historyRequestID == request else { return }
            let unique = TVHistoryDeduplicator.unique(raw)
            let enriched = await api.withProgress(unique)
            guard !Task.isCancelled && historyRequestID == request else { return }
            recentVideos = TVVideoMetadata.reusingRecommendationMetadata(
                enriched, from: videos
            )
            resumeMetadata.reconcile(with: recentVideos)
            // Do not wait for LazyHStack.onAppear. The first visible cards
            // and three lookahead cards can start fetching as soon as the
            // history/progress response is ready, even before TV focus moves.
            resumeMetadata.prime(
                visibleHistory: filteredRecent(), api: api,
                onBatch: { details in applyResumeMetadata(details) }
            )
            historyOffset = raw.count
            historyHasMore = raw.count == historyPageSize
            recentNeedsLogin = false
            recentError = nil
        } catch is CancellationError {
            return
        } catch {
            guard historyRequestID == request else { return }
            recentVideos = []
            historyOffset = 0
            historyHasMore = false
            let status = TVServerErrorMapping.httpStatus(error)
            recentNeedsLogin = status == 401 || status == 403
            recentError = recentNeedsLogin ? nil : error.localizedDescription
        }
    }

    @MainActor
    private func loadMoreHistory() async {
        guard previewVideos == nil && showRecent && historyHasMore &&
              !loadingRecent && !historyLoadingMore else { return }
        let request = historyRequestID
        historyLoadingMore = true
        defer {
            if historyRequestID == request { historyLoadingMore = false }
        }
        do {
            var offset = historyOffset
            var hasMore = historyHasMore
            var fresh: [VideoItem] = []
            // Multiple raw history events may describe the same video.
            // Do not replace the existing shelf or repeatedly fetch its
            // membership/metadata when paginating over duplicates.
            for _ in 0..<10 {
                let raw = try await api.historyPage(
                    offset: offset, limit: historyPageSize
                )
                try Task.checkCancellation()
                guard historyRequestID == request else { return }
                offset += raw.count
                hasMore = raw.count == historyPageSize
                fresh = TVHistoryDeduplicator.appendUnique(
                    raw, to: recentVideos
                )
                if !fresh.isEmpty || !hasMore { break }
            }
            historyOffset = offset
            historyHasMore = hasMore
            guard !fresh.isEmpty else { return }
            let enriched = await api.withProgress(fresh)
            guard !Task.isCancelled && historyRequestID == request else { return }
            recentVideos.append(contentsOf:
                TVVideoMetadata.reusingRecommendationMetadata(enriched, from: videos)
            )
            resumeMetadata.reconcile(with: recentVideos)
        } catch is CancellationError {
            return
        } catch {
            guard historyRequestID == request else { return }
            historyHasMore = false
        }
    }

}

/// Metadata is primed from Home's loaded history, not by cell appearance.
/// LazyHStack.onAppear is only needed when scrolling to additional videos.
enum TVHomeResumeMetadataPolicy {
    static let visibleCards = 4
    static let preloadCards = 3
    static let maxTrackedCards = visibleCards + preloadCards
    static func needsLookup(_ video: VideoItem) -> Bool {
        video.viewCount == nil || (video.viewCount ?? -1) <= 0 ||
            TVVideoMetadata.publicationDate(for: video) == nil
    }
}

@MainActor
final class TVHomeResumeMetadataLoader {
    private struct Request {
        let key: String
        let video: VideoItem
    }

    private let fetch: @MainActor (VideoItem, TypeTypeAPI) async -> StreamInfo?
    private var scope = ""
    private var generation = 0
    private var activeKeys: [String] = []
    private var pending: [Request] = []
    private var attempted = Set<String>()
    // Keep metadata for the tiny visible window across history refreshes.
    // The global TVStreamMetadataCache provides the broader 128-entry cache.
    private var known: [String: StreamInfo] = [:]
    private var completed: [String: StreamInfo] = [:]
    // Three bounded concurrent lookups from the existing stream cache.
    // No startup timer, SwiftUI per-card task or observer.
    private var inFlight: [String: Task<Void, Never>] = [:]
    private var flushTask: Task<Void, Never>?
    private var lastNavigation = Date.distantPast
    private var onBatch: (@MainActor ([String: StreamInfo]) -> Void)?

    init(fetch: @escaping @MainActor (VideoItem, TypeTypeAPI) async -> StreamInfo? = {
        video, api in
        await TVStreamMetadataCache.shared.details(for: video, api: api)
    }) {
        self.fetch = fetch
    }

    // Called after initial /history and progress enrichment; works even
    // when SwiftUI has not emitted a single LazyHStack.onAppear event.
    func prime(visibleHistory: [VideoItem], api: TypeTypeAPI,
               onBatch: @escaping @MainActor ([String: StreamInfo]) -> Void) {
        for video in visibleHistory.prefix(TVHomeResumeMetadataPolicy.maxTrackedCards) {
            appear(video: video, api: api, onBatch: onBatch)
        }
    }

    // Scrolling extends the already-prefetched window by three more
    // candidates. Before the first seven have appeared, no extra work is
    // scheduled: the initial prime() already handles that entire window.
    func cardAppeared(at index: Int, visibleHistory: [VideoItem], api: TypeTypeAPI,
                      onBatch: @escaping @MainActor ([String: StreamInfo]) -> Void) {
        guard index >= 0, index < visibleHistory.count else { return }
        let count = index < TVHomeResumeMetadataPolicy.maxTrackedCards
            ? 1 : TVHomeResumeMetadataPolicy.preloadCards + 1
        for video in visibleHistory.dropFirst(index).prefix(count) {
            appear(video: video, api: api, onBatch: onBatch)
        }
    }

    func appear(video: VideoItem, api: TypeTypeAPI,
                onBatch: @escaping @MainActor ([String: StreamInfo]) -> Void) {
        let nextScope = api.metadataCacheScope
        if scope != nextScope {
            stop()
            scope = nextScope
        }
        self.onBatch = onBatch
        let key = TVHistoryDeduplicator.key(for: video)
        // A prefetched card may later receive onAppear. Do not reorder
        // it and evict another visible card just for that appearance event.
        if !activeKeys.contains(key) { activeKeys.append(key) }
        // Keep just four visible cards plus three forward candidates.
        while activeKeys.count > TVHomeResumeMetadataPolicy.maxTrackedCards {
            let discarded = activeKeys.removeFirst()
            pending.removeAll { $0.key == discarded }
            completed[discarded] = nil
            known[discarded] = nil
        }
        guard TVHomeResumeMetadataPolicy.needsLookup(video) else {
            pending.removeAll { $0.key == key }
            completed[key] = nil
            return
        }
        if let cached = known[key] {
            completed[key] = cached
            scheduleFlush()
            return
        }
        guard !attempted.contains(key), !pending.contains(where: { $0.key == key }) else {
            return
        }
        pending.append(Request(key: key, video: video))
        start(api: api)
    }

    func disappear(_ video: VideoItem) {
        let key = TVHistoryDeduplicator.key(for: video)
        activeKeys.removeAll { $0 == key }
        pending.removeAll { $0.key == key }
        completed[key] = nil
    }

    func reconcile(with history: [VideoItem]) {
        let complete = Set(history.filter { !TVHomeResumeMetadataPolicy.needsLookup($0) }
            .map { TVHistoryDeduplicator.key(for: $0) })
        pending.removeAll { complete.contains($0.key) }
        for key in complete { completed[key] = nil }
        // History refreshes do not promise metadata. Reapply just the small
        // visible cache without fetching or depending on cell reappearance.
        for row in history where TVHomeResumeMetadataPolicy.needsLookup(row) {
            let key = TVHistoryDeduplicator.key(for: row)
            if activeKeys.contains(key), let details = known[key] {
                completed[key] = details
            }
        }
        scheduleFlush()
    }

    func noteNavigation() {
        // Plain reference mutation, no @Published, @State or new Task.
        lastNavigation = Date()
    }

    func stop() {
        generation &+= 1
        for task in inFlight.values { task.cancel() }
        inFlight.removeAll()
        flushTask?.cancel()
        flushTask = nil
        pending.removeAll()
        activeKeys.removeAll()
        attempted.removeAll()
        known.removeAll()
        completed.removeAll()
        onBatch = nil
        scope = ""
    }

    private func start(api: TypeTypeAPI) {
        // Loading starts immediately from the /history completion, not
        // from a remote movement or a 350-ms grace period.
        fillSlots(api: api)
    }

    private func fillSlots(api: TypeTypeAPI) {
        // The shared TVStreamMetadataCache already caps total stream
        // extractions at three. This view also caps its own outstanding work
        // at three, instead of awaiting each lookup sequentially.
        while inFlight.count < 3 && !pending.isEmpty {
            let request = pending.removeFirst()
            guard activeKeys.contains(request.key),
                  !attempted.contains(request.key) else { continue }
            attempted.insert(request.key)
            let expected = generation
            inFlight[request.key] = Task(priority: .utility) { [weak self] in
                guard let self, self.generation == expected else { return }
                // A cell can disappear before this task gets CPU time.
                // Free its reserved slot instead of permanently stalling
                // the remaining visible window.
                guard !Task.isCancelled,
                      self.activeKeys.contains(request.key) else {
                    self.inFlight[request.key] = nil
                    self.attempted.remove(request.key)
                    self.fillSlots(api: api)
                    return
                }
                // The await suspends this task, not the Home render or the
                // other two lookups. Identical URLs share the existing cache.
                let details = await self.fetch(request.video, api)
                guard self.generation == expected else { return }
                self.inFlight[request.key] = nil

                if !Task.isCancelled {
                    if let details, self.activeKeys.contains(request.key) {
                        self.known[request.key] = details
                        self.completed[request.key] = details
                        self.scheduleFlush()
                    } else if !self.activeKeys.contains(request.key) {
                        // A recycled/offscreen tile is eligible on re-entry.
                        self.attempted.remove(request.key)
                    }
                }

                // Refill only a released slot. A single slow server request
                // cannot block metadata for the other visible cards.
                self.fillSlots(api: api)
            }
        }
    }

    private func scheduleFlush() {
        guard !completed.isEmpty, flushTask == nil else { return }
        let expected = generation
        flushTask = Task(priority: .utility) { [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard let self, !Task.isCancelled, self.generation == expected else {
                return
            }
            // Do not invalidate EquatableView while the remote is moving.
            // Navigation just updates a timestamp; only this one task waits.
            while self.generation == expected && !Task.isCancelled &&
                  Date().timeIntervalSince(self.lastNavigation) < 0.55 {
                try? await Task.sleep(for: .milliseconds(200))
            }
            guard self.generation == expected && !Task.isCancelled else { return }
            let batch = self.completed.filter { self.activeKeys.contains($0.key) }
            self.completed.removeAll()
            self.flushTask = nil
            if !batch.isEmpty {
                self.onBatch?(batch)
            }
        }
    }
}

