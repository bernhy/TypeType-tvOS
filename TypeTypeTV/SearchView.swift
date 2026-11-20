import SwiftUI

/// Server-backed YouTube search. Continuation tokens and filter values are
/// opaque; only values advertised by /search/filters are sent back.
struct SearchView: View {
    let api: TypeTypeAPI
    var fixedLayoutWidth: CGFloat?
    var onRevealMenu: () -> Void = {}
    @ObservedObject private var contentPreferences = TVContentPreferences.shared
    @State private var recentEntries: [TVSearchHistoryItem] = []
    @State private var historyError: String?
    @State private var clearingHistory = false
    @State private var savingHistoryCount = 0
    @State private var historyRequestID = UUID()
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
    @State private var handledFocusRequest: Int?
    @StateObject private var videoMenu = TVHomeMenuCoordinator()
    @FocusState private var focusedVideoURL: String?
    @State private var detailReturnVideoID: String?
    @State private var lastMutationID = 0
    // Named results also need an explicit tvOS focus target when the
    // enclosing search content is visually scaled. Video results already
    // have this via TVSharedVideoGrid.
    @FocusState private var focusedNamedResult: String?
    @FocusState private var searchFieldFocused: Bool
    @FocusState private var focusedRecent: String?
    @FocusState private var clearHistoryFocused: Bool

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 30), count: 4)
    private var history: [TVSearchHistoryItem] {
        TVSearchHistoryPresentation.visible(recentEntries)
    }
    private var visibleVideos: [VideoItem] { contentPreferences.displayed(videos) }
    private var allEmpty: Bool { visibleVideos.isEmpty && channels.isEmpty && playlists.isEmpty }
    private var selectedFilters: [String] {
        ([sortFilter] + groupSelections.keys.sorted().flatMap {
            groupSelections[$0, default: []].sorted()
        }).filter { !$0.isEmpty }
    }

    var body: some View {
        GeometryReader { viewport in
        let layoutWidth = fixedLayoutWidth ?? viewport.size.width
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
                                Button("search.clearHistory") {
                                    Task { await clearSearchHistory() }
                                }
                                    .buttonStyle(.bordered)
                                    .disabled(clearingHistory || searching || savingHistoryCount > 0)
                                    .focused($clearHistoryFocused)
                                    .onMoveCommand { direction in
                                        if direction == .down || direction == .left {
                                            focusedRecent = history.first?.term
                                        }
                                    }
                            }
                            ScrollView(.horizontal) {
                                LazyHStack(spacing: 20) {
                                    ForEach(history) { entry in
                                        Button {
                                            term = entry.term
                                            Task { await execute(entry.term) }
                                        } label: {
                                            Label(entry.term, systemImage: "clock.arrow.circlepath")
                                                .lineLimit(1)
                                        }
                                        .buttonStyle(.bordered)
                                        .focused($focusedRecent, equals: entry.term)
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

                    if let historyError {
                        HStack(spacing: 15) {
                            Text(historyError).font(.caption)
                                .foregroundStyle(.orange).lineLimit(2)
                            Button("common.retry") {
                                Task { await loadSearchHistory() }
                            }
                            .buttonStyle(.bordered)
                        }
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
                                        .focused($focusedNamedResult, equals:
                                            "channel-" + channel.url)
                                        .accessibilityIdentifier(
                                            "search-channel-" + channel.id)
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
                                        .focused($focusedNamedResult, equals:
                                            "playlist-" + playlist.url)
                                        .accessibilityIdentifier(
                                            "search-playlist-" + playlist.id)
                                    }
                                }
                                .focusSection()
                            }

                            if !visibleVideos.isEmpty {
                                Text(TVL10n.formatted("search.resultCount", visibleVideos.count, searchedTerm))
                                    .font(.title2.bold())
                                TVSharedVideoGrid(
                                    snapshot: TVSharedVideoGridSnapshot(
                                        videos: visibleVideos,
                                        scope: api.metadataCacheScope,
                                        destination: "search-" + searchedTerm +
                                            selectedFilters.joined(separator: ","),
                                        focusPrefix: "",
                                        accessibilityPrefix: "search-video-",
                                        columns: columns.count, columnSpacing: 30,
                                        rowSpacing: 42, canLoadMore: false,
                                        loadAhead: columns.count + 1,
                                        lookupMissingMetadata: false,
                                        isWatchLaterEntry: false, reloadPlaylistOnRemoval: false,
                                        playbackQueue: nil
                                    ),
                                    api: api, focus: $focusedVideoURL, menu: videoMenu,
                                    onReturnToList: { id in
                                        detailReturnVideoID = id
                                        focusedVideoURL = id
                                    },
                                    onLeftEdge: { _ in onRevealMenu() },
                                    // Membership badges update in VideoCard.
                                    // Blocked rows are removed by the mutation
                                    // journal, never by clearing all search results.
                                    onChanged: {},
                                    onApproachEnd: {}
                                )
                                .equatable()
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
                .frame(width: layoutWidth, alignment: .leading)
                .scaleEffect(
                    TVHomeNavigationZoom.scale(
                        visibleWidth: viewport.size.width, layoutWidth: layoutWidth
                    ),
                    anchor: .topLeading
                )
                .frame(width: viewport.size.width, alignment: .topLeading)
            }
            .frame(width: viewport.size.width, height: viewport.size.height)
            .background(TTTheme.ink)
            .modifier(TVHomeMenuPresentation(model: videoMenu))
            .defaultFocus(
                $focusedVideoURL, detailReturnVideoID,
                priority: detailReturnVideoID == nil ? .automatic : .userInitiated
            )
            .onReceive(TVVideoMutationCenter.shared.$events) { reconcileMutations($0) }
            .onAppear { reconcileMutations(TVVideoMutationCenter.shared.events) }
            .onChange(of: videoMenu.focusRestoreRequest) { _, _ in
                if let id = videoMenu.focusRestoreTarget,
                   visibleVideos.contains(where: { $0.url == id }) {
                    focusedVideoURL = id
                }
            }
            .task {
                await TVWatchLaterMembership.shared.ensureLoaded(api: api)
            }
            .task {
                async let playlists: Void = TVPlaylistMembership.shared.ensureLoaded(api: api)
                async let favorites: Void = TVFavoriteMembership.shared.ensureLoaded(api: api)
                _ = await (playlists, favorites)
            }
            .task {
                await contentPreferences.ensureLoaded(api: api)
                await loadFilterCapabilities()
            }
            .task {
                // Do not upload stale device-local searches into any account.
                UserDefaults.standard.removeObject(forKey: "typetype.recentSearches")
                await loadSearchHistory()
            }
            .onChange(of: contentFilter) { _, _ in
                groupSelections = [:]
                Task {
                    await loadFilterCapabilities()
                    if !searchedTerm.isEmpty {
                        await execute(searchedTerm, recordHistory: false)
                    }
                }
            }
            .onChange(of: sortFilter) { _, _ in
                if !searchedTerm.isEmpty {
                    Task { await execute(searchedTerm, recordHistory: false) }
                }
            }
            .onChange(of: groupSelections) { _, _ in
                if !searchedTerm.isEmpty {
                    Task { await execute(searchedTerm, recordHistory: false) }
                }
            }
            .task(id: focusRequest) {
                guard focusRequest >= 0 else {
                    searchFieldFocused = false
                    return
                }
                // Returning from a result detail must not repeatedly jump
                // back to the search input unless the global rail explicitly
                // issued a new focus request.
                guard handledFocusRequest != focusRequest else { return }
                handledFocusRequest = focusRequest
                let requested = focusRequest
                if requested > 0 {
                    try? await Task.sleep(for: .milliseconds(220))
                } else {
                    await Task.yield()
                }
                guard !Task.isCancelled, focusRequest == requested else { return }
                searchFieldFocused = true
            }
        }
        } // GeometryReader: constant grid width, unscaled scroll viewport.
    }

    @MainActor
    private func loadSearchHistory() async {
        let request = UUID()
        historyRequestID = request
        let scope = api.metadataCacheScope
        do {
            let entries = try await api.searchHistory()
            guard !Task.isCancelled, historyRequestID == request,
                  api.metadataCacheScope == scope else { return }
            recentEntries = entries
            historyError = nil
        } catch {
            guard !Task.isCancelled, historyRequestID == request,
                  api.metadataCacheScope == scope else { return }
            if Self.unauthorizedHistory(error) {
                recentEntries = []
                historyError = nil // guest users have no account search history
            } else {
                historyError = error.localizedDescription
            }
        }
    }

    @MainActor
    private func saveSearchHistory(_ query: String) async {
        let scope = api.metadataCacheScope
        guard !Task.isCancelled else { return }
        savingHistoryCount += 1
        defer { savingHistoryCount -= 1 }
        do {
            _ = try await api.addSearchHistory(query)
            guard !Task.isCancelled, api.metadataCacheScope == scope else { return }
            await loadSearchHistory()
        } catch {
            guard !Task.isCancelled, api.metadataCacheScope == scope else { return }
            if !Self.unauthorizedHistory(error) {
                historyError = error.localizedDescription
            }
        }
    }

    @MainActor
    private func clearSearchHistory() async {
        guard !clearingHistory, savingHistoryCount == 0 else { return }
        clearingHistory = true
        historyRequestID = UUID()
        let scope = api.metadataCacheScope
        defer { clearingHistory = false }
        do {
            try await api.clearSearchHistory()
            guard !Task.isCancelled, api.metadataCacheScope == scope else { return }
            recentEntries = []
            historyError = nil
            focusedRecent = nil
            searchFieldFocused = true
        } catch {
            guard !Task.isCancelled, api.metadataCacheScope == scope else { return }
            historyError = error.localizedDescription
        }
    }

    private static func unauthorizedHistory(_ error: Error) -> Bool {
        if case TypeTypeError.http(401, _) = error { return true }
        if case TypeTypeError.serverDetails(401, _, _) = error { return true }
        return false
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
    private func reconcileMutations(_ events: [TVVideoMutationCenter.Event]) {
        let pending = events.filter {
            $0.id > lastMutationID && $0.accountScope == api.metadataCacheScope
        }
        lastMutationID = max(lastMutationID, events.last?.id ?? 0)
        guard !pending.isEmpty else { return }
        if videos.contains(where: { item in pending.contains { $0.removes(item) } }) {
            videos.removeAll { item in pending.contains { $0.removes(item) } }
        }
        if channels.contains(where: { channel in
            pending.contains { event in
                if case .channelBlocked = event.kind {
                    return event.channelURL == channel.url
                }
                return false
            }
        }) {
            channels.removeAll { channel in
                pending.contains { event in
                    if case .channelBlocked = event.kind {
                        return event.channelURL == channel.url
                    }
                    return false
                }
            }
        }
    }

    @MainActor
    private func execute(_ query: String, recordHistory: Bool = true) async {
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
            if recordHistory {
                // The history write is independent of result enrichment.
                Task { await saveSearchHistory(value) }
            }
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
            // Deduplicate both against older pages and *within* the new
            // page. A fixed pre-page Set lets duplicate search hits through.
            var knownChannels = Set(channels.map(\.url))
            channels += (result.channels ?? []).filter {
                knownChannels.insert($0.url).inserted
            }
            var knownPlaylists = Set(playlists.map(\.url))
            playlists += (result.playlists ?? []).filter {
                knownPlaylists.insert($0.url).inserted
            }
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
