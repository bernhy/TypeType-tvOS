import Foundation

enum TVBlockedCategory: String {
    case videos, channels, keywords
}

struct TVBlockedItem: Decodable, Identifiable {
    let url: String
    let name: String?
    let thumbnailUrl: String?
    let blockedAt: Int64?
    let global: Bool?
    var id: String { url }
}

struct TVBlockedKeyword: Decodable, Identifiable {
    let keyword: String
    let blockedAt: Int64?
    let global: Bool?
    var id: String { keyword }
}

struct TVBlockedKeywordWrite: Encodable {
    let keyword: String
}

/// Never allow a blocked value to insert extra path segments. This matches
/// the Server's variadic tail paths for video/channel URLs and keywords.
enum TVBlockedRoutes {
    static func itemURL(base: URL, category: TVBlockedCategory, key: String) throws -> URL {
        guard !key.isEmpty else { throw TypeTypeError.invalidServerAddress }
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "/:?#%")
        guard let encoded = key.addingPercentEncoding(withAllowedCharacters: allowed),
              var result = URLComponents(
                url: base.appendingPathComponent("blocked/" + category.rawValue,
                                                 isDirectory: true),
                resolvingAgainstBaseURL: false
              ) else { throw TypeTypeError.invalidServerAddress }
        result.percentEncodedPath += encoded
        guard let url = result.url else { throw TypeTypeError.invalidServerAddress }
        return url
    }
}
