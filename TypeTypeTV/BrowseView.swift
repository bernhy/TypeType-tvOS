import SwiftUI

/// Main sections remain accessible using a narrow icon rail. Moving left from
/// the first thumbnail expands the rail and puts focus on the current section.
enum TVSection: String, CaseIterable, Hashable {
    case home, search, subscriptions, channels, library, account, settings

    var label: String {
        switch self {
        case .home: return TVL10n.value("nav.home")
        case .search: return TVL10n.value("nav.search")
        case .library: return TVL10n.value("nav.library")
        case .subscriptions: return TVL10n.value("nav.subscriptions")
        case .channels: return TVL10n.value("nav.channels")
        case .account: return TVL10n.value("settings.groupAccount")
        case .settings: return TVL10n.value("nav.settings")
        }
    }
    var localizedLabel: LocalizedStringKey {
        switch self {
        case .home: return "nav.home"
        case .search: return "nav.search"
        case .library: return "nav.library"
        case .subscriptions: return "nav.subscriptions"
        case .channels: return "nav.channels"
        case .account: return "settings.groupAccount"
        case .settings: return "nav.settings"
        }
    }
    var icon: String {
        switch self {
        case .home: return "house.fill"
        case .search: return "magnifyingglass"
        case .library: return "books.vertical"
        case .subscriptions: return "play.rectangle.on.rectangle"
        case .channels: return "rectangle.stack"
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
    @State private var enteringFromMenu = false
    @State private var menuHandoffActive = false
    @State private var menuHandoffGeneration = 0
    // When returning from content, tvOS may momentarily choose the closest
    // *other* icon before @FocusState can restore our selected section.
    // Restrict the rail to the intended icon until that Left move settles.
    @State private var returnToRailTarget: TVSection?
    @State private var returnToRailGeneration = 0
    @State private var searchFocusRequest = 0
    @State private var sidebarIdentity: TVAccountIdentity?
    @ObservedObject private var playbackVisibility = TVPlaybackVisibility.shared
    @ObservedObject private var playlistPopup = TVPlaylistPopupPresenter.shared
    @State private var settingsEntryGroup: TVSettingsGroup
    @State private var settingsFocusRequest = 0
    @State private var homeFocusRequest = 0
    // On a fresh Home launch, prevent UIKit from selecting the icon rail
    // before the recommendations grid is mounted and can accept focus.
    @State private var homeStartupFocusPending = false
    @State private var libraryFocusRequest = 0
    @State private var subscriptionFocusRequest = 0
    @State private var channelFocusRequest = 0
    @State private var accountFocusRequest = 0
    @State private var accountGeneration = 0
    @State private var returnToSwitcherAfterLogin = false
    @AppStorage("typetype.navigationAnimations") private var navigationAnimations = true
    @FocusState private var menuFocus: TVSection?

    // Previewing and entering a page are different states. Once an explicit
    // activation starts, content may claim focus even if tvOS has not yet
    // delivered the menu's focus-loss notification.
    private var menuPreviewVisible: Bool { expanded && !enteringFromMenu }

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
        // On cold launch, start directly in Home recommendations, never
        // in the left rail or the Recent history grid.
        _homeFocusRequest = State(
            initialValue: initialSection == .home && !initiallyExpanded ? 1 : 0
        )
        _homeStartupFocusPending = State(
            initialValue: initialSection == .home && !initiallyExpanded
        )
        _settingsEntryGroup = State(initialValue: initialSettingsGroup)
    }

    var body: some View {
        if let api = try? TypeTypeAPI(address: instanceOrigin) {
            ZStack(alignment: .leading) {
                TTTheme.ink.ignoresSafeArea()
                HStack(spacing: 0) {
                    if !playbackVisibility.isVisible {
                        sidebar
                            // Home's first-column Left/Back handlers reveal
                            // the menu explicitly. While collapsed, its
                            // focusable icons must never steal focus during
                            // lazy-grid updates or scroll changes.
                            .disabled(homeStartupFocusPending ||
                                      (section == .home && !expanded))
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
                                onInitialFocusReady: { homeStartupFocusPending = false },
                                sidebarFocused: menuPreviewVisible,
                                focusRequest: menuPreviewVisible ? -1 : homeFocusRequest
                            )
                        case .search:
                            SearchView(
                                api: api,
                                focusRequest: menuPreviewVisible ? -1 : searchFocusRequest
                            )
                            .onExitCommand { revealMenu() }
                        case .library:
                            LibraryView(api: api,
                                        focusRequest: menuPreviewVisible ? -1 : libraryFocusRequest,
                                        onRevealMenu: revealMenu)
                        case .subscriptions:
                            TVSubscriptionFeedView(api: api,
                                                   focusRequest: menuPreviewVisible ? -1 : subscriptionFocusRequest,
                                                   onRevealMenu: revealMenu)
                        case .channels:
                            TVSubscriptionsView(api: api,
                                                focusRequest: menuPreviewVisible ? -1 : channelFocusRequest,
                                                onRevealMenu: revealMenu)
                        case .account:
                            TVAccountSwitcherView(
                                api: api,
                                onAddAccount: {
                                    settingsEntryGroup = .account
                                    returnToSwitcherAfterLogin = true
                                    open(.settings)
                                },
                                onAccountChanged: { accountDidChange(api: api) },
                                focusRequest: menuPreviewVisible ? -1 : accountFocusRequest
                            )
                            .onExitCommand { revealMenu() }
                        case .settings:
                            PreferencesView(
                                api: api, onDisconnect: onDisconnect,
                                initialGroup: settingsEntryGroup,
                                focusRequest: menuPreviewVisible ? -1 : settingsFocusRequest,
                                autoPresentAddAccount: returnToSwitcherAfterLogin,
                                onAccountChanged: { accountDidChange(api: api) },
                                onBackToMenu: revealMenu,
                                onGroupChanged: { settingsEntryGroup = $0 },
                                onAddAccountDismissed: { returnToSwitcherAfterLogin = false }
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
                // Keep the entire existing navigation screen visible beneath
                // the picker instead of presenting an opaque tvOS sheet.
                .disabled(playlistPopup.request != nil)

                if let request = playlistPopup.request {
                    ZStack {
                        Color.black.opacity(0.18).ignoresSafeArea()
                        TVPlaylistPickerView(
                            api: request.api, video: request.video,
                            onSaved: { playlistPopup.finish(result: $0) },
                            onCancel: { playlistPopup.finish() }
                        )
                        .id(request.video.url)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .focusSection()
                    .onExitCommand { playlistPopup.finish() }
                    .zIndex(10)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(TTTheme.ink.ignoresSafeArea())
            .task { await reloadSidebarIdentity(api: api) }
            .onDisappear { playlistPopup.finish() }
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
                // Official TypeType TV-shaped mark, generated from the same
                // vector geometry and red as the app icon.
                Image("TypeTypeLogo")
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .frame(width: 36, height: 36)
                    .accessibilityHidden(true)
                if expanded {
                    Text("TypeType")
                        .font(.system(size: 23, weight: .bold))
                        .lineLimit(1)
                        .transition(.opacity)
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
        // We extend the rail through the tvOS top/bottom safe areas, but
        // preserve comfortable logo and Settings icon positions within the
        // actual visible screen (roughly like the YouTube TV sidebar).
        .padding(.top, 72)
        .padding(.bottom, 72)
        .frame(width: expanded ? 214 : 56)
        .frame(maxHeight: .infinity)
        // Paint behind the actual sidebar, not behind the entire HStack.
        // Color.ignoresSafeArea expands the background's paint region above
        // and below the safe-area-limited rail content. This is deliberately
        // the same surface for BOTH expanded and collapsed presentations.
        .background {
            TTTheme.surface
                .ignoresSafeArea(.container, edges: [.top, .bottom, .leading])
        }
        // PlainButtonStyle still permits native focus decoration on tvOS 26.
        // Disable it for the entire rail; only our pill is allowed to render.
        .environment(\.isFocusEffectEnabled, false)
        .focusEffectDisabled(true)
        .animation(navigationAnimations ? .easeInOut(duration: 0.28) : nil, value: expanded)
        .focusSection()
        .onExitCommand {
            // Back while the global rail is focused goes to Home. The final
            // Back on the Home icon is consumed here, never exits TypeType.
            if section == .home {
                // On Home, the next Back returns to the first recommendation.
                open(.home)
            } else {
                section = .home
                menuFocus = .home
                expanded = true
            }
        }
        .onChange(of: menuFocus) { previous, focused in
            if let target = returnToRailTarget {
                // Ignore transient native focus callbacks while the Left
                // movement is resolving. Never preview Account when
                // returning from the Settings subnavigation.
                if focused != target {
                    menuFocus = target
                }
                return
            }
            if enteringFromMenu || menuHandoffActive {
                // Ignore tvOS focus callbacks while the old rail icon is
                // disabled for an explicit handoff. Otherwise Right can
                // immediately re-expand the sidebar and steal page focus.
                // In particular, never re-expand the rail on a transient
                // focus callback while the destination is mounting.
                if focused == nil {
                    enteringFromMenu = false
                    expanded = false
                }
                return
            }

            if let focused {
                expanded = true
                if previous == nil, focused != section {
                    // Left from content returns to the section we left,
                    // not to whichever icon is geometrically nearest.
                    let previouslyShown = section
                    Task { @MainActor in
                        await Task.yield()
                        if menuFocus == focused && expanded {
                            menuFocus = previouslyShown
                        }
                    }
                } else if previous != nil, section != focused {
                    // Up/Down previews a page but keeps rail focus.
                    section = focused
                }
            } else if expanded {
                // An actual focus move out of the rail (including touchpad
                // Right) is an entry, not a reason to pull focus back.
                open(section)
            }
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
                            .transition(.opacity)
                    }
                    Spacer(minLength: 0)
                }
            }
            .padding(.horizontal, 2)
            .frame(height: 52)
            .frame(maxWidth: .infinity, alignment: .leading)
            .modifier(TVRailRowHighlight(
                // Rendering from native menuFocus alone flashes "Account"
                // before the return-to-Settings handoff has settled.
                // Paint ONLY the logical destination while crossing rails;
                // @FocusState still drives the actual Siri Remote controls.
                focused: !enteringFromMenu && !menuHandoffActive &&
                    TVRailVisualFocus.highlights(
                        item, focused: returnToRailTarget ?? menuFocus,
                        selected: section
                    ),
                selected: section == item
            ))
        }
        .buttonStyle(TVRailButtonStyle())
        .focusEffectDisabled(true)
        // Never disable neighboring rail icons while returning from content:
        // otherwise an immediate Up/Down on the remote is swallowed for
        // 360 ms. The visual handoff is controlled by TVRailVisualFocus.
        .disabled(menuHandoffActive)
        .focused($menuFocus, equals: item)
        .accessibilityLabel(item.label)
        .accessibilityIdentifier("main-nav-\(item.rawValue)")
        .onMoveCommand { direction in
            if direction == .up || direction == .down {
                // A genuine vertical move explicitly ends the visual
                // Left-to-rail handoff immediately, even if the native
                // focus engine is still finishing its previous update.
                returnToRailGeneration &+= 1
                returnToRailTarget = nil
            } else if direction == .right {
                // Right, including a touchpad swipe, is equivalent to OK.
                // .onChange(of: menuFocus) must not undo this handoff.
                open(item)
            }
        }
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
        TVWatchLaterMembership.shared.invalidate()
        TVFavoriteMembership.shared.invalidate()
        TVContentPreferences.shared.invalidate()
        accountGeneration += 1
        sidebarIdentity = nil
        Task { await reloadSidebarIdentity(api: api) }
        if returnToSwitcherAfterLogin {
            returnToSwitcherAfterLogin = false
            section = .account
        }
    }

    private func open(_ destination: TVSection) {
        // Cancel any pending Left-to-rail handoff before a Right/OK enter.
        returnToRailGeneration &+= 1
        returnToRailTarget = nil
        // Explicit activation is the ONLY path which transfers focus from
        // the main rail to a page. Up/Down continues to preview on focus.
        let wasInMenu = menuFocus != nil
        enteringFromMenu = wasInMenu
        section = destination
        expanded = false

        // Right can still be resolved by UIKit after onMoveCommand returns.
        // Make the old sidebar icon temporarily ineligible for focus, or a
        // late focus callback reopens the rail instead of entering the page.
        if wasInMenu {
            menuHandoffActive = true
            menuHandoffGeneration &+= 1
            let generation = menuHandoffGeneration
            menuFocus = nil
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(360))
                guard generation == menuHandoffGeneration else { return }
                menuFocus = nil
                expanded = false
                enteringFromMenu = false
                menuHandoffActive = false
                // Search is already mounted during menu preview. Re-issue
                // its focus request after UIKit has completed the Right move.
                if destination == .search {
                    searchFocusRequest &+= 1
                }
            }
        }

        // The child gets a new request after the menu has been released.
        // This works for both a previewed (already mounted) destination
        // and a new section, and lets a second activation re-enter it.
        switch destination {
        case .settings: settingsFocusRequest += 1
        case .home: homeFocusRequest += 1
        case .library: libraryFocusRequest += 1
        case .subscriptions: subscriptionFocusRequest += 1
        case .channels: channelFocusRequest += 1
        case .account: accountFocusRequest += 1
        case .search: searchFocusRequest += 1
        }
    }

    private func revealMenu() {
        menuHandoffGeneration &+= 1
        menuHandoffActive = false
        enteringFromMenu = false
        // The active page, not the nearest vertically positioned rail icon,
        // must own the first visible focus frame on return.
        let target = section
        returnToRailGeneration &+= 1
        let generation = returnToRailGeneration
        returnToRailTarget = target
        menuFocus = target
        expanded = true

        // UIKit may finish its Left move after this handler returns. Keep
        // other rail icons out of the focus search until the remote movement
        // and our 0.28s expansion have completed. Subsequent Up/Down moves
        // once again work normally.
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(360))
            guard generation == returnToRailGeneration,
                  returnToRailTarget == target else { return }
            menuFocus = target
            returnToRailTarget = nil
        }
    }
}

/// Stable identity survives history/recommendation enrichment, filtering,
/// and pagination. Index-based ForEach identity remounts the wrong card when
/// a preceding video disappears, which can reset focus to item zero.
private struct TVHomeGridEntry: Identifiable {
    let index: Int
    let video: VideoItem
    var id: String { video.url }
}

struct HomeView: View {
    let api: TypeTypeAPI
    @ObservedObject private var contentPreferences = TVContentPreferences.shared
    @ObservedObject private var localProgress = TVLocalProgress.shared
    let onRevealMenu: () -> Void
    let onOpenAccount: () -> Void
    let onInitialFocusReady: () -> Void
    let sidebarFocused: Bool
    let focusRequest: Int
    @FocusState private var focusedHomeVideo: String?
    // A separate desired target must survive transient FocusState=nil while
    // a detail screen is popped. Otherwise resetFocus selects item 0 and
    // pulls the deep-scrolled grid back to the top.
    @State private var preferredHomeCardID: String?
    @Namespace private var homeFocusScope
    @Environment(\.resetFocus) private var resetFocus
    @State private var needsHomeFocus = false
    // .task(id:) can run again when NavigationStack returns from details.
    // Consume each explicit request once, so reappearing Home cannot
    // overwrite the card-specific focus restoration with recommendation 0.
    @State private var processedHomeFocusRequest = 0
    @State private var pendingHomeFocus: Task<Void, Never>?
    @State private var homeFocusGeneration = 0
    @State private var didLoadHomeOnce = false

