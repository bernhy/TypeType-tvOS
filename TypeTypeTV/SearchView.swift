import SwiftUI

/// Server-backed YouTube search. Continuation tokens and filter values are
/// opaque; only values advertised by /search/filters are sent back.
struct SearchView: View {
    let api: TypeTypeAPI
    @ObservedObject private var contentPreferences = TVContentPreferences.shared
    @AppStorage("typetype.recentSearches") private var recentJSON = "[]"
    @State private var term = ""
    @State private var searchedTerm = ""
    @State private var videos: [VideoItem] = []
    @State private var channels: [TVChannelSearchResult] = []
    @State private var playlists: [TVPublicPlaylistSummary] = []
    @State private var nextPage: String?
    @State private var suggestion: String?
    @State private var corrected = false
    @State private var capabilities: TVSearchFiltersResponse?
    @State private var contentFilter = ""
    @State private var sortFilter = ""
    @State private var groupSelections: [String: Set<String>] = [:]
    @State private var error: String?
    @State private var pageError: String?
    @State private var searching = false
    @State private var paging = false
    @State private var requestID = UUID()
    var focusRequest = 0
    @FocusState private var focusedVideoURL: String?
    @FocusState private var searchFieldFocused: Bool
    @FocusState private var focusedRecent: String?
    @FocusState private var clearHistoryFocused: Bool

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 30), count: 4)
    private var history: [String] { TVRecentQueries.decode(recentJSON) }
    private var visibleVideos: [VideoItem] { contentPreferences.displayed(videos) }
    private var allEmpty: Bool { visibleVideos.isEmpty && channels.isEmpty && playlists.isEmpty }
    private var selectedFilters: [String] {
        ([sortFilter] + groupSelections.keys.sorted().flatMap {
            groupSelections[$0, default: []].sorted()
        }).filter { !$0.isEmpty }
    }

    var body: some View {
        ScrollViewReader { scroll in
            ScrollView {
                VStack(alignment: .leading, spacing: 32) {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("search.kicker")
                            .font(.subheadline.bold()).tracking(2.2)
                            .foregroundStyle(TTTheme.accent)
                        Text("nav.search").font(.system(size: 52, weight: .bold))
                        Text("search.subtitle")
                            .font(.body).foregroundStyle(TTTheme.muted)
                    }

                    HStack(spacing: 25) {
                        TextField("search.placeholder", text: $term)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .focused($searchFieldFocused)
                            .onSubmit { Task { await execute(term) } }
                            .accessibilityLabel("search.inputLabel")
                        Button { Task { await execute(term) } } label: {
                            Label("search.button", systemImage: "magnifyingglass")
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(TTTheme.accent)
                        .disabled(term.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || searching)
                    }
                    .focusSection()

                    if let capabilities {
                        TVSearchFilterControls(
                            capabilities: capabilities,
                            contentFilter: $contentFilter,
                            sortFilter: $sortFilter,
                            selectedGroups: $groupSelections
                        )
                        .focusSection()
                    }

                    if !history.isEmpty {
                        VStack(alignment: .leading, spacing: 17) {
                            HStack {
                                Text("search.recents").font(.subheadline.bold())
                                    .tracking(1.7).foregroundStyle(TTTheme.muted)
                                Spacer()
                                Button("search.clearHistory") { recentJSON = "[]" }
                                    .buttonStyle(.bordered)
                                    .focused($clearHistoryFocused)
                                    .onMoveCommand { direction in
                                        if direction == .down || direction == .left {
                                            focusedRecent = history.first
                                        }
                                    }
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
                                        .focused($focusedRecent, equals: query)
                                        .onMoveCommand { direction in
                                            if direction == .up {
                                                clearHistoryFocused = true
                                            }
                                        }
                                    }
                                }
                                .padding(.vertical, 12)
                            }
                            .focusSection()
                        }
                        .focusSection()
                    }

                    if searching && allEmpty {
                        ProgressView(TVL10n.formatted("search.working", searchedTerm))
                            .frame(maxWidth: .infinity, minHeight: 220)
                    } else if let error, allEmpty {
                        TVContentMessage(
                            symbol: "wifi.exclamationmark",
                            title: TVL10n.value("search.unavailable"),
                            detail: error,
                            action: { Task { await execute(term) } }
                        )
                    } else if !searchedTerm.isEmpty && allEmpty {
                        TVContentMessage(
                            symbol: "magnifyingglass",
                            title: TVL10n.value("search.noResults"),
                            detail: TVL10n.formatted("search.noResultsHint", searchedTerm)
                        )
                    } else if !allEmpty {
                        VStack(alignment: .leading, spacing: 28) {
                            if let suggestion, !suggestion.isEmpty {
                                Button {
                                    term = suggestion
                                    Task { await execute(suggestion) }
                                } label: {
                                    Label(
                                        TVL10n.formatted("search.suggestion", suggestion),
                                        systemImage: "text.magnifyingglass"
                                    )
                                }
                                .buttonStyle(.bordered)
                            } else if corrected {
                                Text("search.corrected")
                                    .font(.callout).foregroundStyle(TTTheme.muted)
                            }

                            if !channels.isEmpty {
                                Text("search.channels").font(.title2.bold())
                                LazyVGrid(columns: columns, spacing: 28) {
                                    ForEach(channels) { channel in
                                        NavigationLink {
                                            TVSubscriptionsView(
                                                api: api, directChannelURL: channel.url,
                                                directChannelName: channel.name
                                            )
                                        } label: {
                                            TVSearchNamedCard(
                                                title: channel.name, subtitle: channel.description,
                                                image: api.relativeMediaURL(channel.thumbnailUrl),
                                                origin: api.origin, symbol: "person.crop.circle"
                                            )
                                        }
                                        .buttonStyle(TVRailButtonStyle())
                                        .focusEffectDisabled(true)
                                    }
                                }
                                .focusSection()
                            }

                            if !playlists.isEmpty {
                                Text("search.playlists").font(.title2.bold())
                                LazyVGrid(columns: columns, spacing: 28) {
                                    ForEach(playlists) { playlist in
                                        NavigationLink {
                                            TVPublicPlaylistView(api: api, playlistURL: playlist.url,
                                                                 startingTitle: playlist.title)
                                        } label: {
                                            TVSearchNamedCard(
                                                title: playlist.title,
                                                subtitle: playlist.uploaderName,
                                                image: api.relativeMediaURL(playlist.thumbnailUrl),
                                                origin: api.origin, symbol: "list.bullet.rectangle"
                                            )
                                        }
                                        .buttonStyle(TVRailButtonStyle())
                                        .focusEffectDisabled(true)
                                    }
                                }
                                .focusSection()
                            }

                            if !visibleVideos.isEmpty {
                                Text(TVL10n.formatted("search.resultCount", visibleVideos.count, searchedTerm))
                                    .font(.title2.bold())
                                LazyVGrid(columns: columns, spacing: 42) {
                                    ForEach(visibleVideos) { video in
                                        NavigationLink {
                                            VideoDetailView(
                                                api: api, video: video,
                                                onReturnToList: {
                                                    TVVideoFocusReturn.restore(
                                                        $focusedVideoURL, id: video.url, scroll: scroll
                                                    )
                                                }
                                            )
                                        } label: {
                                            VideoCard(api: api, video: video)
                                        }
                                        .buttonStyle(TVRailButtonStyle())
                                        .focusEffectDisabled(true)
                                        .videoActions(api: api, video: video, onChanged: {
                                            Task { await execute(searchedTerm) }
                                        }, focus: $focusedVideoURL, focusID: video.url)
                                        .accessibilityLabel(TTTheme.accessibilityText(for: video))
                                        .id(video.url)
                                    }
                                }
                                .focusSection()
                            }
                            if paging {
                                ProgressView("search.loadingMore")
                                    .frame(maxWidth: .infinity)
                            } else if nextPage != nil {
                                Button("search.loadMore") { Task { await loadMore() } }
                                    .buttonStyle(.bordered)
                                    .frame(maxWidth: .infinity)
                            }
                            if let pageError {
                                Text(pageError).foregroundStyle(.orange)
                                Button("common.retry") { Task { await loadMore() } }
                                    .buttonStyle(.bordered)
                            }
                        }
                    } else {
                        TVContentMessage(
                            symbol: "play.rectangle.on.rectangle",
                            title: TVL10n.value("search.startTitle"),
                            detail: TVL10n.value("search.startHelp")
                        )
                    }
                }
                .padding(.horizontal, 75)
                .padding(.top, 55)
                .padding(.bottom, 110)
            }
            .background(TTTheme.ink)
            .task {
                await contentPreferences.ensureLoaded(api: api)
                await loadFilterCapabilities()
            }
            .onChange(of: contentFilter) { _, _ in
                groupSelections = [:]
                Task {
                    await loadFilterCapabilities()
                    if !searchedTerm.isEmpty { await execute(searchedTerm) }
                }
            }
            .onChange(of: sortFilter) { _, _ in
                if !searchedTerm.isEmpty { Task { await execute(searchedTerm) } }
            }
            .onChange(of: groupSelections) { _, _ in
                if !searchedTerm.isEmpty { Task { await execute(searchedTerm) } }
            }
            .task(id: focusRequest) {
                guard focusRequest >= 0 else {
                    searchFieldFocused = false
                    return
                }
                if focusRequest > 0 {
                    try? await Task.sleep(for: .milliseconds(220))
                } else {
                    await Task.yield()
                }
                guard !Task.isCancelled else { return }
                searchFieldFocused = true
            }
        }
    }

    @MainActor
    private func loadFilterCapabilities() async {
        do {
            capabilities = try await api.searchFilters(
                contentFilter: contentFilter.isEmpty ? nil : contentFilter
            )
        } catch {
            // Older servers may not support search filters; basic search works.
            capabilities = nil
        }
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
        paging = false
        error = nil
        pageError = nil
        videos = []
        channels = []
        playlists = []
        suggestion = nil
        corrected = false
        nextPage = nil
        defer { if identifier == requestID { searching = false } }
        do {
            let result = try await api.search(
                value, contentFilter: contentFilter.isEmpty ? nil : contentFilter,
                filters: selectedFilters
            )
            guard requestID == identifier && !Task.isCancelled else { return }
            videos = result.items
            channels = result.channels ?? []
            playlists = result.playlists ?? []
            nextPage = result.nextpage
            suggestion = result.searchSuggestion
            corrected = result.isCorrectedSearch == true
            recentJSON = TVRecentQueries.encode(TVRecentQueries.add(value, to: history))
            let enriched = await api.withProgress(result.items)
            guard requestID == identifier && !Task.isCancelled else { return }
            videos = enriched
        } catch is CancellationError {
            return
        } catch {
            guard requestID == identifier else { return }
            self.error = error.localizedDescription
        }
    }

    @MainActor
    private func loadMore() async {
        guard !paging, !searching, let cursor = nextPage else { return }
        let identifier = requestID
        paging = true
        pageError = nil
        defer { if identifier == requestID { paging = false } }
        do {
            let result = try await api.search(
                searchedTerm, nextpage: cursor,
                contentFilter: contentFilter.isEmpty ? nil : contentFilter,
                filters: selectedFilters
            )
            guard requestID == identifier, nextPage == cursor,
                  !Task.isCancelled else { return }
            var seen = Set(videos.map(\.url))
            let fresh = result.items.filter { seen.insert($0.url).inserted }
            videos += fresh
            let knownChannels = Set(channels.map(\.url))
            channels += (result.channels ?? []).filter { !knownChannels.contains($0.url) }
            let knownPlaylists = Set(playlists.map(\.url))
            playlists += (result.playlists ?? []).filter { !knownPlaylists.contains($0.url) }
            nextPage = result.nextpage == cursor ? nil : result.nextpage
            let enriched = await api.withProgress(fresh)
            guard requestID == identifier && !Task.isCancelled else { return }
            let progress = Dictionary(uniqueKeysWithValues: enriched.map { ($0.url, $0) })
            videos = videos.map { progress[$0.url] ?? $0 }
        } catch {
            if identifier == requestID { pageError = error.localizedDescription }
        }
    }
}
