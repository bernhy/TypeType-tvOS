import SwiftUI

/// Main sections remain accessible using a narrow icon rail. Moving left from
/// the first thumbnail expands the rail and puts focus on the current section.
enum TVSection: String, CaseIterable, Hashable {
    case home, search, library, settings

    var label: String {
        switch self {
        case .home: return "Start"
        case .search: return "Suche"
        case .library: return "Bibliothek"
        case .settings: return "Einstellungen"
        }
    }
    var localizedLabel: LocalizedStringKey {
        switch self {
        case .home: return "nav.home"
        case .search: return "nav.search"
        case .library: return "nav.library"
        case .settings: return "nav.settings"
        }
    }
    var icon: String {
        switch self {
        case .home: return "house.fill"
        case .search: return "magnifyingglass"
        case .library: return "books.vertical"
        case .settings: return "gearshape"
        }
    }
}

struct BrowseView: View {
    let instanceOrigin: String
    let onDisconnect: () -> Void
    let previewVideos: [VideoItem]?
    @State private var section: TVSection
    @State private var expanded = false
    @FocusState private var menuFocus: TVSection?

    init(instanceOrigin: String, onDisconnect: @escaping () -> Void,
         initialSection: TVSection = .home, previewVideos: [VideoItem]? = nil,
         initiallyExpanded: Bool = false) {
        self.instanceOrigin = instanceOrigin
        self.onDisconnect = onDisconnect
        self.previewVideos = previewVideos
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
                        case .settings:
                            PreferencesView(api: api, onDisconnect: onDisconnect)
                        }
                    }
                }
                .id(section)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .background(TTTheme.ink)
        } else {
            TVContentMessage(symbol: "exclamationmark.triangle",
                             title: "Ungültige Serveradresse",
                             detail: "Bitte verbinde deine TypeType-Instanz erneut.",
                             action: onDisconnect,
                             actionTitle: "Server auswählen")
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
            .accessibilityLabel(expanded ? "Menü einklappen" : "Menü ausklappen")
        }
        .padding(.horizontal, 18)
        .padding(.top, 34)
        .padding(.bottom, 42)
        .frame(width: expanded ? 355 : 98)
        .frame(maxHeight: .infinity)
        .background(TTTheme.surface)
        .animation(.easeInOut(duration: 0.18), value: expanded)
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
                    Text("\(videos.count) Videos")
                        .font(.callout).foregroundStyle(TTTheme.muted)
                    Button {
                        Task { await load() }
                    } label: {
                        Label("Aktualisieren", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(.bordered)
                    .disabled(loading || previewVideos != nil)
                }
                .padding(.bottom, 5)

                if loading && videos.isEmpty {
                    ProgressView("Empfehlungen werden geladen …")
                        .frame(maxWidth: .infinity, minHeight: 200)
                } else if videos.isEmpty {
                    TVContentMessage(
                        symbol: message == nil ? "rectangle.stack" : "wifi.exclamationmark",
                        title: message == nil ? "Noch keine Empfehlungen" : "Server nicht erreichbar",
                        detail: message ?? "Dein TypeType-Server hat derzeit keine Empfehlungen.",
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
            videos = try await api.home().items
            message = nil
        } catch {
            message = error.localizedDescription
        }
    }
}

struct VideoCard: View {
    let api: TypeTypeAPI
    let video: VideoItem

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ZStack(alignment: .bottomTrailing) {
                AsyncImage(url: api.relativeMediaURL(video.thumbnailUrl)) { image in
                    image.resizable().scaledToFill()
                } placeholder: {
                    ZStack {
                        LinearGradient(colors: [TTTheme.surface,
                                                TTTheme.accent.opacity(0.18)],
                                       startPoint: .topLeading, endPoint: .bottomTrailing)
                        Image(systemName: "play.rectangle.fill")
                            .font(.system(size: 55))
                            .foregroundStyle(TTTheme.accent.opacity(0.5))
                    }
                }
                    .frame(height: 198).frame(maxWidth: .infinity).clipped()
                if video.isLive == true {
                    Text("LIVE").font(.caption.bold())
                        .padding(8).background(TTTheme.accent).padding(8)
                } else if let duration = video.duration, duration > 0 {
                    Text(TTTheme.time(duration))
                        .font(.caption.monospacedDigit())
                        .padding(8).background(.black.opacity(0.8)).padding(8)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 10))
            Text(video.title)
                .font(.system(size: 22, weight: .semibold))
                .lineLimit(2)
            Text(video.uploaderName ?? "").font(.system(size: 17))
                .foregroundStyle(TTTheme.muted).lineLimit(1)
        }
        .foregroundStyle(.white)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(TTTheme.accessibilityText(for: video))
    }
}