    private func homeCardID(_ video: VideoItem, recommended: Bool) -> String {
        (recommended ? "recommendation-" : "recent-") + video.url
    }
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
    private var visibleRecent: [VideoItem] {
        // Home is resume-only; the complete watch history remains in Library.
        // Local playback updates may already be newer than the server list
        // when returning from a video without reloading the entire grid.
        contentPreferences.displayed(recentVideos).filter {
            TVContinueWatchingPolicy.isEligible(
                $0, positionMs: localProgress.position(for: $0.url) ?? $0.watchPositionMs
            )
        }.prefix(8).map { $0 }
    }
    private var visibleRecommendations: [VideoItem] { contentPreferences.displayed(videos) }
    private var showRecent: Bool { contentPreferences.settings?.hideContinueWatching != true }
    private var showRecommendations: Bool { contentPreferences.settings?.hideHomeRecommendations != true }
    private var firstVisible: (video: VideoItem, recommendation: Bool)? {
        if showRecommendations, let v = visibleRecommendations.first { return (v, true) }
        if showRecent, let v = visibleRecent.first { return (v, false) }
        return nil
    }

    init(api: TypeTypeAPI, previewVideos: [VideoItem]? = nil,
         onRevealMenu: @escaping () -> Void = {},
         onOpenAccount: @escaping () -> Void = {},
         onInitialFocusReady: @escaping () -> Void = {},
         sidebarFocused: Bool = false,
         focusRequest: Int = 0) {
        self.api = api
        self.previewVideos = previewVideos
        self.onRevealMenu = onRevealMenu
        self.onOpenAccount = onOpenAccount
        self.onInitialFocusReady = onInitialFocusReady
        self.sidebarFocused = sidebarFocused
        self.focusRequest = focusRequest
        _videos = State(initialValue: previewVideos ?? [])
        _preferredHomeCardID = State(
            initialValue: previewVideos?.first.map { "recommendation-" + $0.url }
        )
        _recentVideos = State(initialValue: previewVideos.map {
            Array($0.prefix(4))
        } ?? [])
        _loading = State(initialValue: previewVideos == nil)
        _loadingRecent = State(initialValue: previewVideos == nil)
    }

