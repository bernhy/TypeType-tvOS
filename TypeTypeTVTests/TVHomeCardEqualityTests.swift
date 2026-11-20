import XCTest
@testable import TypeTypeTV

final class TVHomeCardEqualityTests: XCTestCase {

    func testResumeMetadataPolicyOnlyRequestsIncompleteCards() {
        var video = VideoItem(
            id: "a", title: "Resume", url: "https://youtu.be/ABCDEFGHIJK",
            thumbnailUrl: nil, uploaderName: "Channel", duration: 180, isLive: false
        )
        XCTAssertEqual(TVHomeResumeMetadataPolicy.visibleCards, 4)
        XCTAssertEqual(TVHomeResumeMetadataPolicy.preloadCards, 3)
        XCTAssertEqual(TVHomeResumeMetadataPolicy.maxTrackedCards, 7)
        XCTAssertTrue(TVHomeResumeMetadataPolicy.needsLookup(video))
        video.viewCount = 1_230
        XCTAssertTrue(TVHomeResumeMetadataPolicy.needsLookup(video))
        video.publishedAt = 1_800_000_000_000
        XCTAssertFalse(TVHomeResumeMetadataPolicy.needsLookup(video))
        video.viewCount = 0
        XCTAssertTrue(TVHomeResumeMetadataPolicy.needsLookup(video))
    }

    @MainActor
    func testResumeMetadataLoaderDeduplicatesVisibleRequestsAndBatches() async throws {
        let api = try TypeTypeAPI(address: "https://example.com")
        let metadata = try JSONDecoder().decode(StreamInfo.self, from: Data(
            #"{"viewCount":5123,"publishedAt":1800000000000}"#.utf8
        ))
        func row(_ id: String) -> VideoItem {
            VideoItem(
                id: id, title: id, url: "https://youtu.be/\(id)",
                thumbnailUrl: nil, uploaderName: "Channel", duration: 120,
                isLive: false
            )
        }
        var running = 0
        var highestRunning = 0
        var lookups: [String] = []
        let loader = TVHomeResumeMetadataLoader(fetch: { video, _ in
            running += 1
            highestRunning = max(highestRunning, running)
            lookups.append(video.url)
            try? await Task.sleep(for: .milliseconds(40))
            running -= 1
            return metadata
        })
        let received = expectation(description: "One batch for two visible cards")
        var batches = 0
        var merged: [String: StreamInfo] = [:]
        let onBatch: ([String: StreamInfo]) -> Void = { data in
            batches += 1
            merged.merge(data, uniquingKeysWith: { _, latest in latest })
            if merged.count == 2 { received.fulfill() }
        }
        let first = row("ABCDEFGHIJK")
        let second = row("LMNOPQRSTUV")
        let offscreen = row("WXYZabcdefg")
        loader.appear(video: first, api: api, onBatch: onBatch)
        loader.appear(video: first, api: api, onBatch: onBatch)
        loader.appear(video: second, api: api, onBatch: onBatch)
        loader.appear(video: offscreen, api: api, onBatch: onBatch)
        loader.disappear(offscreen)
        await fulfillment(of: [received], timeout: 5)
        XCTAssertEqual(highestRunning, 2, "Two visible cards fetch concurrently")
        XCTAssertEqual(lookups.count, 2, "Duplicated/offscreen cards do not fetch")
        XCTAssertEqual(batches, 1, "Results are applied in one idle batch")
        XCTAssertEqual(merged.count, 2)
        loader.stop()
    }

    @MainActor
    func testResumeMetadataLoaderCapsParallelRequestsAtThree() async throws {
        let api = try TypeTypeAPI(address: "https://example.com")
        let metadata = try JSONDecoder().decode(StreamInfo.self, from: Data(
            #"{"viewCount":515,"publishedAt":1800000000000}"#.utf8
        ))
        var active = 0
        var maximumActive = 0
        var requested: [String] = []
        let loader = TVHomeResumeMetadataLoader(fetch: { video, _ in
            active += 1
            maximumActive = max(maximumActive, active)
            requested.append(video.url)
            // Long enough that the first three requests overlap and the
            // fourth/fifth must wait until a concurrency slot is free.
            try? await Task.sleep(for: .milliseconds(180))
            active -= 1
            return metadata
        })
        let received = expectation(description: "Five results loaded")
        var combined: [String: StreamInfo] = [:]
        let ids = [
            "ABCDEFGHIJK", "LMNOPQRSTUV", "WXYZabcdefg",
            "hijkLMNopqr", "stuvwXYZabc"
        ]
        for id in ids {
            let row = VideoItem(
                id: id, title: id, url: "https://youtu.be/\(id)",
                thumbnailUrl: nil, uploaderName: "Channel", duration: 120,
                isLive: false
            )
            loader.appear(video: row, api: api, onBatch: { batch in
                combined.merge(batch, uniquingKeysWith: { _, latest in latest })
                if combined.count == ids.count { received.fulfill() }
            })
        }
        await fulfillment(of: [received], timeout: 5)
        XCTAssertEqual(requested.count, ids.count)
        XCTAssertEqual(Set(requested).count, ids.count)
        XCTAssertEqual(maximumActive, 3, "First three requests should overlap")
        XCTAssertEqual(active, 0, "All requests must release their slot")
        loader.stop()
    }

