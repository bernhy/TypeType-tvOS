import SwiftUI

/// Account subscriptions are their own destination, not a second shortcut to
/// Playlists. Source: GET /api/subscriptions + GET /api/channel?url=...
struct TVSubscriptionsView: View {
    let api: TypeTypeAPI

    @State private var subscriptions: [TVSubscription] = []
    @State private var selectedChannelURL: String?
    @State private var videos: [VideoItem] = []
    @State private var channelTitle = ""
    @State private var channelDescription = ""
    @State private var nextPage: String?
    @State private var loadingSubscriptions = false
    @State private var loadingVideos = false
    @State private var channelRequestID = UUID()
    @State private var pageRequestID = UUID()
    @State private var loadingMore = false
    @State private var error: String?
    @FocusState private var focusedSubscription: String?
    @FocusState private var focusedVideo: String?
    private let columns = Array(repeating: GridItem(.flexible(), spacing: 22), count: 3)

    var body: some View {
        HStack(alignment: .top, spacing: 25) {
            channelRail
                .frame(width: 285)
                .environment(\.isFocusEffectEnabled, false)
                .focusEffectDisabled(true)
                .focusSection()
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    VStack(alignment: .leading, spacing: 9) {
                        Text("subscriptions.kicker")
                            .font(.subheadline.bold())
                            .tracking(2)
                            .foregroundStyle(TTTheme.accent)
                        Text(channelTitle.isEmpty ? TVL10n.value("subscriptions.title") : channelTitle)
                            .font(.system(size: 39, weight: .bold))
                        if !channelDescription.isEmpty {
                            Text(channelDescription)
                                .font(.callout)
                                .foregroundStyle(TTTheme.muted)
                                .lineLimit(3)
                        }
                    }
                    if loadingVideos {
                        ProgressView("settings.remoteLoading")
                            .frame(maxWidth: .infinity, minHeight: 160)
                    }
                    if let error {
                        TVContentMessage(
                            symbol: "wifi.exclamationmark",
                            title: error,
                            detail: TVL10n.value("subscriptions.loadError"),
                            action: { Task { await reload() } }
                        )
                    } else if !loadingVideos && videos.isEmpty {
                        TVContentMessage(
                            symbol: "play.rectangle",
                            title: TVL10n.value("subscriptions.emptyVideos"),
                            detail: TVL10n.value("subscriptions.chooseChannel")
                        )
                    } else {
                        LazyVGrid(columns: columns, spacing: 28) {
                            ForEach(Array(videos.enumerated()), id: \.offset) { index, video in
                                NavigationLink {
                                    VideoDetailView(api: api, video: video)
                                } label: {
                                    VideoCard(api: api, video: video)
                                }
                                .buttonStyle(.plain)
                                .focusEffectDisabled(true)
                                .videoActions(
                                    api: api, video: video, onChanged: {},
                                    focus: $focusedVideo, focusID: video.url
                                )
                                .onMoveCommand { direction in
                                    if direction == .left && index % columns.count == 0 {
                                        focusedSubscription = selectedChannelURL
                                    }
                                }
                                .onAppear {
                                    if index >= videos.count - columns.count - 1,
                                       nextPage != nil, !loadingMore && !loadingVideos {
                                        Task { await loadMore() }
                                    }
                                }
                            }
                        }
                        .focusSection()
                        if loadingMore {
                            ProgressView("settings.remoteLoading")
                        }
                    }
                }
                .padding(.top, 38)
                .padding(.trailing, 44)
                .padding(.bottom, 110)
            }
            .focusSection()
        }
        .background(TTTheme.ink)
        .task { await reload() }
        .task(id: selectedChannelURL) {
            if let selectedChannelURL {
                await loadChannel(selectedChannelURL)
            }
        }
    }

    private var channelRail: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text("subscriptions.title")
                .font(.system(size: 27, weight: .bold))
                .padding(.top, 43)
                .padding(.horizontal, 12)
                .padding(.bottom, 12)
            if loadingSubscriptions {
                ProgressView()
                    .padding(16)
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 7) {
                    ForEach(subscriptions) { channel in
                        Button {
                            selectedChannelURL = channel.channelUrl
                        } label: {
                            HStack(spacing: 12) {
                                TVThumbnail(
                                    url: api.relativeMediaURL(channel.avatarUrl),
                                    origin: api.origin
                                )
                                .frame(width: 43, height: 43)
                                .clipShape(Circle())
                                Text(channel.name)
                                    .font(.system(size: 18, weight: .medium))
                                    .lineLimit(2)
                                Spacer(minLength: 0)
                                if selectedChannelURL == channel.channelUrl {
                                    Image(systemName: "chevron.right")
                                        .font(.caption.bold())
                                }
                            }
                            .padding(.horizontal, 10)
                            .frame(maxWidth: .infinity, minHeight: 58, alignment: .leading)
                            .modifier(TVRailRowHighlight(
                                focused: focusedSubscription == channel.channelUrl,
                                selected: selectedChannelURL == channel.channelUrl
                            ))
                        }
                        .buttonStyle(TVRailButtonStyle())
                        .focusEffectDisabled(true)
                        .focused($focusedSubscription, equals: channel.channelUrl)
                        .onMoveCommand { direction in
                            if direction == .right {
                                focusedVideo = videos.first?.url
                            }
                        }
                        .accessibilityIdentifier("subscription-\(channel.channelUrl)")
                    }
                    if subscriptions.isEmpty && !loadingSubscriptions {
                        Text("subscriptions.empty")
                            .font(.callout)
                            .foregroundStyle(TTTheme.muted)
                            .padding(15)
                    }
                }
            }
        }
        .padding(.horizontal, 13)
        .padding(.bottom, 32)
        .frame(maxHeight: .infinity)
        .background(TTTheme.surface)
    }

    @MainActor
    private func reload() async {
        loadingSubscriptions = true
        error = nil
        defer { loadingSubscriptions = false }
        do {
            let received = try await api.subscriptions()
            try Task.checkCancellation()
            subscriptions = received.sorted {
                $0.name.localizedStandardCompare($1.name) == .orderedAscending
            }
            if !subscriptions.contains(where: { $0.channelUrl == selectedChannelURL }) {
                selectedChannelURL = subscriptions.first?.channelUrl
            }
            await Task.yield()
            focusedSubscription = selectedChannelURL
        } catch is CancellationError {
            return
        } catch {
            self.error = error.localizedDescription
        }
    }

    @MainActor
    private func loadChannel(_ channelURL: String) async {
        let identifier = UUID()
        channelRequestID = identifier
        // A cancelled page of the previous channel must not block this one.
        pageRequestID = UUID()
        loadingMore = false
        loadingVideos = true
        videos = []
        nextPage = nil
        channelTitle = subscriptions.first(where: { $0.channelUrl == channelURL })?.name ?? ""
        channelDescription = ""
        error = nil
        defer { if channelRequestID == identifier { loadingVideos = false } }
        do {
            let response = try await api.channel(channelURL)
            try Task.checkCancellation()
            guard channelRequestID == identifier,
                  selectedChannelURL == channelURL else { return }
            channelTitle = response.name
            channelDescription = response.description ?? ""
            videos = response.videos
            nextPage = response.nextpage
        } catch is CancellationError {
            return
        } catch {
            if channelRequestID == identifier && selectedChannelURL == channelURL {
                self.error = error.localizedDescription
            }
        }
    }

    @MainActor
    private func loadMore() async {
        guard !loadingMore, !loadingVideos, let nextPage,
              let selectedChannelURL else { return }
        let identifier = UUID()
        pageRequestID = identifier
        loadingMore = true
        defer { if pageRequestID == identifier { loadingMore = false } }
        do {
            let response = try await api.channel(selectedChannelURL, nextpage: nextPage)
            try Task.checkCancellation()
            guard pageRequestID == identifier,
                  self.selectedChannelURL == selectedChannelURL,
                  self.nextPage == nextPage else { return }
            var seen = Set(videos.map(\.url))
            videos += response.videos.filter { seen.insert($0.url).inserted }
            self.nextPage = response.nextpage == nextPage ? nil : response.nextpage
        } catch is CancellationError {
            return
        } catch {
            if pageRequestID == identifier { self.error = error.localizedDescription }
        }
    }
}
