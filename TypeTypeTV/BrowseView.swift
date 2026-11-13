import SwiftUI

/// Main sections remain accessible using a narrow icon rail. Moving left from
/// the first thumbnail expands the rail and puts focus on the current section.
enum TVSection: String, CaseIterable, Hashable {
    case home, search, library, playlists, settings

    var label: String {
        switch self {
        case .home: return TVL10n.value("nav.home")
        case .search: return TVL10n.value("nav.search")
        case .library: return TVL10n.value("nav.library")
        case .playlists: return TVL10n.value("nav.playlists")
        case .settings: return TVL10n.value("nav.settings")
        }
    }
    var localizedLabel: LocalizedStringKey {
        switch self {
        case .home: return "nav.home"
        case .search: return "nav.search"
        case .library: return "nav.library"
        case .playlists: return "nav.playlists"
        case .settings: return "nav.settings"
        }
    }
    var icon: String {
        switch self {
        case .home: return "house.fill"
        case .search: return "magnifyingglass"
        case .library: return "books.vertical"
        case .playlists: return "list.bullet.rectangle"
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
                            HomeView(api: api, previewVideos: previewVideos,
                                     onRevealMenu: revealMenu)
                        case .search:
                            SearchView(api: api)
                        case .library:
                            LibraryView(api: api)
                        case .playlists:
                            LibraryView(api: api, preferPlaylists: true)
                        case .settings:
                            PreferencesView(api: api, onDisconnect: onDisconnect, initialGroup: initialSettingsGroup)
                        }
                    }
                }
                .id(section)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .background(TTTheme.ink)
        } else {
            TVContentMessage(symbol: "exclamationmark.triangle",
                             title: TVL10n.value("server.invalidStored"),
                             detail: TVL10n.value("server.reconnectHelp"),
                             action: onDisconnect,
                             actionTitle: TVL10n.value("common.changeServer"))
        }
    }

    private var sidebar: some View {
        VStack(spacing: 20) {
            HStack(spacing: 14) {
                Image(systemName: "play.rectangle.fill")
                    .font(.system(size: 37))
                    .foregroundStyle(TTTheme.accent)
                    .frame(width: 50)
                if expanded {
                    Text("TypeType")
                        .font(.title2.bold())
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 90)
            .padding(.bottom, 20)

            ForEach(TVSection.allCases, id: \.self) { item in
                Button {
                    section = item
                    expanded = false
                    menuFocus = nil
                } label: {
                    HStack(spacing: 16) {
                        Image(systemName: item.icon)
                            .font(.system(size: 27))
                            .frame(width: 50)
                        if expanded {
                            Text(item.localizedLabel)
                                .font(.system(size: 22, weight: .semibold))
                                .lineLimit(1)
                            Spacer(minLength: 0)
                        }
                    }
                    .padding(.horizontal, 13)
                    .frame(maxWidth: .infinity, minHeight: 66, alignment: .leading)
                    .background(
                        item == section ? TTTheme.accent.opacity(0.2) : .clear,
                        in: RoundedRectangle(cornerRadius: 14)
                    )
                    .foregroundStyle(item == section ? TTTheme.accent : .white)
                }
                .buttonStyle(.plain)
                .focused($menuFocus, equals: item)
                .accessibilityLabel(item.label)
                .accessibilityAddTraits(item == section ? .isSelected : [])
            }
            Spacer()
            Button {
                expanded.toggle()
                if expanded { menuFocus = section }
            } label: {
                Image(systemName: expanded ? "sidebar.left" : "sidebar.right")
                    .font(.title2)
                    .frame(width: 50, height: 56)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(TVL10n.value(expanded ? "nav.collapse" : "nav.expand"))
        }
        .padding(.horizontal, 18)
        .padding(.top, 34)
        .padding(.bottom, 42)
        .frame(width: expanded ? 355 : 98)
        .frame(maxHeight: .infinity)
        .background(TTTheme.surface)
        .animation(navigationAnimations ? .easeInOut(duration: 0.18) : nil, value: expanded)
        .focusSection()
    }

    private func revealMenu() {
        expanded = true
        menuFocus = section
    }
}

struct HomeView: View {
    let api: TypeTypeAPI
    let onRevealMenu: () -> Void
    private let previewVideos: [VideoItem]?
    @State private var videos: [VideoItem]
    @State private var message: String?
    @State private var loading: Bool
    @FocusState private var focusedIndex: Int?

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 26), count: 4)

    init(api: TypeTypeAPI, previewVideos: [VideoItem]? = nil,
         onRevealMenu: @escaping () -> Void = {}) {
        self.api = api
        self.previewVideos = previewVideos
        self.onRevealMenu = onRevealMenu
        _videos = State(initialValue: previewVideos ?? [])
        _loading = State(initialValue: previewVideos == nil)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 30) {
                HStack(alignment: .center) {
                    VStack(alignment: .leading, spacing: 7) {
                        Text("home.forYou")
                            .font(.subheadline.bold())
                            .tracking(2.4)
                            .foregroundStyle(TTTheme.accent)
                        Text("home.recommendations")
                            .font(.system(size: 48, weight: .bold))
                    }
                    Spacer()
                    Text(TVL10n.formatted("common.videoCount", videos.count))
                        .font(.callout).foregroundStyle(TTTheme.muted)
                    Button {
                        Task { await load() }
                    } label: {
                        Label("common.refresh", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(.bordered)
                    .disabled(loading || previewVideos != nil)
                }
                .padding(.bottom, 5)

                if loading && videos.isEmpty {
                    ProgressView("home.loading")
                        .frame(maxWidth: .infinity, minHeight: 200)
                } else if videos.isEmpty {
                    TVContentMessage(
                        symbol: message == nil ? "rectangle.stack" : "wifi.exclamationmark",
                        title: TVL10n.value(message == nil ? "home.noRecommendations" : "home.serverUnavailable"),
                        detail: message ?? TVL10n.value("home.emptyHelp"),
                        action: { Task { await load() } }
                    )
                } else {
                    LazyVGrid(columns: columns, alignment: .leading, spacing: 34) {
                        ForEach(Array(videos.enumerated()), id: \.offset) { index, video in
                            NavigationLink {
                                VideoDetailView(api: api, video: video)
                            } label: {
                                VideoCard(api: api, video: video)
                            }
                            .buttonStyle(.card)
                            .videoActions(api: api, video: video) {
                                Task { await load() }
                            }
                            .focused($focusedIndex, equals: index)
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
            }
            .padding(.horizontal, 64)
            .padding(.top, 42)
            .padding(.bottom, 120)
        }
        .background(TTTheme.ink)
        .task { if previewVideos == nil { await load() } }
    }

    @MainActor
    private func load() async {
        guard previewVideos == nil else { return }
        loading = true
        defer { loading = false }
        do {
            let result = try await api.home().items
            videos = result
            message = nil
            let enriched = await api.withProgress(result)
            guard !Task.isCancelled else { return }
            videos = enriched
        } catch {
            message = error.localizedDescription
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
