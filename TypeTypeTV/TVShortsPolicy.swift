import Foundation

/// Shorts are identified by TypeType Server or a genuine YouTube Shorts URL.
/// Duration alone never establishes Shorts identity.
enum TVShortsPolicy {
    static func isShort(isShortFormContent: Bool?, url: String) -> Bool {
        if isShortFormContent == true { return true }
        guard let parsed = URLComponents(string: url),
              let host = parsed.host?.lowercased(),
              ["youtube.com", "www.youtube.com", "m.youtube.com"].contains(host),
              parsed.path.hasPrefix("/shorts/"),
              VideoAddress.youtubeID(url) != nil else { return false }
        return true
    }

    /// Only initial opens ignore saved position. Explicit seek and quality
    /// changes keep their current position within the same playback.
    static func startPositionMs(video: VideoItem,
                                explicitPositionMs: Int64?,
                                savedPositionMs: Int64?) -> Int64 {
        if let explicitPositionMs { return max(0, explicitPositionMs) }
        if video.isShort { return 0 }
        return max(0, savedPositionMs ?? 0)
    }

    static func knownDurationSeconds(video: VideoItem, stream: StreamInfo?) -> Int? {
        if let duration = video.duration, duration > 0 { return duration }
        if let duration = stream?.duration, duration > 0 { return duration }
        return nil
    }
}
