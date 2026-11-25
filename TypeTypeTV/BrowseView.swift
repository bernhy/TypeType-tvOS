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

/// Rail and page share one native SwiftUI layout animation. Home maintains
/// its grid width and applies visual scaling inside the fixed-height ScrollView.
enum TVMainNavigationLayout {
    static let collapsedWidth: CGFloat = 56
    static let expandedWidth: CGFloat = 214
    static let duration = 0.28

    static func width(expanded: Bool) -> CGFloat {
        expanded ? expandedWidth : collapsedWidth
    }
}

struct BrowseView: View {
    let instanceOrigin: String
    let onDisconnect: () -> Void
    // Parse and validate the instance once per BrowseView construction;
    // SwiftUI may re-evaluate body repeatedly while focus/progress changes.
    private let configuredAPI: TypeTypeAPI?
    let previewVideos: [VideoItem]?
    let initialSettingsGroup: TVSettingsGroup
    @State private var section: TVSection
    @State private var expanded = false
    // Only the region owning remote focus is eligible for native focus.
    // This replaces delayed handoffs and rail-icon suppression timers.
    private enum NavigationFocusRegion { case sidebar, content }
    @State private var focusRegion: NavigationFocusRegion = .content
    @State private var searchFocusRequest = 0
    @State private var sidebarIdentity: TVAccountIdentity?
    private var playbackVisibility = TVPlaybackVisibility.shared
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
    @State private var topShelfSelection: TVTopShelfSnapshotStore.Item?
    // One route for all video cards, never per-tile navigation state.
    @State private var directPlaybackSelection: TVDirectPlaybackRequest?
    @AppStorage("typetype.navigationAnimations") private var navigationAnimations = true
    @FocusState private var menuFocus: TVSection?

    // Previewing is exclusive to the focused sidebar. Right/OK changes the
    // owning region; the child then uses its own native defaultFocus.
    private var menuPreviewVisible: Bool { focusRegion == .sidebar }

