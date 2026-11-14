import Foundation

struct TVSponsorBlockSegment: Decodable, Hashable {
    let startTime: Double
    let endTime: Double
    let category: String
    let action: String
}

/// Matches TypeType Server's category rules, for both SABR and HLS.
enum TVSponsorBlock {
    static let categories = [
        "sponsor", "selfpromo", "exclusive_access", "interaction",
        "poi_highlight", "intro", "outro", "preview", "filler",
        "chapter", "music_offtopic"
    ]
    static let defaults: [String: String] = [
        "sponsor": "auto_skip", "selfpromo": "auto_skip",
        "exclusive_access": "mark_only", "interaction": "auto_skip",
        "poi_highlight": "mark_only", "intro": "auto_skip",
        "outro": "auto_skip", "preview": "auto_skip",
        "filler": "auto_skip", "chapter": "mark_only",
        "music_offtopic": "auto_skip"
    ]

    static func titleKey(_ category: String) -> String {
        let components = category.split(separator: "_").map(String.init)
        return "sponsor." + (components.first ?? category) +
            components.dropFirst().map { $0.capitalized }.joined()
    }

    static func action(_ category: String, settings: TVServerSettings) -> String {
        settings.sponsorBlockCategoryActions?[category] ?? defaults[category] ?? "mark_only"
    }

    static func bounds(_ segment: TVSponsorBlockSegment, duration: Double) -> ClosedRange<Double>? {
        guard segment.startTime.isFinite && segment.endTime.isFinite else { return nil }
        let ms = duration > 0 && segment.endTime > duration + 30
        let factor = ms ? 0.001 : 1.0
        let start = max(0, segment.startTime * factor)
        let rawEnd = max(0, segment.endTime * factor)
        let end = duration > 0 ? min(duration, rawEnd) : rawEnd
        guard end > start else { return nil }
        return start...end
    }

    static func isFullVideo(_ range: ClosedRange<Double>, duration: Double) -> Bool {
        duration > 0 && range.lowerBound <= 5 && range.upperBound >= duration * 0.9
    }

    static func visible(_ segment: TVSponsorBlockSegment, settings: TVServerSettings,
                        duration: Double) -> Bool {
        guard settings.sponsorBlockMode != "disabled",
              (segment.category != "chapter" || settings.sponsorBlockShowChapters == true),
              action(segment.category, settings: settings) != "disabled",
              let range = bounds(segment, duration: duration),
              range.upperBound - range.lowerBound >=
                  Double(max(0, settings.sponsorBlockMinimumDuration ?? 0)) else { return false }
        return settings.sponsorBlockShowFullVideoLabels != false ||
            !isFullVideo(range, duration: duration)
    }

    static func shouldAutoSkip(_ segment: TVSponsorBlockSegment, settings: TVServerSettings,
                               duration: Double, streamCategory: String?) -> Bool {
        // SponsorBlock's 'mute', 'poi', 'chapter' and 'full' actions
        // are markers/other behaviors, never automatic seek requests.
        guard segment.action == "skip",
              (settings.sponsorBlockMode ?? "auto_skip") == "auto_skip",
              action(segment.category, settings: settings) == "auto_skip",
              visible(segment, settings: settings, duration: duration),
              let range = bounds(segment, duration: duration) else { return false }
        let length = range.upperBound - range.lowerBound
        guard length <= 1_800 && (duration <= 0 || length <= duration * 0.5),
              !(settings.sponsorBlockManualSkipOnFullVideo != false &&
                isFullVideo(range, duration: duration)) else { return false }
        if segment.category == "music_offtopic" &&
            settings.sponsorBlockSkipNonMusicOnlyOnMusicVideos == true {
            return streamCategory?.lowercased() == "music"
        }
        return true
    }

    static func target(segments: [TVSponsorBlockSegment], settings: TVServerSettings,
                       position: Double, duration: Double,
                       streamCategory: String?) -> Double? {
        guard position.isFinite, position >= 0 else { return nil }
        return segments.compactMap { segment -> Double? in
            guard shouldAutoSkip(segment, settings: settings,
                                 duration: duration, streamCategory: streamCategory),
                  let range = bounds(segment, duration: duration),
                  position >= range.lowerBound,
                  position < range.upperBound - 0.12 else { return nil }
            return range.upperBound
        }.max()
    }

    static func label(segments: [TVSponsorBlockSegment], settings: TVServerSettings,
                      position: Double, duration: Double) -> String? {
        guard settings.sponsorBlockMode != "disabled",
              settings.sponsorBlockShowCurrentSegment != false else { return nil }
        return segments.first(where: { segment in
            guard visible(segment, settings: settings, duration: duration),
                  let range = bounds(segment, duration: duration) else { return false }
            return position >= range.lowerBound && position < range.upperBound
        }).map { TVL10n.value(titleKey($0.category)) }
    }
}