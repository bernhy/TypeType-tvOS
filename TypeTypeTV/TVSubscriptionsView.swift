import SwiftUI

/// Account subscriptions are their own destination, not a second shortcut to
/// Playlists. Source: GET /api/subscriptions + GET /api/channel?url=...
struct TVSubscriptionsView: View {
    let api: TypeTypeAPI
    @ObservedObject private var contentPreferences = TVContentPreferences.shared
    var focusRequest = 0
    var fixedLayoutWidth: CGFloat?
    var onRevealMenu: () -> Void = {}
    /// When opened from a video's channel link, show this specific channel
    /// even if it is not part of the signed-in user's subscriptions.
    var directChannelURL: String? = nil
    var directChannelName: String? = nil
    @Environment(\.dismiss) private var dismiss

    @State private var subscriptions: [TVSubscription] = []
    // A nil membership list means "not checked", not "not subscribed".
    @State private var knownMemberships: [TVSubscription]?
    @State private var checkingMembership = false
    @State private var changingSubscription = false
    @State private var subscriptionErrorMessage: String?
    @State private var membershipRequestID = UUID()
    @State private var channelAvatarURL = ""
    @State private var channelBannerURL = ""
    @State private var selectedChannelURL: String?
    @State private var videos: [VideoItem] = []
    @State private var showingShorts = false
    @State private var videoSort = "latest"
    @State private var hasCourses = false
    @State private var channelTitle = ""
    @State private var channelDescription = ""
    @State private var nextPage: String?
    @State private var loadingSubscriptions = false
    @State private var loadingVideos = false
    @State private var channelRequestID = UUID()
    @State private var pageRequestID = UUID()
    @State private var initializedOnce = false
    @State private var handledFocusRequest: Int?
    @State private var lastLoadedChannelURL: String?
    @State private var loadingMore = false
    @State private var enterGridAfterLoad = false
    @State private var error: String?
    @State private var pageError: String?
    @FocusState private var focusedSubscription: String?
    // Suppress a geometrically chosen neighbor while returning from video
    // content; browsing Up/Down within this rail still works normally.
    @State private var railBrowsingVertically = false
    @State private var railReturnVideoID: String?
    @State private var detailReturnVideoID: String?
    @State private var mutationCursor = TVVideoMutationCursor()
    @StateObject private var videoMenu = TVHomeMenuCoordinator()
    @FocusState private var focusedVideo: String?
    @FocusState private var loadingRailFocused: Bool
    @FocusState private var subscriptionButtonFocused: Bool
    @FocusState private var focusedChannelTab: ChannelTab?
    @FocusState private var focusedAction: String?

    private enum ChannelTab: Hashable {
        case videos, shorts
    }

