import SwiftUI
import AVKit

struct PlaybackView: View {
    let api: TypeTypeAPI
    let video: VideoItem
    var onPlaybackEvent: ((TVPlaybackEvent) -> Void)? = nil
    @State private var hlsURL: URL?
    @State private var errorMessage: String?

    var body: some View {
        Group {
            if VideoAddress.youtubeID(video.url) != nil && video.isLive != true {
                SabrPlayerView(api: api, video: video, onPlaybackEvent: onPlaybackEvent)
            } else if let hlsURL {
                TVHLSPlaybackView(api: api, video: video, url: hlsURL,
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
        .task {
            if VideoAddress.youtubeID(video.url) == nil || video.isLive == true {
                await prepare()
            }
        }
    }

    @MainActor
    private func prepare() async {
        errorMessage = nil
        do {
            let stream = try await api.stream(for: video)
            guard let url = api.relativeMediaURL(stream.hlsUrl) else {
                throw TypeTypeError.unavailableFormat
            }
            hlsURL = url
        } catch is CancellationError {
            return
        } catch TypeTypeError.videoUnavailable {
            errorMessage = TVL10n.value("player.videoUnavailable")
            onPlaybackEvent?(.unavailable)
        } catch {
            errorMessage = error.localizedDescription
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
