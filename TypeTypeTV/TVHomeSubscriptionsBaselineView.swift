import SwiftUI

/// Native subscriptions-style Home with an optional horizontal resume shelf.
/// Both sections share one stable video-tile builder, one lightweight menu
/// coordinator and one card-attached Liquid Glass feedback surface.
/// No legacy Home focusScope, rail-width freezing or per-tile menu state.
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
    let resume: Bool
    let columns: Int
    let focus: FocusState<String?>.Binding
    let homeMenu: TVHomeMenuCoordinator
    let onRevealMenu: () -> Void
    let onReturnToList: () -> Void
    let onChanged: () -> Void
    let onNavigation: () -> Void

    private var focusID: String {
        (resume ? "recent-" : "recommendation-") + entry.video.url
    }

    var body: some View {
        let video = entry.video
        let id = focusID
        // Use one read for both zIndex and the DEBUG counter. The Home
        // parent never reads this binding during ordinary navigation.
        let activeFocusID = focus.wrappedValue
        #if DEBUG
        let _ = TVHomeFocusDiagnostics.tileBody(focusedID: activeFocusID)
        #endif
        let link = NavigationLink {
            VideoDetailView(
                api: api, video: video,
                onReturnToList: onReturnToList
            )
        } label: {
            VideoCard(api: api, video: video, diagnoseHomeFocus: true)
        }
        .buttonStyle(TVRailButtonStyle())
        .focusEffectDisabled(true)
        .zIndex(activeFocusID == id ? 5 : 0)
        .id(id)
        .modifier(TVHomeLightweightVideoActions(
            api: api, video: video, model: homeMenu,
            focus: focus, focusID: id,
            onChanged: onChanged
        ))
        .onMoveCommand { direction in
            // No SwiftUI state change: just defer metadata-driven row updates
            // while remote navigation is active.
            onNavigation()
            if direction == .left &&
               (resume ? entry.index == 0 : entry.index % columns == 0) {
                onRevealMenu()
            }
        }
        .accessibilityIdentifier(resume
            ? "home-baseline-recent-\(entry.index)"
            : "home-baseline-video-\(entry.index)")

        if resume {
            link.containerRelativeFrame(.horizontal, count: 4, spacing: 26)
        } else {
            link
        }
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
/// The two section layouts use the same TVHomeBaselineTile.
private struct TVHomeBaselineVideoCollection: View, Equatable {
    let snapshot: TVHomeCollectionSnapshot
    let api: TypeTypeAPI
    let focus: FocusState<String?>.Binding
    let homeMenu: TVHomeMenuCoordinator
    let onRevealMenu: () -> Void
    let onReturnToList: (String) -> Void
    let onChanged: () -> Void
    let onApproachEnd: () -> Void
    let onResumeAppear: (VideoItem) -> Void
    let onResumeDisappear: (VideoItem) -> Void
    let onNavigation: () -> Void

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.snapshot == rhs.snapshot && lhs.homeMenu === rhs.homeMenu
    }

    @ViewBuilder
    var body: some View {
        if snapshot.resume {
            ScrollView(.horizontal) {
                LazyHStack(alignment: .center, spacing: 26) {
                    entries
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
        } else {
            LazyVGrid(columns: Array(repeating:
                GridItem(.flexible(), spacing: 26), count: snapshot.columns),
                spacing: 32) {
                entries
            }
            .focusSection()
        }
    }

    private var entries: some View {
        ForEach(snapshot.items.enumerated().map {
            TVHomeBaselineGridEntry(index: $0.offset, video: $0.element)
        }) { entry in
            let id = (snapshot.resume ? "recent-" : "recommendation-") +
                entry.video.url
            #if DEBUG
            let _ = TVHomeFocusDiagnostics.hit(.tileBuild)
            #endif
            TVHomeBaselineTile(
                api: api, entry: entry, resume: snapshot.resume,
                columns: snapshot.columns, focus: focus, homeMenu: homeMenu,
                onRevealMenu: onRevealMenu,
                onReturnToList: { onReturnToList(id) },
                onChanged: onChanged, onNavigation: onNavigation
            )
            .onAppear {
                if snapshot.resume { onResumeAppear(entry.video) }
                #if DEBUG
                TVHomeFocusDiagnostics.hit(snapshot.resume
                    ? .resumeAppear : .recommendationAppear)
                #endif
                let threshold = snapshot.resume ? 2 : snapshot.columns + 1
                if snapshot.canLoadMore &&
                    entry.index >= snapshot.items.count - threshold {
                    onApproachEnd()
                }
            }
            .onDisappear {
                if snapshot.resume { onResumeDisappear(entry.video) }
            }
        }
    }
}

struct TVHomeSubscriptionsBaselineView: View {
    let api: TypeTypeAPI
    let previewVideos: [VideoItem]?
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
        #if DEBUG
        return TVHomeFocusDiagnostics.measure(.filterRecommendations) {
            contentPreferences.displayed(videos)
        }
        #else
        return contentPreferences.displayed(videos)
        #endif
    }
    private var visibleRecent: [VideoItem] {
        #if DEBUG
        return TVHomeFocusDiagnostics.measure(.filterRecent) {
            filteredRecent()
        }
        #else
        return filteredRecent()
        #endif
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
        #if DEBUG
        return TVHomeFocusDiagnostics.measure(.buildFocusIDs) {
            buildCardIDs()
        }
        #else
        return buildCardIDs()
        #endif
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
         focusRequest: Int = 0, onRevealMenu: @escaping () -> Void = {},
         onOpenAccount: @escaping () -> Void = {},
         onInitialFocusReady: @escaping () -> Void = {}) {
        self.api = api
        self.previewVideos = previewVideos
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
        #if DEBUG
        // Only count the parent render. Reading focusedVideo here would
        // itself force the parent to update on each focus change, corrupting
        // the result of this focus-isolation experiment.
        let _ = TVHomeFocusDiagnostics.homeBody(
            focusedID: nil, recommendations: videos.count,
            recent: recentVideos.count
        )
        #endif
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
                        if previewVideos == nil { TVHomeComparisonMenu() }
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
                            }
                        }
                    }
                }
                .padding(.horizontal, 65)
                .padding(.top, 42)
                .padding(.bottom, 120)
            }
            .background(TTTheme.ink)
            // Shared by BOTH sources. No per-card dialog or toast state.
            .modifier(TVHomeMenuPresentation(model: homeMenu))
            .onChange(of: homeMenu.focusRestoreRequest) { _, _ in
                if let id = homeMenu.focusRestoreTarget { focusedVideo = id }
            }
            .task {
                await TVWatchLaterMembership.shared.ensureLoaded(api: api)
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
            homeMenu: homeMenu, onRevealMenu: onRevealMenu,
            onReturnToList: { id in
                TVVideoFocusReturn.restore($focusedVideo, id: id, scroll: scroll)
            },
            onChanged: {
                Task {
                    if resume { await loadHistory() }
                    else { await reload() }
                }
            },
            onApproachEnd: {
                Task {
                    if resume { await loadMoreHistory() }
                    else { await loadMore() }
                }
            },
            onResumeAppear: { video in
                guard previewVideos == nil else { return }
                resumeMetadata.appear(
                    video: video, api: api,
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

    @MainActor
    private func claimInitialFocus() {
        guard initialFocusPending else { return }
        if let firstCardID {
            initialFocusPending = false
            focusedVideo = firstCardID
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
            onRevealMenu()
        } else {
            TVVideoFocusReturn.restore($focusedVideo, id: firstCardID,
                                       scroll: scroll)
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
        nextCursor = nil
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
            nextCursor = page.nextCursor?.isEmpty == false ? page.nextCursor : nil
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
        #if DEBUG
        TVHomeFocusDiagnostics.hit(.pageRequest)
        #endif
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
            nextCursor = page.nextCursor?.isEmpty == false &&
                page.nextCursor != cursor ? page.nextCursor : nil
            videos.append(contentsOf: enriched)
            // Paginated recommendations may match older resume entries.
            let updated = TVVideoMetadata.reusingRecommendationMetadata(
                recentVideos, from: enriched
            )
            if updated != recentVideos {
                recentVideos = updated
                resumeMetadata.reconcile(with: updated)
            }
            #if DEBUG
            TVHomeFocusDiagnostics.hit(.pageAppend)
            #endif
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

/// No stream extraction is attached to VideoCard. Loading is driven solely by
/// LazyHStack onAppear/onDisappear and runs only for a small, recent window.
enum TVHomeResumeMetadataPolicy {
    static let maxTrackedCards = 6
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
    private var completed: [String: StreamInfo] = [:]
    private var worker: Task<Void, Never>?
    private var flushTask: Task<Void, Never>?
    private var lastNavigation = Date.distantPast
    private var onBatch: (([String: StreamInfo]) -> Void)?

    init(fetch: @escaping @MainActor (VideoItem, TypeTypeAPI) async -> StreamInfo? = {
        video, api in
        await TVStreamMetadataCache.shared.details(for: video, api: api)
    }) {
        self.fetch = fetch
    }

    func appear(video: VideoItem, api: TypeTypeAPI,
                onBatch: @escaping ([String: StreamInfo]) -> Void) {
        let nextScope = api.metadataCacheScope
        if scope != nextScope {
            stop()
            scope = nextScope
        }
        self.onBatch = onBatch
        let key = TVHistoryDeduplicator.key(for: video)
        activeKeys.removeAll { $0 == key }
        activeKeys.append(key)
        // tvOS may pre-create cells ahead of the viewport. Retain only the
        // four visible cards plus two likely neighbors, not all 100 history rows.
        while activeKeys.count > TVHomeResumeMetadataPolicy.maxTrackedCards {
            let discarded = activeKeys.removeFirst()
            pending.removeAll { $0.key == discarded }
            completed[discarded] = nil
        }
        guard TVHomeResumeMetadataPolicy.needsLookup(video) else {
            pending.removeAll { $0.key == key }
            completed[key] = nil
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
        guard !complete.isEmpty else { return }
        pending.removeAll { complete.contains($0.key) }
        for key in complete { completed[key] = nil }
    }

    func noteNavigation() {
        // Plain reference mutation, no @Published, @State or new Task.
        lastNavigation = Date()
    }

    func stop() {
        generation &+= 1
        worker?.cancel()
        worker = nil
        flushTask?.cancel()
        flushTask = nil
        pending.removeAll()
        activeKeys.removeAll()
        attempted.removeAll()
        completed.removeAll()
        onBatch = nil
        scope = ""
    }

    private func start(api: TypeTypeAPI) {
        guard worker == nil, !pending.isEmpty else { return }
        let currentGeneration = generation
        worker = Task(priority: .utility) { [weak self] in
            // Allow initial recommendations to finish and scrolling to settle.
            try? await Task.sleep(for: .milliseconds(350))
            guard let self, !Task.isCancelled,
                  self.generation == currentGeneration else { return }
            await self.drain(api: api, generation: currentGeneration)
        }
    }

    private func drain(api: TypeTypeAPI, generation expected: Int) async {
        defer {
            if generation == expected { worker = nil }
        }
        // Exactly one sequential fetch, even when the system cache permits
        // three other callers. Never fetch merely because focus changed.
        while generation == expected && !Task.isCancelled && !pending.isEmpty {
            let request = pending.removeFirst()
            guard activeKeys.contains(request.key) else { continue }
            attempted.insert(request.key)
            #if DEBUG
            TVHomeFocusDiagnostics.hit(.resumeMetadataLookup)
            #endif
            let details = await fetch(request.video, api)
            guard generation == expected && !Task.isCancelled else { return }
            if let details, activeKeys.contains(request.key) {
                completed[request.key] = details
                scheduleFlush()
            } else if !activeKeys.contains(request.key) {
                // An abandoned attempt may be retried if the card reappears.
                attempted.remove(request.key)
            }
        }
        scheduleFlush()
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
                #if DEBUG
                TVHomeFocusDiagnostics.hit(.resumeMetadataBatch)
                #endif
                self.onBatch?(batch)
            }
        }
    }
}

