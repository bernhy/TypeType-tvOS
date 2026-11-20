import SwiftUI

/// Compact second rail immediately to the right of the global navigation.
/// Once a library tab is selected the content area remains fully available
/// for a four-column video grid, just like the Android TV two-rail layout.
private enum TVLibraryDestination: Hashable {
    case standard(TVLibrarySection)
    case playlist(String)
}

struct LibraryView: View {
    let api: TypeTypeAPI
    var fixedLayoutWidth: CGFloat?
    var preferPlaylists = false
    var focusRequest = 0
    var onRevealMenu: () -> Void = {}

    @State private var handledFocusRequest: Int?
    @State private var lastLoadedDestination: TVLibraryDestination?
    @State private var selected: TVLibraryDestination = .standard(.watchLater)
    @FocusState private var focusedDestination: TVLibraryDestination?
    // Only Up/Down moves already within this rail may visually follow the
    // native focus. Left from content is pinned to the selected destination.
    @State private var railBrowsingVertically = false
    @StateObject private var videoMenu = TVHomeMenuCoordinator()
    @FocusState private var focusedVideoURL: String?
    @FocusState private var focusedRefresh: Bool
    @FocusState private var focusedEditPlaylist: Bool
    @FocusState private var focusedDeletePlaylist: Bool
    @State private var playlists: [TVPlaylistDTO] = []
    @State private var firstPlaylistSelectionPending = true
    @State private var editPlaylistID: String?
    @State private var playlistToDelete: String?
    @State private var mutationError: String?
    @State private var savingPlaylist = false
    @State private var videos: [VideoItem] = []
    @ObservedObject private var contentPreferences = TVContentPreferences.shared
    private var visibleVideos: [VideoItem] {
        contentPreferences.withoutHiddenLivestreams(videos)
    }
    @State private var statusMessage: String?
    @State private var railError: String?
    @State private var loading = false
    @State private var focusContentAfterLoad = false
    @State private var libraryRequestID = UUID()
    @State private var historyOffset = 0
    @State private var historyHasMore = false
    @State private var historyLoadingMore = false
    @State private var historyPageError: String?
    private let historyPageSize = 100
    @State private var title = TVL10n.value("library.watchLater")
    private let columns = Array(repeating: GridItem(.flexible(), spacing: 25), count: 4)

