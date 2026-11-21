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
    @State private var initialLoadStarted = false
    @State private var initialLoadFinished = false
    // Set synchronously as the detail dismisses, before tvOS chooses its
    // next native focus target; does not trigger a second grid reload.
    @State private var detailReturnVideoID: String?
    @State private var railReturnVideoID: String?
    @State private var mutationCursor = TVVideoMutationCursor()
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
    private var preferredVideoID: String? {
        guard let saved = detailReturnVideoID ?? railReturnVideoID,
              visibleVideos.contains(where: { $0.url == saved }) else { return nil }
        return saved
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
                // Enter the currently selected library destination directly;
                // no Task.yield correction after tvOS chose a neighbor.
                .defaultFocus(
                    $focusedDestination, selected, priority: .userInitiated
                )
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
                                reloadPlaylistOnRemoval: isPlaylistSelected,
                                playbackQueue: playbackQueue
                            ),
                            api: api, focus: $focusedVideoURL, menu: videoMenu,
                            onReturnToList: { id in
                                // The ScrollView and its LazyVGrid are still
                                // mounted. Preserve their natural scroll
                                // position instead of centering the card
                                // after an arbitrary 180+140ms delay.
                                // If this exact video was removed from the
                                // currently displayed list while in detail,
                                // the old focus target no longer exists.
                                let target = visibleVideos.first(where: {
                                    TVVideoIdentity.equivalent($0.url, id)
                                })?.url ?? visibleVideos.first?.url
                                detailReturnVideoID = target
                                focusedDestination = target == nil ? selected : nil
                                focusedVideoURL = target
                            },
                            onLeftEdge: { id in
                                railReturnVideoID = id
                                detailReturnVideoID = nil
                                focusedDestination = selected
                            },
                            // Mutations remove only affected cached entries.
                            onChanged: {},
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
                // The user explicitly returned from this detail tile. Give
                // its current position first priority during the pop.
                .defaultFocus(
                    $focusedVideoURL, preferredVideoID,
                    priority: preferredVideoID == nil
                        ? .automatic : .userInitiated
                )
            }
            } // GeometryReader: library rail stays native; grid zooms.
        }
        // The entire page is a native focus-entry region. A Right move
        // from the global rail should prefer the last saved video even
        // though the secondary navigation sits geometrically to its left.
        // A nil saved ID leaves first-entry rail focus unchanged.
        .defaultFocus(
            $focusedVideoURL, preferredVideoID,
            priority: preferredVideoID == nil ? .automatic : .userInitiated
        )
        .background(TTTheme.ink)
        .modifier(TVHomeMenuPresentation(model: videoMenu))
        .onReceive(TVVideoMutationCenter.shared.$events) { reconcileMutations($0) }
        .onAppear { reconcileMutations(TVVideoMutationCenter.shared.events) }
        .onChange(of: videoMenu.focusRestoreRequest) { _, _ in
            if let id = videoMenu.focusRestoreTarget,
               visibleVideos.contains(where: { $0.url == id }) {
                focusedDestination = nil
                focusedVideoURL = id
            }
        }
        .task { await TVWatchLaterMembership.shared.ensureLoaded(api: api) }
        .task {
            async let playlists: Void = TVPlaylistMembership.shared.ensureLoaded(api: api)
            async let favorites: Void = TVFavoriteMembership.shared.ensureLoaded(api: api)
            _ = await (playlists, favorites)
        }
        .task { await contentPreferences.ensureLoaded(api: api) }
        .task {
            // A SwiftUI .task restarts after returning from a pushed detail.
            // Never replace the visible LazyVGrid with a loading placeholder
            // or refetch playlists/history unless explicitly requested.
            guard !initialLoadStarted, !initialLoadFinished else { return }
            initialLoadStarted = true
            await refresh()
            if Task.isCancelled {
                // A detail push can cancel an initial load that has not
                // finished. Unlike a normal completed load, that must be
                // eligible for retry when the Library becomes visible again.
                initialLoadStarted = false
                return
            }
            lastLoadedDestination = selected
            initialLoadFinished = true
        }
        .onChange(of: focusedDestination) { previous, next in
            railBrowsingVertically = previous != nil && next != nil
        }
        .task(id: focusRequest) {
            guard focusRequest >= 0, handledFocusRequest != focusRequest else { return }
            handledFocusRequest = focusRequest
            // The last tile is already registered with native defaultFocus.
            // Do not focus the subrail first and then visibly jump to it.
            if preferredVideoID != nil { return }
            await Task.yield()
            guard !Task.isCancelled else { return }
            focusedDestination = selected
        }
        .task(id: selected) {
            // Initial refresh owns the first load. Later only an actual tab
            // change may fetch and replace this grid.
            guard initialLoadFinished,
                  lastLoadedDestination != selected else { return }
            lastLoadedDestination = selected
            await loadSelected()
        }
        .onExitCommand {
            if focusedDestination != nil {
                onRevealMenu()
            } else {
                if let focusedVideoURL {
                    railReturnVideoID = focusedVideoURL
                }
                detailReturnVideoID = nil
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

    private var isPlaylistSelected: Bool {
        if case .playlist = selected { return true }
        return false
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
            await TVVideoMutationCenter.shared.record(
                api: api, video: video, kind: .playlist(id: id, added: false)
            )
        }
    }

    @MainActor
    private func reconcileMutations(_ events: [TVVideoMutationCenter.Event]) {
        let pending = events.filter {
            $0.id > mutationCursor.lastID && $0.accountScope == api.metadataCacheScope
        }
        mutationCursor.lastID = max(mutationCursor.lastID, events.last?.id ?? 0)
        guard !pending.isEmpty else { return }
        let destination = selected
        let shouldRemove: (VideoItem) -> Bool = { video in
            pending.contains { event in
                if event.removes(video) { return true }
                switch destination {
                case .standard(.watchLater):
                    return event.removesFromWatchLater(video)
                case .standard(.favorites):
                    return event.removesFromFavorites(video)
                case .playlist(let id):
                    return event.removesFromPlaylist(video, id: id)
                case .standard(.history):
                    return false
                }
            }
        }
        if videos.contains(where: shouldRemove) {
            videos.removeAll(where: shouldRemove)
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
            railReturnVideoID = nil
            detailReturnVideoID = nil
            focusContentAfterLoad = true
            selected = destination
        } else if let preferredVideoID {
            // Explicit OK/Right on the selected category transfers directly.
            // Native defaultFocus owns the destination, not a delayed Task.
            focusedVideoURL = preferredVideoID
        } else {
            focusFirstContent()
        }
    }

    @MainActor
    private func focusFirstContent() {
        if let preferredVideoID {
            focusedVideoURL = preferredVideoID
            return
        }
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
