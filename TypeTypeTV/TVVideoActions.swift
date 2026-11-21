import SwiftUI

/// Shared account playlist picker used by lightweight video menus.
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
            TVVideoMutationCenter.shared.record(
                api: api, video: video, kind: .playlist(id: playlist.id, added: true)
            )
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
                TVVideoMutationCenter.shared.record(
                    api: api, video: video,
                    kind: .playlist(id: playlist.id, added: false)
                )
                onSaved(TVL10n.value("action.removedPlaylist"))
            } else {
                try await api.addToPlaylist(playlist.id, video: video)
                playlistMembership.markAdded(
                    videoURL: video.url, playlist: playlist, api: api
                )
                TVVideoMutationCenter.shared.record(
                    api: api, video: video, kind: .playlist(id: playlist.id, added: true)
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
                        scroll: ScrollViewProxy? = nil,
                        scrollTarget: String? = nil,
                        nestedScroll: ScrollViewProxy? = nil) {
        Task { @MainActor in
            // Wait for the detail pop, then materialize the offscreen card
            // before asking tvOS to give it focus.
            try? await Task.sleep(nanoseconds: 180_000_000)
            guard !Task.isCancelled else { return }
            if let scroll {
                withAnimation(.easeOut(duration: 0.18)) {
                    // For a resume tile, reveal the outer shelf AND the
                    // original horizontal card. The outer proxy alone cannot
                    // locate IDs inside the nested LazyHStack.
                    scroll.scrollTo(scrollTarget ?? id, anchor: .center)
                    nestedScroll?.scrollTo(id, anchor: .center)
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



// MARK: - Home lightweight context actions

/// A single stable action host per video grid (Home, subscriptions, search,
/// library); the lightweight NavigationLinks never gain per-card observable
/// state, toast tasks or dialog presentation modifiers. Only destructive
/// feed changes require a reload; membership/progress update shared caches.
enum TVHomeMenuReloadPolicy {
    case watched
    case watchLater
    case watchLaterRemoval
    case playlist
    case playlistRemoval
    case block

    // Successful mutations are handled by the screen-level change
    // journal; only the affected cached rows are removed. No timed GET.
    var requiresFeedReload: Bool { false }
}

/// Each lightweight Home card publishes one layout anchor, without
/// attaching state/observers/animations to NavigationLink. Prefer ordered,
/// append-only storage: PreferenceKey.reduce is called thousands of times
/// while lazy grids materialize and hashing/merging dictionaries for each
/// partial subtree is unnecessary. Resolve the single desired focusID only
/// when a toast actually needs to appear.
///
/// Duplicate IDs retain the previous dictionary's "latest wins" semantics:
/// lookup deliberately searches the array from the end.
struct TVHomeCardToastAnchor {
    let focusID: String
    let anchor: Anchor<CGRect>
}

struct TVHomeCardToastAnchorKey: PreferenceKey {
    static var defaultValue: [TVHomeCardToastAnchor] { [] }

    static func reduce(value: inout [TVHomeCardToastAnchor],
                       nextValue: () -> [TVHomeCardToastAnchor]) {
        value.append(contentsOf: nextValue())
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

    /// The source card must still overlap the visible Home viewport.
    /// Merely having a retained LazyVGrid anchor does not make it visible.
    static func isVisible(_ frame: CGRect, in viewport: CGRect) -> Bool {
        !frame.isEmpty && !viewport.isEmpty && frame.intersects(viewport)
    }

    /// Keep the clip's top edge exactly on the source card's top edge.
    /// The reveal can extend beyond the card's right edge so the text keeps
    /// its natural single-line width, as before the animation change.
    static func revealRect(for card: CGRect, in viewport: CGRect) -> CGRect {
        CGRect(x: card.minX, y: card.minY,
               width: max(0, viewport.maxX - card.minX), height: 76)
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
    // On-demand shorts metadata belongs to the single shared menu host.
    // It must survive closing/reopening the context menu, but must NOT be
    // @Published or stored on each VideoCard (which would rerender the grid).
    private var knownDurations: [String: Int] = [:]
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

    /// Scrolling the source tile fully outside the viewport ends its toast.
    /// Never re-show the same confirmation if the user scrolls back quickly.
    func dismissFeedback(matching id: UUID) {
        guard feedback?.id == id else { return }
        feedbackTask?.cancel()
        feedbackTask = nil
        withAnimation(.easeOut(duration: 0.16)) {
            feedback = nil
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

    func videoWithKnownDuration(_ video: VideoItem) -> VideoItem {
        guard (video.duration ?? 0) <= 0,
              let duration = knownDurations[video.url] else { return video }
        var result = video
        result.duration = duration
        return result
    }

    func rememberKnownDuration(_ duration: Int, for url: String) {
        guard duration > 0 else { return }
        if knownDurations.count >= 128, knownDurations[url] == nil,
           let oldKey = knownDurations.keys.first {
            knownDurations.removeValue(forKey: oldKey)
        }
        knownDurations[url] = duration
    }

    func markWatched(api: TypeTypeAPI, video: VideoItem, focusID: String,
                     onChanged: @escaping () -> Void) {
        run(focusID: focusID, kind: .watched, onChanged: onChanged) {
            var target = self.videoWithKnownDuration(video)
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
            // This is mutated only after a menu action, never when focus
            // moves. A later menu opening now sees the correct toggle even
            // if the original shorts/history row omitted duration.
            self.rememberKnownDuration(duration, for: video.url)
            TVLocalProgress.shared.record(
                video.url, positionMs: mark ? Int64(duration) * 1_000 : 0
            )
            return TVL10n.value(mark ? "action.markWatchedSuccess"
                                    : "action.markUnwatchedSuccess")
        }
    }

    func removePlaylistEntry(focusID: String,
                             onChanged: @escaping () -> Void,
                             action: @escaping () async throws -> Void) {
        run(focusID: focusID, kind: .playlistRemoval, onChanged: onChanged) {
            try await action()
            return TVL10n.value("action.removedPlaylist")
        }
    }

    func updateWatchLater(api: TypeTypeAPI, video: VideoItem,
                          focusID: String, enabled: Bool,
                          reloadOnRemoval: Bool = false,
                          onChanged: @escaping () -> Void) {
        let kind: TVHomeMenuReloadPolicy =
            (!enabled && reloadOnRemoval) ? .watchLaterRemoval : .watchLater
        run(focusID: focusID, kind: kind, onChanged: onChanged) {
            try await api.setWatchLater(video: video, enabled: enabled)
            TVWatchLaterMembership.shared.mark(video.url, present: enabled, api: api)
            TVVideoMutationCenter.shared.record(
                api: api, video: video, kind: .watchLater(added: enabled)
            )
            return TVL10n.value(enabled ? "action.savedWatchLater"
                                        : "action.removedWatchLater")
        }
    }

    func presentPlaylist(api: TypeTypeAPI, video: VideoItem,
                         focusID: String, onChanged: (() -> Void)? = nil,
                         reloadOnRemoval: Bool = false) {
        lastFocusID = focusID
        TVPlaylistPopupPresenter.shared.present(
            api: api, video: video,
            onSaved: { result in
                // Membership updates are shared. Only a library screen
                // showing the affected playlist needs its own list reloaded.
                self.showFeedback(result, on: focusID)
                // The picker itself records the precise playlist ID.
                // Its containing library screen removes only that row.
                _ = onChanged
                _ = reloadOnRemoval
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
                TVVideoMutationCenter.shared.record(
                    api: request.api, video: request.video, kind: .videoBlocked
                )
            case .channel:
                try await request.api.blockChannel(request.video)
                TVVideoMutationCenter.shared.record(
                    api: request.api, video: request.video, kind: .channelBlocked
                )
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
/// Unlike the retired per-card action state, this has no @ObservedObject, @State, .task,
/// dialog, toast, or animation for each thumbnail.
/// Menu-only state snapshot. The home card body deliberately has no
/// subscription to watch-later/progress: it remains unchanged on focus-only
/// moves, while the menu can always show current "remove"/"unwatched"
/// actions and the current playback position.
struct TVHomeCardMenuState: Equatable {
    let positionMs: Int64?
    let watched: Bool
    let watchLater: TVWatchLaterMenuStatus

    init(video: VideoItem, positionMs: Int64?,
         watchLater: TVWatchLaterMenuStatus) {
        self.positionMs = positionMs
        self.watched = TVWatchedState.isWatched(video, positionMs: positionMs)
        self.watchLater = watchLater
    }
}

/// SwiftUI can cache a .contextMenu builder when its Home tile sits behind
/// EquatableView. A menu-scoped ObservedObject makes that *menu* reactive
/// without re-subscribing or refreshing every tile in the lazy grid.
/// Both dependencies are existing shared in-memory caches: no GET here.
private struct TVHomeCardMenuContents: View {
    let api: TypeTypeAPI
    let video: VideoItem
    let model: TVHomeMenuCoordinator
    let focusID: String
    let onChanged: () -> Void
    var isWatchLaterEntry = false
    var onRemoveFromPlaylist: (() async throws -> Void)? = nil
    var reloadPlaylistOnRemoval = false

    @ObservedObject private var localProgress = TVLocalProgress.shared
    @ObservedObject private var watchLaterMembership = TVWatchLaterMembership.shared

    @ViewBuilder
    var body: some View {
                // This menu body, NOT the permanent Home tile, observes
                // shared account/progress state. Values refresh whenever a
                // long-press presents this menu or a library action changes
                // the snapshot. No extra work during focus-only navigation.
                let state = TVHomeCardMenuState(
                    video: model.videoWithKnownDuration(video),
                    positionMs: localProgress.position(for: video.url) ??
                        video.watchPositionMs,
                    watchLater: isWatchLaterEntry ? .saved :
                        watchLaterMembership.menuStatus(
                            for: video.url, api: api
                        )
                )
                let position = state.positionMs
                let watched = state.watched
                let watchLaterStatus = state.watchLater

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
                            focusID: focusID, enabled: false,
                            reloadOnRemoval: isWatchLaterEntry,
                            onChanged: onChanged)
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
                        focusID: focusID, onChanged: onChanged,
                        reloadOnRemoval: reloadPlaylistOnRemoval)
                } label: {
                    Label("action.addPlaylist", systemImage: "text.badge.plus")
                }
                if let onRemoveFromPlaylist {
                    Button(role: .destructive) {
                        model.removePlaylistEntry(
                            focusID: focusID, onChanged: onChanged,
                            action: onRemoveFromPlaylist
                        )
                    } label: {
                        Label("action.removePlaylistVideo", systemImage: "minus.circle")
                    }
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
}

struct TVHomeLightweightVideoActions: ViewModifier {
    let api: TypeTypeAPI
    let video: VideoItem
    let model: TVHomeMenuCoordinator
    let focus: FocusState<String?>.Binding
    let focusID: String
    let onChanged: () -> Void
    var isWatchLaterEntry = false
    var onRemoveFromPlaylist: (() async throws -> Void)? = nil
    var reloadPlaylistOnRemoval = false

    func body(content: Content) -> some View {
        content
            .focused(focus, equals: focusID)
            .contextMenu {
                TVHomeCardMenuContents(
                    api: api, video: video, model: model,
                    focusID: focusID, onChanged: onChanged,
                    isWatchLaterEntry: isWatchLaterEntry,
                    onRemoveFromPlaylist: onRemoveFromPlaylist,
                    reloadPlaylistOnRemoval: reloadPlaylistOnRemoval
                )
            }
            .anchorPreference(key: TVHomeCardToastAnchorKey.self, value: .bounds) {
                [TVHomeCardToastAnchor(focusID: focusID, anchor: $0)]
            }
    }
}

/// Exactly one dialog/toast host, instead of one per visible Home thumbnail.
struct TVHomeMenuPresentation: ViewModifier {
    @ObservedObject var model: TVHomeMenuCoordinator
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    // The clip exists only during a toast and its short exit transition.
    // No GeometryReader or clipping surface remains in the idle Home grid.
    @State private var toastAnchorID: String?

    func body(content: Content) -> some View {
        content
            .overlayPreferenceValue(TVHomeCardToastAnchorKey.self) { cardAnchors in
                if model.feedback != nil || toastAnchorID != nil {
                GeometryReader { geometry in
                    let toast = model.feedback
                    let sourceID = toast?.focusID ?? toastAnchorID
                    // Only scan when a toast is visible or sliding out;
                    // the normal Home does not perform per-card dictionary
                    // lookups or hashing during directional focus movement.
                    let cardFrame = sourceID.flatMap { id in
                        cardAnchors.last(where: { $0.focusID == id })?.anchor
                    }.map { geometry[$0] }
                    let viewport = CGRect(origin: .zero, size: geometry.size)
                    let visible = cardFrame.map {
                        TVHomeCardToastPosition.isVisible($0, in: viewport)
                    } ?? false

                    ZStack(alignment: .topLeading) {
                        Color.clear
                            .onChange(of: visible) { wasVisible, isVisible in
                                guard wasVisible && !isVisible, let toast else { return }
                                model.dismissFeedback(matching: toast.id)
                            }

                        if let cardFrame, visible {
                            // This one, fixed clipping region has its top
                            // EXACTLY at the card's top. The toast travels
                            // a full own-height behind that edge, rather
                            // than suddenly appearing 24 pt above it.
                            let clip = TVHomeCardToastPosition.revealRect(
                                for: cardFrame, in: viewport
                            )
                            ZStack(alignment: .topLeading) {
                                if let toast {
                                    Label(toast.message,
                                          systemImage: "checkmark.circle.fill")
                                        .font(.callout.bold())
                                        .foregroundStyle(.white)
                                        .padding(10)
                                        .glassEffect(
                                            .regular,
                                            in: RoundedRectangle(cornerRadius: 12)
                                        )
                                        // Natural text width: not restricted
                                        // to the original tile's width.
                                        .fixedSize(horizontal: true, vertical: false)
                                        .padding(.leading, 7)
                                        .padding(.top, 7)
                                        .onDisappear {
                                            model.dismissFeedback(matching: toast.id)
                                        }
                                        .transition(reduceMotion
                                            ? .identity : .move(edge: .top))
                                }
                            }
                            .frame(width: clip.width, height: clip.height,
                                   alignment: .topLeading)
                            .clipped()
                            .offset(x: clip.minX, y: clip.minY)
                        }
                    }
                }
                .allowsHitTesting(false)
                }
            }
            // The single task is keyed only to a new/dismissed toast.
            // It never runs on focus movement or normal thumbnail layout.
            .task(id: model.feedback?.id) {
                if let toast = model.feedback {
                    toastAnchorID = toast.focusID
                } else if toastAnchorID != nil {
                    // Keep the clipping parent for the 0.23s slide-out,
                    // then remove it entirely from the idle render tree.
                    try? await Task.sleep(for: .milliseconds(300))
                    guard !Task.isCancelled, model.feedback == nil else { return }
                    toastAnchorID = nil
                }
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