    @MainActor
    func testResumeMetadataPrimesSevenCardsBeforeAnyOnAppear() async throws {
        let api = try TypeTypeAPI(address: "https://example.com")
        let metadata = try JSONDecoder().decode(StreamInfo.self, from: Data(
            #"{"viewCount":515,"publishedAt":1800000000000}"#.utf8
        ))
        let ids = [
            "ABCDEFGHIJK", "LMNOPQRSTUV", "WXYZabcdefg",
            "hijkLMNopqr", "stuvwXYZabc", "defghXYZuvw",
            "ABCDxyzEFGH", "pqrstUVWXYZ", "jklmnopQRSt"
        ]
        let rows = ids.map { id in
            VideoItem(id: id, title: id, url: "https://youtu.be/\(id)",
                      thumbnailUrl: nil, uploaderName: "Channel",
                      duration: 120, isLive: false)
        }
        var requested: [String] = []
        var active = 0
        var peak = 0
        let started = expectation(description: "Metadata started without focus or card onAppear")
        let completed = expectation(description: "All seven preloaded metadata results received")
        var delivered: [String: StreamInfo] = [:]
        let loader = TVHomeResumeMetadataLoader(fetch: { video, _ in
            active += 1
            peak = max(active, peak)
            requested.append(video.url)
            if requested.count == 1 { started.fulfill() }
            try? await Task.sleep(for: .milliseconds(50))
            active -= 1
            return metadata
        })
        loader.prime(visibleHistory: rows, api: api, onBatch: { batch in
            delivered.merge(batch, uniquingKeysWith: { _, new in new })
            if delivered.count == 7 { completed.fulfill() }
        })
        // Deliberately do NOT call appear(), scroll or change focus.
        await fulfillment(of: [started, completed], timeout: 5)
        XCTAssertEqual(requested.count, 7, "Only the four visible and three ahead")
        XCTAssertEqual(Set(requested), Set(rows.prefix(7).map(\.url)))
        XCTAssertEqual(peak, 3)
        // The later LazyHStack.onAppear must not reorder this window or refetch.
        loader.appear(video: rows[0], api: api, onBatch: { _ in })
        XCTAssertEqual(requested.count, 7)
        XCTAssertEqual(active, 0)
        loader.stop()
    }

    @MainActor
    func testResumeScrollKeepsThreeAheadWithoutRefetchingInitialWindow() async throws {
        let api = try TypeTypeAPI(address: "https://example.com")
        let rows = [
            "ABCDEFGHIJK", "LMNOPQRSTUV", "WXYZabcdefg",
            "hijkLMNopqr", "stuvwXYZabc", "defghXYZuvw",
            "ABCDxyzEFGH", "pqrstUVWXYZ", "jklmnopQRSt",
            "aaaaBBBcccc", "ddddEEEffff"
        ].map { id in
            VideoItem(id: id, title: id, url: "https://youtu.be/\(id)",
                      thumbnailUrl: nil, uploaderName: "Channel",
                      duration: 120, isLive: false)
        }
        let metadata = try JSONDecoder().decode(StreamInfo.self, from: Data(
            #"{"viewCount":515,"publishedAt":1800000000000}"#.utf8
        ))
        var requested: [String] = []
        var delivered: [String: StreamInfo] = [:]
        var reportedInitial = false
        var reportedExtended = false
        let initial = expectation(description: "Initial seven metadata results")
        let extended = expectation(description: "Three lookahead results after scrolling")
        let loader = TVHomeResumeMetadataLoader(fetch: { video, _ in
            requested.append(video.url)
            try? await Task.sleep(for: .milliseconds(25))
            return metadata
        })
        let onBatch: ([String: StreamInfo]) -> Void = { batch in
            delivered.merge(batch, uniquingKeysWith: { _, new in new })
            if delivered.count == 7 && !reportedInitial {
                reportedInitial = true
                initial.fulfill()
            }
            if delivered.count == 11 && !reportedExtended {
                reportedExtended = true
                extended.fulfill()
            }
        }
        loader.prime(visibleHistory: rows, api: api, onBatch: onBatch)
        await fulfillment(of: [initial], timeout: 5)
        XCTAssertEqual(requested.count, 7)
        // Lazy appearance of an already primed tile is a no-op for requests.
        loader.cardAppeared(at: 3, visibleHistory: rows, api: api, onBatch: onBatch)
        XCTAssertEqual(requested.count, 7)
        // First newly visible tile shifts the window to cards 4...10.
        loader.cardAppeared(at: 7, visibleHistory: rows, api: api, onBatch: onBatch)
        await fulfillment(of: [extended], timeout: 5)
        XCTAssertEqual(requested.count, 11, "Card 7 plus three ahead are fetched")
        XCTAssertEqual(Set(requested).count, requested.count)
        loader.stop()
    }

