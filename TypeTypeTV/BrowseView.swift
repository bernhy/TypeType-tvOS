import SwiftUI

/// Main sections remain accessible using a narrow icon rail. Moving left from
/// the first thumbnail expands the rail and puts focus on the current section.
enum TVSection: String, CaseIterable, Hashable {
    case home, search, library, playlists, account, settings

    var label: String {
        switch self {
        case .home: return TVL10n.value("nav.home")
        case .search: return TVL10n.value("nav.search")
        case .library: return TVL10n.value("nav.library")
        case .playlists: return TVL10n.value("nav.playlists")
        case .account: return TVL10n.value("settings.groupAccount")
        case .settings: return TVL10n.value("nav.settings")
        }
    }
    var localizedLabel: LocalizedStringKey {
        switch self {
        case .home: return "nav.home"
        case .search: return "nav.search"
        case .library: return "nav.library"
        case .playlists: return "nav.playlists"
        case .account: return "settings.groupAccount"
        case .settings: return "nav.settings"
        }
    }
    var icon: String {
        switch self {
        case .home: return "house.fill"
        case .search: return "magnifyingglass"
        case .library: return "books.vertical"
        case .playlists: return "list.bullet.rectangle"
        case .account: return "person.crop.circle"
        case .settings: return "gearshape"
        }
    }
}

struct BrowseView: View {
    let instanceOrigin: String
    let onDisconnect: () -> Void
    let previewVideos: [VideoItem]?
    let initialSettingsGroup: TVSettingsGroup
    @State private var section: TVSection
    @State private var expanded = false
    @State private var sidebarIdentity: TVAccountIdentity?
    @ObservedObject private var playbackVisibility = TVPlaybackVisibility.shared
    @State private var settingsEntryGroup: TVSettingsGroup
    @State private var accountGeneration = 0
    @State private var returnToSwitcherAfterLogin = false
    @AppStorage("typetype.navigationAnimations") private var navigationAnimations = true
    @FocusState private var menuFocus: TVSection?

    init(instanceOrigin: String, onDisconnect: @escaping () -> Void,
         initialSection: TVSection = .home, previewVideos: [VideoItem]? = nil,
         initiallyExpanded: Bool = false,
         initialSettingsGroup: TVSettingsGroup = .playback) {
        self.instanceOrigin = instanceOrigin
        self.onDisconnect = onDisconnect
        self.previewVideos = previewVideos
        self.initialSettingsGroup = initialSettingsGroup
        _section = State(initialValue: initialSection)
        _expanded = State(initialValue: initiallyExpanded)
        _settingsEntryGroup = State(initialValue: initialSettingsGroup)
    }

