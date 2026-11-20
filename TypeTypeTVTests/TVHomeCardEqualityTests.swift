import XCTest
@testable import TypeTypeTV

final class TVHomeCardEqualityTests: XCTestCase {
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