    @MainActor
    func testImmediateLoaderDoesNotStartCancelledFetchBeforeFirstScheduling() async throws {
        let api = try TypeTypeAPI(address: "https://example.com")
        let video = VideoItem(
            id: "ABCDEFGHIJK", title: "Resume",
            url: "https://youtu.be/ABCDEFGHIJK",
            thumbnailUrl: nil, uploaderName: "Channel", duration: 120,
            isLive: false
        )
        var lookups = 0
        let loader = TVHomeResumeMetadataLoader(fetch: { _, _ in
            lookups += 1
            return nil
        })
        loader.prime(visibleHistory: [video], api: api, onBatch: { _ in })
        loader.stop()
        try await Task.sleep(for: .milliseconds(120))
        XCTAssertEqual(lookups, 0, "Immediate stop cancels unscheduled lookups")
    }

    @MainActor
    func testResumeMetadataLoaderIgnoresLateResultsAfterLeavingHome() async throws {
        let api = try TypeTypeAPI(address: "https://example.com")
        let metadata = try JSONDecoder().decode(StreamInfo.self, from: Data(
            #"{"viewCount":777,"publishedAt":1800000000000}"#.utf8
        ))
        let started = expectation(description: "Request started")
        var delivered = false
        let loader = TVHomeResumeMetadataLoader(fetch: { _, _ in
            started.fulfill()
            // Simulate a provider that returns even after caller cancellation.
            try? await Task.sleep(for: .milliseconds(250))
            return metadata
        })
        let video = VideoItem(
            id: "ABCDEFGHIJK", title: "Resume", url: "https://youtu.be/ABCDEFGHIJK",
            thumbnailUrl: nil, uploaderName: "Channel", duration: 120, isLive: false
        )
        loader.appear(video: video, api: api, onBatch: { _ in delivered = true })
        await fulfillment(of: [started], timeout: 3)
        loader.stop()
        try await Task.sleep(for: .milliseconds(450))
        XCTAssertFalse(delivered, "Old Home results must not update a new view")
    }

    func testHomeContextMenuReflectsWatchLaterAndWatchedStateChanges() {
        let video = VideoItem(
            id: "menu-a", title: "Example",
            url: "https://youtu.be/ABCDEFGHIJK",
            thumbnailUrl: nil, uploaderName: "Channel",
            duration: 300, isLive: false
        )
        let initial = TVHomeCardMenuState(
            video: video, positionMs: nil, watchLater: .notSaved
        )
        XCTAssertEqual(initial.watchLater, .notSaved)
        XCTAssertFalse(initial.watched)
        XCTAssertNil(initial.positionMs)

        // After server-side add and in-memory mark, a new invocation
        // must show REMOVE, not the cached initial ADD menu.
        let saved = TVHomeCardMenuState(
            video: video, positionMs: 135_000, watchLater: .saved
        )
        XCTAssertEqual(saved.watchLater, .saved)
        XCTAssertFalse(saved.watched)
        XCTAssertEqual(saved.positionMs, 135_000,
                       "The menu must display 2:15 of playback progress")

        // Mark-watched uses the same duration/position rule as VideoCard.
        let watched = TVHomeCardMenuState(
            video: video, positionMs: 300_000, watchLater: .saved
        )
        XCTAssertTrue(watched.watched)
        XCTAssertEqual(watched.positionMs, 300_000)

        // Removing Watch Later and toggling watched off must update BOTH
        // menu actions without a Home grid reload.
        let cleared = TVHomeCardMenuState(
            video: video, positionMs: 0, watchLater: .notSaved
        )
        XCTAssertFalse(cleared.watched)
        XCTAssertEqual(cleared.positionMs, 0)
        XCTAssertEqual(cleared.watchLater, .notSaved)
    }


