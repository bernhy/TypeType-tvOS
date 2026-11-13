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
        case .history: return "Verlauf"
        case .favorites: return "Favoriten"
        case .watchLater: return "Später ansehen"
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
        case .history: return "Dein Wiedergabeverlauf ist noch leer."
        case .favorites: return "Du hast noch keine Videos als Favoriten markiert."
        case .watchLater: return "In deiner Merkliste sind noch keine Videos."
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

    var video: VideoItem {
        VideoItem(id: url, title: title, url: url, thumbnailUrl: thumbnail,
                  uploaderName: channelName, duration: duration, isLive: false)
    }
}

struct TVFavoriteDTO: Decodable {
    let videoUrl: String
    let title: String
    let thumbnail: String
    let channelName: String
    let duration: Int

    var video: VideoItem {
        VideoItem(id: videoUrl, title: title, url: videoUrl, thumbnailUrl: thumbnail,
                  uploaderName: channelName, duration: duration, isLive: false)
    }
}

struct TVWatchLaterDTO: Decodable {
    let url: String
    let title: String
    let thumbnail: String
    let channelName: String
    let duration: Int

    var video: VideoItem {
        VideoItem(id: url, title: title, url: url, thumbnailUrl: thumbnail,
                  uploaderName: channelName, duration: duration, isLive: false)
    }
}