    var body: some View {
        if let api = try? TypeTypeAPI(address: instanceOrigin) {
            HStack(spacing: 0) {
                if !playbackVisibility.isVisible {
                    sidebar
                        .zIndex(1)
                }
                NavigationStack {
                    Group {
                        switch section {
                        case .home:
                            HomeView(
                                api: api, previewVideos: previewVideos,
                                onRevealMenu: revealMenu,
                                onOpenAccount: { open(.account) },
                                sidebarFocused: menuFocus != nil
                            )
                        case .search:
                            SearchView(api: api)
                                .onExitCommand { revealMenu() }
                        case .library:
                            LibraryView(api: api)
                                .onExitCommand { revealMenu() }
                        case .playlists:
                            LibraryView(api: api, preferPlaylists: true)
                                .onExitCommand { revealMenu() }
                        case .account:
                            TVAccountSwitcherView(
                                api: api,
                                onAddAccount: {
                                    settingsEntryGroup = .account
                                    returnToSwitcherAfterLogin = true
                                    open(.settings)
                                },
                                onAccountChanged: { accountDidChange(api: api) }
                            )
                            .onExitCommand { revealMenu() }
                        case .settings:
                            PreferencesView(
                                api: api, onDisconnect: onDisconnect,
                                initialGroup: settingsEntryGroup,
                                onAccountChanged: { accountDidChange(api: api) },
                                onBackToMenu: revealMenu
                            )
                        }
                    }
                }
                .id("\(section.rawValue)-\(accountGeneration)")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .focusSection()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .ignoresSafeArea(.container, edges: .leading)
            // The global rail background must cover the whole screen, not only
            // the vertically inset tvOS safe area occupied by its buttons.
            .background(TTTheme.ink.ignoresSafeArea())
            .background(alignment: .leading) {
                TTTheme.surface
                    .frame(width: expanded ? 214 : 56)
                    .ignoresSafeArea(.container, edges: [.top, .bottom, .leading])
            }
            .task { await reloadSidebarIdentity(api: api) }
            .onChange(of: section) { old, _ in
                if old == .account || old == .settings {
                    Task { await reloadSidebarIdentity(api: api) }
                }
            }
        } else {
            TVContentMessage(symbol: "exclamationmark.triangle",
                             title: TVL10n.value("server.invalidStored"),
                             detail: TVL10n.value("server.reconnectHelp"),
                             action: onDisconnect,
                             actionTitle: TVL10n.value("common.changeServer"))
        }
    }

    private var sidebar: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "play.rectangle.fill")
                    .font(.system(size: 27))
                    .foregroundStyle(TTTheme.accent)
                    .frame(width: 36)
                if expanded {
                    Text("TypeType")
                        .font(.system(size: 23, weight: .bold))
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .frame(height: 64)
            .padding(.bottom, 12)

            ForEach(TVSection.allCases.filter { $0 != .settings }, id: \.self) { item in
                sidebarButton(item)
            }
            Spacer(minLength: 10)
            sidebarButton(.settings)
        }
        .padding(.horizontal, 4)
        .padding(.top, 20)
        .padding(.bottom, 20)
        .frame(width: expanded ? 214 : 56)
        .frame(maxHeight: .infinity)
        .background(TTTheme.surface)
        .ignoresSafeArea(.container, edges: [.top, .bottom])
        // Disable inherited tvOS lift/glow on the whole rail, not only on
        // each button. Otherwise the focus overlay can exceed its bounds.
        .focusEffectDisabled(true)
        .clipped()
        .animation(navigationAnimations ? .easeInOut(duration: 0.16) : nil, value: expanded)
        .focusSection()
        .onExitCommand {
            // Back while the global rail is focused goes to Home. The final
            // Back on the Home icon is consumed here, never exits TypeType.
            if section != .home {
                open(.home)
            } else {
                menuFocus = .home
                expanded = true
            }
        }
        .onChange(of: menuFocus) { _, focused in
            expanded = focused != nil
        }
    }

    private func sidebarButton(_ item: TVSection) -> some View {
        Button {
            open(item)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: item == .account && sidebarIdentity?.isGuest == false
                      ? "person.crop.circle.fill" : item.icon)
                    .font(.system(size: 24, weight: .medium))
                    .frame(width: 36, height: 52)
                if expanded {
                    if item == .account {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.localizedLabel)
                                .font(.system(size: 20, weight: .medium))
                            Text(sidebarAccountLabel)
                                .font(.system(size: 12))
                                .foregroundStyle(TTTheme.muted)
                                .lineLimit(1)
                        }
                    } else {
                        Text(item.localizedLabel)
                            .font(.system(size: 20, weight: .medium))
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
            }
            .padding(.horizontal, 2)
            .frame(height: 52)
            .frame(maxWidth: .infinity, alignment: .leading)
            // Never change size or draw the native tvOS focus overlay.
            .foregroundStyle(menuFocus == item
                             ? (section == item ? TTTheme.accent : TTTheme.ink)
                             : (section == item ? TTTheme.accent : TTTheme.muted))
            .background {
                // YouTube-style rounded, high-contrast focus pill.
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(menuFocus == item ? Color.white : .clear)
            }
            .contentShape(RoundedRectangle(cornerRadius: 12))
            .clipShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .focusEffectDisabled(true)
        .focused($menuFocus, equals: item)
        .accessibilityLabel(item.label)
        .accessibilityAddTraits(item == section ? .isSelected : [])
    }

    private var sidebarAccountLabel: String {
        if let identity = sidebarIdentity {
            if identity.isGuest { return TVL10n.value("login.guestActive") }
            if let name = identity.visibleName { return name }
            if let api = try? TypeTypeAPI(address: instanceOrigin),
               let known = TypeTypeCredentials.shared.displayIdentifier(for: api.origin) {
                return known
            }
            return TVL10n.value("login.accountActive")
        }
        return TVL10n.value("login.notSignedIn")
    }

    @MainActor
    private func reloadSidebarIdentity(api: TypeTypeAPI) async {
        guard api.origin.host != "preview.invalid" else { return }
        do {
            sidebarIdentity = try await api.currentAccount()
        } catch {
            // Network hiccups must not discard the last known identity.
        }
    }

    @MainActor
    private func accountDidChange(api: TypeTypeAPI) {
        // Unmount the previous user's Home/Library/player state immediately.
        // Later requests and progress UI must belong to the newly selected user.
        TVLocalProgress.shared.clear()
        accountGeneration += 1
        sidebarIdentity = nil
        Task { await reloadSidebarIdentity(api: api) }
        if returnToSwitcherAfterLogin {
            returnToSwitcherAfterLogin = false
            section = .account
        }
    }

    private func open(_ destination: TVSection) {
        if destination == .settings && section != .account {
            settingsEntryGroup = initialSettingsGroup
        }
        section = destination
        // Selecting a destination transfers focus INTO its content. Keeping
        // menuFocus = destination stranded the remote in the global rail,
        // even after opening Settings -> Apple TV.
        menuFocus = nil
        expanded = false
    }

    private func revealMenu() {
        menuFocus = section
        expanded = true
    }
}