    func testHomeCollectionSnapshotIgnoresFocusButTracksRealChanges() {
        let first = VideoItem(
            id: "focus-a", title: "Example", url: "https://youtu.be/ABCDEFGHIJK",
            thumbnailUrl: nil, uploaderName: "Channel", duration: 300,
            isLive: false
        )
        let reference = TVHomeCollectionSnapshot(
            items: [first], scope: "account-one", resume: false,
            columns: 4, canLoadMore: true
        )
        XCTAssertEqual(reference, reference,
                       "Remote focus moves must not invalidate card data")
        var watched = first
        watched.watchPositionMs = 60_000
        XCTAssertNotEqual(reference, TVHomeCollectionSnapshot(
            items: [watched], scope: "account-one", resume: false,
            columns: 4, canLoadMore: true
        ), "Progress changes must update card data")
        XCTAssertNotEqual(reference, TVHomeCollectionSnapshot(
            items: [first], scope: "account-two", resume: false,
            columns: 4, canLoadMore: true
        ), "A different server account must update membership context")
        XCTAssertNotEqual(reference, TVHomeCollectionSnapshot(
            items: [first], scope: "account-one", resume: false,
            columns: 4, canLoadMore: false
        ), "Pagination eligibility must refresh the shelf")
    }


    func testHomeCardsSkipMetadataTasksUnlessLookupIsReallyNeeded() {
        var video = VideoItem(
            id: "test", title: "Title", url: "https://youtu.be/abcdefghijk",
            thumbnailUrl: nil, uploaderName: "Channel",
            duration: 300, isLive: false
        )
        // Both Home sections use the default (no metadata enrichment).
        XCTAssertFalse(TVVideoCardMetadataTaskPolicy.needsTask(
            for: video, enabled: false
        ))
        // Diagnostics may request metadata enrichment for missing fields.
        XCTAssertTrue(TVVideoCardMetadataTaskPolicy.needsTask(
            for: video, enabled: true
        ))
        // Fully populated feed rows need no background task either.
        video.viewCount = 500
        video.publishedAt = 1_720_000_000_000
        XCTAssertFalse(TVVideoCardMetadataTaskPolicy.needsTask(
            for: video, enabled: true
        ))
    }


