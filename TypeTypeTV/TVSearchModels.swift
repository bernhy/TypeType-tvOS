import Foundation

struct TVSearchHistoryItem: Decodable, Identifiable, Equatable {
    let id: String
    let term: String
    let searchedAt: Int64?
}

struct TVSearchHistoryWrite: Encodable {
    let term: String
}

/// Keep server IDs and ordering; only compress repeated labels for the TV rail.
enum TVSearchHistoryPresentation {
    static let displayLimit = 8

    static func visible(_ entries: [TVSearchHistoryItem]) -> [TVSearchHistoryItem] {
        var seen = Set<String>()
        var output: [TVSearchHistoryItem] = []
        for item in entries {
            let text = item.term.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            let key = text.folding(options: [.caseInsensitive],
                                   locale: Locale(identifier: "en_US_POSIX"))
            guard seen.insert(key).inserted else { continue }
            output.append(TVSearchHistoryItem(id: item.id, term: text,
                                              searchedAt: item.searchedAt))
            if output.count == displayLimit { break }
        }
        return output
    }
}

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
