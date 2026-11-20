import SwiftUI

/// Native tvOS context menus open by holding Select on a focused video card.
/// Actions always operate on TypeType's account library, never an isolated
/// Apple TV-only copy. A toast confirms success and alerts explain failures.
private struct TVActionFocusModifier: ViewModifier {
    let local: FocusState<Bool>.Binding
    let external: FocusState<String?>.Binding?
    let key: String?

    func body(content: Content) -> some View {
        if let external, let key {
            content.focused(external, equals: key)
        } else {
            content.focused(local)
        }
    }
}

struct TVVideoActionModifier: ViewModifier {
    let api: TypeTypeAPI
    let video: VideoItem
    let onChanged: (() -> Void)?
    let onRemoveFromPlaylist: (() async throws -> Void)?
    let isWatchLaterEntry: Bool
    let externalFocus: FocusState<String?>.Binding?
    let focusID: String?

    @ObservedObject private var localProgress = TVLocalProgress.shared
    @ObservedObject private var watchLaterMembership = TVWatchLaterMembership.shared

    private var videoWithKnownDuration: VideoItem {
        var row = video
        if (row.duration ?? 0) <= 0, let resolvedDuration {
            row.duration = resolvedDuration
        }
        return row
    }
    private var isMarkedWatched: Bool {
        TVWatchedState.isWatched(videoWithKnownDuration, positionMs:
            localProgress.position(for: video.url) ?? video.watchPositionMs)
    }
    @State private var resolvedDuration: Int?
    @FocusState private var cardFocus: Bool
    @State private var toBlock: TVBlockTarget?
    @State private var feedback: String?
    @State private var feedbackDelayTask: Task<Void, Never>?
    @State private var errorMessage: String?
    @State private var working = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .modifier(TVActionFocusModifier(
                local: $cardFocus, external: externalFocus, key: focusID
            ))
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
                if video.isLive != true,
                   ((videoWithKnownDuration.duration ?? 0) > 0 || video.isShort) {
                    Button {
                        // Resolve missing Shorts duration only when the user
                        // invokes the action, never for every thumbnail.
                        perform(refresh: false) {
                            var target = videoWithKnownDuration
                            if (target.duration ?? 0) <= 0 {
                                let details = await TVStreamMetadataCache.shared.details(
                                    for: video, api: api
                                )
                                target = TVVideoMetadata.merged(video, stream: details)
                            }
                            guard let duration = target.duration, duration > 0,
                                  duration <= Int64.max / 1_000 else {
                                throw TypeTypeError.missingVideoDuration
                            }
                            let markWatched = !isMarkedWatched
                            try await api.setWatched(markWatched, video: target)
                            resolvedDuration = duration
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
                let watchLaterStatus: TVWatchLaterMenuStatus = isWatchLaterEntry
                    ? .saved : watchLaterMembership.menuStatus(for: video.url, api: api)
                if watchLaterStatus == .saved {
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
                } else if watchLaterStatus == .notSaved {
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
                } else if watchLaterStatus == .loading {
                    Button {} label: {
                        Label("action.watchLaterLoading", systemImage: "clock")
                    }
                    .disabled(true)
                } else {
                    Button {
                        Task { await watchLaterMembership.retryLoading(api: api) }
                    } label: {
                        Label("action.watchLaterRetry", systemImage: "arrow.clockwise")
                    }
                }
                Button {
                    TVPlaylistPopupPresenter.shared.present(
                        api: api, video: video,
                        onSaved: { success in
                            presentFeedback(success)
                            // A successful addition updates only the shared
                            // membership index, retaining grid scroll/focus.
                            if success == TVL10n.value("action.removedPlaylist") {
                                refreshAfterFeedback()
                            }
                        },
                        onDismiss: restoreCardFocus
                    )
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
                        .transition(.opacity)
                }
            }
            .animation(.easeInOut(duration: reduceMotion ? 0.12 : 0.23),
                       value: feedback)
            .task(id: feedback) {
                guard let current = feedback else { return }
                try? await Task.sleep(for: .seconds(2.4))
                guard !Task.isCancelled && feedback == current else { return }
                withAnimation(.easeInOut(duration: reduceMotion ? 0.12 : 0.23)) {
                    feedback = nil
                }
            }
            .onDisappear { feedbackDelayTask?.cancel() }
            .onChange(of: toBlock) { old, current in
                if old != nil && current == nil { restoreCardFocus() }
            }
            .onChange(of: errorMessage) { old, current in
                if old != nil && current == nil { restoreCardFocus() }
            }
            .confirmationDialog(
                TVL10n.formatted(
                    "action.confirmBlockNamed",
                    toBlock == .channel
                        ? (video.uploaderName ?? TVL10n.value("action.channelUnavailable"))
                        : video.title
                ),
                isPresented: Binding(
                    get: { toBlock != nil },
                    set: { if !$0 { toBlock = nil } }
                ),
                titleVisibility: .visible
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
                            case .video:
                                try await api.blockVideo(video)
                                TVBlockedNameCache.remember(
                                    title: video.title, url: video.url, api: api
                                )
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
            if let externalFocus, let focusID {
                externalFocus.wrappedValue = focusID
            } else {
                cardFocus = true
            }
        }
    }

    /// A menu dismissal briefly shrinks then re-enlarges its focused card.
    /// Wait for that navigation/focus animation before starting the toast fade.
    /// The server action itself runs immediately; only visual feedback waits.
    @MainActor
    private func presentFeedback(_ message: String) {
        feedbackDelayTask?.cancel()
        feedback = nil
        feedbackDelayTask = Task { @MainActor in
            do {
                try await Task.sleep(for: .milliseconds(TVActionFeedbackPolicy.delayMilliseconds))
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            withAnimation(.easeInOut(duration: reduceMotion ? 0.12 : 0.23)) {
                feedback = message
            }
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
        feedbackDelayTask?.cancel()
        feedback = nil
        Task { @MainActor in
            defer { working = false }
            do {
                let text = try await action()
                presentFeedback(text)
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
        isWatchLaterEntry: Bool = false,
        focus: FocusState<String?>.Binding? = nil,
        focusID: String? = nil
    ) -> some View {
        modifier(TVVideoActionModifier(
            api: api, video: video, onChanged: onChanged,
            onRemoveFromPlaylist: onRemoveFromPlaylist,
            isWatchLaterEntry: isWatchLaterEntry,
            externalFocus: focus, focusID: focusID
        ))
    }
}

struct TVPlaylistPickerView: View {
    let api: TypeTypeAPI
    let video: VideoItem
    let onSaved: (String) -> Void
    let onCancel: () -> Void
    @FocusState private var cancelFocused: Bool

    @ObservedObject private var playlistMembership = TVPlaylistMembership.shared
    @State private var playlists: [TVPlaylistDTO] = []
    @State private var loading = true
    @State private var pending = false
    @State private var error: String?
    @State private var newName = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack {
                Text("action.choosePlaylist").font(.title.bold())
                Spacer()
                Button("common.cancel", action: onCancel)
                    .buttonStyle(.bordered)
                    .focused($cancelFocused)
                    .disabled(pending)
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
                            let included = playlistMembership.contains(
                                video.url, in: playlist.id
                            )
                            Button {
                                Task { await toggle(playlist) }
                            } label: {
                                HStack(spacing: 12) {
                                    Label(playlist.name, systemImage:
                                          included ? "checkmark.circle.fill" : "list.bullet")
                                    Spacer()
                                    if included {
                                        Text("playlist.alreadyAdded")
                                            .font(.caption.bold())
                                    } else {
                                        Text("\(playlist.count)")
                                            .foregroundStyle(TTTheme.muted)
                                    }
                                }
                            }
                            .buttonStyle(.bordered)
                            .tint(included
                                  ? Color(red: 0.34, green: 0.24, blue: 0.72)
                                  : TTTheme.accent)
                            .background(
                                included ? Color.purple.opacity(0.25) : .clear,
                                in: RoundedRectangle(cornerRadius: 10)
                            )
                            .accessibilityIdentifier("playlist-choice-\(playlist.id)")
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
                HStack(spacing: 12) {
                    Text(error).font(.callout).foregroundStyle(.orange)
                    Button("common.retry") { Task { await reloadMembership() } }
                        .buttonStyle(.bordered)
                }
            }
        }
        .padding(50)
        .frame(width: 850, height: 820)
        .tvGlassPopup(transparent: true)
        .onAppear { cancelFocused = true }
        .task { await load() }
    }

    @MainActor
    private func load() async {
        loading = true
        defer { loading = false }
        await playlistMembership.ensureLoaded(api: api)
        playlists = playlistMembership.playlists
        error = playlistMembership.error
    }

    @MainActor
    private func reloadMembership() async {
        loading = true
        defer { loading = false }
        await playlistMembership.retry(api: api)
        playlists = playlistMembership.playlists
        error = playlistMembership.error
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
            playlistMembership.markAdded(videoURL: video.url, playlist: playlist, api: api)
            onSaved(TVL10n.value("action.addedPlaylist"))
        } catch { self.error = error.localizedDescription }
    }

    @MainActor
    private func toggle(_ playlist: TVPlaylistDTO) async {
        guard !pending else { return }
        pending = true
        defer { pending = false }
        do {
            if playlistMembership.contains(video.url, in: playlist.id) {
                try await api.removeFromPlaylist(
                    playlist.id,
                    videoURL: playlistMembership.storedURL(video.url, in: playlist.id)
                )
                playlistMembership.markRemoved(
                    videoURL: video.url, playlistID: playlist.id, api: api
                )
                onSaved(TVL10n.value("action.removedPlaylist"))
            } else {
                try await api.addToPlaylist(playlist.id, video: video)
                playlistMembership.markAdded(
                    videoURL: video.url, playlist: playlist, api: api
                )
                onSaved(TVL10n.value("action.addedPlaylist"))
            }
        } catch {
            self.error = error.localizedDescription
        }
    }
}

/// Return focus after the pushed video details are removed from the stack.
/// A synchronous assignment during dismissal is overwritten by tvOS.
enum TVVideoFocusReturn {
    static func restore(_ binding: FocusState<String?>.Binding, id: String,
                        scroll: ScrollViewProxy? = nil) {
        Task { @MainActor in
            // Wait for the detail pop, then materialize the offscreen card
            // before asking tvOS to give it focus.
            try? await Task.sleep(nanoseconds: 180_000_000)
            guard !Task.isCancelled else { return }
            if let scroll {
                withAnimation(.easeOut(duration: 0.18)) {
                    scroll.scrollTo(id, anchor: .center)
                }
                try? await Task.sleep(nanoseconds: 140_000_000)
                guard !Task.isCancelled else { return }
            } else {
                await Task.yield()
            }
            binding.wrappedValue = id
        }
    }
}



// MARK: - Home performance experiment: stable focus with on-demand actions

/// The old approach conditionally inserted/removed a heavy modifier on the
/// focused NavigationLink. UIKit dropped that focus owner, breaking the Left
/// transition and the card zoom. This model lives ONCE for the whole Home
/// screen; individual links keep a stable, observer-free contextMenu modifier.
/// Only removing videos/channels from the displayed feed needs a full
/// recommendations fetch. All other Home menu actions update the shared
/// progress, watch-later or playlist state directly.
enum TVHomeMenuReloadPolicy {
    case watched
    case watchLater
    case playlist
    case block

    var requiresFeedReload: Bool { self == .block }
}

/// Each lightweight Home card publishes only a layout anchor. There is
/// still exactly one presentation/observer for the entire grid. Unlike
/// attaching a toast to every card, preferences do not add card state,
/// tasks or a focus-affecting wrapper to NavigationLink.
struct TVHomeCardToastAnchorKey: PreferenceKey {
    static var defaultValue: [String: Anchor<CGRect>] { [:] }

    static func reduce(value: inout [String: Anchor<CGRect>],
                       nextValue: () -> [String: Anchor<CGRect>]) {
        value.merge(nextValue(), uniquingKeysWith: { _, latest in latest })
    }
}

struct TVHomeCardToast: Equatable {
    let message: String
    let focusID: String
    let id = UUID()
}

enum TVHomeCardToastPosition {
    static func topLeft(of frame: CGRect) -> CGPoint {
        CGPoint(x: frame.minX + 7, y: frame.minY + 7)
    }
}

@MainActor
final class TVHomeMenuCoordinator: ObservableObject {
    enum BlockTarget { case video, channel }

    struct BlockRequest {
        let target: BlockTarget
        let api: TypeTypeAPI
        let video: VideoItem
        let focusID: String
        let onChanged: () -> Void
    }

    @Published var blockRequest: BlockRequest?
    @Published var errorMessage: String?
    @Published var feedback: TVHomeCardToast?
    @Published private(set) var focusRestoreRequest = 0
    private(set) var focusRestoreTarget: String?
    private var lastFocusID: String?
    private var working = false
    private var feedbackTask: Task<Void, Never>?

    func restoreFocus(_ id: String) {
        Task { @MainActor in
            await Task.yield()
            focusRestoreTarget = id
            focusRestoreRequest &+= 1
        }
    }

    private func showFeedback(_ message: String, on focusID: String) {
        feedbackTask?.cancel()
        // Animate only the toast state. Never apply a feedback animation
        // to the parent ScrollView: that can animate the entire Home grid.
        withAnimation(.easeInOut(duration: 0.23)) {
            feedback = TVHomeCardToast(message: message, focusID: focusID)
        }
        feedbackTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(2.4))
            guard !Task.isCancelled else { return }
            withAnimation(.easeInOut(duration: 0.23)) {
                feedback = nil
            }
        }
    }

