import Foundation

/// Account-wide TypeType Server API v1 preference fields.
/// Optional values allow compatible servers with older/defaulted settings.
struct TVServerSettings: Decodable {
    var hideHomeRecommendations: Bool?
    var hideContinueWatching: Bool?
    var hideRelatedVideos: Bool?
    var hideShorts: Bool?
    var hideComments: Bool?
    var disableWatchHistory: Bool?
    var subtitlesEnabled: Bool?
    var autoplay: Bool?
    var sponsorBlockMode: String?
    var defaultQuality: String?

    func enabled(_ field: TVServerToggle) -> Bool {
        let hidden: Bool
        switch field {
        case .recommendations: hidden = hideHomeRecommendations ?? false
        case .continueWatching: hidden = hideContinueWatching ?? false
        case .relatedVideos: hidden = hideRelatedVideos ?? false
        case .shorts: hidden = hideShorts ?? false
        case .comments: hidden = hideComments ?? false
        case .watchHistory: hidden = disableWatchHistory ?? false
        }
        return !hidden
    }

    mutating func setEnabled(_ field: TVServerToggle, _ enabled: Bool) {
        let hidden = !enabled
        switch field {
        case .recommendations: hideHomeRecommendations = hidden
        case .continueWatching: hideContinueWatching = hidden
        case .relatedVideos: hideRelatedVideos = hidden
        case .shorts: hideShorts = hidden
        case .comments: hideComments = hidden
        case .watchHistory: disableWatchHistory = hidden
        }
    }
}

enum TVServerToggle: String, CaseIterable, Identifiable {
    case recommendations = "hideHomeRecommendations"
    case continueWatching = "hideContinueWatching"
    case relatedVideos = "hideRelatedVideos"
    case shorts = "hideShorts"
    case comments = "hideComments"
    case watchHistory = "disableWatchHistory"
    var id: String { rawValue }

    var titleKey: String {
        switch self {
        case .recommendations: return "settings.remoteRecommendations"
        case .continueWatching: return "settings.remoteContinue"
        case .relatedVideos: return "settings.remoteRelated"
        case .shorts: return "settings.remoteShorts"
        case .comments: return "settings.remoteComments"
        case .watchHistory: return "settings.remoteWatchHistory"
        }
    }
}

enum TVSettingValue: Encodable {
    case boolean(Bool)
    case text(String)
    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .boolean(let v): try container.encode(v)
        case .text(let v): try container.encode(v)
        }
    }
}
