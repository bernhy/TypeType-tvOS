import SwiftUI

struct SearchView: View {
    let api: TypeTypeAPI
    @AppStorage("typetype.recentSearches") private var recentJSON = "[]"
    @State private var term = ""
    @State private var searchedTerm = ""
    @State private var videos: [VideoItem] = []
    @State private var error: String?
    @State private var searching = false
    @State private var requestID = UUID()

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 30), count: 4)
    private var history: [String] { TVRecentQueries.decode(recentJSON) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 32) {
                VStack(alignment: .leading, spacing: 10) {
                    Text("VIDEOS ENTDECKEN")
                        .font(.subheadline.bold()).tracking(2.2)
                        .foregroundStyle(TTTheme.accent)
                    Text("Suche").font(.system(size: 52, weight: .bold))
                    Text("Finde Videos und Kanäle auf deiner TypeType-Instanz.")
                        .font(.body).foregroundStyle(TTTheme.muted)
                }

                HStack(spacing: 25) {
                    TextField("Titel, Kanal oder Suchbegriff", text: $term)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .onSubmit { Task { await execute(term) } }
                        .accessibilityLabel("Suchbegriff")
                    Button {
                        Task { await execute(term) }
                    } label: {
                        Label("Suchen", systemImage: "magnifyingglass")
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(TTTheme.accent)
                    .disabled(term.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || searching)
                }
                .focusSection()

                if !history.isEmpty {
                    VStack(alignment: .leading, spacing: 17) {
                        HStack {
                            Text("ZULETZT GESUCHT").font(.subheadline.bold())
                                .tracking(1.7).foregroundStyle(TTTheme.muted)
                            Spacer()
                            Button("Verlauf löschen") {
                                recentJSON = "[]"
                            }
                            .buttonStyle(.bordered)
                        }
                        ScrollView(.horizontal) {
                            LazyHStack(spacing: 20) {
                                ForEach(history, id: \.self) { query in
                                    Button {
                                        term = query
                                        Task { await execute(query) }
                                    } label: {
                                        Label(query, systemImage: "clock.arrow.circlepath")
                                            .lineLimit(1)
                                    }
                                    .buttonStyle(.bordered)
                                }
                            }
                            .padding(.vertical, 12)
                        }
                    }
                    .focusSection()
                }

                if searching {
                    ProgressView("Suche nach „\(searchedTerm)“ …")
                        .frame(maxWidth: .infinity, minHeight: 220)
                } else if let error {
                    TVContentMessage(
                        symbol: "wifi.exclamationmark",
                        title: "Suche nicht verfügbar",
                        detail: error,
                        action: { Task { await execute(term) } }
                    )
                } else if !searchedTerm.isEmpty && videos.isEmpty {
                    TVContentMessage(
                        symbol: "magnifyingglass",
                        title: "Keine Treffer",
                        detail: "Für „\(searchedTerm)“ wurden keine Videos gefunden. Versuche einen anderen Suchbegriff."
                    )
                } else if !videos.isEmpty {
                    VStack(alignment: .leading, spacing: 24) {
                        Text("\(videos.count) Treffer für „\(searchedTerm)“")
                            .font(.title2.bold())
                        LazyVGrid(columns: columns, spacing: 42) {
                            ForEach(videos) { video in
                                NavigationLink {
                                    VideoDetailView(api: api, video: video)
                                } label: {
                                    VideoCard(api: api, video: video)
                                }
                                .buttonStyle(.card)
                                .accessibilityLabel(TTTheme.accessibilityText(for: video))
                            }
                        }
                    }
                    .focusSection()
                } else {
                    TVContentMessage(
                        symbol: "play.rectangle.on.rectangle",
                        title: "Was möchtest du ansehen?",
                        detail: "Tippe deinen Suchbegriff ein oder wähle eine der letzten Suchanfragen aus."
                    )
                }
            }
            .padding(.horizontal, 75)
            .padding(.top, 55)
            .padding(.bottom, 110)
        }
        .background(TTTheme.ink)
    }

    @MainActor
    private func execute(_ query: String) async {
        let value = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        term = value
        searchedTerm = value
        let identifier = UUID()
        requestID = identifier
        searching = true
        error = nil
        do {
            let result = try await api.search(value).items
            guard requestID == identifier && !Task.isCancelled else { return }
            videos = result
            recentJSON = TVRecentQueries.encode(TVRecentQueries.add(value, to: history))
            searching = false
        } catch is CancellationError {
            return
        } catch {
            guard requestID == identifier else { return }
            videos = []
            self.error = error.localizedDescription
            searching = false
        }
    }
}
