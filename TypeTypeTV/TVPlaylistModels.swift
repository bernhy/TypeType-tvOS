import Foundation

/// Exact TypeType Server /api/playlists and /api/playlists/{id} models.
struct TVPlaylistDTO: Decodable, Identifiable {
    let id: String
    let name: String
    let description: String?
    let videos: [TVPlaylistVideoDTO]?
    let videoCount: Int?

    var count: Int { videoCount ?? videos?.count ?? 0 }
    var items: [VideoItem] { (videos ?? []).map(\.video) }
}

struct TVPlaylistVideoDTO: Decodable {
    let url: String
    let title: String
    let thumbnail: String
    let duration: Int
    let channelName: String?
    let channelUrl: String?
    let watchPosition: Int64?
    let watched: Bool?

    var video: VideoItem {
        var row = VideoItem(
            id: url, title: title, url: url,
            thumbnailUrl: thumbnail, uploaderName: channelName,
            duration: duration, isLive: false
        )
        row.uploaderUrl = channelUrl
        row.watchPositionMs = watchPosition
        row.watched = watched
        return row
    }
}

struct TVProgressBatchWrite: Encodable {
    let videoUrls: [String]
}

struct TVCreatePlaylistWrite: Encodable {
    let name: String
}

struct TVUpdatePlaylistWrite: Encodable {
    let name: String
    let description: String
}

struct TVPlaylistVideoWrite: Encodable {
    let url: String
    let title: String
    let thumbnail: String
    let duration: Int
    let channelName: String
    let channelUrl: String
    let channelAvatar: String

    init(video: VideoItem) {
        url = video.url
        title = video.title
        thumbnail = video.thumbnailUrl ?? ""
        duration = max(0, video.duration ?? 0)
        channelName = video.uploaderName ?? ""
        channelUrl = video.uploaderUrl ?? ""
        channelAvatar = ""
    }
}

struct TVBlockWrite: Encodable {
    let url: String
    let name: String?
    let thumbnailUrl: String?
}
