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
    }

    var body: some View {
        if let api = try? TypeTypeAPI(address: instanceOrigin) {
            HStack(spacing: 0) {
                sidebar
                    .zIndex(1)
                NavigationStack {
                    Group {
                        switch section {
                        case .home:
                            HomeView(
                                api: api, previewVideos: previewVideos,
                                onRevealMenu: revealMenu,
                                onOpenAccount: { open(.account) }
                            )
                        case .search:
                            SearchView(api: api)
                        case .library:
                            LibraryView(api: api)
                        case .playlists:
                            LibraryView(api: api, preferPlaylists: true)
                        case .account:
                            PreferencesView(
                                api: api, onDisconnect: onDisconnect,
                                initialGroup: .account,
                                onAccountChanged: { Task { await reloadSidebarIdentity(api: api) } }
                            )
                        case .settings:
                            PreferencesView(
                                api: api, onDisconnect: onDisconnect,
                                initialGroup: initialSettingsGroup,
                                onAccountChanged: { Task { await reloadSidebarIdentity(api: api) } }
                            )
                        }
                    }
                }
                .id(section)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .focusSection()
            }
            .background(TTTheme.ink)
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
            HStack(spacing: 11) {
                Image(systemName: "play.rectangle.fill")
                    .font(.system(size: 27))
                    .foregroundStyle(TTTheme.accent)
                    .frame(width: 38)
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
        .padding(.horizontal, 11)
        .padding(.top, 24)
        .padding(.bottom, 25)
        .frame(width: expanded ? 244 : 74)
        .frame(maxHeight: .infinity)
        .background(TTTheme.surface)
        .animation(navigationAnimations ? .easeInOut(duration: 0.16) : nil, value: expanded)
        // The full-height focus section makes the remote cross to the nearest
        // content control even when no item is at exactly the same Y position.
        .focusSection()
        .onChange(of: menuFocus) { _, focused in
            expanded = focused != nil
        }
    }

    private func sidebarButton(_ item: TVSection) -> some View {
        Button {
            open(item)
        } label: {
            HStack(spacing: 12) {
                Image(systemName: item == .account && sidebarIdentity?.isGuest == false
                      ? "person.crop.circle.fill" : item.icon)
                    .font(.system(size: 24, weight: .medium))
                    .frame(width: 38, height: 54)
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
            .padding(.horizontal, 7)
            .frame(height: 54)
            .frame(maxWidth: .infinity, alignment: .leading)
            // Never change size or draw the native tvOS focus overlay.
            .foregroundStyle(menuFocus == item ? .white :
                             (section == item ? TTTheme.accent : TTTheme.muted))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
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

    private func open(_ destination: TVSection) {
        section = destination
        // Focus stays on the selected rail item until the user moves right.
        // onChange(of: menuFocus) collapses the rail when focus leaves.
        menuFocus = destination
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
    private let previewVideos: [VideoItem]?

    @State private var videos: [VideoItem]
    @State private var recentVideos: [VideoItem]
    @State private var message: String?
    @State private var recentError: String?
    @State private var recentNeedsLogin = false
    @State private var loading: Bool
    @State private var loadingRecent: Bool

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 26), count: 4)

    init(api: TypeTypeAPI, previewVideos: [VideoItem]? = nil,
         onRevealMenu: @escaping () -> Void = {},
         onOpenAccount: @escaping () -> Void = {}) {
        self.api = api
        self.previewVideos = previewVideos
        self.onRevealMenu = onRevealMenu
        self.onOpenAccount = onOpenAccount
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
                    .disabled((loading && loadingRecent) || previewVideos != nil)
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
                        videoGrid(videos)
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
    }

    @ViewBuilder
    private func videoGrid(_ items: [VideoItem]) -> some View {
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
            let result = try await api.home().items
            guard !Task.isCancelled else { return }
            videos = result
            message = nil
            let enriched = await api.withProgress(result)
            guard !Task.isCancelled else { return }
            videos = enriched
        } catch is CancellationError {
            return
        } catch {
            message = error.localizedDescription
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
