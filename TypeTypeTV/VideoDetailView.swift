import SwiftUI

struct VideoDetailView: View {
    let api: TypeTypeAPI
    let video: VideoItem
    var playbackQueue: [VideoItem]? = nil
    @Environment(\.dismiss) private var dismiss
    @State private var favorite = false
    @State private var watchLater = false
    @State private var activityLoaded = false
    @State private var activitySaving = false
    @State private var activityError: String?
    @State private var streamMetadata: StreamInfo?
    @State private var savedPositionMs: Int64?
    @State private var progressSaving = false
    @State private var progressError: String?
    @ObservedObject private var localProgress = TVLocalProgress.shared

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
        guard let duration = video.duration, duration > 0 else { return saved }
        return min(saved, Int64(duration) * 1_000)
    }
    private var watchedFraction: Double {
        guard let duration = video.duration, duration > 0 else { return 0 }
        return max(0, min(1, Double(playbackPosition) / (Double(duration) * 1_000)))
    }
    private var isMarkedWatched: Bool {
        TVWatchedState.isWatched(detailedVideo, positionMs:
            localProgress.position(for: video.url) ?? savedPositionMs ?? video.watchPositionMs)
    }


    var body: some View {
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
                                    Label {
                                        HStack(spacing: 10) {
                                            Text(channel)
                                            Image(systemName: "chevron.right")
                                                .font(.caption.bold())
                                        }
                                    } icon: {
                                        Image(systemName: "person.crop.circle")
                                    }
                                }
                                .buttonStyle(.bordered)
                                .tint(TTTheme.muted)
                                .accessibilityIdentifier("video-open-channel")
                            } else {
                                Label(channel, systemImage: "person.crop.circle")
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
                            } else if let seconds = video.duration, seconds > 0 {
                                Label(TTTheme.time(seconds), systemImage: "clock")
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
                                            PlaybackView(api: api, video: video)
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

                                    Button { dismiss() } label: {
                                        Label("common.back", systemImage: "chevron.left")
                                    }
                                    .buttonStyle(.bordered)

                                    Button {
                                        Task { await changeFavorite() }
                                    } label: {
                                        Label(TVL10n.value("library.favorites"),
                                              systemImage: favorite ? "heart.fill" : "heart")
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
                                    }
                                    .accessibilityAddTraits(watchLater ? .isSelected : [])
                                    .buttonStyle(.bordered)
                                    .tint(watchLater ? TTTheme.accent : TTTheme.muted)
                                    .disabled(!activityLoaded || activitySaving)
                                }

                                // Mark-as-watched is a separate, less prominent
                                // action; never allow its long translated label
                                // to squeeze the primary controls/progress.
                                if video.isLive != true, (video.duration ?? 0) > 0 {
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

                            if video.isLive != true, let duration = video.duration,
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
                if let description = descriptionText,
                   !description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text("video.descriptionHeading").font(.title2.bold())
                    TVRemoteDescriptionScrollView(text: description)
                        .frame(height: 370)
                        .background(TTTheme.surface,
                                    in: RoundedRectangle(cornerRadius: 12))
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                        .focusSection()
                }
            }
            .padding(.horizontal, 90)
            .padding(.bottom, 110)
            }
            .background(TTTheme.ink)
            .task(id: video.url) {
                async let activity: Void = loadActivity()
                async let enrichment: Void = loadMetadata()
                _ = await (activity, enrichment)
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
        guard !progressSaving, let duration = video.duration, duration > 0 else { return }
        progressSaving = true
        progressError = nil
        defer { progressSaving = false }
        let next = !isMarkedWatched
        do {
            try await api.setWatched(next, video: video)
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

