import SwiftUI

struct BrowseView: View {
    let instanceOrigin: String
    let onDisconnect: () -> Void

    var body: some View {
        // Address was validated in the setup flow. If settings become invalid,
        // show an action that can recover without wiping any other user data.
        if let api = try? TypeTypeAPI(address: instanceOrigin) {
            TabView {
                NavigationStack {
                    HomeView(api: api)
                }
                .tabItem { Label("Start", systemImage: "house") }

                NavigationStack {
                    SearchView(api: api)
                }
                .tabItem { Label("Suche", systemImage: "magnifyingglass") }

                NavigationStack {
                    LibraryView(api: api)
                }
                .tabItem { Label("Bibliothek", systemImage: "books.vertical") }

                PreferencesView(api: api, onDisconnect: onDisconnect)
                    .tabItem { Label("Einstellungen", systemImage: "gearshape") }
            }
        } else {
            VStack(spacing: 20) {
                Text("Serveradresse nicht mehr gültig.")
                Button("Neu verbinden", action: onDisconnect)
            }
        }
    }
}


private enum TTColor {
    static let ink = Color(red: 0.035, green: 0.035, blue: 0.043)
    static let red = Color(red: 0.937, green: 0.267, blue: 0.267)
    static let mid = Color(red: 0.631, green: 0.631, blue: 0.667)
}

struct HomeView: View {
    let api: TypeTypeAPI
    @State private var videos: [VideoItem] = []
    @State private var message: String?
    @State private var loading = true

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 44) {
                if let hero = videos.first {
                    heroView(hero)
                    shelf("Für dich", videos: Array(videos.dropFirst().prefix(18)))
                    let live = videos.filter { $0.isLive == true }
                    if !live.isEmpty { shelf("Live", videos: live) }
                    if videos.count > 19 {
                        shelf("Weitere Empfehlungen", videos: Array(videos.dropFirst(19)))
                    }
                } else {
                    VStack(alignment: .leading, spacing: 24) {
                        Text("TypeType").font(.system(size: 60, weight: .bold)).foregroundStyle(TTColor.red)
                        if loading { ProgressView("Empfehlungen werden geladen …") }
                        if let message { Text(message).foregroundStyle(.orange) }
                    }
                    .padding(.horizontal, 80).padding(.top, 120)
                }
            }.padding(.bottom, 100)
        }
        .background(TTColor.ink)
        .task { await load() }
    }

    private func heroView(_ video: VideoItem) -> some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                AsyncImage(url: api.relativeMediaURL(video.thumbnailUrl)) { image in
                    image.resizable().scaledToFill()
                        .frame(width: geometry.size.width, height: geometry.size.height).clipped()
                } placeholder: { TTColor.ink }
                LinearGradient(
                    stops: [.init(color: TTColor.ink, location: 0),
                            .init(color: TTColor.ink.opacity(0.9), location: 0.33),
                            .init(color: TTColor.ink.opacity(0.32), location: 0.8),
                            .init(color: TTColor.ink.opacity(0.15), location: 1)],
                    startPoint: .leading, endPoint: .trailing
                )
                LinearGradient(colors: [.clear, TTColor.ink],
                               startPoint: .center, endPoint: .bottom)
                VStack(alignment: .leading, spacing: 24) {
                    Text("EMPFOHLEN").font(.system(size: 22, weight: .bold))
                        .tracking(3).foregroundStyle(TTColor.red)
                    Text(video.title).font(.system(size: 54, weight: .bold))
                        .lineLimit(2).frame(maxWidth: 850, alignment: .leading)
                    Text(video.uploaderName ?? "").foregroundStyle(.white.opacity(0.75))
                    HStack(spacing: 25) {
                        NavigationLink {
                            PlaybackView(api: api, video: video)
                        } label: { Label("Abspielen", systemImage: "play.fill") }
                            .buttonStyle(.borderedProminent).tint(TTColor.red)
                        NavigationLink {
                            VideoDetailView(api: api, video: video)
                        } label: { Label("Details", systemImage: "info.circle") }
                            .buttonStyle(.bordered)
                    }
                }
                .padding(.leading, 80).padding(.top, 105)
            }
        }
        .frame(height: 540).clipped()
    }

    private func shelf(_ title: String, videos: [VideoItem]) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(title.uppercased())
                .font(.system(size: 24, weight: .bold)).tracking(1.5)
                .foregroundStyle(TTColor.mid)
                .padding(.leading, 80)
            ScrollView(.horizontal) {
                LazyHStack(alignment: .top, spacing: 30) {
                    ForEach(videos) { video in
                        NavigationLink {
                            VideoDetailView(api: api, video: video)
                        } label: {
                            VideoCard(api: api, video: video).frame(width: 350)
                        }
                        .buttonStyle(.card)
                    }
                }
                .padding(.horizontal, 80).padding(.vertical, 10)
            }
        }
    }

    @MainActor
    private func load() async {
        loading = true
        defer { loading = false }
        do {
            videos = try await api.home().items
            message = videos.isEmpty ? "Noch keine Empfehlungen." : nil
        } catch {
            message = "Empfehlungen nicht verfügbar: \(error.localizedDescription)"
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
                } placeholder: { Rectangle().fill(TTColor.ink.opacity(0.8)) }
                    .frame(height: 185).frame(maxWidth: .infinity).clipped()
                if video.isLive == true {
                    Text("LIVE").font(.caption.bold())
                        .padding(8).background(TTColor.red).padding(8)
                } else if let duration = video.duration, duration > 0 {
                    Text(String(format: "%d:%02d", duration / 60, duration % 60))
                        .font(.caption.monospacedDigit())
                        .padding(8).background(.black.opacity(0.8)).padding(8)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 10))
            Text(video.title).font(.headline).lineLimit(2)
            Text(video.uploaderName ?? "").font(.caption)
                .foregroundStyle(TTColor.mid).lineLimit(1)
        }
        .foregroundStyle(.white)
    }
}
