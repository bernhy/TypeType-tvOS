import Foundation

struct TVChannelPlaylistPage: Decodable {
    let playlists: [TVPublicPlaylistSummary]
    let nextpage: String?
}

struct TVCommunityPostsPage: Decodable {
    let channelName: String?
    let channelUrl: String?
    let posts: [TVCommunityPost]
    let nextpage: String?
}

struct TVCommunityPost: Decodable, Identifiable {
    let id: String
    let url: String?
    let type: String?
    let text: String?
    let authorName: String?
    let publishedTime: String?
    let images: [String]?
    let textualLikeCount: String?
    let textualCommentCount: String?
    let poll: TVCommunityPoll?
    let video: TVCommunityVideo?
}

struct TVCommunityPoll: Decodable {
    let type: String?
    let choices: [TVCommunityPollChoice]?
    let textualVoteCount: String?
}
struct TVCommunityPollChoice: Decodable, Identifiable {
    let text: String
    let imageUrl: String?
    var id: String { text }
}
struct TVCommunityVideo: Decodable {
    let url: String
    let title: String
    let thumbnailUrl: String?
    func videoItem(author: String?) -> VideoItem {
        VideoItem(id: url, title: title, url: url,
                  thumbnailUrl: thumbnailUrl, uploaderName: author,
                  duration: nil, isLive: false)
    }
}

struct TVPodcastPage: Decodable {
    let channelName: String?
    let channelUrl: String?
    let podcasts: [TVPublicPlaylistSummary]
    let episodes: [VideoItem]
    let nextpage: String?
}
struct TVPodcastEpisodesPage: Decodable {
    let podcast: TVPublicPlaylistSummary?
    let episodes: [VideoItem]
    let nextpage: String?
}
