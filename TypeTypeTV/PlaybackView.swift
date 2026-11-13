import SwiftUI
import AVKit

struct PlaybackView: View {
    let api: TypeTypeAPI
    let video: VideoItem
    @State private var hlsURL: URL?
    @State private var errorMessage: String?

    var body: some View {
        Group {
            if let hlsURL {
                SystemVideoPlayer(url: hlsURL)
                    .ignoresSafeArea()
            } else if let errorMessage {
                VStack(spacing: 25) {
                    Text("Wiedergabe noch nicht möglich").font(.largeTitle)
                    Text(errorMessage).font(.body).multilineTextAlignment(.center)
                }
                .padding(70)
            } else {
                ProgressView("Bereite Wiedergabe vor …")
            }
        }
        .task { await prepare() }
    }

    @MainActor
    private func prepare() async {
        do {
            let stream = try await api.stream(for: video)
            guard let url = api.relativeMediaURL(stream.hlsUrl) else {
                throw TypeTypeError.unavailableFormat
            }
            hlsURL = url
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

/// tvOS's public, native player handles HLS transport and Siri Remote controls.
struct SystemVideoPlayer: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let controller = AVPlayerViewController()
        controller.player = AVPlayer(url: url)
        controller.player?.play()
        return controller
    }

    func updateUIViewController(_ controller: AVPlayerViewController, context: Context) {}

    static func dismantleUIViewController(_ controller: AVPlayerViewController, coordinator: ()) {
        controller.player?.pause()
        controller.player = nil
    }
}
