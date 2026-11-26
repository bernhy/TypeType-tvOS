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
    private static func dateWindow(
        for dateRange: TVSubscriptionFeedDateRange,
        now: Date, calendar: Calendar
    ) -> DateInterval? {
        switch dateRange {
        case .all: return nil
        case .today: return calendar.dateInterval(of: .day, for: now)
        case .week: return calendar.dateInterval(of: .weekOfYear, for: now)
        case .month: return calendar.dateInterval(of: .month, for: now)
        }
    }

    static func contains(_ video: VideoItem, dateRange: TVSubscriptionFeedDateRange,
                         now: Date = Date(), calendar: Calendar = .current) -> Bool {
        guard dateRange != .all else { return true }
        guard let window = dateWindow(for: dateRange, now: now, calendar: calendar),
              let date = TVVideoMetadata.publicationDate(for: video) else {
            // Missing dates are not evidence of this day/week/month.
            return false
        }
        return window.contains(date)
    }

    static func visible(_ videos: [VideoItem],
                        hideWatched: Bool,
                        dateRange: TVSubscriptionFeedDateRange,
                        thresholdPercent: Int,
                        now: Date = Date(),
                        calendar: Calendar = .current,
                        position: (VideoItem) -> Int64?) -> [VideoItem] {
        // Calculate the local calendar boundary ONCE per grid snapshot,
        // not separately for every thumbnail on a Siri Remote focus move.
        let window = dateWindow(for: dateRange, now: now, calendar: calendar)
        return videos.filter { item in
            if dateRange != .all {
                guard let window,
                      let published = TVVideoMetadata.publicationDate(for: item),
                      window.contains(published) else { return false }
            }
            return !hideWatched || !TVWatchedState.isWatched(
                item, positionMs: position(item),
                thresholdPercent: thresholdPercent
            )
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
