import SwiftUI

struct SearchView: View {
    let api: TypeTypeAPI
    @State private var term = ""
    @State private var videos: [VideoItem] = []
    @State private var message: String?
    @State private var searching = false

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 34), count: 4)

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                Text("Suche").font(.largeTitle.bold())
                HStack {
                    TextField("Video suchen", text: $term)
                        .onSubmit { Task { await search() } }
                    Button("Suchen") { Task { await search() } }
                        .disabled(term.trimmingCharacters(in: .whitespaces).isEmpty || searching)
                }
                if searching { ProgressView("Suche …") }
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
    }

    @MainActor
    private func search() async {
        let value = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        searching = true
        defer { searching = false }
        do {
            videos = try await api.search(value).items
            message = videos.isEmpty ? "Keine Treffer." : nil
        } catch {
            message = error.localizedDescription
        }
    }
}
