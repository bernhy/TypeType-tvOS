import SwiftUI
import AVKit

struct PlaybackView: View {
    let api: TypeTypeAPI
    let video: VideoItem
    var onPlaybackEvent: ((TVPlaybackEvent) -> Void)? = nil
    @Environment(\.dismiss) private var dismiss
    @State private var hlsURL: URL?
    @State private var hlsMetadata: StreamInfo?
    @State private var errorMessage: String?

    var body: some View {
        Group {
            if VideoAddress.youtubeID(video.url) != nil && video.isLive != true {
                SabrPlayerView(api: api, video: video, onPlaybackEvent: onPlaybackEvent)
            } else if let hlsURL {
                TVHLSPlaybackView(api: api, video: video, url: hlsURL,
                                  streamMetadata: hlsMetadata,
                                  onPlaybackEvent: onPlaybackEvent)
                    .ignoresSafeArea()
            } else if let errorMessage {
                VStack(spacing: 25) {
                    Text("player.failed").font(.largeTitle)
                    Text(errorMessage).font(.body).multilineTextAlignment(.center)
                    Button("common.retry") { Task { await prepare() } }
                        .buttonStyle(.borderedProminent)
                }
                .padding(70)
            } else {
                ProgressView("player.preparing")
            }
        }
        .onAppear { TVPlaybackVisibility.shared.enter() }
        .onDisappear { TVPlaybackVisibility.shared.leave() }
        .onExitCommand { dismiss() }
        .task {
            if VideoAddress.youtubeID(video.url) == nil || video.isLive == true {
                await prepare()
            }
        }
    }

    @MainActor
    private func prepare() async {
        errorMessage = nil
        let policy = TVStreamRecoveryPolicy()
        let started = Date()
        for attempt in 1...policy.maxAttempts {
            do {
                try Task.checkCancellation()
                let stream = try await api.stream(for: video)
                guard let url = api.relativeMediaURL(stream.hlsUrl) else {
                    throw TypeTypeError.unavailableFormat
                }
                guard !Task.isCancelled else { return }
                hlsMetadata = stream
                hlsURL = url
                return
            } catch is CancellationError {
                return
            } catch TypeTypeError.videoUnavailable {
                errorMessage = TVL10n.value("player.videoUnavailable")
                onPlaybackEvent?(.unavailable)
                return
            } catch {
                guard let delay = policy.delayNanoseconds(
                    error: error, attempt: attempt,
                    elapsedSeconds: Date().timeIntervalSince(started)
                ) else {
                    errorMessage = error.localizedDescription
                    return
                }
                do { try await Task.sleep(nanoseconds: delay) }
                catch { return }
            }
        }
    }
}

/// The system AVPlayerViewController owns focus, Siri Remote play/pause,
/// transport controls and system-provided audio/subtitle track selection.
/// Playback state and account progress are managed by TVHLSPlaybackController.
struct SystemVideoPlayer: UIViewControllerRepresentable {
    let player: AVPlayer

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let controller = AVPlayerViewController()
        controller.player = player
        return controller
    }

    func updateUIViewController(_ controller: AVPlayerViewController, context: Context) {
        if controller.player !== player { controller.player = player }
    }

    static func dismantleUIViewController(_ controller: AVPlayerViewController,
                                         coordinator: ()) {
        controller.player = nil
    }
}
