import Foundation
import SwiftUI

/// TypeType Server /api/dearrow contract. Never query the third-party
/// DeArrow service directly or leak account credentials to image CDNs.
struct TVDeArrowItem: Decodable {
    let videoId: String
    let titles: [TVDeArrowTitleCandidate]
    let thumbnails: [TVDeArrowThumbnailCandidate]
    let randomTime: Double?
    let videoDuration: Double?
}

struct TVDeArrowTitleCandidate: Decodable {
    let title: String
    let original: Bool
    let votes: Int
    let locked: Bool
}

struct TVDeArrowThumbnailCandidate: Decodable {
    let timestamp: Double?
    let original: Bool
    let votes: Int
    let locked: Bool
}

struct TVDeArrowDisplay {
    let title: String?
    let thumbnailURL: URL?
}

/// DeArrow is an opt-in replacement, NOT a fallback image source. If no
/// eligible branded/random image exists, pass nil so the existing TypeType
/// original -> TypeType proxy HQ/MQ -> YouTube HQ/MQ chain remains intact.
enum TVDeArrowPolicy {
    static func enabled(_ settings: TVServerSettings?) -> Bool {
        settings?.deArrowEnabled == true
    }

    static func requiresLookup(_ settings: TVServerSettings?) -> Bool {
        enabled(settings) &&
            (settings?.deArrowTitleMode != "original" ||
             settings?.deArrowThumbnailMode != "original")
    }

    static func signature(_ settings: TVServerSettings?) -> String {
        guard enabled(settings) else { return "off" }
        return "on|\(settings?.deArrowTitleMode ?? "dearrow")|" +
            "\(settings?.deArrowThumbnailMode ?? "dearrow_or_random")|" +
            "\(settings?.deArrowTrustMode ?? "accepted")"
    }

    static func key(video: VideoItem, api: TypeTypeAPI,
                    settings: TVServerSettings?) -> String? {
        guard requiresLookup(settings),
              !TVLiveStreamDisplayPolicy.isOngoing(video),
              let id = VideoAddress.youtubeID(video.url) else { return nil }
        return api.metadataCacheScope + "|dearrow|" + id + "|" + signature(settings)
    }

    static func display(_ item: TVDeArrowItem, videoID: String,
                        origin: URL, settings: TVServerSettings) -> TVDeArrowDisplay? {
        guard enabled(settings), item.videoId == videoID else { return nil }
        let lockedOnly = settings.deArrowTrustMode == "locked"
        func trusted(votes: Int, locked: Bool, original: Bool) -> Bool {
            !original && (lockedOnly ? locked : (locked || votes >= 0))
        }

        var title: String?
        if settings.deArrowTitleMode != "original" {
            title = item.titles.first {
                trusted(votes: $0.votes, locked: $0.locked, original: $0.original)
            }?.title.trimmingCharacters(in: .whitespacesAndNewlines)
            if title?.isEmpty == true { title = nil }
        }

        let mode = settings.deArrowThumbnailMode ?? "dearrow_or_random"
        let accepted = item.thumbnails.first {
            trusted(votes: $0.votes, locked: $0.locked, original: $0.original) &&
                ($0.timestamp?.isFinite == true) && ($0.timestamp ?? 0) > 0
        }?.timestamp
        let random: Double? = {
            guard let fraction = item.randomTime, fraction.isFinite,
                  (0...1).contains(fraction),
                  let duration = item.videoDuration, duration.isFinite,
                  duration > 0 else { return nil }
            let time = fraction * duration
            return time.isFinite && time > 0 ? time : nil
        }()
        let timestamp: Double?
        switch mode {
        case "original": timestamp = nil
        case "dearrow": timestamp = accepted
        case "random": timestamp = random
        default: timestamp = accepted ?? random
        }

        var thumbnail: URL?
        if let timestamp, timestamp > 0 {
            var components = URLComponents(
                url: origin.appendingPathComponent("api/dearrow/thumbnail"),
                resolvingAgainstBaseURL: false
            )
            components?.queryItems = [
                URLQueryItem(name: "videoId", value: videoID),
                URLQueryItem(name: "time", value: String(format: "%.3f", locale:
                    Locale(identifier: "en_US_POSIX"), timestamp))
            ]
            thumbnail = components?.url
        }
        if title == nil && thumbnail == nil { return nil }
        return TVDeArrowDisplay(title: title, thumbnailURL: thumbnail)
    }
}

