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

struct HomeView: View {
    let api: TypeTypeAPI
    @State private var videos: [VideoItem] = []
    @State private var message: String?
    @State private var loading = true

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 34), count: 4)

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 36) {
                Text("Für dich").font(.largeTitle.bold())
                if loading { ProgressView("Lade Videos …") }
                if let message { Text(message).foregroundStyle(.orange) }
                LazyVGrid(columns: columns, spacing: 45) {
                    ForEach(videos) { video in
                        NavigationLink {
                            VideoDetailView(api: api, video: video)
                        } label: {
                            VideoCard(api: api, video: video)
                        }
                        .buttonStyle(.card)
                    }
                }
            }
            .padding(60)
        }
        .task { await load() }
    }

    @MainActor
    private func load() async {
        loading = true
        defer { loading = false }
        do {
            videos = try await api.home().items
            message = videos.isEmpty ? "Der Server hat derzeit keine Empfehlungen zurückgegeben." : nil
        } catch {
            message = "Empfehlungen konnten nicht geladen werden: \(error.localizedDescription)"
        }
    }
}

struct VideoCard: View {
    let api: TypeTypeAPI
    let video: VideoItem

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            AsyncImage(url: api.relativeMediaURL(video.thumbnailUrl)) { image in
                image.resizable().scaledToFill()
            } placeholder: {
                Rectangle().fill(.gray.opacity(0.25))
            }
            .frame(height: 160)
            .frame(maxWidth: .infinity)
            .clipped()
            Text(video.title)
                .font(.headline)
                .lineLimit(2)
            Text(video.uploaderName ?? "")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }
}
