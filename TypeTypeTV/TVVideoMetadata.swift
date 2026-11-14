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