    var body: some View {
        ScrollViewReader { scroll in
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

                if showRecent {
                VStack(alignment: .leading, spacing: 19) {
                    Text("home.continueWatching")
                        .font(.system(size: 35, weight: .bold))
                    if loadingRecent && recentVideos.isEmpty {
                        TVPulsingPlaceholder()
                            .frame(maxWidth: .infinity, minHeight: 135)
                    } else if !visibleRecent.isEmpty {
                        videoGrid(visibleRecent, scroll: scroll,
                                  lookupHistoryMetadata: true)
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

                }
                if showRecommendations {
                Divider().padding(.vertical, 6)

                VStack(alignment: .leading, spacing: 19) {
                    HStack {
                        Text("home.recommendations")
                            .font(.system(size: 35, weight: .bold))
                        Spacer()
                        Text(TVL10n.formatted("common.videoCount", visibleRecommendations.count))
                            .font(.callout)
                            .foregroundStyle(TTTheme.muted)
                    }
                    if loading && videos.isEmpty {
                        TVPulsingPlaceholder()
                            .frame(maxWidth: .infinity, minHeight: 200)
                    } else if visibleRecommendations.isEmpty {
                        TVContentMessage(
                            symbol: message == nil ? "rectangle.stack" : "wifi.exclamationmark",
                            title: TVL10n.value(
                                message == nil ? "home.noRecommendations" : "home.serverUnavailable"
                            ),
                            detail: message ?? TVL10n.value("home.emptyHelp"),
                            action: { Task { await loadRecommendations() } }
                        )
                    } else {
                        videoGrid(visibleRecommendations, scroll: scroll, paginate: true)
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
            }
            .padding(.horizontal, 64)
            .padding(.top, 42)
            .padding(.bottom, 120)
        }
            .background(TTTheme.ink)
            .focusScope(homeFocusScope)
            .task {
                await contentPreferences.ensureLoaded(api: api)
                // A detail push/pop can restart .task while the user is on
                // a deep recommendation. Reloading the entire grid there
                // invalidates focus and often selects tile zero or the rail.
                if previewVideos == nil && !didLoadHomeOnce {
                    didLoadHomeOnce = true
                    await refresh()
                }
            }
            .onExitCommand { handleHomeBack(scroll: scroll) }
            .task(id: focusRequest) {
                guard focusRequest > 0,
                      processedHomeFocusRequest != focusRequest else { return }
                processedHomeFocusRequest = focusRequest
                needsHomeFocus = true
                await Task.yield()
                focusFirstHomeVideo(scroll: scroll)
            }
            .onChange(of: recentVideos.count) { _, _ in
                focusFirstHomeVideo(scroll: scroll)
            }
            .onChange(of: videos.count) { _, _ in
                focusFirstHomeVideo(scroll: scroll)
            }
            .onChange(of: focusedHomeVideo) { _, current in
                guard let current else { return }
                // Never mistake a transient wrong tile selected during a
                // programmatic scroll/return for user navigation. User remote
                // moves cancel the pending restore in videoGrid below.
                if pendingHomeFocus == nil && preferredHomeCardID != current {
                    preferredHomeCardID = current
                }
                if let first = firstVisible,
                   current == homeCardID(first.video, recommended: first.recommendation) {
                    onInitialFocusReady()
                }
            }
            .onChange(of: loading) { _, stillLoading in
                // An empty or unavailable recommendation feed must never
                // permanently lock the user out of the main navigation.
                if !stillLoading && firstVisible == nil { onInitialFocusReady() }
            }
        }
    }

    @MainActor
    private func handleHomeBack(scroll: ScrollViewProxy) {
        if let first = firstVisible {
            let target = homeCardID(first.video, recommended: first.recommendation)
            if focusedHomeVideo != target {
                focusHomeCard(target, scroll: scroll)
            } else {
                onRevealMenu()
            }
        } else {
            onRevealMenu()
        }
    }

    @MainActor
    private func focusHomeCard(_ target: String, scroll: ScrollViewProxy,
                               returningFromDetails: Bool = false) {
        pendingHomeFocus?.cancel()
        homeFocusGeneration &+= 1
        let generation = homeFocusGeneration
        // Keep the preferred target stable even while FocusState is cleared
        // for NavigationStack's pop animation.
        preferredHomeCardID = target
        pendingHomeFocus = Task { @MainActor in
            defer {
                if homeFocusGeneration == generation { pendingHomeFocus = nil }
            }
            // The pushed detail temporarily owns UIKit focus. Clearing our
            // old FocusState is necessary even when returning to the exact
            // same tile, otherwise assigning the same value does nothing.
            // Give NavigationStack's pop transition time to complete before
            // asking LazyVGrid to materialize an offscreen tile.
            if returningFromDetails {
                focusedHomeVideo = nil
                try? await Task.sleep(for: .milliseconds(450))
            }
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.18)) {
                scroll.scrollTo(target, anchor: .center)
            }
            try? await Task.sleep(for: .milliseconds(returningFromDetails ? 220 : 140))
            guard !Task.isCancelled, homeFocusGeneration == generation else { return }
            focusedHomeVideo = target
            resetFocus(in: homeFocusScope)
            if returningFromDetails {
                // tvOS can finish its focus transition just after the pop.
                // Re-evaluate the same preferred deep card if native focus
                // landed elsewhere; do not clear FocusState a second time,
                // as that used to select the top recommendation instead.
                try? await Task.sleep(for: .milliseconds(350))
                guard !Task.isCancelled else { return }
                if focusedHomeVideo != target {
                    withAnimation(.easeOut(duration: 0.18)) {
                        scroll.scrollTo(target, anchor: .center)
                    }
                    try? await Task.sleep(for: .milliseconds(180))
                    guard !Task.isCancelled else { return }
                    focusedHomeVideo = target
                    resetFocus(in: homeFocusScope)
                }
            }
        }
    }

    @MainActor
    private func userMovedWithinHome() {
        // Explicit directional input takes precedence over delayed startup
        // and post-detail focus restoration. Otherwise the pending timer
        // can send the cursor back to the first tile mid-navigation.
        homeFocusGeneration &+= 1
        pendingHomeFocus?.cancel()
        pendingHomeFocus = nil
    }

    @MainActor
    private func focusFirstHomeVideo(scroll: ScrollViewProxy) {
        guard needsHomeFocus else { return }
        // Wait for recommendations to arrive. Recent history may load first
        // but must never steal the initial Home focus.
        guard let first = firstVisible else { return }
        let target = homeCardID(first.video, recommended: first.recommendation)
        needsHomeFocus = false
        focusHomeCard(target, scroll: scroll)
    }

    @ViewBuilder
    private func videoGrid(_ items: [VideoItem], scroll: ScrollViewProxy,
                           paginate: Bool = false,
                           lookupHistoryMetadata: Bool = false) -> some View {
        LazyVGrid(columns: columns, alignment: .leading, spacing: 34) {
            ForEach(items.enumerated().map {
                TVHomeGridEntry(index: $0.offset, video: $0.element)
            }) { row in
                let index = row.index
                let video = row.video
                NavigationLink {
                    VideoDetailView(
                        api: api, video: video,
                        onReturnToList: {
                            focusHomeCard(
                                homeCardID(video, recommended: paginate),
                                scroll: scroll, returningFromDetails: true
                            )
                        }
                    )
                } label: {
                    VideoCard(api: api, video: video,
                              lookupMissingMetadata: lookupHistoryMetadata)
                }
                .buttonStyle(TVRailButtonStyle())
                .focusEffectDisabled(true)
                .zIndex(focusedHomeVideo ==
                    homeCardID(video, recommended: paginate) ? 5 : 0)
                .videoActions(api: api, video: video, onChanged: {
                    Task { await refresh() }
                }, focus: $focusedHomeVideo,
                   focusID: homeCardID(video, recommended: paginate))
                // The default focus engine otherwise prefers the first
                // (recently watched) grid or the global rail on cold launch.
                // Also gives resetFocus() a concrete deep-card destination
                // after popping a video details screen.
                .prefersDefaultFocus(
                    preferredHomeCardID == homeCardID(video, recommended: paginate),
                    in: homeFocusScope
                )
                .onMoveCommand { direction in
                    userMovedWithinHome()
                    if direction == .left && index % columns.count == 0 {
                        onRevealMenu()
                    }
                }
                .accessibilityLabel(TTTheme.accessibilityText(for: video))
                .accessibilityIdentifier(
                    "home-video-" + (paginate ? "recommendation-" : "recent-") + String(index)
                )
                .id(homeCardID(video, recommended: paginate))
                .onExitCommand { handleHomeBack(scroll: scroll) }
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
        await contentPreferences.ensureLoaded(api: api)
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
            // The first eight history records may all be finished. Fetch a
            // bounded recent history page, enrich saved positions, and then
            // choose up to eight eligible resumable items for Home.
            let raw = try await api.historyPage(offset: 0, limit: 100)
            guard !Task.isCancelled else { return }
            let latest = TVHistoryDeduplicator.unique(raw)
            let enriched = await api.withProgress(latest)
            guard !Task.isCancelled else { return }
            recentVideos = enriched
            recentNeedsLogin = false
            recentError = nil
        } catch is CancellationError {
            return
        } catch {
            recentVideos = []
            let status = TVServerErrorMapping.httpStatus(error)
            recentNeedsLogin = status == 401 || status == 403
            recentError = recentNeedsLogin ? nil : error.localizedDescription
        }
    }
}

struct VideoCard: View {
    let api: TypeTypeAPI
    let video: VideoItem
    @ObservedObject private var localProgress = TVLocalProgress.shared
    @ObservedObject private var watchLaterMembership = TVWatchLaterMembership.shared
    @ObservedObject private var playlistMembership = TVPlaylistMembership.shared
    @ObservedObject private var favoriteMembership = TVFavoriteMembership.shared
    @Environment(\.isFocused) private var isFocused
    var lookupMissingMetadata = false
    @State private var streamMetadata: StreamInfo?
    @State private var metadataVideoURL: String?

    private var metadataVideo: VideoItem {
        // SwiftUI recycles cards in grids. Never show the previous video's
        // stream metadata on a newly reused thumbnail cell.
        TVVideoMetadata.merged(
            video, stream: metadataVideoURL == video.url ? streamMetadata : nil
        )
    }

    private var effectivePosition: Int64? {
        localProgress.position(for: video.url) ?? video.watchPositionMs
    }
    private var fraction: Double? {
        guard video.isLive != true,
              let duration = metadataVideo.duration, duration > 0,
              let progress = effectivePosition, progress > 0 else { return nil }
        return max(0, min(1, Double(progress) / Double(Int64(duration) * 1_000)))
    }
    private var completed: Bool {
        // Some server versions expose a 'watched' convenience flag whose
        // duration and progress units differ. Prefer measured millisecond
        // progress and its 90% threshold whenever the position is available.
        TVWatchedState.isWatched(metadataVideo, positionMs: effectivePosition)
    }
    private var watchedTime: String? {
        guard let progress = effectivePosition, progress > 0 else { return nil }
        return TTTheme.time(Int(progress / 1_000))
    }

    private var videoMetadata: String? {
        TVVideoMetadata.subtitle(for: metadataVideo)
    }

    var body: some View {
        // One card surface, no transparent 10-point gap between artwork
        // and the info panel. That gap used to reveal the black grid behind.
        VStack(alignment: .leading, spacing: 0) {
            ZStack(alignment: .bottomTrailing) {
                TVThumbnail(url: api.relativeMediaURL(video.thumbnailUrl),
                            origin: api.origin, contentMode: .fit)
                    .grayscale(completed ? 1 : 0)
                    // Never scale thumbnail content: on tvOS the duration
                    // badge at the bottom-right otherwise appears enlarged
                    // and can be cropped by its card.
                    .aspectRatio(16.0 / 9.0, contentMode: .fit)
                    .frame(maxWidth: .infinity)
                    .clipped()
                if video.requiresMembership == true {
                    Label("video.membersOnly", systemImage: "person.crop.circle.badge.checkmark")
                        .font(.caption.bold())
                        .foregroundStyle(.white)
                        .padding(7)
                        .background(.black.opacity(0.88),
                                    in: RoundedRectangle(cornerRadius: 7))
                        .frame(maxWidth: .infinity, maxHeight: .infinity,
                               alignment: .topLeading)
                        .padding(8)
                }
                if metadataVideo.isShort && video.isLive != true {
                    Label("video.shortsBadge", systemImage: "play.rectangle.fill")
                        .font(.caption.bold())
                        .foregroundStyle(.white)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 6)
                        .background(.black.opacity(0.86),
                                    in: RoundedRectangle(cornerRadius: 6))
                        .frame(maxWidth: .infinity, maxHeight: .infinity,
                               alignment: .bottomLeading)
                        .padding(.leading, 9)
                        .padding(.bottom, 14)
                        .allowsHitTesting(false)
                }
                if let position = watchedTime, video.isLive != true {
                    Label(position, systemImage: completed ? "checkmark.circle.fill" : "play.circle")
                        .font(.caption.monospacedDigit())
                        .padding(7)
                        .background(.black.opacity(0.84), in: RoundedRectangle(cornerRadius: 6))
                        .frame(maxWidth: .infinity, maxHeight: .infinity,
                               alignment: .topTrailing)
                        .padding(7)
                }
                Group {
                    if video.isLive == true {
                        Text("video.liveBadge")
                            .font(.caption.bold())
                            .padding(8)
                            .background(TTTheme.accent,
                                        in: RoundedRectangle(cornerRadius: 6))
                    } else if let duration = metadataVideo.duration, duration > 0 {
                        Text(TTTheme.time(duration))
                            .font(.caption.monospacedDigit())
                            .padding(8)
                            .background(.black.opacity(0.8),
                                        in: RoundedRectangle(cornerRadius: 6))
                    }
                }
                .padding(9)
                // Keep the time badge's background at its original size
                // while the full card scales on focus.
                .scaleEffect(isFocused ? 1 / 1.065 : 1, anchor: .bottomTrailing)
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
            // The actual remote-driven specular/glimbal highlight lives on
            // the artwork viewport. It was previously a fixed gradient.
            .modifier(TVFocusedArtworkGlint())
            VStack(alignment: .leading, spacing: 7) {
                Text(video.title)
                    .font(.system(size: 21, weight: .semibold))
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, minHeight: 54, alignment: .topLeading)
                HStack(alignment: .center, spacing: 12) {
                    VStack(alignment: .leading, spacing: 7) {
                        Text(video.uploaderName ?? "")
                            .font(.system(size: 17))
                            .lineLimit(1)
                            .frame(maxWidth: .infinity, minHeight: 23,
                                   alignment: .topLeading)
                        Text(videoMetadata ?? " ")
                            .font(.system(size: 15))
                            .lineLimit(1)
                            .frame(maxWidth: .infinity, minHeight: 21,
                                   alignment: .topLeading)
                    }
                    .foregroundStyle(TTTheme.muted)
                    // Compact library indicators on one metadata row:
                    // red Watch Later, blue playlists, heart for favorites.
                    HStack(spacing: 9) {
                        if watchLaterMembership.contains(video.url) {
                            Image(systemName: "bookmark.fill")
                                .foregroundStyle(TTTheme.accent)
                                .accessibilityLabel("library.watchLater")
                        }
                        if playlistMembership.count(for: video.url) > 0 {
                            // Match the Library playlist menu symbol.
                            Image(systemName: "list.bullet.rectangle")
                                .foregroundStyle(Color(red: 0.26, green: 0.56, blue: 1))
                                .accessibilityIdentifier("playlist-membership-badge")
                                .accessibilityLabel("action.playlists")
                        }
                        if favoriteMembership.contains(video.url) {
                            Image(systemName: "heart.fill")
                                .foregroundStyle(Color(red: 0.96, green: 0.25, blue: 0.38))
                                .accessibilityIdentifier("favorite-membership-badge")
                                .accessibilityLabel("library.favorites")
                        }
                    }
                    .font(.system(size: 19, weight: .semibold))
                    .fixedSize(horizontal: true, vertical: false)
                    .padding(.trailing, 2)
                }
            }
            .padding(.horizontal, 14)
            .padding(.top, 11)
            .padding(.bottom, 13)
            // Subtle focus cue only below the thumbnail; keep artwork,
            // duration badge and existing whole-card zoom unchanged.
            .background(isFocused
                        ? Color(red: 0.15, green: 0.15, blue: 0.165)
                        : TTTheme.surface)
        }
        .frame(minHeight: 322, alignment: .top)
        .background(TTTheme.surface)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        // Scale the complete card, not the thumbnail viewport.
        // .fit preserves the original image edges and the progress bar.
        .scaleEffect(isFocused ? 1.065 : 1, anchor: .center)
        .shadow(color: isFocused ? Color.black.opacity(0.55) : .clear,
                radius: 19, y: 10)
        .animation(.easeOut(duration: 0.13), value: isFocused)
        .foregroundStyle(.white)
        .task(id: video.url) {
            metadataVideoURL = video.url
            streamMetadata = nil
            guard lookupMissingMetadata &&
                (video.viewCount == nil || TVVideoMetadata.publicationDate(for: video) == nil)
            else { return }
            let fetched = await TVStreamMetadataCache.shared.details(for: video, api: api)
            guard !Task.isCancelled else { return }
            streamMetadata = fetched
        }
        .task(id: api.metadataCacheScope) {
            await playlistMembership.ensureLoaded(api: api)
        }
        .task(id: api.metadataCacheScope) {
            await favoriteMembership.ensureLoaded(api: api)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(TTTheme.accessibilityText(for: video))
    }
}
