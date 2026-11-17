import SwiftUI

struct VideoDetailView: View {
    let api: TypeTypeAPI
    let video: VideoItem
    var playbackQueue: [VideoItem]? = nil
    var onReturnToList: (() -> Void)? = nil
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var heroVisible = false
    @State private var favorite = false
    @State private var watchLater = false
    @State private var activityLoaded = false
    @State private var activitySaving = false
    @State private var activityError: String?
    @State private var streamMetadata: StreamInfo?
    @State private var channelArtwork: TVChannelArtwork?
    @ObservedObject private var contentPreferences = TVContentPreferences.shared
    @State private var savedPositionMs: Int64?
    @State private var progressSaving = false
    @State private var progressError: String?
    @ObservedObject private var localProgress = TVLocalProgress.shared

    private enum DetailFocus: Hashable {
        case play, channel, markWatched, playlist, descriptionEntry, descriptionBody, commentsTab
    }

    private enum DetailPane {
        case description, comments
    }

    @State private var selectedPane: DetailPane = .description
    @FocusState private var focusedDetail: DetailFocus?
    @State private var initiallyFocusedVideoURL: String?
    @State private var descriptionScrollCommand = 0
    @State private var fullDescriptionPresented = false

    private var youtube: Bool { VideoAddress.youtubeID(video.url) != nil }

    private var channelName: String? {
        let fromVideo = video.uploaderName?.trimmingCharacters(in: .whitespacesAndNewlines)
        let fromStream = streamMetadata?.uploaderName?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return [fromVideo, fromStream].compactMap { $0 }.first { !$0.isEmpty }
    }

    private var channelURL: String? {
        TVVideoMetadata.channelURL(for: video, stream: streamMetadata)
    }

    private var descriptionText: String? {
        #if DEBUG
        if api.origin.host == "preview.invalid" {
            return Array(repeating:
                "Eine ausführliche Testbeschreibung für die Siri Remote. " +
                "Dieser Text bleibt ein einziger Block und kann in beide Richtungen gescrollt werden.",
                count: 38).joined(separator: "\n\n")
        }
        #endif
        return streamMetadata?.description
    }
    private var detailedVideo: VideoItem {
        TVVideoMetadata.merged(video, stream: streamMetadata)
    }
    private var playbackPosition: Int64 {
        let saved = max(0, localProgress.position(for: video.url) ??
            savedPositionMs ?? video.watchPositionMs ?? 0)
        // A stale server progress record can exceed the video's duration
        // (e.g. the screenshot showed 10:20 / 3:33). Never present an
        // impossible position even if its completed flag is correct.
        guard let duration = detailedVideo.duration, duration > 0 else { return saved }
        return min(saved, Int64(duration) * 1_000)
    }
    private var watchedFraction: Double {
        guard let duration = detailedVideo.duration, duration > 0 else { return 0 }
        return max(0, min(1, Double(playbackPosition) / (Double(duration) * 1_000)))
    }
    private var isMarkedWatched: Bool {
        TVWatchedState.isWatched(detailedVideo, positionMs:
            localProgress.position(for: video.url) ?? savedPositionMs ?? video.watchPositionMs)
    }


