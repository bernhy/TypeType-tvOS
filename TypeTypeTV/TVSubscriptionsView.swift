import SwiftUI

/// Account subscriptions are their own destination, not a second shortcut to
/// Playlists. Source: GET /api/subscriptions + GET /api/channel?url=...
struct TVSubscriptionsView: View {
    let api: TypeTypeAPI
    var focusRequest = 0
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
    @State private var selectedChannelURL: String?
    @State private var videos: [VideoItem] = []
    @State private var showingShorts = false
    @State private var channelTitle = ""
    @State private var channelDescription = ""
    @State private var nextPage: String?
    @State private var loadingSubscriptions = false
    @State private var loadingVideos = false
    @State private var channelRequestID = UUID()
    @State private var pageRequestID = UUID()
    @State private var loadingMore = false
    @State private var enterGridAfterLoad = false
    @State private var error: String?
    @State private var pageError: String?
    @FocusState private var focusedSubscription: String?
    // Suppress a geometrically chosen neighbor while returning from video
    // content; browsing Up/Down within this rail still works normally.
    @State private var railBrowsingVertically = false
    @FocusState private var focusedVideo: String?
    @FocusState private var loadingRailFocused: Bool
    @FocusState private var subscriptionButtonFocused: Bool
    @FocusState private var focusedChannelTab: ChannelTab?

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
            }
            ScrollViewReader { scroll in
                ScrollView {
                    VStack(alignment: .leading, spacing: 28) {
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
                                .foregroundStyle(TTTheme.muted)
                                .lineLimit(3)
                        }
                    }
                    if supportsShorts {
                        HStack(spacing: 15) {
                            Button("channels.videos") { showingShorts = false }
                                .tint(showingShorts ? TTTheme.muted : TTTheme.accent)
                                .focused($focusedChannelTab, equals: .videos)
                                .onMoveCommand { direction in
                                    if direction == .up {
                                        subscriptionButtonFocused = true
                                    } else if direction == .right {
                                        focusedChannelTab = .shorts
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
                                    }
                                }
                        }
                        .buttonStyle(.bordered)
                        .focusSection()
                    }
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
                    } else if !loadingVideos && videos.isEmpty {
                        TVContentMessage(
                            symbol: "play.rectangle",
                            title: TVL10n.value("subscriptions.emptyVideos"),
                            detail: TVL10n.value(
                                directChannelURL == nil
                                    ? "subscriptions.chooseChannel" : "subscriptions.emptyVideos"
                            )
                        )
                    } else {
                        LazyVGrid(columns: columns, spacing: 28) {
                            ForEach(Array(videos.enumerated()), id: \.offset) { index, video in
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
                                .videoActions(
                                    api: api, video: video, onChanged: {},
                                    focus: $focusedVideo, focusID: video.url
                                )
                                .accessibilityIdentifier("subscription-video-\(index)")
                                .onMoveCommand { direction in
                                    if direction == .up && index < columns.count {
                                        // All top-row thumbnails return to the
                                        // tabs, not only the rightmost one.
                                        if supportsShorts {
                                            focusedChannelTab = showingShorts ? .shorts : .videos
                                        } else {
                                            subscriptionButtonFocused = true
                                        }
                                    } else if direction == .left &&
                                                index % columns.count == 0 &&
                                                directChannelURL == nil {
                                        returnToChannelRail()
                                    }
                                }
                                .onAppear {
                                    if index >= videos.count - columns.count - 1,
                                       nextPage != nil, !loadingMore && !loadingVideos &&
                                       pageError == nil {
                                        Task { await loadMore() }
                                    }
                                }
                            }
                        }
                        .focusSection()
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
            }
            .focusSection()
            }
        }
        .background(TTTheme.ink)
        .task {
            if let directChannelURL {
                channelTitle = directChannelName ?? ""
                enterGridAfterLoad = true
                selectedChannelURL = directChannelURL
                // A channel opened from a video's details has no subscription
                // rail, so it must load account membership independently.
                await refreshMembership()
            } else {
                await reload()
            }
        }
        .task(id: focusRequest) {
            guard focusRequest >= 0 else { return }
            await Task.yield()
            if directChannelURL != nil {
                // Give channel visitors immediate access to Subscribe.
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
        .task(id: selectedChannelURL) {
            if let selectedChannelURL {
                await loadChannel(selectedChannelURL)
            }
        }
        .onChange(of: focusedSubscription) { previous, next in
            if next == nil {
                railBrowsingVertically = false
            } else if previous == nil {
                railBrowsingVertically = false
                if let next, let selectedChannelURL, next != selectedChannelURL {
                    let expected = selectedChannelURL
                    Task { @MainActor in
                        await Task.yield()
                        guard selectedChannelURL == expected,
                              focusedSubscription == next else { return }
                        focusedSubscription = expected
                    }
                }
            } else {
                railBrowsingVertically = true
            }
        }
        .onChange(of: selectedChannelURL) { _, _ in
            subscriptionErrorMessage = nil
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
                if supportsShorts {
                    focusedChannelTab = showingShorts ? .shorts : .videos
                } else if let first = videos.first {
                    focusedVideo = first.url
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
        if case TypeTypeError.http(401, _) = error {
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
            if let first = videos.first {
                focusedVideo = first.url
            } else {
                enterGridAfterLoad = true
            }
        } else {
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
        let target = selectedChannelURL
        focusedSubscription = target
        // Restore once the directional focus engine has completed its move.
        Task { @MainActor in
            await Task.yield()
            guard selectedChannelURL == target else { return }
            focusedSubscription = target
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
            if focusRequest >= 0 {
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
        #if DEBUG
        if api.origin.host == "preview.invalid" {
            channelTitle = subscriptions.first(where: { $0.channelUrl == channelURL })?.name
                ?? (directChannelURL == channelURL ? directChannelName ?? "" : "")
            channelDescription = ""
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
        error = nil
        pageError = nil
        defer { if channelRequestID == identifier { loadingVideos = false } }
        do {
            let response = try await api.channel(channelURL, shorts: shorts)
            try Task.checkCancellation()
            guard channelRequestID == identifier,
                  selectedChannelURL == channelURL, showingShorts == shorts else { return }
            channelTitle = response.name
            channelAvatarURL = response.avatarUrl ?? ""
            channelDescription = response.description ?? ""
            videos = response.videos
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
            let enriched = await api.withProgress(response.videos)
            guard !Task.isCancelled, channelRequestID == identifier,
                  selectedChannelURL == channelURL, showingShorts == shorts else { return }
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
        pageRequestID = identifier
        pageError = nil
        loadingMore = true
        defer { if pageRequestID == identifier { loadingMore = false } }
        do {
            let response = try await api.channel(selectedChannelURL, nextpage: nextPage,
                                                 shorts: shorts)
            try Task.checkCancellation()
            guard pageRequestID == identifier,
                  self.selectedChannelURL == selectedChannelURL, showingShorts == shorts,
                  self.nextPage == nextPage else { return }
            var seen = Set(videos.map(\.url))
            let fresh = response.videos.filter { seen.insert($0.url).inserted }
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
