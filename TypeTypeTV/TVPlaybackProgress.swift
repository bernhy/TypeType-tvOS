import Foundation

struct TVProgressDTO: Decodable {
    let videoUrl: String?
    let position: Int64
}

struct TVSaveProgressWrite: Encodable {
    let position: Int64
}

struct TVHistoryWrite: Encodable {
    let url: String
    let title: String
    let thumbnail: String
    let duration: Int
    let channelName: String
    let channelUrl: String
    let channelAvatar: String
    let progress: Int64

    init(video: VideoItem, positionMs: Int64) {
        url = video.url
        title = video.title
        thumbnail = video.thumbnailUrl ?? ""
        duration = max(0, video.duration ?? 0)
        channelName = video.uploaderName ?? ""
        channelUrl = video.uploaderUrl ?? ""
        channelAvatar = ""
        progress = max(0, positionMs / 1_000)
    }
}

/// Serializes progress writes across seeks and restarts. Earlier checkpoints
/// cannot race a newer checkpoint onto the account. A failed write does not
/// block subsequent attempts, and failures never create a local false-success.
actor TVPlaybackProgressWriter {
    private var lastWrite: Task<Void, Never>?
    private var lastRequestedMs: Int64?
    private var policyAllowsHistory = false

    func enable(_ enabled: Bool) { policyAllowsHistory = enabled }

    func checkpoint(api: TypeTypeAPI, video: VideoItem, positionMs: Int64,
                    started: Bool = false, force: Bool = false) {
        guard policyAllowsHistory, video.isLive != true, positionMs >= 0 else { return }
        if !force, let last = lastRequestedMs,
           abs(last - positionMs) < 5_000 { return }
        lastRequestedMs = positionMs
        let predecessor = lastWrite
        lastWrite = Task {
            await predecessor?.value
            if started {
                try? await api.addHistory(video: video, milliseconds: positionMs)
            }
            try? await api.savePosition(videoURL: video.url, milliseconds: positionMs)
        }
    }

    func flush() async { await lastWrite?.value }
}
