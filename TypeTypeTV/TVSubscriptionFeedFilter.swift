import Foundation

/// The server exposes two stable cursor orders for the account's feed.
/// Unlike grouping/ordering, date selection is intentionally local: changing
/// it does not invalidate or rebuild the server's subscription snapshot.
enum TVSubscriptionFeedOrder: String, CaseIterable {
    case newest, oldest
}

enum TVSubscriptionFeedDateRange: String, CaseIterable {
    case all, today, week, month
}

enum TVSubscriptionFeedFilter {
    static func contains(_ video: VideoItem, dateRange: TVSubscriptionFeedDateRange,
                         now: Date = Date(), calendar: Calendar = .current) -> Bool {
        guard dateRange != .all else { return true }
        guard let date = TVVideoMetadata.publicationDate(for: video) else {
            // An unknown publication date is not evidence that a video
            // belongs to today, this week or this month.
            return false
        }
        switch dateRange {
        case .all: return true
        case .today:
            return calendar.isDate(date, inSameDayAs: now)
        case .week:
            return calendar.dateInterval(of: .weekOfYear, for: now)?.contains(date) == true
        case .month:
            return calendar.dateInterval(of: .month, for: now)?.contains(date) == true
        }
    }

    static func visible(_ videos: [VideoItem],
                        hideWatched: Bool,
                        dateRange: TVSubscriptionFeedDateRange,
                        thresholdPercent: Int,
                        now: Date = Date(),
                        calendar: Calendar = .current,
                        position: (VideoItem) -> Int64?) -> [VideoItem] {
        videos.filter { item in
            contains(item, dateRange: dateRange, now: now, calendar: calendar) &&
                (!hideWatched ||
                 !TVWatchedState.isWatched(
                    item, positionMs: position(item),
                    thresholdPercent: thresholdPercent
                 ))
        }
    }
}

/// 1.20.0's auto-load fix: the end-of-list sentinel may fetch at most
/// three consecutive pages that add no visible videos. A manual "Load more"
/// remains available, even when the entire current page is filtered out.
enum TVSubscriptionAutoLoadPolicy {
    static let maximumEmptyPages = 3

    static func nextStreak(_ current: Int, visibleBefore: Int,
                           visibleAfter: Int) -> Int {
        visibleAfter > visibleBefore ? 0 : current + 1
    }

    static func mayAutoLoad(_ streak: Int) -> Bool {
        streak < maximumEmptyPages
    }
}
