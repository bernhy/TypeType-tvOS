import Foundation
import XCTest
@testable import TypeTypeTV

final class TVSubscriptionFeedFilterTests: XCTestCase {
    private func item(_ id: String, date: Date?, watched: Bool = false,
                      position: Int64? = nil, live: Bool = false) -> VideoItem {
        var video = VideoItem(
            id: id, title: id, url: "https://youtu.be/\(id)",
            thumbnailUrl: nil, uploaderName: nil,
            duration: 600, isLive: live
        )
        video.publishedAt = date.map {
            Int64($0.timeIntervalSince1970 * 1_000)
        }
        video.watchPositionMs = position
        video.watched = watched
        return video
    }

    func testDateRangesUseCalendarDayWeekAndMonthNotFetchedPageNumber() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        calendar.firstWeekday = 2 // Monday
        let now = try XCTUnwrap(calendar.date(from:
            DateComponents(year: 2026, month: 11, day: 26, hour: 12)))
        func date(_ month: Int, _ day: Int) -> Date {
            calendar.date(from: DateComponents(
                year: 2026, month: month, day: day, hour: 10
            ))!
        }
        let videos = [
            item("today", date: date(11, 26)),
            item("thisweek", date: date(11, 23)),
            item("thismonth", date: date(11, 2)),
            item("older", date: date(10, 31)),
            item("nodate", date: nil)
        ]
        func filtered(_ range: TVSubscriptionFeedDateRange) -> [String] {
            TVSubscriptionFeedFilter.visible(
                videos, hideWatched: false, dateRange: range,
                thresholdPercent: 0, now: now, calendar: calendar,
                position: { $0.watchPositionMs }
            ).map(\.id)
        }
        XCTAssertEqual(filtered(.all),
                       ["today", "thisweek", "thismonth", "older", "nodate"])
        XCTAssertEqual(filtered(.today), ["today"])
        XCTAssertEqual(filtered(.week), ["today", "thisweek"])
        XCTAssertEqual(filtered(.month), ["today", "thisweek", "thismonth"])
    }

    func testWatchedFilterUsesSameAccountThresholdAndKeepsLive() {
        let videos = [
            item("watched", date: nil, position: 550_000),
            item("unwatched", date: nil, position: 490_000),
            item("live", date: nil, position: 600_000, live: true)
        ]
        let hidden = TVSubscriptionFeedFilter.visible(
            videos, hideWatched: true, dateRange: .all,
            thresholdPercent: 0, position: { $0.watchPositionMs }
        )
        XCTAssertEqual(hidden.map(\.id), ["unwatched", "live"])
        let strict = TVSubscriptionFeedFilter.visible(
            videos, hideWatched: true, dateRange: .all,
            thresholdPercent: 100, position: { $0.watchPositionMs }
        )
        XCTAssertEqual(strict.map(\.id),
                       ["watched", "unwatched", "live"])
        let displayed = TVSubscriptionFeedFilter.visible(
            videos, hideWatched: false, dateRange: .all,
            thresholdPercent: 0, position: { $0.watchPositionMs }
        )
        XCTAssertEqual(displayed.count, 3)
    }

    func testLocalProgressOverridesStaleServerCompletionForUnwatch() {
        let video = item("watched", date: nil, watched: true, position: 600_000)
        let filtered = TVSubscriptionFeedFilter.visible(
            [video], hideWatched: true, dateRange: .all, thresholdPercent: 0,
            position: { _ in 0 }
        )
        XCTAssertEqual(filtered.count, 1,
                       "Explicit zero progress must restore a previously watched card")
    }

    func testThreeConsecutiveEmptyPagesRequireManualResume() {
        var streak = 0
        for _ in 0..<3 {
            XCTAssertTrue(TVSubscriptionAutoLoadPolicy.mayAutoLoad(streak))
            streak = TVSubscriptionAutoLoadPolicy.nextStreak(
                streak, visibleBefore: 2, visibleAfter: 2
            )
        }
        XCTAssertEqual(streak, 3)
        XCTAssertFalse(TVSubscriptionAutoLoadPolicy.mayAutoLoad(streak))
        XCTAssertEqual(TVSubscriptionAutoLoadPolicy.nextStreak(
            streak, visibleBefore: 2, visibleAfter: 4
        ), 0, "A page containing visible videos must reset the streak")
        XCTAssertTrue(TVSubscriptionAutoLoadPolicy.mayAutoLoad(0))
    }

    func testServerWatchedPreferenceDefaultsToShowAndDecodesTrue() throws {
        let missing = try JSONDecoder().decode(
            TVServerSettings.self, from: Data("{}".utf8)
        )
        XCTAssertNil(missing.hideWatchedSubscriptionVideos)
        let enabled = try JSONDecoder().decode(
            TVServerSettings.self,
            from: Data(#"{"hideWatchedSubscriptionVideos":true}"#.utf8)
        )
        XCTAssertEqual(enabled.hideWatchedSubscriptionVideos, true)
    }
}
