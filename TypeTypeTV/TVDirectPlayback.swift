import SwiftUI

/// One navigation request per remote Play/Pause press. The identity is
/// independent of a video's URL so reopening the same video after returning
/// from playback always creates a fresh navigation destination.
struct TVDirectPlaybackRequest: Identifiable, Hashable {
    let id = UUID()
    let video: VideoItem
    let playbackQueue: [VideoItem]?
    let onReturnedVideo: ((VideoItem) -> Void)?

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.id == rhs.id }

    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

/// A small environment action rather than per-thumbnail @State or observers.
/// The only state change is the explicit navigation requested by the remote.
struct TVDirectPlaybackAction {
    let perform: (VideoItem, [VideoItem]?, ((VideoItem) -> Void)?) -> Void

    func callAsFunction(_ video: VideoItem, playbackQueue: [VideoItem]? = nil,
                        onReturnedVideo: ((VideoItem) -> Void)? = nil) {
        perform(video, playbackQueue, onReturnedVideo)
    }
}

private struct TVDirectPlaybackActionKey: EnvironmentKey {
    static let defaultValue = TVDirectPlaybackAction { _, _, _ in }
}

extension EnvironmentValues {
    var tvDirectPlayback: TVDirectPlaybackAction {
        get { self[TVDirectPlaybackActionKey.self] }
        set { self[TVDirectPlaybackActionKey.self] = newValue }
    }
}

/// Keep remote Play/Pause identical to the detail screen's Play button:
/// playlist/Watch Later queues start at the selected item; otherwise use
/// the existing SABR/HLS player, which owns transport controls during video.
enum TVDirectPlaybackPolicy {
    static func queueIndex(for video: VideoItem,
                           in queue: [VideoItem]?) -> Int? {
        queue?.firstIndex(where: { $0.url == video.url })
    }
}

struct TVDirectPlaybackDestination: View {
    let api: TypeTypeAPI
    let video: VideoItem
    let playbackQueue: [VideoItem]?

    @ViewBuilder
    var body: some View {
        if let playbackQueue,
           let index = TVDirectPlaybackPolicy.queueIndex(
               for: video, in: playbackQueue
           ) {
            TVPlaylistPlaybackView(
                api: api, videos: playbackQueue, startIndex: index
            )
        } else {
            PlaybackView(api: api, video: video)
        }
    }
}