    func testContinueWatchingRespectsAccountSetting() {
        let hidden = try? JSONDecoder().decode(
            TVServerSettings.self,
            from: Data(#"{"hideContinueWatching":true}"#.utf8)
        )
        XCTAssertEqual(hidden?.hideContinueWatching, true)
        XCTAssertEqual(hidden?.enabled(.continueWatching), false)
        let shown = try? JSONDecoder().decode(
            TVServerSettings.self,
            from: Data(#"{"hideContinueWatching":false}"#.utf8)
        )
        XCTAssertEqual(shown?.hideContinueWatching, false)
        XCTAssertEqual(shown?.enabled(.continueWatching), true)
    }


    func testHomeToastKeepsItsOriginalActionCardAndPosition() {
        let toast = TVHomeCardToast(
            message: "Saved", focusID: "recommendation-https://example.com/video"
        )
        XCTAssertEqual(toast.focusID, "recommendation-https://example.com/video")
        XCTAssertEqual(toast.message, "Saved")
        let rect = CGRect(x: 140, y: 230, width: 300, height: 180)
        XCTAssertEqual(TVHomeCardToastPosition.topLeft(of: rect),
                       CGPoint(x: 147, y: 237))
    }

    func testToastRevealIsClippedExactlyAtTheCardTopEdge() {
        let card = CGRect(x: 310, y: 245, width: 265, height: 190)
        let viewport = CGRect(x: 0, y: 0, width: 1400, height: 780)
        let reveal = TVHomeCardToastPosition.revealRect(
            for: card, in: viewport
        )
        XCTAssertEqual(reveal.minY, card.minY,
                       "The clipped slide must emerge at the card's top edge")
        XCTAssertEqual(reveal.minX, card.minX)
        XCTAssertGreaterThan(reveal.width, card.width,
                             "A long toast must not wrap at the tile's width")
        XCTAssertEqual(reveal.maxX, viewport.maxX)
    }

    func testToastDisappearsWhenItsCardLeavesTheVisibleViewport() {
        let viewport = CGRect(x: 0, y: 0, width: 1200, height: 680)
        let visible = CGRect(x: 140, y: 230, width: 300, height: 180)
        XCTAssertTrue(TVHomeCardToastPosition.isVisible(visible, in: viewport))
        // Still display while some part of the original card is visible.
        XCTAssertTrue(TVHomeCardToastPosition.isVisible(
            CGRect(x: 140, y: 650, width: 300, height: 180), in: viewport
        ))
        // No offscreen/frozen floating confirmation when the card is recycled.
        XCTAssertFalse(TVHomeCardToastPosition.isVisible(
            CGRect(x: 140, y: 680, width: 300, height: 180), in: viewport
        ))
        XCTAssertFalse(TVHomeCardToastPosition.isVisible(
            CGRect(x: 1200, y: 230, width: 300, height: 180), in: viewport
        ))
        XCTAssertFalse(TVHomeCardToastPosition.isVisible(
            CGRect(x: 140, y: 230, width: 0, height: 180), in: viewport
        ))
    }


    func testLivestreamFilterWorksAcrossHomeAndOtherGrids() {
        let normal = VideoItem(id: "normal", title: "Normal", url: "https://yt/normal",
                               thumbnailUrl: nil, uploaderName: nil, duration: 120,
                               isLive: false)
        var live = VideoItem(id: "live", title: "Live", url: "https://yt/live",
                             thumbnailUrl: nil, uploaderName: nil, duration: nil,
                             isLive: true)
        var stream = VideoItem(id: "stream", title: "Stream",
                               url: "https://yt/stream", thumbnailUrl: nil,
                               uploaderName: nil, duration: nil, isLive: false)
        stream.isLiveContent = true
        var archive = VideoItem(id: "archive", title: "Archive",
                                url: "https://yt/archive", thumbnailUrl: nil,
                                uploaderName: nil, duration: 500, isLive: false)
        archive.isLiveContent = true
        archive.isPostLive = true
        live.isPostLive = false
        XCTAssertTrue(TVLiveStreamDisplayPolicy.isOngoing(live))
        XCTAssertTrue(TVLiveStreamDisplayPolicy.isOngoing(stream))
        XCTAssertFalse(TVLiveStreamDisplayPolicy.isOngoing(archive))
        var archivedLiveFlag = live
        archivedLiveFlag.isPostLive = true
        XCTAssertFalse(TVLiveStreamDisplayPolicy.isOngoing(archivedLiveFlag))
        XCTAssertEqual(TVLiveStreamDisplayPolicy.visible(
            [normal, live, stream, archive], hideLiveStreams: true
        ).map(\.id), ["normal", "archive"])
        XCTAssertEqual(TVLiveStreamDisplayPolicy.visible(
            [normal, live, stream, archive], hideLiveStreams: false
        ).count, 4)
    }


    func testWatchLaterMenuNeverGuessesFromUnloadedMembership() {
        XCTAssertEqual(TVWatchLaterMenuStatus.resolved(
            loaded: false, failed: false, saved: false
        ), .loading)
        XCTAssertEqual(TVWatchLaterMenuStatus.resolved(
            loaded: false, failed: false, saved: true
        ), .loading)
        XCTAssertEqual(TVWatchLaterMenuStatus.resolved(
            loaded: false, failed: true, saved: false
        ), .failed)
        XCTAssertEqual(TVWatchLaterMenuStatus.resolved(
            loaded: true, failed: false, saved: false
        ), .notSaved)
        XCTAssertEqual(TVWatchLaterMenuStatus.resolved(
            loaded: true, failed: false, saved: true
        ), .saved)
    }


    func testSharedVideoGridInvalidatesForDataAndDestinationNotFocus() {
        let video = VideoItem(
            id: "sample", title: "Item", url: "https://youtu.be/ABCDEFGHIJK",
            thumbnailUrl: nil, uploaderName: "Channel",
            duration: 120, isLive: false
        )
        func snapshot(destination: String, rows: [VideoItem] = [],
                      watchLater: Bool = false) -> TVSharedVideoGridSnapshot {
            TVSharedVideoGridSnapshot(
                videos: rows.isEmpty ? [video] : rows,
                scope: "account-1", destination: destination,
                focusPrefix: "", accessibilityPrefix: "library-video-",
                columns: 4, columnSpacing: 25, rowSpacing: 28,
                canLoadMore: false, loadAhead: 8,
                lookupMissingMetadata: false,
                isWatchLaterEntry: watchLater,
                reloadPlaylistOnRemoval: false, playbackQueue: nil
            )
        }
        let original = snapshot(destination: "library-history")
        XCTAssertEqual(original, snapshot(destination: "library-history"))
        XCTAssertNotEqual(original, snapshot(destination: "library-watchLater"),
                          "Switching tabs must refresh tile action closures")
        XCTAssertNotEqual(original, snapshot(destination: "library-history",
                                            watchLater: true),
                          "Watch Later menus differ from other lists")
        let renamed = VideoItem(
            id: "sample", title: "Updated", url: video.url,
            thumbnailUrl: nil, uploaderName: "Channel",
            duration: 120, isLive: false
        )
        XCTAssertNotEqual(original, snapshot(destination: "library-history",
                                            rows: [renamed]),
                          "Visible video metadata changes must still redraw")
        // SwiftUI FocusState is deliberately NOT included in this immutable
        // snapshot. Directional focus changes update only the matching tile.
    }

    func testOnlyListRemovingActionsRequireFeedReload() {
        XCTAssertFalse(TVHomeMenuReloadPolicy.watched.requiresFeedReload)
        XCTAssertFalse(TVHomeMenuReloadPolicy.watchLater.requiresFeedReload)
        XCTAssertFalse(TVHomeMenuReloadPolicy.playlist.requiresFeedReload)
        XCTAssertTrue(TVHomeMenuReloadPolicy.block.requiresFeedReload)
        XCTAssertTrue(TVHomeMenuReloadPolicy.watchLaterRemoval.requiresFeedReload)
        XCTAssertTrue(TVHomeMenuReloadPolicy.playlistRemoval.requiresFeedReload)
    }


    func testHomePaginationHonorsServerHasMoreAndCursorCycles() {
        let first = HomeRecommendations(items: [], nextCursor: "cursor-2", hasMore: true)
        XCTAssertEqual(TVHomePagingPolicy.nextCursor(first), "cursor-2")
        let legacy = HomeRecommendations(items: [], nextCursor: "cursor-2", hasMore: nil)
        XCTAssertEqual(TVHomePagingPolicy.nextCursor(legacy), "cursor-2")
        let serverComplete = HomeRecommendations(items: [], nextCursor: "cursor-2", hasMore: false)
        XCTAssertNil(TVHomePagingPolicy.nextCursor(serverComplete),
                     "hasMore=false must suppress even a nonempty cursor")
        XCTAssertNil(TVHomePagingPolicy.nextCursor(first, after: "cursor-2"),
                     "A repeated cursor must not generate an endless request")
        let missing = HomeRecommendations(items: [], nextCursor: nil, hasMore: true)
        XCTAssertNil(TVHomePagingPolicy.nextCursor(missing))
        let empty = HomeRecommendations(items: [], nextCursor: "", hasMore: true)
        XCTAssertNil(TVHomePagingPolicy.nextCursor(empty))
    }

    @MainActor
    func testResolvedShortDurationEnablesCorrectWatchedAndUnwatchedMenuStates() {
        var short = VideoItem(
            id: "short", title: "Short", url: "https://youtu.be/ABCDEFGHIJK",
            thumbnailUrl: nil, uploaderName: nil, duration: nil, isLive: false
        )
        short.isShortFormContent = true
        let model = TVHomeMenuCoordinator()
        let before = TVHomeCardMenuState(
            video: model.videoWithKnownDuration(short),
            positionMs: 180_000, watchLater: .notSaved
        )
        XCTAssertFalse(before.watched, "Missing duration cannot imply completion")
        // One metadata lookup from the first menu action is retained by the
        // shared host, not published to every card of the Home LazyVGrid.
        model.rememberKnownDuration(180, for: short.url)
        let cached = model.videoWithKnownDuration(short)
        XCTAssertEqual(cached.duration, 180)
        let after = TVHomeCardMenuState(
            video: cached, positionMs: 180_000, watchLater: .notSaved
        )
        XCTAssertTrue(after.watched, "Reopening the menu must offer Unwatched")
        let removed = TVHomeCardMenuState(
            video: cached, positionMs: 0, watchLater: .notSaved
        )
        XCTAssertFalse(removed.watched, "Unwatching must restore Watched")
    }

}
