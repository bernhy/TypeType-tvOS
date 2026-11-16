import Foundation

struct TVSearchFilterOption: Decodable, Identifiable, Hashable {
    let value: String
    let label: String
    let isDefault: Bool?
    var id: String { value }
}

struct TVSearchFilterGroup: Decodable, Identifiable {
    let key: String
    let label: String
    let multiSelect: Bool
    let options: [TVSearchFilterOption]
    var id: String { key }
}

struct TVSearchFiltersResponse: Decodable {
    let contentFilters: [TVSearchFilterOption]
    let sortFilters: [TVSearchFilterOption]
    let filterGroups: [TVSearchFilterGroup]
}

struct TVChannelSearchResult: Decodable, Identifiable {
    let id: String
    let name: String
    let url: String
    let thumbnailUrl: String?
    let description: String?
    let subscriberCount: Int64?
    let streamCount: Int64?
    let isVerified: Bool?
}

struct TVPublicPlaylistSummary: Decodable, Identifiable {
    let id: String
    let title: String
    let url: String
    let thumbnailUrl: String?
    let uploaderName: String?
    let streamCount: Int?
    let playlistType: String?
}

struct TVPublicPlaylistPage: Decodable {
    let playlist: TVPublicPlaylistSummary?
    let videos: [VideoItem]
    let nextpage: String?
}
