import Foundation

/// Metadata is supplied by TypeType Server: viewCount and publishedAt are
/// first-class VideoItem fields. Avoid guessing from thumbnail text.
enum TVVideoMetadata {
    static func viewLabel(_ count: Int64, language: String = TVLanguages.activeLanguage) -> String? {
        guard count >= 0 else { return nil }
        let compact: String
        switch count {
        case 1_000_000_000...:
            compact = String(format: "%.1fB", Double(count) / 1_000_000_000)
        case 1_000_000...:
            compact = String(format: "%.1fM", Double(count) / 1_000_000)
        case 1_000...:
            compact = "\(Int((count + 500) / 1_000))K"
        default:
            compact = "\(count)"
        }
        return "\(compact) \(TVL10n.value("video.views", language: language))"
    }

    static func publicationDate(for video: VideoItem) -> Date? {
        if let timestamp = [video.publishedAt, video.uploaded]
            .compactMap({ $0 }).first(where: { $0 > 0 }) {
            // The TypeType frontend passes publishedAt directly to Date(),
            // so the server field is epoch milliseconds, NOT Unix seconds.
            return Date(timeIntervalSince1970: Double(timestamp) / 1_000)
        }
        guard let text = video.uploadDate, !text.isEmpty else { return nil }
        let parser = DateFormatter()
        parser.locale = Locale(identifier: "en_US_POSIX")
        parser.timeZone = TimeZone(secondsFromGMT: 0)
        parser.dateFormat = "yyyy-MM-dd"
        return parser.date(from: String(text.prefix(10)))
    }

    static func subtitle(for video: VideoItem,
                         now: Date = Date(),
                         language: String = TVLanguages.activeLanguage) -> String? {
        var parts: [String] = []
        if let count = video.viewCount,
           let label = viewLabel(count, language: language) {
            parts.append(label)
        }
        if let date = publicationDate(for: video) {
            let formatter = RelativeDateTimeFormatter()
            formatter.locale = TVLanguages.locale(for: language)
            formatter.unitsStyle = .full
            formatter.dateTimeStyle = .named
            parts.append(formatter.localizedString(for: date, relativeTo: now))
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

extension TVVideoMetadata {
    static func merged(_ video: VideoItem, stream: StreamInfo?) -> VideoItem {
        guard let stream else { return video }
        var row = video
        if row.viewCount == nil || row.viewCount! < 0 { row.viewCount = stream.viewCount }
        if row.publishedAt == nil || row.publishedAt! <= 0 { row.publishedAt = stream.publishedAt }
        if row.uploaded == nil || row.uploaded! <= 0 { row.uploaded = stream.uploaded }
        if row.uploadDate?.isEmpty != false { row.uploadDate = stream.uploadDate }
        if row.uploaderUrl?.isEmpty != false { row.uploaderUrl = stream.uploaderUrl }
        return row
    }
}

/// Deduplicated and bounded on-demand metadata lookups. /history has no
/// view-count/publication fields; /streams does. Limit the extraction load.
actor TVStreamMetadataCache {
    static let shared = TVStreamMetadataCache()
    private var completed: [String: StreamInfo] = [:]
    private var pending: [String: Task<StreamInfo?, Never>] = [:]
    private var failedUntil: [String: Date] = [:]
    private var active = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func details(for video: VideoItem, api: TypeTypeAPI) async -> StreamInfo? {
        let key = api.origin.absoluteString + "|" + video.url
        if let value = completed[key] { return value }
        if let until = failedUntil[key], until > Date() { return nil }
        if let task = pending[key] { return await task.value }
        let task = Task<StreamInfo?, Never> { await fetch(video: video, api: api) }
        pending[key] = task
        let result = await task.value
        pending[key] = nil
        if let result {
            if completed.count >= 128, let first = completed.keys.first {
                completed.removeValue(forKey: first)
            }
            completed[key] = result
            failedUntil[key] = nil
        } else {
            failedUntil[key] = Date().addingTimeInterval(120)
        }
        return result
    }

    private func fetch(video: VideoItem, api: TypeTypeAPI) async -> StreamInfo? {
        await acquire()
        defer { release() }
        guard !Task.isCancelled else { return nil }
        return try? await api.stream(for: video)
    }

    private func acquire() async {
        if active < 3 {
            active += 1
            return
        }
        await withCheckedContinuation { waiter in waiters.append(waiter) }
    }

    private func release() {
        if waiters.isEmpty { active -= 1 }
        else { waiters.removeFirst().resume() }
    }
}