/// Only three server-side branding lookups may be active. A fast scrolling
/// grid never starts all metadata requests at once, unlike the image worker.
private actor TVDeArrowRequestGate {
    static let shared = TVDeArrowRequestGate()
    private var active = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    private func acquire() async {
        if active < 3 { active += 1; return }
        await withCheckedContinuation { waiters.append($0) }
    }

    private func release() {
        if waiters.isEmpty { active -= 1 }
        else { waiters.removeFirst().resume() }
    }

    func fetch(api: TypeTypeAPI, videoID: String) async -> TVDeArrowItem? {
        await acquire()
        defer { release() }
        return try? await api.deArrow(videoID: videoID)
    }
}

/// One lightweight, bounded account/mode-scoped metadata cache. No focus
/// observers, polling, persistent per-tile state or repeated network fetches
/// when the user moves between Home, History and Video Details.
@MainActor
final class TVDeArrowCache {
    static let shared = TVDeArrowCache()

    private struct Entry {
        let value: TVDeArrowDisplay?
        let expires: Date
    }

    private var entries: [String: Entry] = [:]
    private var inFlight: [String: Task<TVDeArrowDisplay?, Never>] = [:]
    private let capacity = 192
    private let maximumPending = 32

    private init() {}

    func hasResult(for video: VideoItem, api: TypeTypeAPI,
                   settings: TVServerSettings?) -> Bool {
        guard let key = TVDeArrowPolicy.key(video: video, api: api,
                                          settings: settings),
              let entry = entries[key] else { return false }
        return entry.expires > Date()
    }

    func cached(for video: VideoItem, api: TypeTypeAPI,
                settings: TVServerSettings?) -> TVDeArrowDisplay? {
        guard let key = TVDeArrowPolicy.key(video: video, api: api,
                                          settings: settings),
              let entry = entries[key], entry.expires > Date()
        else { return nil }
        return entry.value
    }

    func resolve(for video: VideoItem, api: TypeTypeAPI,
                 settings: TVServerSettings?) async -> TVDeArrowDisplay? {
        guard let key = TVDeArrowPolicy.key(video: video, api: api,
                                          settings: settings),
              let id = VideoAddress.youtubeID(video.url),
              let settings else { return nil }

        if let entry = entries[key], entry.expires > Date() { return entry.value }
        if let pending = inFlight[key] { return await pending.value }
        // Navigating a huge feed must not queue unbounded lookup tasks.
        guard inFlight.count < maximumPending else { return nil }

        let task = Task<TVDeArrowDisplay?, Never> { @MainActor in
            let item = await TVDeArrowRequestGate.shared.fetch(api: api, videoID: id)
            let result = item.flatMap {
                TVDeArrowPolicy.display($0, videoID: id, origin: api.origin,
                                       settings: settings)
            }
            // Cache *inside* the shared Task before notifying all waiters.
            // Otherwise Top Shelf can observe a finished coalesced lookup
            // before the card's original caller has populated the cache.
            self.remember(result, key: key)
            return result
        }
        inFlight[key] = task
        let value = await task.value
        inFlight[key] = nil
        return value
    }

    private func remember(_ value: TVDeArrowDisplay?, key: String) {
        if entries.count >= capacity {
            let now = Date()
            entries = entries.filter { $0.value.expires > now }
            if entries.count >= capacity, let oldest = entries.min(
                by: { $0.value.expires < $1.value.expires }
            ) {
                entries[oldest.key] = nil
            }
        }
        entries[key] = Entry(value: value, expires:
            Date().addingTimeInterval(value == nil ? 90 : 3600))
    }
}

/// Attach a task only when DeArrow is enabled and a YouTube video is
/// visible. The ordinary card remains task-free when DeArrow is off.
struct TVDeArrowCardTask: ViewModifier {
    let video: VideoItem
    let api: TypeTypeAPI
    let settings: TVServerSettings?
    @Binding var selectedKey: String?
    @Binding var selected: TVDeArrowDisplay?

    @ViewBuilder
    func body(content: Content) -> some View {
        if let key = TVDeArrowPolicy.key(video: video, api: api,
                                        settings: settings) {
            content.task(id: key) {
                selectedKey = key
                selected = nil
                let result = await TVDeArrowCache.shared.resolve(
                    for: video, api: api, settings: settings
                )
                guard !Task.isCancelled else { return }
                selected = result
            }
        } else {
            content
        }
    }
}
