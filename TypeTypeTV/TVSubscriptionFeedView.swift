import SwiftUI

/// Stable cursor-based account feed. TypeType's server-side snapshot avoids
/// querying every subscribed channel on the Apple TV.
struct TVSubscriptionFeedView: View {
    let api: TypeTypeAPI
    @ObservedObject private var contentPreferences = TVContentPreferences.shared
    var focusRequest = 0
    var fixedLayoutWidth: CGFloat?
    var onRevealMenu: () -> Void = {}

    @State private var videos: [VideoItem] = []
    @State private var feedOrder: TVSubscriptionFeedOrder = .newest
    @State private var dateRange: TVSubscriptionFeedDateRange = .all
    @State private var watchedSettingSaving = false
    @State private var watchedSettingError: String?
    @State private var emptyPageStreak = 0
    private var hideWatched: Bool {
        contentPreferences.settings?.hideWatchedSubscriptionVideos == true
    }
    private var visibleVideos: [VideoItem] {
        TVSubscriptionFeedFilter.visible(
            contentPreferences.displayed(videos),
            hideWatched: hideWatched,
            dateRange: dateRange,
            thresholdPercent: contentPreferences.watchedThresholdPercent,
            position: { item in
                TVLocalProgress.shared.position(for: item.url) ?? item.watchPositionMs
            }
        )
    }
    private var canAutomaticallyLoad: Bool {
        nextCursor != nil && !loading && !loadingMore && pageError == nil &&
            TVSubscriptionAutoLoadPolicy.mayAutoLoad(emptyPageStreak)
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
    @FocusState private var focusedHeader: HeaderControl?
    @State private var headerReturnVideoID: String?
    private enum HeaderControl: Hashable {
        case watched, order, date, refresh
    }
    @State private var railReturnVideoID: String?
    @State private var detailReturnVideoID: String?
    @State private var mutationCursor = TVVideoMutationCursor()
    @StateObject private var videoMenu = TVHomeMenuCoordinator()
    private let columns = Array(repeating: GridItem(.flexible(), spacing: 26), count: 4)

    var body: some View {
        GeometryReader { viewport in
        let layoutWidth = fixedLayoutWidth ?? viewport.size.width
        ScrollViewReader { scroll in
            ScrollView {
            VStack(alignment: .leading, spacing: 27) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("nav.subscriptions")
                        .font(.subheadline.bold()).tracking(2.3)
                        .foregroundStyle(TTTheme.accent)
                    Text("subscriptions.feedTitle")
                        .font(.system(size: 45, weight: .bold))
                }
                // Native focus controls stay mounted when the feed changes.
                // Opening the feed focuses the first video. Only Up from a
                // first-row tile enters this header; Down returns to that tile.
                HStack(spacing: 18) {
                    Button {
                        Task { await saveWatchedPreference(!hideWatched) }
                    } label: {
                        Label(
                            TVL10n.value(hideWatched
                                ? "subscriptions.feedShowWatched"
                                : "subscriptions.feedHideWatched"),
                            systemImage: hideWatched ? "eye.slash" : "eye"
                        )
                    }
                    .buttonStyle(.bordered)
                    .disabled(watchedSettingSaving)
                    .focused($focusedHeader, equals: .watched)
                    .accessibilityIdentifier("subscriptions-feed-watched")
                    .onMoveCommand { if $0 == .down { returnToVideoFromHeader() } }

                    Picker("subscriptions.feedOrder", selection: $feedOrder) {
                        Text("subscriptions.feedNewest").tag(TVSubscriptionFeedOrder.newest)
                        Text("subscriptions.feedOldest").tag(TVSubscriptionFeedOrder.oldest)
                    }
                    .pickerStyle(.menu)
                    .focused($focusedHeader, equals: .order)
                    .accessibilityIdentifier("subscriptions-feed-order")
                    .onMoveCommand { if $0 == .down { returnToVideoFromHeader() } }

                    Picker("subscriptions.feedDate", selection: $dateRange) {
                        Text("subscriptions.feedAllDates").tag(TVSubscriptionFeedDateRange.all)
                        Text("subscriptions.feedToday").tag(TVSubscriptionFeedDateRange.today)
                        Text("subscriptions.feedWeek").tag(TVSubscriptionFeedDateRange.week)
                        Text("subscriptions.feedMonth").tag(TVSubscriptionFeedDateRange.month)
                    }
                    .pickerStyle(.menu)
                    .focused($focusedHeader, equals: .date)
                    .accessibilityIdentifier("subscriptions-feed-date")
                    .onMoveCommand { if $0 == .down { returnToVideoFromHeader() } }

                    Spacer(minLength: 12)
                    Button("common.refresh") {
                        Task { await refreshFeed() }
                    }
                    .buttonStyle(.bordered)
                    .disabled(loading || loadingMore || watchedSettingSaving)
                    .focused($focusedHeader, equals: .refresh)
                    .accessibilityIdentifier("subscriptions-feed-refresh")
                    .onMoveCommand { if $0 == .down { returnToVideoFromHeader() } }
                }
                .focusSection()
                if let watchedSettingError {
                    Text(watchedSettingError)
                        .font(.callout)
                        .foregroundStyle(.red)
                        .accessibilityIdentifier("subscriptions-feed-watched-error")
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
                    // Without any visible tiles the lazy-grid sentinel
                    // cannot trigger. Keep manual pagination reachable.
                    if nextCursor != nil || pageError != nil {
                        Button("subscriptions.feedLoadMore") {
                            Task { await loadMore(manual: true) }
                        }
                        .buttonStyle(.bordered)
                        .disabled(loadingMore)
                    }
                } else {
                    TVSharedVideoGrid(
                        snapshot: TVSharedVideoGridSnapshot(
                            videos: visibleVideos, scope: api.metadataCacheScope,
                            destination: "subscriptions-feed",
                            focusPrefix: "",
                            accessibilityPrefix: "subscriptions-video-",
                            columns: columns.count, columnSpacing: 26,
                            rowSpacing: 32, canLoadMore: canAutomaticallyLoad,
                            loadAhead: columns.count + 1,
                            lookupMissingMetadata: false,
                            isWatchLaterEntry: false, playbackQueue: nil
                        ),
                        api: api, focus: $focusedVideo, menu: videoMenu,
                        onReturnToList: { id in
                            // No post-pop timer or scrollTo when the existing
                            // lazy grid remains mounted at its current offset.
                            detailReturnVideoID = id
                            focusedVideo = id
                            reconcileRecordedProgress()
                        },
                        onReturnedVideo: { _ in
                            reconcileRecordedProgress()
                        },
                        onLeftEdge: { id in
                            detailReturnVideoID = nil
                            railReturnVideoID = id
                            onRevealMenu()
                        },
                        onApproachEnd: { Task { await loadMore() } },
                        onTopEdge: { id in
                            headerReturnVideoID = id
                            let index = visibleVideos.firstIndex { $0.url == id } ?? 0
                            switch index % columns.count {
                            case 0: focusedHeader = .watched
                            case 1: focusedHeader = .order
                            case 2: focusedHeader = .date
                            default: focusedHeader = .refresh
                            }
                        }
                    )
                    .equatable()
                    if loadingMore {
                        ProgressView("settings.remoteLoading")
                            .frame(maxWidth: .infinity)
                    } else if nextCursor != nil || pageError != nil {
                        Button("subscriptions.feedLoadMore") {
                            Task { await loadMore(manual: true) }
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
            $focusedVideo,
            detailReturnVideoID ?? railReturnVideoID ?? visibleVideos.first?.url,
            priority: .userInitiated
        )
        .modifier(TVHomeMenuPresentation(model: videoMenu))
        .onReceive(TVVideoMutationCenter.shared.$events) { reconcileMutations($0) }
        .onReceive(TVLocalProgress.shared.$positions) { _ in
            // Only one screen-level observer, not one per video tile.
            // When a context action changes watched state, update the
            // affected values once. No HTTP request and no focus timer.
            if hideWatched { reconcileRecordedProgress() }
        }
        .onAppear { reconcileMutations(TVVideoMutationCenter.shared.events) }
        .onChange(of: feedOrder) { _, _ in
            emptyPageStreak = 0
            Task { await reload(replacing: true) }
        }
        .onChange(of: dateRange) { _, _ in
            emptyPageStreak = 0
        }
        .onChange(of: videoMenu.focusRestoreRequest) { _, _ in
            if let id = videoMenu.focusRestoreTarget,
               visibleVideos.contains(where: { $0.url == id }) {
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
            await contentPreferences.ensureLoaded(api: api)
            guard !loadedOnce else { return }
            loadedOnce = true
            await reload()
        }
        .task(id: focusRequest) {
            guard focusRequest > 0,
                  handledFocusRequest != focusRequest else { return }
            handledFocusRequest = focusRequest
            // Cross-device account toggle: fetch once when re-entering the
            // subscription page, never on individual tile/focus movement.
            if loadedOnce && !watchedSettingSaving {
                await refreshAccountSettings()
            }
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
            guard focusRequest > 0 else { return }
            if urls.isEmpty {
                if focusedVideo != nil {
                    focusedVideo = nil
                    focusedHeader = .watched
                }
                return
            }
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
                detailReturnVideoID = nil
                railReturnVideoID = focusedVideo
                onRevealMenu()
            }
        }
        }
        } // GeometryReader keeps the grid width constant across menu zoom.
    }

    @MainActor
    private func returnToVideoFromHeader() {
        let target = headerReturnVideoID.flatMap { saved in
            visibleVideos.first(where: { $0.url == saved })?.url
        } ?? visibleVideos.first?.url
        if let target { focusedVideo = target }
    }

    @MainActor
    private func reconcileRecordedProgress() {
        guard hideWatched else { return }
        let threshold = contentPreferences.watchedThresholdPercent
        var changed: [VideoItem]?
        for index in videos.indices {
            let video = videos[index]
            guard let position = TVLocalProgress.shared.position(for: video.url) else {
                continue
            }
            let oldState = TVWatchedState.isWatched(
                video, positionMs: video.watchPositionMs,
                thresholdPercent: threshold
            )
            let newState = TVWatchedState.isWatched(
                video, positionMs: position,
                thresholdPercent: threshold
            )
            guard oldState != newState else { continue }
            if changed == nil { changed = videos }
            changed?[index] = video.withProgress(
                position, thresholdPercent: threshold
            )
        }
        if let changed { videos = changed }
    }

    @MainActor
    private func saveWatchedPreference(_ hidden: Bool) async {
        guard !watchedSettingSaving else { return }
        watchedSettingSaving = true
        watchedSettingError = nil
        defer { watchedSettingSaving = false }
        do {
            let result = try await api.setAccountSetting(
                "hideWatchedSubscriptionVideos", value: .boolean(hidden)
            )
            // An older server might ignore unrecognised settings but still
            // return 200. Only a matching value is a confirmed save.
            guard result.hideWatchedSubscriptionVideos == hidden else {
                watchedSettingError = TVL10n.value(
                    "subscriptions.feedSaveNotConfirmed"
                )
                return
            }
            contentPreferences.apply(result, api: api)
            emptyPageStreak = 0
        } catch {
            if let code = TVServerErrorMapping.httpStatus(error) {
                watchedSettingError = TVL10n.value(
                    "subscriptions.feedSaveHTTPFailed"
                ) + " (HTTP \(code))."
            } else {
                watchedSettingError = TVL10n.value(
                    "subscriptions.feedSaveFailed"
                ) + " " + error.localizedDescription
            }
        }
    }

    @MainActor
    private func refreshAccountSettings() async {
        guard !watchedSettingSaving else { return }
        do {
            let remote = try await api.accountSettings()
            contentPreferences.apply(remote, api: api)
        } catch {
            // This is an optional sync operation; the existing filter and
            // feed remain available if the instance is temporarily offline.
        }
    }

    @MainActor
    private func refreshFeed() async {
        await refreshAccountSettings()
        await reload(replacing: true)
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
    private func reload(replacing: Bool = false) async {
        guard !loading || replacing else { return }
        #if DEBUG
        if api.origin.host == "preview.invalid" {
            videos = TVShowcaseFixtures.videos
            nextCursor = nil
            emptyPageStreak = 0
            error = nil
            return
        }
        #endif
        let id = UUID()
        let requestedOrder = feedOrder
        requestID = id
        loading = true
        loadingMore = false
        preparing = false
        error = nil
        pageError = nil
        nextCursor = nil
        emptyPageStreak = 0
        defer {
            if requestID == id {
                loading = false
                preparing = false
            }
        }
        do {
            // 202 means the server is preparing a cursor snapshot, not that
            // the feed is empty. Keep the existing bounded retry policy.
            for _ in 0..<12 {
                let response = try await api.subscriptionFeed(order: requestedOrder)
                try Task.checkCancellation()
                guard requestID == id, feedOrder == requestedOrder else { return }
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
                // Publish the entire page only after its single batch of
                // progress is settled; watched videos must not flash on
                // screen and disappear a moment later.
                let enriched = await api.withProgress(received)
                guard !Task.isCancelled, requestID == id,
                      feedOrder == requestedOrder else { return }
                videos = enriched
                nextCursor = response.nextpage?.isEmpty == false
                    ? response.nextpage : nil
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
    private func loadMore(manual: Bool = false) async {
        guard !loading, !loadingMore, let cursor = nextCursor,
              manual || TVSubscriptionAutoLoadPolicy.mayAutoLoad(emptyPageStreak)
        else { return }
        loadingMore = true
        pageError = nil
        let id = requestID
        let requestedOrder = feedOrder
        let before = visibleVideos.count
        defer { if requestID == id { loadingMore = false } }
        do {
            let response = try await api.subscriptionFeed(
                cursor: cursor, order: requestedOrder
            )
            try Task.checkCancellation()
            guard requestID == id, feedOrder == requestedOrder,
                  nextCursor == cursor, let rows = response.videos else { return }
            let existing = Set(videos.map(\.url))
            var known = existing
            let added = rows.filter { known.insert($0.url).inserted }
            // Never append raw/unverified rows: the filter depends on the
            // progress/batch result, not a transient 0% assumption.
            let enriched = await api.withProgress(added)
            guard !Task.isCancelled, requestID == id,
                  feedOrder == requestedOrder, nextCursor == cursor else { return }
            videos.append(contentsOf: enriched)
            let next = response.nextpage?.isEmpty == false ? response.nextpage : nil
            nextCursor = next == cursor ? nil : next
            emptyPageStreak = TVSubscriptionAutoLoadPolicy.nextStreak(
                manual ? 0 : emptyPageStreak,
                visibleBefore: before, visibleAfter: visibleVideos.count
            )
        } catch is CancellationError {
            return
        } catch {
            if TVServerErrorMapping.httpStatus(error) == 409 {
                // A stale cursor needs one new snapshot; never loop over
                // the same invalid generation indefinitely.
                nextCursor = nil
                loadingMore = false
                await reload(replacing: true)
            } else if requestID == id {
                pageError = error.localizedDescription
            }
        }
    }
}
