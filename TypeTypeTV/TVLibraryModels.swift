import Foundation

/// The three user-data endpoints have distinct wire contracts.
/// The originals are declared in TypeType Server's HistoryItem, FavoriteItem,
/// and WatchLaterItem Kotlin data classes.
enum TVLibrarySection: String, CaseIterable, Identifiable {
    case history = "history"
    case favorites = "favorites"
    case watchLater = "watch-later"

    var id: String { rawValue }
    var title: String {
        switch self {
        case .history: return TVL10n.value("library.history")
        case .favorites: return TVL10n.value("library.favorites")
        case .watchLater: return TVL10n.value("library.watchLater")
        }
    }
    var symbol: String {
        switch self {
        case .history: return "clock.arrow.circlepath"
        case .favorites: return "heart"
        case .watchLater: return "bookmark"
        }
    }
    var emptyMessage: String {
        switch self {
        case .history: return TVL10n.value("library.historyEmpty")
        case .favorites: return TVL10n.value("library.favoritesEmpty")
        case .watchLater: return TVL10n.value("library.watchLaterEmpty")
        }
    }
}

struct TVHistoryDTO: Decodable {
    let id: String
    let url: String
    let title: String
    let thumbnail: String
    let channelName: String
    let duration: Int
    let progress: Int
    let channelUrl: String?
    let viewCount: Int64?
    let publishedAt: Int64?

    var video: VideoItem {
        var row = VideoItem(id: url, title: title, url: url, thumbnailUrl: thumbnail,
                            uploaderName: channelName, duration: duration, isLive: false)
        row.uploaderUrl = channelUrl
        row.viewCount = viewCount
        row.publishedAt = publishedAt
        row.watchPositionMs = Int64(max(0, progress)) * 1_000
        return row
    }
}

struct TVFavoriteDTO: Decodable {
    let videoUrl: String
    let title: String
    let thumbnail: String
    let channelName: String
    let duration: Int
    let channelUrl: String?
    let viewCount: Int64?
    let publishedAt: Int64?

    var video: VideoItem {
        var row = VideoItem(id: videoUrl, title: title, url: videoUrl, thumbnailUrl: thumbnail,
                            uploaderName: channelName, duration: duration, isLive: false)
        row.uploaderUrl = channelUrl
        row.viewCount = viewCount
        row.publishedAt = publishedAt
        return row
    }
}

struct TVWatchLaterDTO: Decodable {
    let url: String
    let title: String
    let thumbnail: String
    let channelName: String
    let duration: Int
    let channelUrl: String?
    let viewCount: Int64?
    let publishedAt: Int64?

    var video: VideoItem {
        var row = VideoItem(id: url, title: title, url: url, thumbnailUrl: thumbnail,
                            uploaderName: channelName, duration: duration, isLive: false)
        row.uploaderUrl = channelUrl
        row.viewCount = viewCount
        row.publishedAt = publishedAt
        return row
    }
}
