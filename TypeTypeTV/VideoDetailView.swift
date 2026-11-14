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

    private var youtube: Bool { VideoAddress.youtubeID(video.url) != nil }

    var body: some View {
        ScrollView {
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
                    VStack(alignment: .leading, spacing: 22) {
                        Text(TVL10n.value(video.isLive == true ? "video.liveBadge" : "video.badge"))
                            .font(.subheadline.bold()).tracking(2.5)
                            .foregroundStyle(TTTheme.accent)
                        Text(video.title)
                            .font(.system(size: 53, weight: .bold))
                            .lineLimit(3)
                            .frame(maxWidth: 830, alignment: .leading)
                            .fixedSize(horizontal: false, vertical: true)
                        if let channel = video.uploaderName, !channel.isEmpty {
                            Label(channel, systemImage: "person.crop.circle")
                                .font(.title3)
                                .foregroundStyle(.white.opacity(0.8))
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
                        VStack(alignment: .leading, spacing: 16) {
                            HStack(spacing: 22) {
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
                                        if video.isLive == true { Text("video.viewLive") }
                                        else { Text("video.play") }
                                    } icon: {
                                        Image(systemName: "play.fill")
                                    }
                                }
                                .buttonStyle(.borderedProminent)
                                .tint(TTTheme.accent)

                                Button {
                                    dismiss()
                                } label: {
                                    Label("common.back", systemImage: "chevron.left")
                                }
                                .buttonStyle(.bordered)
                            }
                            HStack(spacing: 22) {
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

                                if !activityLoaded {
                                    ProgressView().controlSize(.small)
                                }
                            }
                            if let activityError {
                                Text(activityError)
                                    .font(.caption)
                                    .foregroundStyle(.red)
                                    .lineLimit(2)
                            }
                        }
                        .focusSection()
                    }
                    .padding(.leading, 90)
                    .padding(.top, 110)
                }
            }
            .frame(height: 690)
            .clipped()

        }
        .background(TTTheme.ink)
        .task(id: video.url) { await loadActivity() }
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
            favorite = favoriteItems.contains { $0.url == video.url }
            watchLater = savedItems.contains { $0.url == video.url }
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
