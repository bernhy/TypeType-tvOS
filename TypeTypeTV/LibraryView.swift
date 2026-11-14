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
    var preferPlaylists = false

    @State private var selected: TVLibraryDestination = .standard(.watchLater)
    @FocusState private var focusedDestination: TVLibraryDestination?
    @FocusState private var focusedVideoURL: String?
    @FocusState private var focusedEditPlaylist: Bool
    @FocusState private var focusedDeletePlaylist: Bool
    @State private var playlists: [TVPlaylistDTO] = []
    @State private var firstPlaylistSelectionPending = true
    @State private var editPlaylistID: String?
    @State private var playlistToDelete: String?
    @State private var mutationError: String?
    @State private var savingPlaylist = false
    @State private var videos: [VideoItem] = []
    @State private var statusMessage: String?
    @State private var railError: String?
    @State private var loading = false
    @State private var title = TVL10n.value("library.watchLater")
    private let columns = Array(repeating: GridItem(.flexible(), spacing: 25), count: 4)

    var body: some View {
        HStack(alignment: .top, spacing: 20) {
            secondaryRail
                .frame(width: 240)
                .environment(\.isFocusEffectEnabled, false)
                .focusEffectDisabled(true)
                .focusSection()
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
                        Text(TVL10n.formatted("common.videoCount", videos.count))
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
                        ProgressView("settings.remoteLoading")
                            .frame(maxWidth: .infinity, minHeight: 230)
                    } else if let statusMessage {
                        TVContentMessage(
                            symbol: "wifi.exclamationmark",
                            title: statusMessage,
                            detail: TVL10n.value("library.loadHelp"),
                            action: { Task { await refresh() } }
                        )
                    } else if videos.isEmpty {
                        TVContentMessage(
                            symbol: "rectangle.stack",
                            title: title,
                            detail: TVL10n.value("library.historyEmpty")
                        )
                    } else {
                        LazyVGrid(columns: columns, spacing: 28) {
                            ForEach(videos) { video in
                                NavigationLink {
                                    VideoDetailView(
                                        api: api, video: video,
                                        playbackQueue: playbackQueue
                                    )
                                } label: {
                                    VideoCard(api: api, video: video,
                                              lookupMissingMetadata: selected == .standard(.history))
                                }
                                .buttonStyle(.plain)
                                .focusEffectDisabled(true)
                                .videoActions(
                                    api: api, video: video,
                                    onChanged: { Task { await refresh() } },
                                    onRemoveFromPlaylist: removalAction(for: video),
                                    isWatchLaterEntry: selected == .standard(.watchLater),
                                    focus: $focusedVideoURL, focusID: video.url
                                )
                                .accessibilityLabel(TTTheme.accessibilityText(for: video))
                            }
                        }
                        .focusSection()
                    }
                }
                .padding(.top, 38)
                .padding(.trailing, 38)
                .padding(.bottom, 100)
            }
        }
        .background(TTTheme.ink)
        .task {
            // Establish the subrail focus BEFORE waiting on the account's
            // playlist/library HTTP requests. Otherwise tvOS can temporarily
            // focus the global Home icon while the library loads.
            await Task.yield()
            focusedDestination = selected
            await refresh()
        }
        .task(id: selected) { await loadSelected() }
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
            return videos
        case .standard:
            return nil
        }
    }

    private func removalAction(for video: VideoItem) -> (() async throws -> Void)? {
        guard case .playlist(let id) = selected else { return nil }
        return { try await api.removeFromPlaylist(id, videoURL: video.url) }
    }

    @MainActor
    private func deletePlaylist(_ id: String) async {
        guard !savingPlaylist else { return }
        savingPlaylist = true
        mutationError = nil
        defer { savingPlaylist = false; playlistToDelete = nil }
        do {
            try await api.deletePlaylist(id)
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
        .background(TTTheme.surface)
        .focusEffectDisabled(true)
    }

    private func railButton(_ destination: TVLibraryDestination,
                            title: String, symbol: String) -> some View {
        Button {
            selected = destination
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
                focused: focusedDestination == destination,
                selected: selected == destination
            ))
        }
        .buttonStyle(TVRailButtonStyle())
        .focusEffectDisabled(true)
        .focused($focusedDestination, equals: destination)
        .onMoveCommand { direction in
            if direction == .right {
                focusedVideoURL = videos.first?.url
            }
        }
        .accessibilityAddTraits(selected == destination ? .isSelected : [])
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

    @MainActor
    private func loadSelected() async {
        let requested = selected
        loading = true
        statusMessage = nil
        defer { if selected == requested { loading = false } }
        do {
            let loaded: [VideoItem]
            let heading: String
            switch requested {
            case .standard(let section):
                loaded = try await api.library(section)
                heading = section.title
            case .playlist(let id):
                let playlist = try await api.playlist(id)
                loaded = playlist.items
                heading = playlist.name
            }
            guard !Task.isCancelled, requested == selected else { return }
            title = heading
            videos = loaded
            let enriched = await api.withProgress(loaded)
            guard !Task.isCancelled, requested == selected else { return }
            videos = enriched
        } catch is CancellationError {
            return
        } catch {
            guard requested == selected else { return }
            videos = []
            statusMessage = error.localizedDescription
        }
    }
}
