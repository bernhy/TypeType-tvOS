import Foundation
import Combine

/// Successful account mutations only. A page receives one inexpensive
/// screen-level event; video cards themselves do not subscribe or fetch.
/// The bounded log also covers a pushed detail temporarily suspending its
/// parent view: the parent can reconcile missed changes on return.
/// The journal cursor is deliberately NOT observable. A playlist badge
/// update must not invalidate an entire parent screen just to advance its
/// last-seen event ID. Only a real local row removal mutates SwiftUI @State.
@MainActor
final class TVVideoMutationCursor {
    var lastID = 0
}

@MainActor
final class TVVideoMutationCenter: ObservableObject {
    static let shared = TVVideoMutationCenter()

    enum Kind: Equatable {
        case watchLater(added: Bool)
        case favorite(added: Bool)
        case playlist(id: String, added: Bool)
        case videoBlocked
        case channelBlocked
    }

    struct Event: Identifiable {
        let id: Int
        let accountScope: String
        let videoURL: String
        let channelURL: String?
        let kind: Kind

        func removes(_ video: VideoItem) -> Bool {
            switch kind {
            case .videoBlocked:
                return TVVideoIdentity.equivalent(video.url, videoURL)
            case .channelBlocked:
                guard let channelURL, let uploaderURL = video.uploaderUrl else {
                    return false
                }
                return uploaderURL == channelURL
            default:
                return false
            }
        }

        func removesFromWatchLater(_ video: VideoItem) -> Bool {
            if case .watchLater(added: false) = kind {
                return TVVideoIdentity.equivalent(video.url, videoURL)
            }
            return false
        }

        func removesFromFavorites(_ video: VideoItem) -> Bool {
            if case .favorite(added: false) = kind {
                return TVVideoIdentity.equivalent(video.url, videoURL)
            }
            return false
        }

        func removesFromPlaylist(_ video: VideoItem, id: String) -> Bool {
            if case .playlist(let playlistID, added: false) = kind,
               playlistID == id {
                return TVVideoIdentity.equivalent(video.url, videoURL)
            }
            return false
        }
    }

    @Published private(set) var events: [Event] = []
    private var sequence = 0
    private init() {}

    func record(api: TypeTypeAPI, video: VideoItem, kind: Kind) {
        sequence &+= 1
        events.append(Event(
            id: sequence, accountScope: api.metadataCacheScope,
            videoURL: video.url, channelURL: video.uploaderUrl, kind: kind
        ))
        // Keep only a small history for detail-pop reconciliation. No disk
        // cache, extra network call, timer, or per-card observations.
        if events.count > 96 { events.removeFirst(events.count - 96) }
    }
}