struct HomeView: View {
    let api: TypeTypeAPI
    let onRevealMenu: () -> Void
    let onOpenAccount: () -> Void
    let sidebarFocused: Bool
    private let previewVideos: [VideoItem]?

    @State private var videos: [VideoItem]
    @State private var recentVideos: [VideoItem]
    @State private var message: String?
    @State private var recentError: String?
    @State private var recentNeedsLogin = false
    @State private var loading: Bool
    @State private var loadingRecent: Bool
    @State private var nextCursor: String?
    @State private var hasMoreRecommendations = false
    @State private var loadingMore = false
    @State private var loadMoreError: String?

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 26), count: 4)

    init(api: TypeTypeAPI, previewVideos: [VideoItem]? = nil,
         onRevealMenu: @escaping () -> Void = {},
         onOpenAccount: @escaping () -> Void = {},
         sidebarFocused: Bool = false) {
        self.api = api
        self.previewVideos = previewVideos
        self.onRevealMenu = onRevealMenu
        self.onOpenAccount = onOpenAccount
        self.sidebarFocused = sidebarFocused
        _videos = State(initialValue: previewVideos ?? [])
        _recentVideos = State(initialValue: previewVideos.map {
            Array($0.prefix(4))
        } ?? [])
        _loading = State(initialValue: previewVideos == nil)
        _loadingRecent = State(initialValue: previewVideos == nil)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 32) {
                HStack {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("home.forYou")
                            .font(.subheadline.bold())
                            .tracking(2.4)
                            .foregroundStyle(TTTheme.accent)
                        Text("nav.home")
                            .font(.system(size: 48, weight: .bold))
                    }
                    Spacer()
                    Button {
                        Task { await refresh() }
                    } label: {
                        Label("common.refresh", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(.bordered)
                    // Do not steal the initial Right move from the icon rail.
                    // Once a thumbnail receives focus, Up can reach Refresh.
                    .disabled((loading && loadingRecent) || previewVideos != nil ||
                              sidebarFocused)
                }

                VStack(alignment: .leading, spacing: 19) {
                    Text("home.recentlyWatched")
                        .font(.system(size: 35, weight: .bold))
                    if loadingRecent && recentVideos.isEmpty {
                        ProgressView("home.loadingHistory")
                            .frame(maxWidth: .infinity, minHeight: 135)
                    } else if !recentVideos.isEmpty {
                        videoGrid(recentVideos)
                    } else if recentNeedsLogin {
                        VStack(alignment: .leading, spacing: 15) {
                            Text("home.signInForHistory")
                                .foregroundStyle(TTTheme.muted)
                            Button {
                                onOpenAccount()
                            } label: {
                                Label("settings.pair", systemImage: "person.crop.circle")
                            }
                            .buttonStyle(.borderedProminent)
                        }
                    } else {
                        Text(recentError ?? TVL10n.value("library.historyEmpty"))
                            .foregroundStyle(TTTheme.muted)
                            .font(.callout)
                    }
                }

                Divider().padding(.vertical, 6)

                VStack(alignment: .leading, spacing: 19) {
                    HStack {
                        Text("home.recommendations")
                            .font(.system(size: 35, weight: .bold))
                        Spacer()
                        Text(TVL10n.formatted("common.videoCount", videos.count))
                            .font(.callout)
                            .foregroundStyle(TTTheme.muted)
                    }
                    if loading && videos.isEmpty {
                        ProgressView("home.loading")
                            .frame(maxWidth: .infinity, minHeight: 200)
                    } else if videos.isEmpty {
                        TVContentMessage(
                            symbol: message == nil ? "rectangle.stack" : "wifi.exclamationmark",
                            title: TVL10n.value(
                                message == nil ? "home.noRecommendations" : "home.serverUnavailable"
                            ),
                            detail: message ?? TVL10n.value("home.emptyHelp"),
                            action: { Task { await loadRecommendations() } }
                        )
                    } else {
                        videoGrid(videos, paginate: true)
                        if loadingMore {
                            ProgressView("home.loadingMore")
                                .frame(maxWidth: .infinity)
                        } else if hasMoreRecommendations || loadMoreError != nil {
                            Button("home.loadMore") {
                                Task { await loadMoreRecommendations() }
                            }
                            .buttonStyle(.bordered)
                            .frame(maxWidth: .infinity)
                        }
                        if let loadMoreError {
                            Text(loadMoreError)
                                .font(.callout)
                                .foregroundStyle(.orange)
                        }
                    }
                }
            }
            .padding(.horizontal, 64)
            .padding(.top, 42)
            .padding(.bottom, 120)
        }
        .background(TTTheme.ink)
        .task {
            if previewVideos == nil { await refresh() }
        }
        .onExitCommand { onRevealMenu() }
    }

    @ViewBuilder
    private func videoGrid(_ items: [VideoItem], paginate: Bool = false) -> some View {
        LazyVGrid(columns: columns, alignment: .leading, spacing: 34) {
            ForEach(Array(items.enumerated()), id: \.offset) { index, video in
                NavigationLink {
                    VideoDetailView(api: api, video: video)
                } label: {
                    VideoCard(api: api, video: video)
                }
                .buttonStyle(.card)
                .videoActions(api: api, video: video) {
                    Task { await refresh() }
                }
                .onMoveCommand { direction in
                    if direction == .left && index % columns.count == 0 {
                        onRevealMenu()
                    }
                }
                .accessibilityLabel(TTTheme.accessibilityText(for: video))
                .onAppear {
                    // LazyVGrid renders only the rows approaching the viewport.
                    // Prefetch the following page when nearing the last row,
                    // never during initial Home appearance.
                    if paginate, index >= items.count - columns.count - 1,
                       hasMoreRecommendations, !loading, !loadingMore {
                        Task { await loadMoreRecommendations() }
                    }
                }
            }
        }
        .focusSection()
    }

    @MainActor
    private func refresh() async {
        async let recommendations: Void = loadRecommendations()
        async let history: Void = loadHistory()
        _ = await (recommendations, history)
    }

    @MainActor
    private func loadRecommendations() async {
        guard previewVideos == nil else { return }
        loading = true
        defer { loading = false }
        do {
            let page = try await api.home()
            guard !Task.isCancelled else { return }
            nextCursor = page.nextCursor?.isEmpty == false ? page.nextCursor : nil
            hasMoreRecommendations = (page.hasMore ?? (nextCursor != nil)) &&
                nextCursor != nil
            loadMoreError = nil
            videos = page.items
            message = nil
            let enriched = await api.withProgress(page.items)
            guard !Task.isCancelled else { return }
            videos = enriched
        } catch is CancellationError {
            return
        } catch {
            message = error.localizedDescription
        }
    }

    @MainActor
    private func loadMoreRecommendations() async {
        guard previewVideos == nil, !loading, !loadingMore,
              hasMoreRecommendations, let cursor = nextCursor else { return }
        loadingMore = true
        loadMoreError = nil
        defer { loadingMore = false }
        do {
            let page = try await api.home(cursor: cursor)
            guard !Task.isCancelled else { return }
            let existing = Set(videos.map(\.url))
            var seen = existing
            let additional = page.items.filter { seen.insert($0.url).inserted }
            // Preserve existing cards and the user's scroll position. Only
            // fetch progress decoration for the newly appended page.
            let enriched = await api.withProgress(additional)
            guard !Task.isCancelled else { return }
            videos.append(contentsOf: enriched)
            let candidate = page.nextCursor?.isEmpty == false ? page.nextCursor : nil
            // Protect against servers returning the same cursor forever.
            nextCursor = candidate != cursor ? candidate : nil
            hasMoreRecommendations = (page.hasMore ?? (nextCursor != nil)) &&
                nextCursor != nil
        } catch is CancellationError {
            return
        } catch {
            loadMoreError = error.localizedDescription
        }
    }

    @MainActor
    private func loadHistory() async {
        guard previewVideos == nil else { return }
        loadingRecent = true
        defer { loadingRecent = false }
        do {
            let latest = Array(try await api.library(.history).prefix(8))
            guard !Task.isCancelled else { return }
            recentVideos = latest
            recentNeedsLogin = false
            recentError = nil
            let enriched = await api.withProgress(latest)
            guard !Task.isCancelled else { return }
            recentVideos = enriched
        } catch is CancellationError {
            return
        } catch TypeTypeError.http(let status, _) where status == 401 || status == 403 {
            recentVideos = []
            recentNeedsLogin = true
            recentError = nil
        } catch {
            recentVideos = []
            recentNeedsLogin = false
            recentError = error.localizedDescription
        }
    }
}

