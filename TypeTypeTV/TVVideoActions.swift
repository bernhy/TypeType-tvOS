import SwiftUI

/// Native tvOS context menus open by holding Select on a focused video card.
/// Actions always operate on TypeType's account library, never an isolated
/// Apple TV-only copy. A toast confirms success and alerts explain failures.
struct TVVideoActionModifier: ViewModifier {
    let api: TypeTypeAPI
    let video: VideoItem
    let onChanged: (() -> Void)?
    let onRemoveFromPlaylist: (() async throws -> Void)?
    let isWatchLaterEntry: Bool

    @ObservedObject private var localProgress = TVLocalProgress.shared
    @ObservedObject private var watchLaterMembership = TVWatchLaterMembership.shared

    private var isMarkedWatched: Bool {
        guard let duration = video.duration, duration > 0 else { return false }
        if let position = localProgress.positions[video.url] ?? video.watchPositionMs {
            return position >= Int64(duration) * 900
        }
        return video.watched == true
    }
    @FocusState private var cardFocus: Bool
    @State private var pickerVisible = false
    @State private var toBlock: TVBlockTarget?
    @State private var feedback: String?
    @State private var errorMessage: String?
    @State private var working = false

    func body(content: Content) -> some View {
        content
            .focused($cardFocus)
            .task { await watchLaterMembership.ensureLoaded(api: api) }
            .contextMenu {
                if let position = localProgress.positions[video.url] ?? video.watchPositionMs,
                   position > 0 {
                    Button {
                    } label: {
                        Label(
                            TVL10n.formatted("action.playedUntil", TTTheme.time(Int(position / 1_000))),
                            systemImage: "clock.arrow.circlepath"
                        )
                    }
                    .disabled(true)
                }
                if video.isLive != true, let duration = video.duration, duration > 0 {
                    Button {
                        // Local progress observation refreshes all visible cards.
                        // Do not reload the entire recommendations page and
                        // discard its cursor/scroll position after a toggle.
                        perform(refresh: false) {
                            let markWatched = !isMarkedWatched
                            try await api.setWatched(markWatched, video: video)
                            TVLocalProgress.shared.record(
                                video.url, positionMs: markWatched ? Int64(duration) * 1_000 : 0
                            )
                            return TVL10n.value(markWatched
                                ? "action.markWatchedSuccess" : "action.markUnwatchedSuccess")
                        }
                    } label: {
                        Label(
                            isMarkedWatched ? "action.markUnwatched" : "action.markWatched",
                            systemImage: isMarkedWatched ? "arrow.uturn.backward.circle" : "checkmark.circle"
                        )
                    }
                }
                if isWatchLaterEntry || watchLaterMembership.contains(video.url) {
                    Button(role: .destructive) {
                        perform {
                            try await api.setWatchLater(video: video, enabled: false)
                            TVWatchLaterMembership.shared.mark(
                                video.url, present: false, api: api
                            )
                            return TVL10n.value("action.removedWatchLater")
                        }
                    } label: {
                        Label("action.removeWatchLater", systemImage: "bookmark.slash")
                    }
                } else {
                    Button {
                        perform {
                            try await api.setWatchLater(video: video, enabled: true)
                            TVWatchLaterMembership.shared.mark(
                                video.url, present: true, api: api
                            )
                            return TVL10n.value("action.savedWatchLater")
                        }
                    } label: {
                        Label("action.watchLater", systemImage: "bookmark")
                    }
                }
                Button {
                    pickerVisible = true
                } label: {
                    Label("action.addPlaylist", systemImage: "text.badge.plus")
                }
                if let onRemoveFromPlaylist {
                    Button(role: .destructive) {
                        perform {
                            try await onRemoveFromPlaylist()
                            return TVL10n.value("action.removedPlaylist")
                        }
                    } label: {
                        Label("action.removePlaylistVideo", systemImage: "minus.circle")
                    }
                }
                Button(role: .destructive) {
                    toBlock = .video
                } label: {
                    Label("action.blockVideo", systemImage: "hand.raised")
                }
                Button(role: .destructive) {
                    if video.uploaderUrl?.isEmpty == false {
                        toBlock = .channel
                    } else {
                        errorMessage = TVL10n.value("action.channelUnavailable")
                    }
                } label: {
                    Label("action.blockChannel", systemImage: "person.crop.circle.badge.xmark")
                }
            }
            .overlay(alignment: .topLeading) {
                if let feedback {
                    Label(feedback, systemImage: "checkmark.circle.fill")
                        .font(.callout.bold())
                        .foregroundStyle(.white)
                        .padding(10)
                        .background(.black.opacity(0.88), in: RoundedRectangle(cornerRadius: 12))
                        .padding(7)
                        .allowsHitTesting(false)
                }
            }
            .sheet(isPresented: $pickerVisible, onDismiss: restoreCardFocus) {
                TVPlaylistPickerView(api: api, video: video) { success in
                    pickerVisible = false
                    feedback = success
                    refreshAfterFeedback()
                }
            }
            .onChange(of: toBlock) { old, current in
                if old != nil && current == nil { restoreCardFocus() }
            }
            .onChange(of: errorMessage) { old, current in
                if old != nil && current == nil { restoreCardFocus() }
            }
            .confirmationDialog(
                TVL10n.value("action.confirmBlock"),
                isPresented: Binding(
                    get: { toBlock != nil },
                    set: { if !$0 { toBlock = nil } }
                )
            ) {
                if let target = toBlock {
                    Button(
                        TVL10n.value(
                            target == .video ? "action.blockVideo" : "action.blockChannel"
                        ),
                        role: .destructive
                    ) {
                        perform {
                            switch target {
                            case .video: try await api.blockVideo(video)
                            case .channel: try await api.blockChannel(video)
                            }
                            return TVL10n.value("action.blocked")
                        }
                        toBlock = nil
                    }
                }
                Button("common.cancel", role: .cancel) { toBlock = nil }
            }
            .alert(
                TVL10n.value("action.failed"),
                isPresented: Binding(
                    get: { errorMessage != nil },
                    set: { if !$0 { errorMessage = nil } }
                )
            ) {
                Button("common.ok") { errorMessage = nil }
            } message: {
                Text(errorMessage ?? "")
            }
    }