    var body: some View {
        ScrollViewReader { page in
            ScrollView {
                // The hero sizes itself to the complete title and action rows.
                // A fixed GeometryReader height used to clip buttons on long
                // titles while the progress section overlapped them.
                VStack(alignment: .leading, spacing: 22) {
                        Text(TVL10n.value(video.isLive == true ? "video.liveBadge" : "video.badge"))
                            .font(.subheadline.bold()).tracking(2.5)
                            .foregroundStyle(TTTheme.accent)
                        Text(video.title)
                            .font(.system(size: 53, weight: .bold))
                            .frame(maxWidth: 830, alignment: .leading)
                            .fixedSize(horizontal: false, vertical: true)
                        if let channel = channelName {
                            if let channelURL {
                                NavigationLink {
                                    TVSubscriptionsView(
                                        api: api,
                                        directChannelURL: channelURL,
                                        directChannelName: channel
                                    )
                                } label: {
                                    HStack(spacing: 10) {
                                        TVChannelAvatar(
                                            api: api, imageURL: channelArtwork?.avatarURL,
                                            size: 38
                                        )
                                        Text(channel)
                                        Image(systemName: "chevron.right")
                                            .font(.caption.bold())
                                    }
                                }
                                .buttonStyle(.bordered)
                                .tint(TTTheme.muted)
                                .accessibilityIdentifier("video-open-channel")
                                .focused($focusedDetail, equals: .channel)
                            } else {
                                HStack(spacing: 10) {
                                    TVChannelAvatar(
                                        api: api, imageURL: channelArtwork?.avatarURL,
                                        size: 38
                                    )
                                    Text(channel)
                                }
                                .font(.title3)
                                .foregroundStyle(.white.opacity(0.8))
                            }
                        }
                        if let metadata = TVVideoMetadata.subtitle(for: detailedVideo) {
                            Text(metadata)
                                .font(.title3)
                                .foregroundStyle(.white.opacity(0.84))
                        }
                        HStack(spacing: 22) {
                            if video.isLive == true {
                                Label("video.liveStream", systemImage: "dot.radiowaves.left.and.right")
                                    .foregroundStyle(TTTheme.accent)
                            } else if let seconds = detailedVideo.duration, seconds > 0 {
                                Label(TTTheme.time(seconds), systemImage: "clock")
                            }
                            if detailedVideo.isShort && video.isLive != true {
                                Label("video.shortsBadge", systemImage: "play.rectangle.fill")
                            }
                            Text(youtube && video.isLive != true
                                ? "YouTube · SABR"
                                : TVL10n.value("video.providerNative"))
                        }
                        .font(.callout)
                        .foregroundStyle(.white.opacity(0.72))
                        HStack(alignment: .top, spacing: 36) {
                            VStack(alignment: .leading, spacing: 18) {
                                HStack(spacing: 18) {
                                    NavigationLink {
                                        if let playbackQueue,
                                           let position = playbackQueue.firstIndex(where: {
                                               $0.url == video.url
                                           }) {
                                            TVPlaylistPlaybackView(
                                                api: api, videos: playbackQueue,
                                                startIndex: position
                                            )
                                        } else {
                                            // The detail screen has already enriched views/date
                                            // via the existing metadata request; forward it to OSD.
                                            PlaybackView(api: api, video: detailedVideo)
                                        }
                                    } label: {
                                        Label {
                                            if video.isLive == true {
                                                Text("video.viewLive")
                                            } else {
                                                Text("video.play")
                                            }
                                        } icon: {
                                            Image(systemName: "play.fill")
                                        }
                                    }
                                    .buttonStyle(.borderedProminent)
                                    .tint(TTTheme.accent)
                                    .focused($focusedDetail, equals: .play)
                                    .accessibilityIdentifier("video-play")
                                    .onMoveCommand { direction in
                                        guard direction == .down else { return }
                                        if video.isLive != true,
                                           ((detailedVideo.duration ?? 0) > 0 || detailedVideo.isShort) {
                                            focusedDetail = .markWatched
                                        } else {
                                            // A live stream has no watched action.
                                            focusedDetail = .playlist
                                        }
                                    }

                                    Button { returnToList() } label: {
                                        Label("common.back", systemImage: "chevron.left")
                                    }
                                    .buttonStyle(.bordered)

                                    Button {
                                        Task { await changeFavorite() }
                                    } label: {
                                        Label(TVL10n.value("library.favorites"),
                                              systemImage: favorite ? "heart.fill" : "heart")
                                            .symbolEffect(.bounce, value: favorite && !reduceMotion)
                                    }
                                    .accessibilityAddTraits(favorite ? .isSelected : [])
                                    .buttonStyle(.bordered)
                                    .tint(favorite ? TTTheme.accent : TTTheme.muted)
                                    .disabled(!activityLoaded || activitySaving)

                                    Button {
                                        Task { await changeWatchLater() }
                                    } label: {
                                        Label(TVL10n.value("library.watchLater"),
                                              systemImage: watchLater ? "bookmark.fill" : "bookmark")
                                            .symbolEffect(.bounce, value: watchLater && !reduceMotion)
                                    }
                                    .accessibilityAddTraits(watchLater ? .isSelected : [])
                                    .buttonStyle(.bordered)
                                    .tint(watchLater ? TTTheme.accent : TTTheme.muted)
                                    .disabled(!activityLoaded || activitySaving)
                                }

                                // Keep "Mark watched" directly below Play,
                                // first and leftmost in the second action row.
                                HStack(spacing: 18) {
                                    if video.isLive != true,
                                       ((detailedVideo.duration ?? 0) > 0 || detailedVideo.isShort) {
                                        Button {
                                            Task { await changeWatched() }
                                        } label: {
                                            Label(isMarkedWatched
                                                  ? "action.markUnwatched" : "action.markWatched",
                                                  systemImage: isMarkedWatched
                                                      ? "arrow.uturn.backward.circle" : "checkmark.circle")
                                        }
                                        .buttonStyle(.bordered)
                                        .disabled(progressSaving)
                                        .focused($focusedDetail, equals: .markWatched)
                                        .onMoveCommand { direction in
                                            if direction == .down,
                                               descriptionText?.isEmpty == false {
                                                revealDescription(using: page)
                                            }
                                        }
                                    }
                                    Button {
                                        TVPlaylistPopupPresenter.shared.present(
                                            api: api, video: detailedVideo,
                                            onDismiss: { focusedDetail = .playlist }
                                        )
                                    } label: {
                                        Label("action.addPlaylist",
                                              systemImage: "list.bullet.rectangle")
                                    }
                                    .buttonStyle(.bordered)
                                    .tint(Color(red: 0.26, green: 0.56, blue: 1))
                                    .focused($focusedDetail, equals: .playlist)
                                    .accessibilityIdentifier("video-add-playlist")
                                    .onMoveCommand { direction in
                                        if direction == .down,
                                           descriptionText?.isEmpty == false {
                                            revealDescription(using: page)
                                        }
                                    }
                                }
                                if let progressError {
                                    Text(progressError)
                                        .font(.caption)
                                        .foregroundStyle(.orange)
                                        .lineLimit(2)
                                }
                                if let activityError {
                                    Text(activityError)
                                        .font(.caption)
                                        .foregroundStyle(.red)
                                        .lineLimit(2)
                                }
                                if !activityLoaded {
                                    ProgressView().controlSize(.small)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)

                            if video.isLive != true, let duration = detailedVideo.duration,
                               duration > 0 {
                                VStack(alignment: .leading, spacing: 10) {
                                    Text("video.progressHeading")
                                        .font(.callout.bold())
                                    ProgressView(value: watchedFraction)
                                        .tint(TTTheme.accent)
                                    Text("\(TTTheme.time(Int(playbackPosition / 1_000))) / \(TTTheme.time(duration)) · \(Int(watchedFraction * 100))%")
                                        .font(.callout.monospacedDigit())
                                        .foregroundStyle(TTTheme.muted)
                                }
                                .frame(width: 350, alignment: .leading)
                                .padding(.top, 13)
                                .accessibilityIdentifier("video-progress-side")
                            }
                        }
                        .focusSection()
                }
                .padding(.horizontal, 90)
                .padding(.top, 105)
                .padding(.bottom, 58)
                .frame(maxWidth: .infinity, minHeight: 690, alignment: .topLeading)
                .background {
                    GeometryReader { proxy in
                        ZStack(alignment: .leading) {
                            TVThumbnail(url: api.relativeMediaURL(video.thumbnailUrl),
                                        origin: api.origin)
                                .frame(width: proxy.size.width, height: proxy.size.height)
                                .scaleEffect(heroVisible || reduceMotion ? 1 : 0.94)
                                .opacity(heroVisible || reduceMotion ? 1 : 0)
                                .clipped()
                            LinearGradient(
                                stops: [
                                    .init(color: TTTheme.ink, location: 0),
                                    .init(color: TTTheme.ink.opacity(0.94), location: 0.36),
                                    .init(color: TTTheme.ink.opacity(0.22), location: 1)
                                ], startPoint: .leading, endPoint: .trailing
                            )
                            LinearGradient(colors: [.clear, TTTheme.ink],
                                           startPoint: .center, endPoint: .bottom)
                        }
                        .clipped()
                    }
                }

                VStack(alignment: .leading, spacing: 26) {
                if let likes = streamMetadata?.likeCount, likes >= 0 {
                    HStack {
                        Image(systemName: "hand.thumbsup")
                        Text("\(likes.formatted()) \(TVL10n.value("video.likes"))")
                    }
                    .font(.callout)
                }
                // A single detail area switches between the original remote-
                // scrollable description and read-only server comments.
                // Keep the existing description entry/focus identifiers:
                // device and UI tests depend on this focus chain.
                if descriptionText?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false ||
                   contentPreferences.settings?.hideComments != true {
                    VStack(alignment: .leading, spacing: 20) {
                        HStack(spacing: 18) {
                            if descriptionText?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
                                Button {
                                    selectedPane = .description
                                    focusedDetail = .descriptionBody
                                } label: {
                                    HStack(spacing: 12) {
                                        Text("video.descriptionHeading")
                                            .font(.title2.bold())
                                        Image(systemName: "chevron.down")
                                            .font(.callout.bold())
                                    }
                                    .foregroundStyle(focusedDetail == .descriptionEntry ||
                                                     selectedPane == .description
                                                     ? .white : TTTheme.muted)
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 8)
                                    .background(selectedPane == .description ||
                                                focusedDetail == .descriptionEntry
                                                ? Color.white.opacity(0.12) : .clear,
                                                in: RoundedRectangle(cornerRadius: 9))
                                }
                                .buttonStyle(.plain)
                                .focused($focusedDetail, equals: .descriptionEntry)
                                .accessibilityIdentifier("video-description-entry")
                                .accessibilityAddTraits(
                                    selectedPane == .description ? .isSelected : []
                                )
                                .onMoveCommand { direction in
                                    if direction == .down {
                                        selectedPane = .description
                                        focusedDetail = .descriptionBody
                                    }
                                }
                            }
                            if contentPreferences.settings?.hideComments != true {
                                Button {
                                    selectedPane = .comments
                                    focusedDetail = .commentsTab
                                } label: {
                                    HStack(spacing: 12) {
                                        Text("video.commentsTab")
                                            .font(.title2.bold())
                                        Image(systemName: "text.bubble")
                                    }
                                    .foregroundStyle(selectedPane == .comments
                                                     ? .white : TTTheme.muted)
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 8)
                                    .background(selectedPane == .comments
                                                ? Color.white.opacity(0.12) : .clear,
                                                in: RoundedRectangle(cornerRadius: 9))
                                }
                                .buttonStyle(.plain)
                                .focused($focusedDetail, equals: .commentsTab)
                                .accessibilityAddTraits(
                                    selectedPane == .comments ? .isSelected : []
                                )
                                .accessibilityIdentifier("video-comments-tab")
                            }
                        }
                        .focusSection()

                        if selectedPane == .comments &&
                           contentPreferences.settings?.hideComments != true {
                            TVCommentsPanel(api: api, videoURL: video.url)
                                .focusSection()
                        } else if let description = descriptionText,
                                  !description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            Button {
                                fullDescriptionPresented = true
                            } label: {
                                VStack(alignment: .leading, spacing: 15) {
                                    Text(String(description.prefix(430)) +
                                         (description.count > 430 ? "…" : ""))
                                        .font(.body)
                                        .foregroundStyle(TTTheme.muted)
                                        .multilineTextAlignment(.leading)
                                        .lineLimit(7)
                                    Label("video.descriptionOpenFull",
                                          systemImage: "arrow.up.left.and.arrow.down.right")
                                        .font(.callout.bold())
                                        .foregroundStyle(TTTheme.accent)
                                }
                                .padding(25)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(TTTheme.surface,
                                            in: RoundedRectangle(cornerRadius: 12))
                                .modifier(TVCardFocusHalo(
                                    focused: focusedDetail == .descriptionBody))
                            }
                            .buttonStyle(TVRailButtonStyle())
                            .focusEffectDisabled(true)
                            .focused($focusedDetail, equals: .descriptionBody)
                            .accessibilityIdentifier("video-description-focus")
                            .focusSection()
                        }
                    }
                    .id("video-detail-tabs")
                }
                if contentPreferences.settings?.hideRelatedVideos != true,
                   let related = streamMetadata?.relatedStreams, !related.isEmpty {
                    TVRelatedVideosSection(api: api,
                        videos: contentPreferences.displayed(related))
                }
            }
            .padding(.horizontal, 90)
            .padding(.bottom, 110)
            }
            .background(TTTheme.ink)
            .defaultFocus($focusedDetail, .play)
            .task(id: video.url) {
                if !heroVisible {
                    withAnimation(reduceMotion ? nil : .easeOut(duration: 0.38)) {
                        heroVisible = true
                    }
                }
                if initiallyFocusedVideoURL != video.url {
                    initiallyFocusedVideoURL = video.url
                    // tvOS otherwise chooses the first focusable item,
                    // which became the channel link above Play.
                    await Task.yield()
                    focusedDetail = .play
                }
                async let activity: Void = loadActivity()
                async let enrichment: Void = loadMetadata()
                _ = await (activity, enrichment)
                await contentPreferences.ensureLoaded(api: api)
            }
            .task(id: channelURL) {
                channelArtwork = nil
                guard let channelURL else { return }
                let artwork = await TVChannelArtworkCache.shared.artwork(
                    for: channelURL, api: api
                )
                if !Task.isCancelled { channelArtwork = artwork }
            }
            .onChange(of: contentPreferences.settings?.hideComments) { _, hidden in
                if hidden == true && selectedPane == .comments {
                    selectedPane = .description
                    focusedDetail = .descriptionEntry
                }
            }
            .onChange(of: focusedDetail) { _, next in
                guard next == .descriptionEntry || next == .descriptionBody ||
                      next == .commentsTab else { return }
                // Moving into either tab must scroll the parent into view
                // before tvOS resolves the nested focus destination.
                withAnimation(.easeOut(duration: 0.24)) {
                    page.scrollTo("video-detail-tabs", anchor: .center)
                }
            }
        }
        .sheet(isPresented: $fullDescriptionPresented, onDismiss: {
            focusedDetail = .descriptionBody
        }) {
            TVFullDescriptionPanel(description: descriptionText ?? "")
        }
        .onExitCommand {
            if fullDescriptionPresented {
                fullDescriptionPresented = false
            } else {
                returnToList()
            }
        }
    }

    @MainActor
    private func returnToList() {
        dismiss()
        onReturnToList?()
    }

    @MainActor
    private func revealDescription(using page: ScrollViewProxy) {
        guard descriptionText?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        else { return }
        selectedPane = .description
        withAnimation(.easeOut(duration: 0.24)) {
            page.scrollTo("video-detail-tabs", anchor: .center)
        }
        Task { @MainActor in
            await Task.yield()
            focusedDetail = .descriptionEntry
        }
    }

    @MainActor
    private func loadMetadata() async {
        async let metadata = TVStreamMetadataCache.shared.details(for: video, api: api)
        async let progress = api.withProgress([video])
        streamMetadata = await metadata
        let rows = await progress
        if !Task.isCancelled { savedPositionMs = rows.first?.watchPositionMs }
    }

    @MainActor
    private func changeWatched() async {
        guard !progressSaving else { return }
        progressSaving = true
        progressError = nil
        defer { progressSaving = false }
        let next = !isMarkedWatched
        do {
            var target = detailedVideo
            // /history omits Shorts metadata and may have no duration.
            // Resolve a real duration, never invent one just to mark watched.
            if (target.duration ?? 0) <= 0, target.isShort {
                let details = await TVStreamMetadataCache.shared.details(for: video, api: api)
                guard !Task.isCancelled else { return }
                if let details { streamMetadata = details }
                target = TVVideoMetadata.merged(video, stream: details)
            }
            guard let duration = target.duration, duration > 0 else {
                throw TypeTypeError.missingVideoDuration
            }
            try await api.setWatched(next, video: target)
            let position = next ? Int64(duration) * 1_000 : 0
            savedPositionMs = position
            TVLocalProgress.shared.record(video.url, positionMs: position)
        } catch {
            progressError = error.localizedDescription
        }
    }

    @MainActor
    private func loadActivity() async {
        activityLoaded = false
        activityError = nil
        do {
            async let favorites = api.library(.favorites)
            async let saved = api.library(.watchLater)
            let (favoriteItems, savedItems) = try await (favorites, saved)
            guard !Task.isCancelled else { return }
            favorite = favoriteItems.contains { TVVideoIdentity.equivalent($0.url, video.url) }
            watchLater = savedItems.contains { TVVideoIdentity.equivalent($0.url, video.url) }
            activityLoaded = true
        } catch is CancellationError {
            return
        } catch {
            activityLoaded = false
            activityError = error.localizedDescription
        }
    }

    @MainActor
    private func changeFavorite() async {
        guard activityLoaded && !activitySaving else { return }
        let old = favorite
        favorite = !old
        activitySaving = true
        activityError = nil
        defer { activitySaving = false }
        do {
            try await api.setFavorite(videoURL: video.url, enabled: favorite)
            TVFavoriteMembership.shared.mark(video.url, present: favorite, api: api)
        } catch {
            favorite = old
            activityError = error.localizedDescription
        }
    }

    @MainActor
    private func changeWatchLater() async {
        guard activityLoaded && !activitySaving else { return }
        let old = watchLater
        watchLater = !old
        activitySaving = true
        activityError = nil
        defer { activitySaving = false }
        do {
            try await api.setWatchLater(video: video, enabled: watchLater)
            TVWatchLaterMembership.shared.mark(video.url, present: watchLater, api: api)
        } catch {
            watchLater = old
            activityError = error.localizedDescription
        }
    }
}

