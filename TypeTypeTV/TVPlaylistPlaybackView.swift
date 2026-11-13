import SwiftUI

/// Emitted only after confirmed media completion or a permanent server error.
/// Network stalls and decode issues remain recoverable, not "unavailable".
enum TVPlaybackEvent: Equatable {
    case finished
    case unavailable
}

enum TVPlaylistAdvancePolicy {
    static func nextIndex(after index: Int, count: Int) -> Int? {
        guard count > 0, index >= 0, index < count - 1 else { return nil }
        return index + 1
    }

    static func validIndex(_ index: Int, count: Int) -> Int? {
        (0..<count).contains(index) ? index : nil
    }
}

/// A continuous Watch Later / playlist player. Failed stream lookups with a
/// permanent server code are skipped after three seconds, but the account
/// playlist itself is never mutated. Transient errors stay on screen with
/// the individual player's Retry action.
struct TVPlaylistPlaybackView: View {
    let api: TypeTypeAPI
    let videos: [VideoItem]
    var startIndex = 0

    @State private var index = 0
    @State private var finished = false
    @State private var skipNotice = false
    @State private var skipTask: Task<Void, Never>?

    private var active: VideoItem? {
        guard !finished, videos.indices.contains(index) else { return nil }
        return videos[index]
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let active {
                let playingIndex = index
                PlaybackView(api: api, video: active) { event in
                    handle(event, from: playingIndex)
                }
                .id("\(playingIndex)|\(active.url)")
                .ignoresSafeArea()

                VStack(spacing: 12) {
                    HStack(spacing: 22) {
                        Text(TVL10n.formatted(
                            "playlist.progress", playingIndex + 1, videos.count
                        ))
                        .font(.callout.weight(.medium))
                        .foregroundStyle(.white)
                        Spacer()
                        if playingIndex > 0 {
                            Button { go(to: playingIndex - 1) } label: {
                                Label("playlist.previous", systemImage: "backward.end.fill")
                            }
                            .buttonStyle(.bordered)
                        }
                        if playingIndex + 1 < videos.count {
                            Button { advance() } label: {
                                Label("playlist.next", systemImage: "forward.end.fill")
                            }
                            .buttonStyle(.bordered)
                        }
                    }
                    if skipNotice {
                        Text("playlist.skippingUnavailable")
                            .font(.callout.bold())
                            .foregroundStyle(.orange)
                            .frame(maxWidth: .infinity, alignment: .trailing)
                    }
                }
                .padding(30)
                .background(
                    LinearGradient(
                        colors: [.black.opacity(0.75), .clear],
                        startPoint: .top, endPoint: .bottom
                    )
                )
                .frame(maxHeight: .infinity, alignment: .top)
            } else {
                VStack(spacing: 18) {
                    Image(systemName: "checkmark.circle")
                        .font(.system(size: 50))
                    Text("playlist.end").font(.largeTitle.bold())
                    Text("playlist.noMore").foregroundStyle(.secondary)
                }
            }
        }
        .onAppear {
            index = TVPlaylistAdvancePolicy.validIndex(
                startIndex, count: videos.count
            ) ?? 0
            finished = videos.isEmpty
        }
        .onDisappear {
            skipTask?.cancel()
            skipTask = nil
        }
    }

    private func handle(_ event: TVPlaybackEvent, from playingIndex: Int) {
        guard playingIndex == index && !finished else { return }
        switch event {
        case .finished:
            advance()
        case .unavailable:
            guard skipTask == nil else { return }
            skipNotice = true
            skipTask = Task { @MainActor in
                do { try await Task.sleep(nanoseconds: 3_000_000_000) }
                catch { return }
                guard !Task.isCancelled, playingIndex == index else { return }
                advance()
            }
        }
    }

    private func advance() {
        guard let next = TVPlaylistAdvancePolicy.nextIndex(
            after: index, count: videos.count
        ) else {
            skipTask?.cancel()
            skipTask = nil
            skipNotice = false
            finished = true
            return
        }
        go(to: next)
    }

    private func go(to target: Int) {
        guard let validated = TVPlaylistAdvancePolicy.validIndex(
            target, count: videos.count
        ) else { return }
        skipTask?.cancel()
        skipTask = nil
        skipNotice = false
        finished = false
        index = validated
    }
}