    private func restoreCardFocus() {
        Task { @MainActor in
            await Task.yield()
            cardFocus = true
        }
    }

    private func refreshAfterFeedback() {
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            onChanged?()
        }
    }

    private func perform(refresh: Bool = true,
                         _ action: @escaping () async throws -> String) {
        guard !working else { return }
        working = true
        feedback = nil
        Task { @MainActor in
            defer { working = false }
            do {
                let text = try await action()
                feedback = text
                if refresh { refreshAfterFeedback() }
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}

private enum TVBlockTarget { case video, channel }

extension View {
    func videoActions(
        api: TypeTypeAPI, video: VideoItem,
        onChanged: (() -> Void)? = nil,
        onRemoveFromPlaylist: (() async throws -> Void)? = nil,
        isWatchLaterEntry: Bool = false
    ) -> some View {
        modifier(TVVideoActionModifier(
            api: api, video: video, onChanged: onChanged,
            onRemoveFromPlaylist: onRemoveFromPlaylist,
            isWatchLaterEntry: isWatchLaterEntry
        ))
    }
}

struct TVPlaylistPickerView: View {
    let api: TypeTypeAPI
    let video: VideoItem
    let onSaved: (String) -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var playlists: [TVPlaylistDTO] = []
    @State private var loading = true
    @State private var pending = false
    @State private var error: String?
    @State private var newName = ""
    @State private var creating = false

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack {
                Text("action.choosePlaylist").font(.title.bold())
                Spacer()
                Button("common.cancel") { dismiss() }
                    .buttonStyle(.bordered)
            }
            Text(video.title)
                .font(.callout)
                .foregroundStyle(TTTheme.muted)
                .lineLimit(2)
            if loading {
                ProgressView("settings.remoteLoading")
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(playlists) { playlist in
                            Button {
                                Task { await add(to: playlist) }
                            } label: {
                                HStack {
                                    Label(playlist.name, systemImage: "list.bullet")
                                    Spacer()
                                    Text("\(playlist.count)")
                                        .foregroundStyle(TTTheme.muted)
                                }
                            }
                            .buttonStyle(.bordered)
                            .disabled(pending)
                        }
                    }
                }
                HStack {
                    TextField("action.newPlaylist", text: $newName)
                        .autocorrectionDisabled()
                    Button("action.createPlaylist") {
                        Task { await createAndAdd() }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(pending || newName.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            if let error {
                Text(error).font(.callout).foregroundStyle(.orange)
            }
        }
        .padding(50)
        .frame(width: 850, height: 820)
        .background(TTTheme.ink)
        .task { await load() }
    }

    @MainActor
    private func load() async {
        loading = true
        defer { loading = false }
        do {
            playlists = try await api.playlists()
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    @MainActor
    private func createAndAdd() async {
        let name = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !pending else { return }
        pending = true
        defer { pending = false }
        do {
            let playlist = try await api.createPlaylist(name: name)
            try await api.addToPlaylist(playlist.id, video: video)
            onSaved(TVL10n.value("action.addedPlaylist"))
        } catch { self.error = error.localizedDescription }
    }

    @MainActor
    private func add(to playlist: TVPlaylistDTO) async {
        guard !pending else { return }
        pending = true
        defer { pending = false }
        do {
            try await api.addToPlaylist(playlist.id, video: video)
            onSaved(TVL10n.value("action.addedPlaylist"))
        } catch { self.error = error.localizedDescription }
    }
}