    var body: some View {
        HStack(alignment: .top, spacing: 20) {
            secondaryRail
                .frame(width: 240)
                .environment(\.isFocusEffectEnabled, false)
                .focusEffectDisabled(true)
                .focusSection()
            GeometryReader { viewport in
            // Keep the library subrail in its original 240pt slot. Only
            // its neighboring video content visually scales as the global
            // sidebar expands, never the library's own navigation controls.
            let layoutWidth = max(0, (fixedLayoutWidth ??
                (viewport.size.width + 260)) - 260)
            ScrollViewReader { scroll in
                ScrollView {
                    VStack(alignment: .leading, spacing: 23) {
                    HStack {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("library.kicker")
                                .font(.caption.bold()).tracking(1.5)
                                .foregroundStyle(TTTheme.accent)
                            Text(title)
                                .font(.system(size: 35, weight: .bold))
                                .lineLimit(1)
                        }
                        Spacer()
                        Text(TVL10n.formatted("common.videoCount", visibleVideos.count))
                            .font(.callout)
                            .foregroundStyle(TTTheme.muted)
                        if let queue = playbackQueue, !queue.isEmpty {
                            NavigationLink {
                                TVPlaylistPlaybackView(api: api, videos: queue)
                            } label: {
                                Label("playlist.playAll", systemImage: "play.fill")
                            }
                            .buttonStyle(.borderedProminent)
                        }
                        Button {
                            Task { await refresh() }
                        } label: {
                            Image(systemName: "arrow.clockwise")
                        }
                        .buttonStyle(.bordered)
                        .disabled(loading)
                        .focused($focusedRefresh)
                        .onMoveCommand { direction in
                            if direction == .left { focusedDestination = selected }
                        }
                        if case .playlist(let id) = selected {
                            Button {
                                editPlaylistID = id
                            } label: {
                                Label("action.renamePlaylist", systemImage: "pencil")
                            }
                            .buttonStyle(.bordered)
                            .disabled(savingPlaylist)
                            .focused($focusedEditPlaylist)
                            Button(role: .destructive) {
                                playlistToDelete = id
                            } label: {
                                Label("action.deletePlaylist", systemImage: "trash")
                            }
                            .buttonStyle(.bordered)
                            .disabled(savingPlaylist)
                            .focused($focusedDeletePlaylist)
                        }
                    }
                    if let mutationError {
                        Text(mutationError).font(.callout)
                            .foregroundStyle(.orange).lineLimit(2)
                    }
                    if loading {
                        TVPulsingPlaceholder()
                            .frame(maxWidth: .infinity, minHeight: 230)
                    } else if let statusMessage {
                        TVContentMessage(
                            symbol: "wifi.exclamationmark",
                            title: statusMessage,
                            detail: TVL10n.value("library.loadHelp"),
                            action: { Task { await refresh() } }
                        )
                    } else if visibleVideos.isEmpty {
                        TVContentMessage(
                            symbol: "rectangle.stack",
                            title: title,
                            detail: TVL10n.value("library.historyEmpty")
                        )
                    } else {
                        TVSharedVideoGrid(
                            snapshot: TVSharedVideoGridSnapshot(
                                videos: visibleVideos, scope: api.metadataCacheScope,
                                destination: "library-" + String(describing: selected),
                                focusPrefix: "",
                                accessibilityPrefix: "library-video-",
                                columns: columns.count, columnSpacing: 25,
                                rowSpacing: 28,
                                canLoadMore: selected == .standard(.history) &&
                                    historyHasMore && !loading && !historyLoadingMore,
                                loadAhead: 8,
                                lookupMissingMetadata: selected == .standard(.history),
                                isWatchLaterEntry: selected == .standard(.watchLater),
                                playbackQueue: playbackQueue
                            ),
                            api: api, focus: $focusedVideoURL, menu: videoMenu,
                            onReturnToList: { id in
                                TVVideoFocusReturn.restore(
                                    $focusedVideoURL, id: id, scroll: scroll
                                )
                            },
                            onLeftEdge: { _ in focusedDestination = selected },
                            onChanged: { Task { await refresh() } },
                            onApproachEnd: { Task { await loadMoreHistory() } },
                            onRemoveFromPlaylist: { removalAction(for: $0) }
                        )
                        .equatable()
                        if selected == .standard(.history) && historyHasMore {
                            HStack(spacing: 16) {
                                if historyLoadingMore { ProgressView() }
                                Button("library.loadMoreHistory") {
                                    Task { await loadMoreHistory() }
                                }
                                .buttonStyle(.bordered)
                                .disabled(historyLoadingMore)
                                if let historyPageError {
                                    Text(historyPageError)
                                        .foregroundStyle(.orange)
                                        .font(.callout)
                                }
                            }
                            .padding(.top, 8)
                        }
                    }
                }
                .padding(.top, 38)
                .padding(.trailing, 38)
                .padding(.bottom, 100)
                .frame(width: layoutWidth, alignment: .leading)
                .scaleEffect(
                    TVHomeNavigationZoom.scale(
                        visibleWidth: viewport.size.width,
                        layoutWidth: layoutWidth
                    ),
                    anchor: .topLeading
                )
                .frame(width: viewport.size.width, alignment: .topLeading)
                }
                .frame(width: viewport.size.width, height: viewport.size.height)
            }
            } // GeometryReader: library rail stays native; grid zooms.
        }
        .background(TTTheme.ink)
        .modifier(TVHomeMenuPresentation(model: videoMenu))
        .task { await contentPreferences.ensureLoaded(api: api) }
        .task { await refresh() }
        .onChange(of: focusedDestination) { previous, next in
            if next == nil {
                railBrowsingVertically = false
            } else if previous == nil {
                railBrowsingVertically = false
                if let next, next != selected {
                    // The nearest playlist/section can win the first native
                    // focus frame. Restore the page that is actually shown.
                    let expected = selected
                    Task { @MainActor in
                        await Task.yield()
                        guard selected == expected, focusedDestination == next else { return }
                        focusedDestination = expected
                    }
                }
            } else {
                railBrowsingVertically = true
            }
        }
        .task(id: focusRequest) {
            guard focusRequest >= 0, handledFocusRequest != focusRequest else { return }
            handledFocusRequest = focusRequest
            await Task.yield()
            guard !Task.isCancelled else { return }
            focusedDestination = selected
        }
        .task(id: selected) {
            // NavigationStack can rerun .task on popping a video detail.
            // A page already loaded for this destination retains its grid
            // identity, scroll position and last focused tile.
            guard lastLoadedDestination != selected else { return }
            lastLoadedDestination = selected
            await loadSelected()
        }
        .onExitCommand {
            if focusedDestination != nil {
                onRevealMenu()
            } else {
                focusedDestination = selected
            }
        }
        .sheet(isPresented: Binding(
            get: { editPlaylistID != nil },
            set: { if !$0 { editPlaylistID = nil } }
        ), onDismiss: {
            Task { @MainActor in
                await Task.yield()
                focusedEditPlaylist = true
            }
        }) {
            if let id = editPlaylistID {
                TVPlaylistRenameView(
                    api: api, playlistID: id, initialName: title,
                    onSaved: {
                        editPlaylistID = nil
                        Task { await refresh() }
                    },
                    onCancel: { editPlaylistID = nil }
                )
            }
        }
        .onChange(of: playlistToDelete) { _, current in
            if current == nil {
                Task { @MainActor in
                    await Task.yield()
                    focusedDeletePlaylist = true
                }
            }
        }
        .confirmationDialog(
            TVL10n.value("action.deletePlaylistConfirm"),
            isPresented: Binding(
                get: { playlistToDelete != nil },
                set: { if !$0 { playlistToDelete = nil } }
            )
        ) {
            if let id = playlistToDelete {
                Button("action.deletePlaylist", role: .destructive) {
                    Task { await deletePlaylist(id) }
                }
            }
            Button("common.cancel", role: .cancel) { playlistToDelete = nil }
        }
    }

    private var playbackQueue: [VideoItem]? {
        switch selected {
        case .playlist, .standard(.watchLater):
            return visibleVideos
        case .standard:
            return nil
        }
    }

    private func removalAction(for video: VideoItem) -> (() async throws -> Void)? {
        guard case .playlist(let id) = selected else { return nil }
        return {
            try await api.removeFromPlaylist(id, videoURL: video.url)
            await TVPlaylistMembership.shared.markRemoved(
                videoURL: video.url, playlistID: id, api: api
            )
        }
    }

    @MainActor
    private func deletePlaylist(_ id: String) async {
        guard !savingPlaylist else { return }
        savingPlaylist = true
        mutationError = nil
        defer { savingPlaylist = false; playlistToDelete = nil }
        do {
            try await api.deletePlaylist(id)
            TVPlaylistMembership.shared.invalidate(api: api)
            Task { await TVPlaylistMembership.shared.ensureLoaded(api: api) }
            selected = .standard(.watchLater)
            await refresh()
        } catch {
            mutationError = error.localizedDescription
        }
    }

    private var secondaryRail: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(preferPlaylists ? TVL10n.value("nav.playlists") :
                    TVL10n.value("nav.library"))
                .font(.system(size: 27, weight: .bold))
                .padding(.top, 44)
                .padding(.bottom, 10)
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    railButton(.standard(.watchLater), title: TVL10n.value("library.watchLater"),
                               symbol: "bookmark")
                    railButton(.standard(.history), title: TVL10n.value("library.history"),
                               symbol: "clock.arrow.circlepath")
                    railButton(.standard(.favorites), title: TVL10n.value("library.favorites"),
                               symbol: "heart")
                    Divider().padding(.vertical, 12)
                    Text("action.playlists")
                        .font(.caption.bold())
                        .foregroundStyle(TTTheme.muted)
                    ForEach(playlists) { playlist in
                        railButton(.playlist(playlist.id), title: playlist.name,
                                   symbol: "list.bullet.rectangle")
                    }
                    if playlists.isEmpty {
                        Text("action.noPlaylists")
                            .font(.caption)
                            .foregroundStyle(TTTheme.muted)
                    }
                    if let railError {
                        Text(railError)
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 30)
        .frame(maxHeight: .infinity)
        // Same black secondary rail as Settings; the gray main icon rail
        // remains unchanged while it expands and collapses.
        .background(TTTheme.ink)
        .focusEffectDisabled(true)
    }

    private func railButton(_ destination: TVLibraryDestination,
                            title: String, symbol: String) -> some View {
        Button {
            enterDestination(destination)
        } label: {
            HStack(spacing: 12) {
                Image(systemName: symbol).frame(width: 25)
                Text(title).lineLimit(1)
                Spacer(minLength: 0)
                if selected == destination {
                    Image(systemName: "chevron.right").font(.caption.bold())
                }
            }
            .font(.system(size: 19, weight: .medium))
            .padding(.horizontal, 13)
            .frame(maxWidth: .infinity, minHeight: 54, alignment: .leading)
            .modifier(TVRailRowHighlight(
                focused: TVRailVisualFocus.highlights(
                    destination, focused: focusedDestination, selected: selected,
                    browsingWithinRail: railBrowsingVertically
                ),
                selected: selected == destination
            ))
        }
        .buttonStyle(TVRailButtonStyle())
        .focusEffectDisabled(true)
        .focused($focusedDestination, equals: destination)
        .onMoveCommand { direction in
            if direction == .right {
                railBrowsingVertically = false
                enterDestination(destination)
            } else if direction == .left {
                railBrowsingVertically = false
                onRevealMenu()
            } else if direction == .up || direction == .down {
                railBrowsingVertically = true
            }
        }
        .accessibilityAddTraits(selected == destination ? .isSelected : [])
        .accessibilityIdentifier("library-nav-" + destinationIdentifier(destination))
    }

    private func destinationIdentifier(_ item: TVLibraryDestination) -> String {
        switch item {
        case .standard(let section): return section.rawValue
        case .playlist(let id): return "playlist-" + id
        }
    }

    @MainActor
    private func enterDestination(_ destination: TVLibraryDestination) {
        if destination != selected {
            focusContentAfterLoad = true
            selected = destination
        } else {
            focusFirstContent()
        }
    }

    @MainActor
    private func focusFirstContent() {
        guard !loading else {
            focusContentAfterLoad = true
            return
        }
        if let first = videos.first {
            focusedVideoURL = first.url
        } else {
            focusedRefresh = true
        }
    }

    @MainActor
    private func refresh() async {
        do {
            playlists = try await api.playlists()
            if preferPlaylists && firstPlaylistSelectionPending,
               let first = playlists.first {
                selected = .playlist(first.id)
            }
            firstPlaylistSelectionPending = false
            railError = nil
        } catch {
            // The built-in tabs still work even if custom playlists fail.
            railError = error.localizedDescription
        }
        await loadSelected()
    }

    /// Load further raw history events until at least one *new* video is
    /// found. A whole page can contain only previously displayed videos.
    /// Never replace the existing grid: preserve focus, scroll and zoom.
    @MainActor
    private func loadMoreHistory() async {
        guard selected == .standard(.history),
              !historyLoadingMore && !loading && historyHasMore else { return }
        let requestID = libraryRequestID
        historyLoadingMore = true
        historyPageError = nil
        defer {
            if requestID == libraryRequestID { historyLoadingMore = false }
        }
        do {
            var nextOffset = historyOffset
            var more = historyHasMore
            var newVideos: [VideoItem] = []
            // Duplicated history events can span several consecutive pages.
            // This is bounded to avoid a very long blocking UI operation.
            for _ in 0..<10 {
                let page = try await api.historyPage(
                    offset: nextOffset, limit: historyPageSize
                )
                try Task.checkCancellation()
                guard selected == .standard(.history),
                      libraryRequestID == requestID else { return }
                nextOffset += page.count
                more = page.count == historyPageSize
                newVideos = TVHistoryDeduplicator.appendUnique(page, to: videos)
                if !newVideos.isEmpty || !more { break }
            }
            historyOffset = nextOffset
            historyHasMore = more
            guard !newVideos.isEmpty else { return }
            videos.append(contentsOf: newVideos)
            let enriched = await api.withProgress(newVideos)
            guard !Task.isCancelled, selected == .standard(.history),
                  libraryRequestID == requestID else { return }
            let lookup = Dictionary(
                enriched.map { (TVHistoryDeduplicator.key(for: $0), $0) },
                uniquingKeysWith: { newer, _ in newer }
            )
            videos = videos.map {
                lookup[TVHistoryDeduplicator.key(for: $0)] ?? $0
            }
        } catch is CancellationError {
            return
        } catch {
            guard libraryRequestID == requestID else { return }
            historyPageError = error.localizedDescription
        }
    }

    @MainActor
    private func loadSelected() async {
        let requested = selected
        let identifier = UUID()
        libraryRequestID = identifier
        loading = true
        statusMessage = nil
        historyOffset = 0
        historyHasMore = false
        historyLoadingMore = false
        historyPageError = nil
        defer {
            if libraryRequestID == identifier { loading = false }
        }
        do {
            let loaded: [VideoItem]
            let heading: String
            switch requested {
            case .standard(let section):
                if section == .history {
                    let page = try await api.historyPage(offset: 0, limit: historyPageSize)
                    loaded = TVHistoryDeduplicator.unique(page)
                    // Do not use unique count as HTTP offset: duplicated
                    // playback events still occupy rows in the server.
                    guard requested == selected, libraryRequestID == identifier else { return }
                    historyOffset = page.count
                    historyHasMore = page.count == historyPageSize
                } else {
                    loaded = try await api.library(section)
                }
                heading = section.title
            case .playlist(let id):
                let playlist = try await api.playlist(id)
                loaded = playlist.items
                heading = playlist.name
            }
            guard !Task.isCancelled, requested == selected,
                  libraryRequestID == identifier else { return }
            title = heading
            videos = loaded
            if focusContentAfterLoad {
                focusContentAfterLoad = false
                Task { @MainActor in
                    await Task.yield()
                    if let first = loaded.first {
                        focusedVideoURL = first.url
                    } else {
                        focusedRefresh = true
                    }
                }
            }
            let enriched = await api.withProgress(loaded)
            guard !Task.isCancelled, requested == selected,
                  libraryRequestID == identifier else { return }
            videos = enriched
        } catch is CancellationError {
            return
        } catch {
            guard requested == selected, libraryRequestID == identifier else { return }
            videos = []
            statusMessage = error.localizedDescription
        }
    }
}
