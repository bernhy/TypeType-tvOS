import Foundation
import Combine

/// Ephemeral presentation state: a newly watched video's thumbnail updates
/// immediately when returning to Home/Library, even before the server-side
/// progress checkpoint has completed. Not stored on Apple TV disk.
@MainActor
final class TVLocalProgress: ObservableObject {
    static let shared = TVLocalProgress()
    @Published private(set) var positions: [String: Int64] = [:]
    private init() {}

    func record(_ url: String, positionMs: Int64) {
        guard !url.isEmpty, positionMs >= 0 else { return }
        positions[url] = positionMs
        if let id = VideoAddress.youtubeID(url) {
            positions["youtube:" + id] = positionMs
        }
        TVVideoCardStatusCenter.changed(videoURL: url)
    }

    /// A YouTube video may enter the app through youtube.com or youtu.be.
    /// Preserve the exact URL and a canonical ID for instant cross-view updates.
    func position(for url: String) -> Int64? {
        if let id = VideoAddress.youtubeID(url),
           let shared = positions["youtube:" + id] { return shared }
        return positions[url]
    }

    func clear() {
        // Prevent playback progress from another account leaking into the
        // next account's thumbnail grid during a same-app sign-out/sign-in.
        positions.removeAll()
        TVVideoCardStatusCenter.changedAll()
    }
}

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
        guard policyAllowsHistory, !TVLiveStreamDisplayPolicy.isOngoing(video), positionMs >= 0 else { return }
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

/// TypeType 1.19.0: 0 = last minute (90% for videos up to 60 s);
/// 50...100 = explicit percentage. 90% is the tvOS fallback for older
/// servers with no setting. Both timestamps and positions are in milliseconds.
enum TVWatchedThresholdPolicy {
    static let defaultPercent = 90

    static func resolved(_ percent: Int?) -> Int {
        guard let percent else { return defaultPercent }
        return percent == 0 || (50...100).contains(percent)
            ? percent : defaultPercent
    }

    static func isComplete(durationSeconds: Int, positionMs: Int64,
                           thresholdPercent: Int = defaultPercent) -> Bool {
        guard durationSeconds > 0, positionMs > 0,
              durationSeconds <= Int64.max / 1_000 else { return false }
        let duration = Int64(durationSeconds)
        let percent = resolved(thresholdPercent)
        let cutoff = percent == 0
            ? (durationSeconds > 60 ? (duration - 60) * 1_000 : duration * 900)
            : duration * Int64(percent) * 10
        return positionMs >= cutoff
    }
}

/// Explicit progress 0 supersedes stale server-side watched flags.
/// Card, action, resume and playback use this one account-configured rule.
enum TVWatchedState {
    static func isWatched(_ video: VideoItem, positionMs: Int64?,
                          thresholdPercent: Int = TVWatchedThresholdPolicy.defaultPercent) -> Bool {
        guard !TVLiveStreamDisplayPolicy.isOngoing(video), let duration = video.duration,
              duration > 0 else { return false }
        if let positionMs {
            return TVWatchedThresholdPolicy.isComplete(
                durationSeconds: duration, positionMs: positionMs,
                thresholdPercent: thresholdPercent
            )
        }
        return video.watched == true
    }
}


/// The Home "Continue watching" rail shows started, not-yet-completed VODs.
/// This is intentionally distinct from the full Library → History list.
/// Progress is always in milliseconds; video.duration is in seconds.
enum TVContinueWatchingPolicy {
    static func isEligible(_ video: VideoItem, positionMs: Int64?,
                           thresholdPercent: Int = TVWatchedThresholdPolicy.defaultPercent) -> Bool {
        guard !TVLiveStreamDisplayPolicy.isOngoing(video), let positionMs, positionMs > 0,
              let duration = video.duration, duration > 0 else {
            return false
        }
        return !TVWatchedState.isWatched(
            video, positionMs: positionMs, thresholdPercent: thresholdPercent
        )
    }
}

/// Update one Home resume entry from the already-recorded local progress.
/// Do not fetch history, invalidate recommendations or duplicate YouTube URL
/// variants; newer playback moves an unfinished video to the shelf's front.
enum TVContinueWatchingLocalUpdate {
    static func applying(_ history: [VideoItem], video: VideoItem,
                         positionMs: Int64?,
                         thresholdPercent: Int = TVWatchedThresholdPolicy.defaultPercent) -> [VideoItem] {
        guard let positionMs else { return history }
        let key = TVHistoryDeduplicator.key(for: video)
        let previous = history.first { TVHistoryDeduplicator.key(for: $0) == key }
        // A sparse recommendation may omit duration, while its existing
        // history entry already knows it. Never invent duration metadata.
        let source = (video.duration ?? 0) > 0 ? video : (previous ?? video)
        var result = history.filter { TVHistoryDeduplicator.key(for: $0) != key }
        if TVContinueWatchingPolicy.isEligible(
            source, positionMs: positionMs, thresholdPercent: thresholdPercent
        ) {
            result.insert(source.withProgress(positionMs, thresholdPercent: thresholdPercent), at: 0)
        }
        return result
    }
}
