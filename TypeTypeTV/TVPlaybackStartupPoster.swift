import SwiftUI

/// A temporary image shown OVER the video surface during initial decoding.
/// Do not move it below AVSampleBufferDisplayLayer: its opaque black contents
/// would cover the image until the first frame arrives.
struct TVPlaybackStartupPoster: View {
    let api: TypeTypeAPI
    let video: VideoItem
    // SABR keeps the same UIKit view mounted for the whole session. HLS keeps
    // its existing thumbnail path unchanged.
    var transientImage = false
    var retainsImage = true

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                Color.black
                if transientImage {
                    TVTransientStartupImage(
                        url: api.relativeMediaURL(video.thumbnailUrl),
                        origin: api.origin, retainsImage: retainsImage
                    )
                    .frame(width: geometry.size.width,
                           height: geometry.size.height)
                } else {
                    TVThumbnail(
                        url: api.relativeMediaURL(video.thumbnailUrl),
                        origin: api.origin, contentMode: .fill
                    )
                    .frame(width: geometry.size.width,
                           height: geometry.size.height)
                }
                LinearGradient(
                    colors: [.black.opacity(0.15), .clear, .black.opacity(0.22)],
                    startPoint: .top, endPoint: .bottom
                )
            }
            .frame(width: geometry.size.width,
                   height: geometry.size.height)
            .clipped()
        }
        .ignoresSafeArea()
        .accessibilityHidden(true)
        .allowsHitTesting(false)
    }
}

/// Thumbnail removal must follow real rendering readiness, not just the
/// arrival of network fragments or a "playing" status on its own.
enum TVPlaybackStartupPosterPolicy {
    static func sabrReady(displayReady: Bool, clockRunning: Bool) -> Bool {
        displayReady && clockRunning
    }

    /// AVPlayerViewController does not expose its internal display layer.
    /// The HLS fallback waits for observable progress after AVPlayer begins
    /// playing, rather than hiding the artwork on .readyToPlay alone.
    static func hlsAdvanced(previous: Double?, current: Double,
                            playing: Bool) -> Bool {
        guard playing, let previous, previous.isFinite, current.isFinite else {
            return false
        }
        return current > previous + 0.08
    }
}
