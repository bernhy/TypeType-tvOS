import SwiftUI

struct LibraryView: View {
    let api: TypeTypeAPI
    @State private var section: TVLibrarySection = .history
    @State private var videos: [VideoItem] = []
    @State private var statusMessage: String?
    @State private var isLoading = false

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 30), count: 4)

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 32) {
                HStack(alignment: .center) {
                    VStack(alignment: .leading, spacing: 9) {
                        Text("DEINE MEDIATHEK")
                            .font(.subheadline.bold()).tracking(2.2)
                            .foregroundStyle(TTTheme.accent)
                        Text("Bibliothek").font(.system(size: 52, weight: .bold))
                    }
                    Spacer()
                    if !videos.isEmpty {
                        Text("\(videos.count) Videos")
                            .font(.callout).foregroundStyle(TTTheme.muted)
                    }
                    Button {
                        Task { await reload(section) }
                    } label: { Label("Aktualisieren", systemImage: "arrow.clockwise") }
                        .buttonStyle(.bordered)
                        .disabled(isLoading)
                }
                HStack(spacing: 24) {
                    ForEach(TVLibrarySection.allCases) { item in
                        Button {
                            section = item
                        } label: {
                            Label(item.title, systemImage: item.symbol)
                        }
                        .buttonStyle(.bordered)
                        .tint(section == item ? TTTheme.accent : TTTheme.muted)
                        .accessibilityAddTraits(section == item ? .isSelected : [])
                    }
                }
                .focusSection()

                if isLoading {
                    ProgressView("Lade \(section.title) …")
                        .frame(maxWidth: .infinity, minHeight: 250)
                } else if let statusMessage {
                    TVContentMessage(
                        symbol: "wifi.exclamationmark",
                        title: statusMessage,
                        detail: "Prüfe die Verbindung und ob dein TypeType-Konto angemeldet ist.",
                        action: { Task { await reload(section) } }
                    )
                } else if videos.isEmpty {
                    TVContentMessage(
                        symbol: section.symbol,
                        title: section.title,
                        detail: section.emptyMessage
                    )
                } else {
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
                    .focusSection()
                }
            }
            .padding(.horizontal, 75)
            .padding(.top, 55)
            .padding(.bottom, 110)
        }
        .background(TTTheme.ink)
        .task(id: section) { await reload(section) }
    }

    @MainActor
    private func reload(_ requested: TVLibrarySection) async {
        isLoading = true
        statusMessage = nil
        defer { isLoading = false }
        do {
            let response = try await api.library(requested)
            guard !Task.isCancelled && requested == section else { return }
            videos = response
        } catch is CancellationError {
            return
        } catch {
            guard requested == section else { return }
            videos = []
            if case TypeTypeError.http(let status, _) = error, status == 401 || status == 403 {
                statusMessage = "Anmeldung erforderlich"
            } else {
                statusMessage = "Bibliothek konnte nicht geladen werden"
            }
        }
    }
}