    init(instanceOrigin: String, onDisconnect: @escaping () -> Void,
         initialSection: TVSection = .home, previewVideos: [VideoItem]? = nil,
         initiallyExpanded: Bool = false,
         initialSettingsGroup: TVSettingsGroup = .playback) {
        self.instanceOrigin = instanceOrigin
        self.onDisconnect = onDisconnect
        self.configuredAPI = try? TypeTypeAPI(address: instanceOrigin)
        self.previewVideos = previewVideos
        self.initialSettingsGroup = initialSettingsGroup
        _section = State(initialValue: initialSection)
        _expanded = State(initialValue: initiallyExpanded)
        _focusRegion = State(initialValue: initiallyExpanded ? .sidebar : .content)
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
        if let api = configuredAPI {
            // Outer size stays constant while the native HStack rail grows.
            // Only Home's scrolled content uses this as its layout baseline.
            GeometryReader { outerViewport in
            ZStack(alignment: .leading) {
                TTTheme.ink.ignoresSafeArea()
                HStack(spacing: 0) {
                    if !playbackVisibility.isVisible {
                        sidebar
                            // A collapsed rail cannot steal focus from content.
                            // The native focus engine chooses within the enabled
                            // region; no post-transition correction is needed.
                            .disabled(homeStartupFocusPending ||
                                      focusRegion != .sidebar)
                            .zIndex(1)
                    }
                NavigationStack {
                    Group {
                        switch section {
                        case .home:
                            TVHomeSubscriptionsBaselineView(
                                api: api, previewVideos: previewVideos,
                                fixedLayoutWidth: TVHomeNavigationZoom.layoutWidth(
                                    outerWidth: outerViewport.size.width
                                ),
                                focusRequest: menuPreviewVisible ? -1 : homeFocusRequest,
                                onRevealMenu: revealMenu,
                                onOpenAccount: { open(.account) },
                                onInitialFocusReady: { homeStartupFocusPending = false }
                            )
                        case .search:
                            SearchView(
                                api: api,
                                fixedLayoutWidth: TVHomeNavigationZoom.layoutWidth(
                                    outerWidth: outerViewport.size.width
                                ),
                                onRevealMenu: revealMenu,
                                focusRequest: menuPreviewVisible ? -1 : searchFocusRequest
                            )
                        case .library:
                            LibraryView(
                                api: api,
                                fixedLayoutWidth: TVHomeNavigationZoom.layoutWidth(
                                    outerWidth: outerViewport.size.width
                                ),
                                focusRequest: menuPreviewVisible ? -1 : libraryFocusRequest,
                                onRevealMenu: revealMenu
                            )
                        case .subscriptions:
                            TVSubscriptionFeedView(
                                api: api,
                                focusRequest: menuPreviewVisible ? -1 : subscriptionFocusRequest,
                                fixedLayoutWidth: TVHomeNavigationZoom.layoutWidth(
                                    outerWidth: outerViewport.size.width
                                ),
                                onRevealMenu: revealMenu
                            )
                        case .channels:
                            TVSubscriptionsView(
                                api: api,
                                focusRequest: menuPreviewVisible ? -1 : channelFocusRequest,
                                fixedLayoutWidth: TVHomeNavigationZoom.layoutWidth(
                                    outerWidth: outerViewport.size.width
                                ),
                                onRevealMenu: revealMenu
                            )
                        case .account:
                            TVAccountSwitcherView(
                                api: api,
                                onAddAccount: {
                                    settingsEntryGroup = .account
                                    returnToSwitcherAfterLogin = true
                                    open(.settings)
                                },
                                onAccountChanged: { accountDidChange(api: api) },
                                focusRequest: menuPreviewVisible ? -1 : accountFocusRequest,
                                onRevealMenu: revealMenu
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
                    .navigationDestination(item: $topShelfSelection) { item in
                        varVideoDetail(api: api, item: item)
                    }
                    .navigationDestination(item: $directPlaybackSelection) { request in
                        TVDirectPlaybackDestination(
                            api: api, video: request.video,
                            playbackQueue: request.playbackQueue
                        )
                        .onDisappear {
                            // Same existing one-video resume reconciliation
                            // as returning from VideoDetailView after playback.
                            request.onReturnedVideo?(request.video)
                        }
                    }
                }
                .environment(
                    \.tvDirectPlayback,
                    TVDirectPlaybackAction { video, queue, onReturn in
                        guard !playbackVisibility.isVisible,
                              playlistPopup.request == nil,
                              directPlaybackSelection == nil else { return }
                        directPlaybackSelection = TVDirectPlaybackRequest(
                            video: video, playbackQueue: queue,
                            onReturnedVideo: onReturn
                        )
                    }
                )
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
            .onOpenURL { url in
                guard let snapshot = TVTopShelfSnapshotStore.read(),
                      let item = TVTopShelfSnapshotStore.item(
                          for: url, in: snapshot,
                          origin: api.origin.absoluteString,
                          scopeFingerprint: TVTopShelfPublisher.accountFingerprint(
                              for: api
                          )
                      ) else {
                    #if DEBUG
                    NSLog("TypeType TOPSHELF action ignored: unavailable snapshot or account mismatch")
                    #endif
                    return
                }
                topShelfSelection = item
            }
            .onDisappear { playlistPopup.finish() }
            .onChange(of: section) { old, _ in
                if old == .account || old == .settings {
                    Task { await reloadSidebarIdentity(api: api) }
                }
            }
            } // outerViewport: sidebar geometry and dialogs remain original.
        } else {
            TVContentMessage(symbol: "exclamationmark.triangle",
                             title: TVL10n.value("server.invalidStored"),
                             detail: TVL10n.value("server.reconnectHelp"),
                             action: onDisconnect,
                             actionTitle: TVL10n.value("common.changeServer"))
        }
    }

    private func varVideoDetail(api: TypeTypeAPI,
                                item: TVTopShelfSnapshotStore.Item) -> some View {
        var video = VideoItem(
            id: item.videoID, title: item.title, url: item.videoURL,
            thumbnailUrl: item.thumbnailURL, uploaderName: item.channelName,
            duration: item.duration, isLive: false
        )
        video.watchPositionMs = item.positionMs
        return VideoDetailView(api: api, video: video)
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
        .frame(width: TVMainNavigationLayout.width(expanded: expanded))
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
        // The sibling page resizes in this same animated HStack transaction.
        .focusSection()
        .defaultFocus($menuFocus, section, priority: .userInitiated)
        .onExitCommand {
            // Back while the global rail is focused goes to Home. The final
            // Back on the Home icon is consumed here, never exits TypeType.
            if section == .home {
                // On Home, the next Back returns to the first recommendation.
                open(.home)
            } else {
                section = .home
                menuFocus = .home
                setRailExpanded(true)
            }
        }
        .onChange(of: menuFocus) { _, focused in
            // Focus updates from a disappearing/disabled sidebar do not
            // trigger another activation or expand the menu again.
            guard focusRegion == .sidebar, let focused else { return }
            if section != focused {
                // Native Up/Down changes the focused icon. Only while the
                // sidebar owns focus may that change preview another page.
                section = focused
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
                // Preserve the selected-item highlight while native focus
                // moves between the two mutually exclusive focus regions.
                focused: focusRegion == .sidebar &&
                    TVRailVisualFocus.highlights(
                        item, focused: menuFocus, selected: section
                    ),
                selected: section == item
            ))
        }
        .buttonStyle(TVRailButtonStyle())
        .focusEffectDisabled(true)
        .focused($menuFocus, equals: item)
        .accessibilityLabel(item.label)
        .accessibilityIdentifier("main-nav-\(item.rawValue)")
        .onMoveCommand { direction in
            if direction == .right {
                // Right and Select both activate; vertical movement remains
                // completely native inside the sidebar focus section.
                open(item)
            }
        }
        .accessibilityAddTraits(item == section ? .isSelected : [])
    }

    private var sidebarAccountLabel: String {
        if let identity = sidebarIdentity {
            if identity.isGuest { return TVL10n.value("login.guestActive") }
            if let name = identity.visibleName { return name }
            if let api = configuredAPI,
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
        let generation = accountGeneration
        do {
            let identity = try await api.currentAccount()
            guard !Task.isCancelled && generation == accountGeneration else { return }
            sidebarIdentity = identity
            TVTopShelfPublisher.shared.accountChecked(identity, api: api)
        } catch {
            guard !Task.isCancelled && generation == accountGeneration else { return }
            // Keep the sidebar label on transient network errors, but never
            // continue displaying personal Top Shelf content while offline.
            let status = TVServerErrorMapping.httpStatus(error)
            TVTopShelfPublisher.shared.serverUnavailable(
                api: api, unauthorized: status == 401 || status == 403
            )
        }
    }

    @MainActor
    private func accountDidChange(api: TypeTypeAPI) {
        // Unmount the previous user's Home/Library/player state immediately.
        // Later requests and progress UI must belong to the newly selected user.
        TVLocalProgress.shared.clear()
        TVTopShelfPublisher.shared.clear()
        topShelfSelection = nil
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

    private func setRailExpanded(_ shouldExpand: Bool) {
        guard expanded != shouldExpand else { return }
        // Animate rail and content width in one transaction. Focus ownership
        // changes synchronously, without a timer or delayed correction.
        withAnimation(navigationAnimations
                      ? .easeInOut(duration: TVMainNavigationLayout.duration)
                      : nil) {
            expanded = shouldExpand
        }
    }

    private func open(_ destination: TVSection) {
        // Only explicit Right/Select or a Back on the Home menu icon
        // transfers ownership. A vertical sidebar move only previews.
        section = destination
        focusRegion = .content
        menuFocus = nil
        setRailExpanded(false)

        // Keep existing per-screen focus requests. Native defaultFocus on
        // the child owns entry; these counters never run per tile/move.
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
        // Make the rail eligible for native focus before restoring the
        // selected section. No delayed correction or icon suppression.
        focusRegion = .sidebar
        setRailExpanded(true)
        menuFocus = section
    }
}

/// Restore the tile that the user explicitly left for the navigation rail.
/// If a filter or feed refresh removed it, fall back to the first visible tile.
enum TVHomeReturnFocusPolicy {
    static func target(saved: String?, visibleIDs: Set<String>,
                       fallback: String) -> String {
        guard let saved, visibleIDs.contains(saved) else { return fallback }
        return saved
    }
}

/// A normal grid card has all data it needs from the feed. In that
/// case do not even attach a SwiftUI .task: no needless task scheduling,
/// MainActor state reset, or state-driven rerender while scrolling.
enum TVVideoCardMetadataTaskPolicy {
    static func needsTask(for video: VideoItem, enabled: Bool) -> Bool {
        enabled && (video.viewCount == nil ||
                    TVVideoMetadata.publicationDate(for: video) == nil)
    }
}

private struct TVVideoCardMetadataTask: ViewModifier {
    let video: VideoItem
    let api: TypeTypeAPI
    let enabled: Bool
    @Binding var metadataVideoURL: String?
    @Binding var streamMetadata: StreamInfo?

    @ViewBuilder
    func body(content: Content) -> some View {
        if TVVideoCardMetadataTaskPolicy.needsTask(for: video, enabled: enabled) {
            content.task(id: video.url) {
                // Reset ONLY if a genuine enrichment is required. The task
                // is removed entirely when regular Home cards are drawn.
                metadataVideoURL = video.url
                streamMetadata = nil
                let fetched = await TVStreamMetadataCache.shared.details(
                    for: video, api: api
                )
                guard !Task.isCancelled else { return }
                streamMetadata = fetched
            }
        } else {
            content
        }
    }
}

struct VideoCard: View {
    let api: TypeTypeAPI
    let video: VideoItem
    let lookupMissingMetadata: Bool
    // One account-scoped, canonical-video signal replaces subscriptions to
    // four global stores. An unrelated playlist/progress mutation no longer
    // invalidates every visible card.
    @ObservedObject private var cardStatus: TVVideoCardStatusSignal
    private let localProgress = TVLocalProgress.shared
    private let watchLaterMembership = TVWatchLaterMembership.shared
    private let playlistMembership = TVPlaylistMembership.shared
    private let favoriteMembership = TVFavoriteMembership.shared
    @Environment(\.isFocused) private var isFocused
    @State private var streamMetadata: StreamInfo?
    @State private var metadataVideoURL: String?
    @State private var deArrowKey: String?
    @State private var deArrowDisplay: TVDeArrowDisplay?

    init(api: TypeTypeAPI, video: VideoItem,
         lookupMissingMetadata: Bool = false) {
        self.api = api
        self.video = video
        self.lookupMissingMetadata = lookupMissingMetadata
        _cardStatus = ObservedObject(wrappedValue:
            TVVideoCardStatusCenter.signal(
                url: video.url, scope: api.metadataCacheScope
            )
        )
    }

    private var metadataVideo: VideoItem {
        // SwiftUI recycles cards in grids. Never show the previous video's
        // stream metadata on a newly reused thumbnail cell.
        TVVideoMetadata.merged(
            video, stream: lookupMissingMetadata &&
                metadataVideoURL == video.url ? streamMetadata : nil
        )
    }

    private var effectivePosition: Int64? {
        localProgress.position(for: video.url) ?? video.watchPositionMs
    }
    private var fraction: Double? {
        guard !TVLiveStreamDisplayPolicy.isOngoing(video),
              let duration = metadataVideo.duration, duration > 0,
              let progress = effectivePosition, progress > 0 else { return nil }
        return max(0, min(1, Double(progress) / (Double(duration) * 1_000)))
    }
    private var completed: Bool {
        // Some server versions expose a 'watched' convenience flag whose
        // duration and progress units differ. Prefer measured millisecond
        // progress and the account threshold whenever a position exists.
        TVWatchedState.isWatched(
            metadataVideo, positionMs: effectivePosition,
            thresholdPercent: TVContentPreferences.shared.watchedThresholdPercent
        )
    }
    private var watchedTime: String? {
        guard let progress = effectivePosition, progress > 0 else { return nil }
        return TTTheme.time(Int(progress / 1_000))
    }

    private var videoMetadata: String? {
        TVVideoMetadata.subtitle(for: metadataVideo)
    }

    var body: some View {
        let _ = cardStatus.revision
        let settings = TVContentPreferences.shared.settings
        let key = TVDeArrowPolicy.key(video: video, api: api, settings: settings)
        let replacement = deArrowKey == key && key != nil ? deArrowDisplay : nil
        // One card surface, no transparent 10-point gap between artwork
        // and the info panel. That gap used to reveal the black grid behind.
        VStack(alignment: .leading, spacing: 0) {
            ZStack(alignment: .bottomTrailing) {
                TVThumbnail(
                    url: replacement?.thumbnailURL ??
                        api.relativeMediaURL(video.thumbnailUrl),
                    origin: api.origin,
                    fallbackPrimary: replacement?.thumbnailURL == nil ? nil :
                        api.relativeMediaURL(video.thumbnailUrl),
                    contentMode: .fit,
                    maximumPixelDimension: 768, videoURL: video.url
                )
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
                if metadataVideo.isShort && !TVLiveStreamDisplayPolicy.isOngoing(video) {
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
                if let position = watchedTime, !TVLiveStreamDisplayPolicy.isOngoing(video) {
                    Label(position, systemImage: completed ? "checkmark.circle.fill" : "play.circle")
                        .font(.caption.monospacedDigit())
                        .padding(7)
                        .background(.black.opacity(0.84), in: RoundedRectangle(cornerRadius: 6))
                        .frame(maxWidth: .infinity, maxHeight: .infinity,
                               alignment: .topTrailing)
                        .padding(7)
                }
                Group {
                    if TVLiveStreamDisplayPolicy.isOngoing(metadataVideo) {
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
                Text(replacement?.title ?? video.title)
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
        .modifier(TVVideoCardMetadataTask(
            video: video, api: api, enabled: lookupMissingMetadata,
            metadataVideoURL: $metadataVideoURL,
            streamMetadata: $streamMetadata
        ))
        .modifier(TVDeArrowCardTask(
            video: video, api: api, settings: settings,
            selectedKey: $deArrowKey, selected: $deArrowDisplay
        ))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(TTTheme.accessibilityText(for: video))
    }
}
