import XCTest
@testable import TypeTypeTV

final class TVHomeCardEqualityTests: XCTestCase {
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
        XCTAssertFalse(hidden?.enabled(.continueWatching))
        let shown = try? JSONDecoder().decode(
            TVServerSettings.self,
            from: Data(#"{"hideContinueWatching":false}"#.utf8)
        )
        XCTAssertEqual(shown?.hideContinueWatching, false)
        XCTAssertTrue(shown?.enabled(.continueWatching))
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


    func testOnlyBlockingRequiresHomeFeedReload() {
        XCTAssertFalse(TVHomeMenuReloadPolicy.watched.requiresFeedReload)
        XCTAssertFalse(TVHomeMenuReloadPolicy.watchLater.requiresFeedReload)
        XCTAssertFalse(TVHomeMenuReloadPolicy.playlist.requiresFeedReload)
        XCTAssertTrue(TVHomeMenuReloadPolicy.block.requiresFeedReload)
    }


    func testComparisonMenuHasOnlyTwoVisibleChoices() {
        XCTAssertEqual(TVHomeComparisonPolicy.previous,
                       TVHomeExperimentMode.fullLightweightStableFocus.rawValue)
        XCTAssertEqual(TVHomeComparisonPolicy.baseline,
                       TVHomeExperimentMode.subscriptionsBaseline.rawValue)
        XCTAssertNotEqual(TVHomeComparisonPolicy.previous, TVHomeComparisonPolicy.baseline)
        XCTAssertEqual(TVHomeComparisonPolicy.label(for: TVHomeComparisonPolicy.previous),
                       "Bisheriges Home")
        XCTAssertEqual(TVHomeComparisonPolicy.label(for: TVHomeComparisonPolicy.baseline),
                       "Home wie Abonnements")
        XCTAssertTrue(TVHomeComparisonPolicy.isChosen(
            TVHomeComparisonPolicy.baseline, selected: TVHomeComparisonPolicy.baseline
        ))
        XCTAssertFalse(TVHomeComparisonPolicy.isChosen(
            TVHomeComparisonPolicy.previous, selected: TVHomeComparisonPolicy.baseline
        ))
        XCTAssertTrue(TVHomeComparisonPolicy.isChosen(
            TVHomeComparisonPolicy.previous, selected: TVHomeExperimentMode.full.rawValue
        ))
    }

    func testDiagnosticModesIsolateHomeWorkWithoutReduccingImageQuality() {
        XCTAssertEqual(TVHomeExperimentMode.allCases.count, 11)
        XCTAssertEqual(TVHomeExperimentMode.full.next,
                       .noStreamMetadata)
        XCTAssertEqual(TVHomeExperimentMode.noStreamMetadata.next,
                       .recommendationsOnly)
        XCTAssertEqual(TVHomeExperimentMode.recommendationsOnly.next,
                       .twelveRecommendations)
        XCTAssertEqual(TVHomeExperimentMode.twelveRecommendations.next,
                       .twelveWithoutActions)
        XCTAssertEqual(TVHomeExperimentMode.twelveWithoutActions.next,
                       .twelveWithoutEffects)
        XCTAssertEqual(TVHomeExperimentMode.twelveWithoutEffects.next,
                       .twelveWithoutFocusHints)
        XCTAssertEqual(TVHomeExperimentMode.twelveWithoutFocusHints.next,
                       .twelveLightweightMenu)
        XCTAssertEqual(TVHomeExperimentMode.twelveLightweightMenu.next,
                       .fullLightweightMenu)
        XCTAssertEqual(TVHomeExperimentMode.fullLightweightMenu.next,
                       .fullLightweightStableFocus)
        XCTAssertEqual(TVHomeExperimentMode.fullLightweightStableFocus.next,
                       .subscriptionsBaseline)
        XCTAssertEqual(TVHomeExperimentMode.subscriptionsBaseline.next,
                       .full)
        XCTAssertTrue(TVHomeExperimentMode.full.includesResume)
        XCTAssertTrue(TVHomeExperimentMode.full.enrichesResumeMetadata)
        XCTAssertFalse(TVHomeExperimentMode.noStreamMetadata.enrichesResumeMetadata)
        XCTAssertTrue(TVHomeExperimentMode.noStreamMetadata.includesResume)
        XCTAssertFalse(TVHomeExperimentMode.recommendationsOnly.includesResume)
        XCTAssertNil(TVHomeExperimentMode.recommendationsOnly.recommendationLimit)
        XCTAssertEqual(TVHomeExperimentMode.twelveRecommendations.recommendationLimit, 12)
        XCTAssertEqual(TVHomeExperimentMode.twelveWithoutActions.recommendationLimit, 12)
        XCTAssertEqual(TVHomeExperimentMode.twelveWithoutEffects.recommendationLimit, 12)
        XCTAssertEqual(TVHomeExperimentMode.twelveWithoutFocusHints.recommendationLimit, 12)
        XCTAssertEqual(TVHomeExperimentMode.twelveLightweightMenu.recommendationLimit, 12)
        XCTAssertNil(TVHomeExperimentMode.fullLightweightMenu.recommendationLimit)
        XCTAssertNil(TVHomeExperimentMode.fullLightweightStableFocus.recommendationLimit)
        XCTAssertTrue(TVHomeExperimentMode.fullLightweightStableFocus.includesResume)
        XCTAssertTrue(TVHomeExperimentMode.fullLightweightMenu.includesResume)
        XCTAssertFalse(TVHomeExperimentMode.twelveWithoutActions.includesCardActionModifiers)
        XCTAssertTrue(TVHomeExperimentMode.twelveWithoutActions.includesCardVisualEffects)
        XCTAssertTrue(TVHomeExperimentMode.twelveWithoutEffects.includesCardActionModifiers)
        XCTAssertFalse(TVHomeExperimentMode.twelveWithoutEffects.includesCardVisualEffects)
        XCTAssertTrue(TVHomeExperimentMode.full.includesCardActionModifiers)
        XCTAssertTrue(TVHomeExperimentMode.full.includesCardVisualEffects)
        XCTAssertTrue(TVHomeExperimentMode.full.includesDefaultFocusHints)
        XCTAssertFalse(TVHomeExperimentMode.twelveWithoutFocusHints.includesDefaultFocusHints)
        XCTAssertTrue(TVHomeExperimentMode.twelveWithoutFocusHints.includesCardActionModifiers)
        XCTAssertTrue(TVHomeExperimentMode.twelveWithoutFocusHints.includesCardVisualEffects)
        XCTAssertTrue(TVHomeExperimentMode.twelveLightweightMenu.usesLightweightMenu)
        XCTAssertTrue(TVHomeExperimentMode.fullLightweightMenu.usesLightweightMenu)
        XCTAssertTrue(TVHomeExperimentMode.fullLightweightStableFocus.usesLightweightMenu)
        XCTAssertTrue(TVHomeExperimentMode.fullLightweightMenu.tracksDefaultFocusDuringNavigation)
        XCTAssertFalse(TVHomeExperimentMode.fullLightweightStableFocus.tracksDefaultFocusDuringNavigation)
        XCTAssertFalse(TVHomeExperimentMode.subscriptionsBaseline.includesResume)
        XCTAssertNil(TVHomeExperimentMode.subscriptionsBaseline.recommendationLimit)
        XCTAssertFalse(TVHomeExperimentMode.subscriptionsBaseline.usesLightweightMenu)
        XCTAssertFalse(TVHomeExperimentMode.full.usesLightweightMenu)
        XCTAssertTrue(TVHomeExperimentMode.fullLightweightMenu.includesCardActionModifiers)
    }

    func testSingleTargetRailHandoffNeverPermitsNeighborFocus() throws {
        let first = "recommendation-" + "https://youtu.be/ABCDEFGHIJK"
        let second = "recommendation-" + "https://youtu.be/LMNOPQRSTUV"
        let row = VideoItem(
            id: "one", title: "Example", url: "https://youtu.be/ABCDEFGHIJK",
            thumbnailUrl: nil, uploaderName: "Channel", duration: 120,
            isLive: false
        )
        XCTAssertEqual(TVHomeRailHandoffPolicy.savedTarget(
            first, recommendations: [row], recent: []
        ), first)
        XCTAssertNil(TVHomeRailHandoffPolicy.savedTarget(
            second, recommendations: [row], recent: []
        ))
        XCTAssertTrue(TVHomeRailHandoffPolicy.canFocus(first, restoring: first))
        XCTAssertFalse(TVHomeRailHandoffPolicy.canFocus(second, restoring: first))
        XCTAssertTrue(TVHomeRailHandoffPolicy.canFocus(second, restoring: nil))
    }


    func testHomeViewportStaysStableAcrossMainRailExpansion() {
        // 158pt narrower navigation content must not shrink its 4-column
        // thumbnails or accumulate per-row vertical drift.
        let collapsed = CGFloat(1650)
        let expanded = CGFloat(1492)
        let widest = TVHomeViewportPolicy.widest(0, measured: collapsed)
        XCTAssertEqual(TVHomeViewportPolicy.contentWidth(
            available: expanded, widest: widest
        ), collapsed)
        XCTAssertEqual(TVHomeViewportPolicy.contentWidth(
            available: collapsed, widest: widest
        ), collapsed)
        XCTAssertEqual(TVHomeViewportPolicy.widest(widest, measured: expanded),
                       collapsed)
        XCTAssertEqual(TVHomeViewportPolicy.widest(widest, measured: .nan), collapsed)
    }

    func testReturningFromRailDoesNotRecenterAlreadyVisibleCard() {
        let deep = "recommendation-deep"
        XCTAssertFalse(TVHomeViewportPolicy.shouldScrollToRestore(
            savedRailCard: deep, target: deep
        ))
        XCTAssertTrue(TVHomeViewportPolicy.shouldScrollToRestore(
            savedRailCard: deep, target: "recommendation-first"
        ))
        XCTAssertTrue(TVHomeViewportPolicy.shouldScrollToRestore(
            savedRailCard: nil, target: deep
        ))
    }

    func testHomeCardEqualityOnlySkipsIdenticalVisualInputs() throws {
        let api = try TypeTypeAPI(address: "https://example.com")
        let other = try TypeTypeAPI(address: "https://other.example.com")
        let video = VideoItem(
            id: "one", title: "Original", url: "https://youtu.be/ABCDEFGHIJK",
            thumbnailUrl: "https://img.example.com/one.jpg",
            uploaderName: "Channel", duration: 120, isLive: false
        )
        var changed = video
        changed.viewCount = 100

        let a = TVHomeCardContent(api: api, video: video)
        XCTAssertEqual(a, TVHomeCardContent(api: api, video: video))
        XCTAssertNotEqual(a, TVHomeCardContent(api: other, video: video))
        XCTAssertNotEqual(a, TVHomeCardContent(api: api, video: changed))
        XCTAssertNotEqual(a, TVHomeCardContent(
            api: api, video: video, lookupMissingMetadata: true
        ))
        XCTAssertNotEqual(a, TVHomeCardContent(
            api: api, video: video, includeVisualEffects: false
        ))
    }
}