    private func refreshAfterFeedback(_ onChanged: @escaping () -> Void) {
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(1_200))
            guard !Task.isCancelled else { return }
            onChanged()
        }
    }

    private func run(focusID: String, kind: TVHomeMenuReloadPolicy,
                     onChanged: @escaping () -> Void,
                     action: @escaping () async throws -> String) {
        guard !working else { return }
        lastFocusID = focusID
        working = true
        Task { @MainActor in
            defer { working = false }
            do {
                let result = try await action()
                showFeedback(result, on: focusID)
                if kind.requiresFeedReload { refreshAfterFeedback(onChanged) }
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    func markWatched(api: TypeTypeAPI, video: VideoItem, focusID: String,
                     onChanged: @escaping () -> Void) {
        run(focusID: focusID, kind: .watched, onChanged: onChanged) {
            var target = video
            if (target.duration ?? 0) <= 0 {
                let details = await TVStreamMetadataCache.shared.details(for: video, api: api)
                target = TVVideoMetadata.merged(video, stream: details)
            }
            guard let duration = target.duration, duration > 0,
                  duration <= Int64.max / 1_000 else {
                throw TypeTypeError.missingVideoDuration
            }
            let currentPosition = TVLocalProgress.shared.position(for: video.url) ??
                video.watchPositionMs
            let mark = !TVWatchedState.isWatched(target, positionMs: currentPosition)
            try await api.setWatched(mark, video: target)
            TVLocalProgress.shared.record(
                video.url, positionMs: mark ? Int64(duration) * 1_000 : 0
            )
            return TVL10n.value(mark ? "action.markWatchedSuccess"
                                    : "action.markUnwatchedSuccess")
        }
    }

    func updateWatchLater(api: TypeTypeAPI, video: VideoItem,
                          focusID: String, enabled: Bool,
                          onChanged: @escaping () -> Void) {
        run(focusID: focusID, kind: .watchLater, onChanged: onChanged) {
            try await api.setWatchLater(video: video, enabled: enabled)
            TVWatchLaterMembership.shared.mark(video.url, present: enabled, api: api)
            return TVL10n.value(enabled ? "action.savedWatchLater"
                                        : "action.removedWatchLater")
        }
    }

    func presentPlaylist(api: TypeTypeAPI, video: VideoItem,
                         focusID: String) {
        lastFocusID = focusID
        TVPlaylistPopupPresenter.shared.present(
            api: api, video: video,
            onSaved: { result in
                // TVPlaylistPickerView updates the shared membership state.
                // Do not discard/re-fetch the recommendations grid.
                self.showFeedback(result, on: focusID)
            },
            onDismiss: { self.restoreFocus(focusID) }
        )
    }

    func requestBlock(_ target: BlockTarget, api: TypeTypeAPI,
                      video: VideoItem, focusID: String,
                      onChanged: @escaping () -> Void) {
        lastFocusID = focusID
        guard target != .channel || video.uploaderUrl?.isEmpty == false else {
            errorMessage = TVL10n.value("action.channelUnavailable")
            return
        }
        blockRequest = BlockRequest(target: target, api: api, video: video,
                                    focusID: focusID, onChanged: onChanged)
    }

    func dismissBlock() {
        guard let request = blockRequest else { return }
        blockRequest = nil
        restoreFocus(request.focusID)
    }

    func confirmBlock() {
        guard let request = blockRequest else { return }
        blockRequest = nil
        run(focusID: request.focusID, kind: .block,
            onChanged: request.onChanged) {
            switch request.target {
            case .video:
                try await request.api.blockVideo(request.video)
                TVBlockedNameCache.remember(title: request.video.title,
                                            url: request.video.url, api: request.api)
            case .channel:
                try await request.api.blockChannel(request.video)
            }
            return TVL10n.value("action.blocked")
        }
        restoreFocus(request.focusID)
    }

    func dismissError() {
        errorMessage = nil
        if let lastFocusID { restoreFocus(lastFocusID) }
    }
}

/// Stable per-card modifier: the focused NavigationLink is never replaced.
/// Unlike TVVideoActionModifier, this has no @ObservedObject, @State, .task,
/// dialog, toast, or animation for each thumbnail.
struct TVHomeLightweightVideoActions: ViewModifier {
    let api: TypeTypeAPI
    let video: VideoItem
    let model: TVHomeMenuCoordinator
    let focus: FocusState<String?>.Binding
    let focusID: String
    let onChanged: () -> Void

    func body(content: Content) -> some View {
        content
            .focused(focus, equals: focusID)
            .contextMenu {
                // Read the current shared state only when the menu is built.
                // Do not subscribe every Home card to progress/membership.
                let position = TVLocalProgress.shared.position(for: video.url) ??
                    video.watchPositionMs
                let watched = TVWatchedState.isWatched(video, positionMs: position)
                let watchLaterStatus = TVWatchLaterMembership.shared.menuStatus(
                    for: video.url, api: api
                )

                if let position, position > 0 {
                    Button {} label: {
                        Label(
                            TVL10n.formatted("action.playedUntil",
                                           TTTheme.time(Int(position / 1_000))),
                            systemImage: "clock.arrow.circlepath"
                        )
                    }
                    .disabled(true)
                }
                if video.isLive != true &&
                   ((video.duration ?? 0) > 0 || video.isShort) {
                    Button {
                        model.markWatched(api: api, video: video,
                                          focusID: focusID, onChanged: onChanged)
                    } label: {
                        Label(
                            watched ? "action.markUnwatched" : "action.markWatched",
                            systemImage: watched
                                ? "arrow.uturn.backward.circle" : "checkmark.circle"
                        )
                    }
                }
                if watchLaterStatus == .saved {
                    Button(role: .destructive) {
                        model.updateWatchLater(api: api, video: video,
                            focusID: focusID, enabled: false, onChanged: onChanged)
                    } label: {
                        Label("action.removeWatchLater", systemImage: "bookmark.slash")
                    }
                } else if watchLaterStatus == .notSaved {
                    Button {
                        model.updateWatchLater(api: api, video: video,
                            focusID: focusID, enabled: true, onChanged: onChanged)
                    } label: {
                        Label("action.watchLater", systemImage: "bookmark")
                    }
                } else if watchLaterStatus == .loading {
                    Button {} label: {
                        Label("action.watchLaterLoading", systemImage: "clock")
                    }
                    .disabled(true)
                } else {
                    Button {
                        Task { await TVWatchLaterMembership.shared.retryLoading(api: api) }
                    } label: {
                        Label("action.watchLaterRetry", systemImage: "arrow.clockwise")
                    }
                }
                Button {
                    model.presentPlaylist(api: api, video: video,
                        focusID: focusID)
                } label: {
                    Label("action.addPlaylist", systemImage: "text.badge.plus")
                }
                Button(role: .destructive) {
                    model.requestBlock(.video, api: api, video: video,
                                       focusID: focusID, onChanged: onChanged)
                } label: {
                    Label("action.blockVideo", systemImage: "hand.raised")
                }
                Button(role: .destructive) {
                    model.requestBlock(.channel, api: api, video: video,
                                       focusID: focusID, onChanged: onChanged)
                } label: {
                    Label("action.blockChannel",
                          systemImage: "person.crop.circle.badge.xmark")
                }
            }
            .anchorPreference(key: TVHomeCardToastAnchorKey.self, value: .bounds) {
                [focusID: $0]
            }
    }
}

/// Exactly one dialog/toast host, instead of one per visible Home thumbnail.
struct TVHomeMenuPresentation: ViewModifier {
    @ObservedObject var model: TVHomeMenuCoordinator
    // Only a single rect is cached for the rare case that a successful
    // block action removes the original card before the toast has faded.
    @State private var lastToastLocation: (id: String, frame: CGRect)?

    func body(content: Content) -> some View {
        content
            .overlayPreferenceValue(TVHomeCardToastAnchorKey.self) { cardAnchors in
                GeometryReader { geometry in
                    if let toast = model.feedback {
                        let liveFrame = cardAnchors[toast.focusID].map {
                            geometry[$0]
                        }
                        let cardFrame = liveFrame ??
                            (lastToastLocation?.id == toast.focusID
                             ? lastToastLocation?.frame : nil)
                        if let cardFrame {
                            let position = TVHomeCardToastPosition.topLeft(of: cardFrame)
                            Label(toast.message, systemImage: "checkmark.circle.fill")
                                .font(.callout.bold())
                                .foregroundStyle(.white)
                                .padding(10)
                                .background(.black.opacity(0.88),
                                            in: RoundedRectangle(cornerRadius: 12))
                                .offset(x: position.x, y: position.y)
                                .onAppear {
                                    lastToastLocation = (toast.focusID, cardFrame)
                                }
                                .onChange(of: cardFrame) { _, updated in
                                    lastToastLocation = (toast.focusID, updated)
                                }
                                .transition(.opacity)
                        }
                    }
                }
                .allowsHitTesting(false)
            }
            .confirmationDialog(
                TVL10n.formatted(
                    "action.confirmBlockNamed",
                    model.blockRequest?.target == .channel
                        ? (model.blockRequest?.video.uploaderName ??
                           TVL10n.value("action.channelUnavailable"))
                        : (model.blockRequest?.video.title ?? "")
                ),
                isPresented: Binding(
                    get: { model.blockRequest != nil },
                    set: { if !$0 { model.dismissBlock() } }
                ),
                titleVisibility: .visible
            ) {
                if let request = model.blockRequest {
                    Button(TVL10n.value(request.target == .video
                        ? "action.blockVideo" : "action.blockChannel"),
                        role: .destructive) {
                        model.confirmBlock()
                    }
                }
                Button("common.cancel", role: .cancel) {
                    model.dismissBlock()
                }
            }
            .alert(
                TVL10n.value("action.failed"),
                isPresented: Binding(
                    get: { model.errorMessage != nil },
                    set: { if !$0 { model.dismissError() } }
                )
            ) {
                Button("common.ok") { model.dismissError() }
            } message: {
                Text(model.errorMessage ?? "")
            }
    }
}