    private var currentSubscription: TVSubscription? {
        guard let selectedChannelURL, let knownMemberships else { return nil }
        return TVChannelSubscriptionMembership.entry(
            for: selectedChannelURL, in: knownMemberships
        )
    }

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 22), count: 3)
    private var visibleVideos: [VideoItem] { contentPreferences.displayed(videos) }
    private var preferredVideoID: String? {
        guard let target = detailReturnVideoID ?? railReturnVideoID,
              visibleVideos.contains(where: { $0.url == target }) else { return nil }
        return target
    }
    private var supportsShorts: Bool {
        guard let url = selectedChannelURL else { return false }
        #if DEBUG
        if api.origin.host == "preview.invalid" { return true }
        #endif
        let host = URLComponents(string: url)?.host?.lowercased() ?? ""
        return host == "youtube.com" || host.hasSuffix(".youtube.com")
    }

    var body: some View {
        HStack(alignment: .top, spacing: 25) {
            if directChannelURL == nil {
                channelRail
                    .frame(width: 285)
                    .environment(\.isFocusEffectEnabled, false)
                    .focusEffectDisabled(true)
                    .focusSection()
                    .defaultFocus(
                        $focusedSubscription, selectedChannelURL,
                        priority: .userInitiated
                    )
            }
            GeometryReader { viewport in
            let railWidth: CGFloat = directChannelURL == nil ? 310 : 0
            let layoutWidth = max(0, (fixedLayoutWidth ??
                (viewport.size.width + railWidth)) - railWidth)
            ScrollViewReader { scroll in
                ScrollView {
                    VStack(alignment: .leading, spacing: 28) {
                    VStack(alignment: .leading, spacing: 18) {
                    VStack(alignment: .leading, spacing: 9) {
                        Text(directChannelURL == nil
                             ? "subscriptions.kicker" : "channels.videos")
                            .font(.subheadline.bold())
                            .tracking(2)
                            .foregroundStyle(TTTheme.accent)
                        HStack(alignment: .center, spacing: 22) {
                            Text(channelTitle.isEmpty
                                 ? TVL10n.value("subscriptions.title") : channelTitle)
                                .font(.system(size: 39, weight: .bold))
                                .lineLimit(2)
                            Spacer(minLength: 12)
                            if let selectedChannelURL {
                                subscriptionButton(channelURL: selectedChannelURL)
                            }
                        }
                        if let subscriptionErrorMessage {
                            Text(subscriptionErrorMessage)
                                .font(.callout)
                                .foregroundStyle(.orange)
                                .lineLimit(3)
                                .accessibilityIdentifier("channel-subscription-error")
                        }
                        if !channelDescription.isEmpty {
                            Text(channelDescription)
                                .font(.callout)
                                .foregroundStyle(.white.opacity(0.82))
                                .lineLimit(3)
                        }
                    }
                    if supportsShorts && contentPreferences.settings?.hideShorts != true {
                        HStack(spacing: 15) {
                            Button("channels.videos") { showingShorts = false }
                                .tint(showingShorts ? TTTheme.muted : TTTheme.accent)
                                .focused($focusedChannelTab, equals: .videos)
                                .onMoveCommand { direction in
                                    if direction == .up {
                                        subscriptionButtonFocused = true
                                    } else if direction == .right {
                                        focusedChannelTab = .shorts
                                    } else if direction == .down {
                                        focusedAction = "playlists"
                                    }
                                }
                            Button("channels.shorts") { showingShorts = true }
                                .tint(showingShorts ? TTTheme.accent : TTTheme.muted)
                                .focused($focusedChannelTab, equals: .shorts)
                                .onMoveCommand { direction in
                                    if direction == .up || direction == .right {
                                        subscriptionButtonFocused = true
                                    } else if direction == .left {
                                        focusedChannelTab = .videos
                                    } else if direction == .down {
                                        focusedAction = "playlists"
                                    }
                                }
                        }
                        .buttonStyle(.bordered)
                        .focusSection()
                    }
                    if let selectedChannelURL {
                        HStack(spacing: 12) {
                            NavigationLink {
                                TVChannelExtrasView(api: api, channelURL: selectedChannelURL,
                                                    kind: .playlists)
                            } label: {
                                Label("channels.playlists", systemImage: "list.bullet.rectangle")
                            }
                            .focused($focusedAction, equals: "playlists")
                            .accessibilityIdentifier("channel-action-playlists")
                            NavigationLink {
                                TVChannelExtrasView(api: api, channelURL: selectedChannelURL,
                                                    kind: .community)
                            } label: {
                                Label("channels.community", systemImage: "text.bubble")
                            }
                            .focused($focusedAction, equals: "community")
                            NavigationLink {
                                TVChannelExtrasView(api: api, channelURL: selectedChannelURL,
                                                    kind: .podcasts)
                            } label: {
                                Label("channels.podcasts", systemImage: "mic")
                            }
                            .focused($focusedAction, equals: "podcasts")
                            if hasCourses {
                                NavigationLink {
                                    TVChannelExtrasView(api: api, channelURL: selectedChannelURL,
                                                        kind: .courses)
                                } label: {
                                    Label("channels.courses", systemImage: "books.vertical")
                                }
                                .focused($focusedAction, equals: "courses")
                            }
                            Spacer()
                            if !showingShorts {
                                Picker("channels.sort", selection: $videoSort) {
                                    Text("channels.sortLatest").tag("latest")
                                    Text("channels.sortPopular").tag("popular")
                                    Text("channels.sortOldest").tag("oldest")
                                }
                                .pickerStyle(.menu)
                                .focused($focusedAction, equals: "sort")
                            }
                        }
                        .buttonStyle(.bordered)
                        .focusSection()
                        .onMoveCommand { direction in
                            if direction == .up {
                                if supportsShorts &&
                                   contentPreferences.settings?.hideShorts != true {
                                    focusedChannelTab = showingShorts ? .shorts : .videos
                                } else {
                                    subscriptionButtonFocused = true
                                }
                            } else if direction == .down,
                                      let first = visibleVideos.first {
                                focusedVideo = first.url
                            }
                        }
                    }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 28)
                    .padding(.vertical, 26)
                    .background {
                        TVChannelHeroBackdrop(
                            api: api,
                            avatarURL: channelAvatarURL,
                            bannerURL: channelBannerURL
                        )
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 20))
                    if loadingVideos {
                        ProgressView("settings.remoteLoading")
                            .frame(maxWidth: .infinity, minHeight: 160)
                    }
                    if let error {
                        TVContentMessage(
                            symbol: "wifi.exclamationmark",
                            title: error,
                            detail: TVL10n.value("subscriptions.loadError"),
                            action: {
                                Task {
                                    if let selectedChannelURL {
                                        await loadChannel(selectedChannelURL)
                                    } else {
                                        await reload()
                                    }
                                }
                            }
                        )
                    } else if !loadingVideos && visibleVideos.isEmpty {
                        TVContentMessage(
                            symbol: "play.rectangle",
                            title: TVL10n.value("subscriptions.emptyVideos"),
                            detail: TVL10n.value(
                                directChannelURL == nil
                                    ? "subscriptions.chooseChannel" : "subscriptions.emptyVideos"
                            )
                        )
                    } else {
                        TVSharedVideoGrid(
                            snapshot: TVSharedVideoGridSnapshot(
                                videos: visibleVideos, scope: api.metadataCacheScope,
                                destination: "channels-" + (selectedChannelURL ?? "") +
                                    (showingShorts ? "-shorts" : "-videos") + "-" + videoSort,
                                focusPrefix: "",
                                accessibilityPrefix: "subscription-video-",
                                columns: columns.count, columnSpacing: 22,
                                rowSpacing: 28,
                                canLoadMore: nextPage != nil &&
                                    !loadingMore && !loadingVideos && pageError == nil,
                                loadAhead: columns.count + 1,
                                lookupMissingMetadata: false,
                                isWatchLaterEntry: false,
                                playbackQueue: nil
                            ),
                            api: api, focus: $focusedVideo, menu: videoMenu,
                            onReturnToList: { id in
                                detailReturnVideoID = id
                                focusedVideo = id
                            },
                            onLeftEdge: { id in
                                guard directChannelURL == nil else { return }
                                railReturnVideoID = id
                                detailReturnVideoID = nil
                                returnToChannelRail()
                            },
                            onApproachEnd: { Task { await loadMore() } },
                            onTopEdge: { _ in focusedAction = "playlists" }
                        )
                        .equatable()
                        if loadingMore {
                            ProgressView("settings.remoteLoading")
                        } else if let pageError {
                            HStack(spacing: 18) {
                                Text(pageError).foregroundStyle(.orange)
                                Button("common.retry") { Task { await loadMore() } }
                                    .buttonStyle(.bordered)
                            }
                        }
                    }
                }
                .padding(.top, 38)
                .padding(.leading, directChannelURL == nil ? 0 : 72)
                .padding(.trailing, 44)
                .padding(.bottom, 110)
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
            .defaultFocus(
                $focusedVideo, preferredVideoID,
                priority: preferredVideoID == nil ? .automatic : .userInitiated
            )
            .focusSection()
            } // ScrollViewReader
        } // GeometryReader: retain a fixed 3-column grid width.
        } // HStack: channel rail and video content.
        // The entire page is a native focus-entry region. A Right move
        // from the global rail should prefer the last saved video even
        // though the secondary navigation sits geometrically to its left.
        // A nil saved ID leaves first-entry rail focus unchanged.
        .defaultFocus(
            $focusedVideo, preferredVideoID,
            priority: preferredVideoID == nil ? .automatic : .userInitiated
        )
        .background(TTTheme.ink)
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
        .task {
            guard !initializedOnce else { return }
            initializedOnce = true
            if let directChannelURL {
                channelTitle = directChannelName ?? ""
                enterGridAfterLoad = true
                selectedChannelURL = directChannelURL
                // A pushed channel must load its videos on first appearance.
                // Relying on .task(id: selectedChannelURL) races with this
                // initial @State assignment and can leave the grid empty
                // until the Videos/Shorts tab changes.
                await loadChannel(directChannelURL)
                // Membership is independent of the video feed. Check it only
                // once, without making it a prerequisite for the first load.
                await refreshMembership()
            } else {
                await reload()
            }
        }
        .task(id: focusRequest) {
            guard focusRequest >= 0,
                  handledFocusRequest != focusRequest else { return }
            handledFocusRequest = focusRequest
            // The selected tile is already registered as a native default
            // focus target. Reassigning a rail focus after this would
            // produce the old visible two-step jump.
            if preferredVideoID != nil { return }
            await Task.yield()
            guard !Task.isCancelled else { return }
            if directChannelURL != nil {
                subscriptionButtonFocused = true
            } else if let selectedChannelURL {
                focusedSubscription = selectedChannelURL
            } else {
                loadingRailFocused = true
            }
        }
        .onExitCommand {
            if directChannelURL != nil {
                // This view is pushed from VideoDetailView. Menu/Back must
                // pop to *that* video, never to the global app sidebar.
                dismiss()
            } else if focusedSubscription != nil || loadingRailFocused {
                onRevealMenu()
            } else {
                returnToChannelRail()
            }
        }
        .task { await contentPreferences.ensureLoaded(api: api) }
        .task(id: selectedChannelURL) {
            // Direct links are loaded by the first-appearance task above,
            // avoiding a second request and the initial selection race.
            guard directChannelURL == nil,
                  let selectedChannelURL,
                  lastLoadedChannelURL != selectedChannelURL else { return }
            lastLoadedChannelURL = selectedChannelURL
            await loadChannel(selectedChannelURL)
        }
        .onChange(of: focusedSubscription) { previous, next in
            railBrowsingVertically = previous != nil && next != nil
        }
        .onChange(of: selectedChannelURL) { _, _ in
            subscriptionErrorMessage = nil
        }
        .onChange(of: videoSort) { _, _ in
            if let selectedChannelURL, !showingShorts {
                Task { await loadChannel(selectedChannelURL) }
            }
        }
        .onChange(of: contentPreferences.settings?.hideShorts) { _, hidden in
            if hidden == true && showingShorts { showingShorts = false }
        }
        .onChange(of: showingShorts) { _, _ in
            guard let selectedChannelURL else { return }
            Task { await loadChannel(selectedChannelURL) }
        }
    }

    /// This action stays focusable while a request is in flight, preventing
    /// tvOS from jumping to a different video or navigation rail.
    private func subscriptionButton(channelURL: String) -> some View {
        Button {
            guard !checkingMembership, !changingSubscription else { return }
            Task {
                if knownMemberships == nil {
                    await refreshMembership()
                } else {
                    await toggleSubscription(channelURL: channelURL)
                }
            }
        } label: {
            HStack(spacing: 9) {
                if checkingMembership || changingSubscription {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: currentSubscription != nil
                          ? "checkmark.circle.fill" : "plus.circle.fill")
                }
                Text(
                    changingSubscription ? TVL10n.value("channels.subscriptionSaving") :
                    checkingMembership ? TVL10n.value("channels.subscriptionChecking") :
                    knownMemberships == nil ? TVL10n.value("channels.subscriptionRetry") :
                    currentSubscription != nil ? TVL10n.value("channels.unsubscribe") :
                    TVL10n.value("channels.subscribe")
                )
                .lineLimit(1)
            }
            .frame(minHeight: 42)
        }
        .buttonStyle(.borderedProminent)
        .tint(currentSubscription == nil ? TTTheme.accent : TTTheme.surface)
        .focused($subscriptionButtonFocused)
        .accessibilityIdentifier("channel-subscription-toggle")
        .onMoveCommand { direction in
            if direction == .down {
                if supportsShorts && contentPreferences.settings?.hideShorts != true {
                    focusedChannelTab = showingShorts ? .shorts : .videos
                } else if selectedChannelURL != nil {
                    focusedAction = "playlists"
                }
            }
        }
        .accessibilityHint(currentSubscription != nil
                           ? TVL10n.value("channels.unsubscribeHint")
                           : TVL10n.value("channels.subscribeHint"))
    }

    @MainActor
    private func refreshMembership() async {
        guard !checkingMembership, !changingSubscription else { return }
        let id = UUID()
        membershipRequestID = id
        checkingMembership = true
        subscriptionErrorMessage = nil
        defer { if membershipRequestID == id { checkingMembership = false } }
        #if DEBUG
        if api.origin.host == "preview.invalid" {
            knownMemberships = directChannelURL == nil ? subscriptions : []
            return
        }
        #endif
        do {
            let received = try await api.subscriptions()
            try Task.checkCancellation()
            guard membershipRequestID == id else { return }
            knownMemberships = received
            // In the normal channel browser, the sidebar is the live list
            // of memberships. Do not alter the currently opened channel.
            if directChannelURL == nil {
                subscriptions = received.sorted {
                    $0.name.localizedStandardCompare($1.name) == .orderedAscending
                }
            }
        } catch is CancellationError {
            return
        } catch {
            if membershipRequestID == id {
                subscriptionErrorMessage = subscriptionErrorText(error)
            }
        }
    }

    @MainActor
    private func toggleSubscription(channelURL: String) async {
        guard !changingSubscription, !checkingMembership,
              let knownMemberships else { return }
        changingSubscription = true
        subscriptionErrorMessage = nil
        // Prevent an older GET from restoring a stale membership after POST/DELETE.
        membershipRequestID = UUID()
        defer { changingSubscription = false }
        let existing = TVChannelSubscriptionMembership.entry(
            for: channelURL, in: knownMemberships
        )
        do {
            let updated: [TVSubscription]
            #if DEBUG
            if api.origin.host == "preview.invalid" {
                if let existing {
                    updated = TVChannelSubscriptionMembership.removing(
                        channelURL: existing.channelUrl, from: knownMemberships
                    )
                } else {
                    updated = TVChannelSubscriptionMembership.adding(
                        TVSubscription(channelUrl: channelURL,
                                       name: channelTitle,
                                       avatarUrl: channelAvatarURL,
                                       subscribedAt: nil),
                        to: knownMemberships
                    )
                }
            } else {
                if let existing {
                    try await api.unsubscribe(channelURL: existing.channelUrl)
                    updated = TVChannelSubscriptionMembership.removing(
                        channelURL: existing.channelUrl, from: knownMemberships
                    )
                } else {
                    let added = try await api.subscribe(
                        channelURL: channelURL,
                        name: channelTitle.isEmpty ? channelURL : channelTitle,
                        avatarURL: channelAvatarURL
                    )
                    updated = TVChannelSubscriptionMembership.adding(
                        added, to: knownMemberships
                    )
                }
            }
            #else
            if let existing {
                try await api.unsubscribe(channelURL: existing.channelUrl)
                updated = TVChannelSubscriptionMembership.removing(
                    channelURL: existing.channelUrl, from: knownMemberships
                )
            } else {
                let added = try await api.subscribe(
                    channelURL: channelURL,
                    name: channelTitle.isEmpty ? channelURL : channelTitle,
                    avatarURL: channelAvatarURL
                )
                updated = TVChannelSubscriptionMembership.adding(
                    added, to: knownMemberships
                )
            }
            #endif
            // Keep the channel currently on screen after unsubscribing;
            // removing it from the subscription rail must not pop this view.
            self.knownMemberships = updated
            if directChannelURL == nil {
                subscriptions = updated.sorted {
                    $0.name.localizedStandardCompare($1.name) == .orderedAscending
                }
            }
        } catch is CancellationError {
            return
        } catch {
            // On failure the button retains the server-confirmed old status.
            if selectedChannelURL == channelURL {
                subscriptionErrorMessage = subscriptionErrorText(error)
            }
        }
    }

    private func subscriptionErrorText(_ error: Error) -> String {
        if TVServerErrorMapping.httpStatus(error) == 401 {
            return TVL10n.value("channels.subscriptionRequiresLogin")
        }
        return error.localizedDescription
    }

    private var channelRail: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text("subscriptions.title")
                .font(.system(size: 27, weight: .bold))
                .padding(.top, 43)
                .padding(.horizontal, 12)
                .padding(.bottom, 12)
            if loadingSubscriptions || subscriptions.isEmpty {
                Text(loadingSubscriptions
                     ? TVL10n.value("settings.remoteLoading")
                     : TVL10n.value("subscriptions.empty"))
                    .font(.callout)
                    .foregroundStyle(TTTheme.muted)
                    .padding(16)
                    .contentShape(Rectangle())
                    .focusable(true)
                    .focusEffectDisabled(true)
                    .focused($loadingRailFocused)
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 7) {
                    ForEach(subscriptions) { channel in
                        Button {
                            enterChannel(channel.channelUrl)
                        } label: {
                            HStack(spacing: 12) {
                                TVThumbnail(
                                    url: api.relativeMediaURL(channel.avatarUrl),
                                    origin: api.origin
                                )
                                .frame(width: 43, height: 43)
                                .clipShape(Circle())
                                Text(channel.name)
                                    .font(.system(size: 18, weight: .medium))
                                    .lineLimit(2)
                                Spacer(minLength: 0)
                                if selectedChannelURL == channel.channelUrl {
                                    Image(systemName: "chevron.right")
                                        .font(.caption.bold())
                                }
                            }
                            .padding(.horizontal, 10)
                            .frame(maxWidth: .infinity, minHeight: 58, alignment: .leading)
                            .modifier(TVRailRowHighlight(
                                focused: TVRailVisualFocus.highlights(
                                    channel.channelUrl,
                                    focused: focusedSubscription,
                                    selected: selectedChannelURL ?? channel.channelUrl,
                                    browsingWithinRail: railBrowsingVertically
                                ),
                                selected: selectedChannelURL == channel.channelUrl
                            ))
                        }
                        .buttonStyle(TVRailButtonStyle())
                        .focusEffectDisabled(true)
                        .focused($focusedSubscription, equals: channel.channelUrl)
                        .onMoveCommand { direction in
                            if direction == .right {
                                railBrowsingVertically = false
                                enterChannel(channel.channelUrl)
                            } else if direction == .left {
                                railBrowsingVertically = false
                                onRevealMenu()
                            } else if direction == .up || direction == .down {
                                railBrowsingVertically = true
                            }
                        }
                        .accessibilityIdentifier("subscription-\(channel.channelUrl)")
                    }

                }
            }
        }
        .padding(.horizontal, 13)
        .padding(.bottom, 32)
        .frame(maxHeight: .infinity)
        // Match Library and Settings; the global icon rail stays gray.
        .background(TTTheme.ink)
    }

    @MainActor
    private func enterChannel(_ url: String) {
        if selectedChannelURL == url, !loadingVideos {
            if let target = preferredVideoID ?? visibleVideos.first?.url {
                focusedVideo = target
            } else {
                enterGridAfterLoad = true
            }
        } else {
            railReturnVideoID = nil
            detailReturnVideoID = nil
            enterGridAfterLoad = true
            let host = URLComponents(string: url)?.host?.lowercased() ?? ""
            if host != "youtube.com" && !host.hasSuffix(".youtube.com") {
                showingShorts = false
            }
            selectedChannelURL = url
        }
    }

    @MainActor
    private func returnToChannelRail() {
        if let selected = focusedVideo,
           visibleVideos.contains(where: { $0.url == selected }) {
            railReturnVideoID = selected
        }
        detailReturnVideoID = nil
        // The secondary rail has a native user-initiated default target;
        // no delayed focus correction is needed.
        focusedSubscription = selectedChannelURL
    }

    @MainActor
    private func reconcileMutations(_ events: [TVVideoMutationCenter.Event]) {
        let pending = events.filter {
            $0.id > mutationCursor.lastID && $0.accountScope == api.metadataCacheScope
        }
        mutationCursor.lastID = max(mutationCursor.lastID, events.last?.id ?? 0)
        guard !pending.isEmpty else { return }
        let blockedSelectedChannel = pending.contains { event in
            if case .channelBlocked = event.kind {
                return event.channelURL == selectedChannelURL
            }
            return false
        }
        if blockedSelectedChannel {
            videos.removeAll()
        } else if videos.contains(where: { video in
            pending.contains { $0.removes(video) }
        }) {
            videos.removeAll { video in pending.contains { $0.removes(video) } }
        }
        if let target = railReturnVideoID,
           !videos.contains(where: { $0.url == target }) {
            railReturnVideoID = nil
        }
    }

    @MainActor
    private func reload() async {
        #if DEBUG
        if api.origin.host == "preview.invalid" {
            // Network-free Siri Remote focus regressions in CI.
            subscriptions = [
                TVSubscription(channelUrl: "https://preview.invalid/channel/a",
                               name: "Beispielkanal A", avatarUrl: "", subscribedAt: nil),
                TVSubscription(channelUrl: "https://preview.invalid/channel/b",
                               name: "Beispielkanal B", avatarUrl: "", subscribedAt: nil)
            ]
            knownMemberships = subscriptions
            selectedChannelURL = subscriptions.first?.channelUrl
            await Task.yield()
            if focusRequest >= 0 { focusedSubscription = selectedChannelURL }
            return
        }
        #endif
        loadingSubscriptions = true
        error = nil
        defer { loadingSubscriptions = false }
        do {
            let received = try await api.subscriptions()
            try Task.checkCancellation()
            subscriptions = received.sorted {
                $0.name.localizedStandardCompare($1.name) == .orderedAscending
            }
            knownMemberships = received
            if !subscriptions.contains(where: { $0.channelUrl == selectedChannelURL }) {
                selectedChannelURL = subscriptions.first?.channelUrl
            }
            await Task.yield()
            // In global-menu preview mode (focusRequest == -1) this screen
            // may load data but must never take focus from the main rail.
            if focusRequest >= 0, focusedVideo == nil,
               focusedAction == nil, focusedChannelTab == nil,
               !subscriptionButtonFocused {
                focusedSubscription = selectedChannelURL
            }
        } catch is CancellationError {
            return
        } catch {
            self.error = error.localizedDescription
        }
    }

    @MainActor
    private func loadChannel(_ channelURL: String) async {
        let shorts = showingShorts
        let sort = videoSort
        #if DEBUG
        if api.origin.host == "preview.invalid" {
            channelTitle = subscriptions.first(where: { $0.channelUrl == channelURL })?.name
                ?? (directChannelURL == channelURL ? directChannelName ?? "" : "")
            channelDescription = ""
            channelAvatarURL = ""
            channelBannerURL = ""
            videos = (0..<9).map { index in
                var video = VideoItem(
                    id: "subscription-preview-\(index)",
                    title: "Abonniertes Video \(index + 1)",
                    url: "https://youtu.be/ui-preview-\(index)",
                    thumbnailUrl: nil, uploaderName: "Beispielkanal",
                    duration: 500, isLive: false
                )
                if index == 2 { video.watchPositionMs = 480_000 }
                return video
            }
            nextPage = nil
            loadingVideos = false
            if enterGridAfterLoad {
                enterGridAfterLoad = false
                await Task.yield()
                if selectedChannelURL == channelURL { focusedVideo = videos.first?.url }
            }
            return
        }
        #endif
        let identifier = UUID()
        channelRequestID = identifier
        // A cancelled page of the previous channel must not block this one.
        pageRequestID = UUID()
        loadingMore = false
        loadingVideos = true
        videos = []
        nextPage = nil
        channelTitle = subscriptions.first(where: { $0.channelUrl == channelURL })?.name
            ?? (directChannelURL == channelURL ? directChannelName ?? "" : "")
        channelDescription = ""
        channelAvatarURL = subscriptions.first(where: { $0.channelUrl == channelURL })?.avatarUrl ?? ""
        channelBannerURL = ""
        hasCourses = false
        error = nil
        pageError = nil
        defer { if channelRequestID == identifier { loadingVideos = false } }
        do {
            let response = try await api.channel(channelURL, shorts: shorts,
                                                 sort: sort)
            try Task.checkCancellation()
            guard channelRequestID == identifier,
                  selectedChannelURL == channelURL, showingShorts == shorts,
                  videoSort == sort else { return }
            channelTitle = response.name
            channelAvatarURL = response.avatarUrl ?? ""
            channelBannerURL = response.bannerUrl ?? ""
            await TVChannelArtworkCache.shared.remember(response, for: channelURL, api: api)
            channelDescription = response.description ?? ""
            hasCourses = response.hasCourses == true
            // Channel feeds can omit the uploader URL. Keep the known
            // channel identity on each card so blocking that channel can
            // remove the affected tiles locally without another GET.
            let channelVideos = response.videos.map { item in
                var result = item
                if result.uploaderUrl == nil { result.uploaderUrl = channelURL }
                return result
            }
            videos = channelVideos
            nextPage = response.nextpage
            if enterGridAfterLoad {
                enterGridAfterLoad = false
                await Task.yield()
                if selectedChannelURL == channelURL {
                    focusedVideo = videos.first?.url
                }
            }
            // Channel feed has no watch-position metadata. Enrich both
            // first page and pagination exactly like Home and Library.
            let enriched = await api.withProgress(channelVideos)
            guard !Task.isCancelled, channelRequestID == identifier,
                  selectedChannelURL == channelURL, showingShorts == shorts,
                  videoSort == sort else { return }
            videos = enriched
        } catch is CancellationError {
            return
        } catch {
            if channelRequestID == identifier && selectedChannelURL == channelURL && showingShorts == shorts {
                self.error = error.localizedDescription
            }
        }
    }

    @MainActor
    private func loadMore() async {
        guard !loadingMore, !loadingVideos, let nextPage,
              let selectedChannelURL else { return }
        let identifier = UUID()
        let shorts = showingShorts
        let sort = videoSort
        pageRequestID = identifier
        pageError = nil
        loadingMore = true
        defer { if pageRequestID == identifier { loadingMore = false } }
        do {
            let response = try await api.channel(selectedChannelURL, nextpage: nextPage,
                                                 shorts: shorts, sort: sort)
            try Task.checkCancellation()
            guard pageRequestID == identifier,
                  self.selectedChannelURL == selectedChannelURL, showingShorts == shorts,
                  videoSort == sort, self.nextPage == nextPage else { return }
            var seen = Set(videos.map(\.url))
            let fresh = response.videos.map { item in
                var result = item
                if result.uploaderUrl == nil { result.uploaderUrl = selectedChannelURL }
                return result
            }.filter { seen.insert($0.url).inserted }
            videos += fresh
            self.nextPage = response.nextpage == nextPage ? nil : response.nextpage
            let enriched = await api.withProgress(fresh)
            guard !Task.isCancelled, pageRequestID == identifier,
                  self.selectedChannelURL == selectedChannelURL, showingShorts == shorts else { return }
            // Reconcile by URL without replacing the already visible rows.
            let progressByURL = Dictionary(uniqueKeysWithValues: enriched.map { ($0.url, $0) })
            videos = videos.map { progressByURL[$0.url] ?? $0 }
        } catch is CancellationError {
            return
        } catch {
            if pageRequestID == identifier { pageError = error.localizedDescription }
        }
    }
}
