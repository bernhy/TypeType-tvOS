import Foundation

/// The same read-only comment contract as the TypeType Server /comments API.
struct TVCommentsPage: Decodable {
    let comments: [TVCommentItem]
    let nextpage: String?
    let commentsDisabled: Bool?
}

struct TVCommentItem: Decodable, Identifiable {
    let id: String
    let text: String
    let author: String
    let authorUrl: String?
    let authorAvatarUrl: String?
    let likeCount: Int64?
    let textualLikeCount: String?
    let publishedTime: String?
    let isHeartedByUploader: Bool?
    let isPinned: Bool?
    let uploaderVerified: Bool?
    let replyCount: Int?
    let repliesPage: String?
    let image: TVCommentImage?
    let voiceReply: TVCommentVoiceReply?
}

struct TVCommentImage: Decodable {
    let url: String?
    let animated: Bool?
    let unavailableText: String?
}

struct TVCommentVoiceReply: Decodable {
    let url: String
    let durationMs: Int64
    let transcript: String?
    let playable: Bool
    let unavailableText: String?
}

/// Comments can contain YouTube HTML formatting, but SwiftUI Text must not
/// display raw markup or active untrusted HTML. Preserve readable spacing,
/// decode the common entities and leave unknown entities as literal text.
enum TVCommentText {
    static func plain(_ html: String) -> String {
        var result = html.replacingOccurrences(
            of: "<br\\s*/?>", with: "\n",
            options: [.regularExpression, .caseInsensitive]
        )
        result = result.replacingOccurrences(
            of: "</p>", with: "\n\n", options: .caseInsensitive
        )
        result = result.replacingOccurrences(
            of: "<[^>]*>", with: "", options: .regularExpression
        )
        for (entity, value) in [
            ("&nbsp;", " "), ("&quot;", "\""), ("&#39;", "'"),
            ("&lt;", "<"), ("&gt;", ">"), ("&amp;", "&")
        ] {
            result = result.replacingOccurrences(of: entity, with: value)
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