struct VideoCard: View {
    let api: TypeTypeAPI
    let video: VideoItem
    @ObservedObject private var localProgress = TVLocalProgress.shared

    private var effectivePosition: Int64? {
        localProgress.positions[video.url] ?? video.watchPositionMs
    }
    private var fraction: Double? {
        guard video.isLive != true,
              let duration = video.duration, duration > 0,
              let progress = effectivePosition, progress > 0 else { return nil }
        return max(0, min(1, Double(progress) / Double(Int64(duration) * 1_000)))
    }
    private var completed: Bool {
        // Some server versions expose a 'watched' convenience flag whose
        // duration and progress units differ. Prefer measured millisecond
        // progress and its 90% threshold whenever the position is available.
        if effectivePosition != nil { return (fraction ?? 0) >= 0.90 }
        return video.watched == true
    }
    private var watchedTime: String? {
        guard let progress = effectivePosition, progress > 0 else { return nil }
        return TTTheme.time(Int(progress / 1_000))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ZStack(alignment: .bottomTrailing) {
                TVThumbnail(url: api.relativeMediaURL(video.thumbnailUrl), origin: api.origin)
                    .grayscale(completed ? 1 : 0)
                    .frame(height: 198).frame(maxWidth: .infinity).clipped()
                if let position = watchedTime, video.isLive != true {
                    Label(position, systemImage: completed ? "checkmark.circle.fill" : "play.circle")
                        .font(.caption.monospacedDigit())
                        .padding(7)
                        .background(.black.opacity(0.84), in: RoundedRectangle(cornerRadius: 6))
                        .frame(maxWidth: .infinity, maxHeight: .infinity,
                               alignment: .topLeading)
                        .padding(7)
                }
                if video.isLive == true {
                    Text("video.liveBadge").font(.caption.bold())
                        .padding(8).background(TTTheme.accent).padding(8)
                } else if let duration = video.duration, duration > 0 {
                    Text(TTTheme.time(duration))
                        .font(.caption.monospacedDigit())
                        .padding(8).background(.black.opacity(0.8)).padding(8)
                }
                if let fraction {
                    GeometryReader { proxy in
                        Rectangle()
                            .fill(TTTheme.accent)
                            .frame(width: proxy.size.width * fraction, height: 6)
                            .frame(maxWidth: .infinity, maxHeight: .infinity,
                                   alignment: .bottomLeading)
                    }
                    .allowsHitTesting(false)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 10))
            VStack(alignment: .leading, spacing: 7) {
                Text(video.title)
                    .font(.system(size: 21, weight: .semibold))
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, minHeight: 54, alignment: .topLeading)
                Text(video.uploaderName ?? "")
                    .font(.system(size: 17))
                    .foregroundStyle(TTTheme.muted)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, minHeight: 23, alignment: .topLeading)
            }
            .padding(.horizontal, 14)
            .padding(.top, 11)
            .padding(.bottom, 13)
            .background(TTTheme.surface)
        }
        .frame(minHeight: 305, alignment: .top)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .foregroundStyle(.white)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(TTTheme.accessibilityText(for: video))
    }
}
