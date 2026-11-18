import Foundation
import XCTest
@testable import TypeTypeTV

final class SabrRecoveryPolicyTests: XCTestCase {
    func testEarlySessionPreparationUsesCommonAVBufferAndRetryableErrors() {
        XCTAssertEqual(SabrEarlySessionPrewarmPolicy.startPosition(
            playheadMs: 30_000, audioQueuedEndMs: 55_000,
            videoQueuedEndMs: 42_000
        ), 40_000)
        XCTAssertNil(SabrEarlySessionPrewarmPolicy.startPosition(
            playheadMs: 30_000, audioQueuedEndMs: 45_000,
            videoQueuedEndMs: 32_999
        ))
        XCTAssertNil(SabrEarlySessionPrewarmPolicy.startPosition(
            playheadMs: 0, audioQueuedEndMs: 0,
            videoQueuedEndMs: 20_000
        ))
        XCTAssertTrue(SabrEarlySessionPrewarmPolicy.shouldPrepare(
            for: SabrFailure.server(404, "sabr/playback/session/segments")
        ))
        XCTAssertTrue(SabrEarlySessionPrewarmPolicy.shouldPrepare(
            for: URLError(.networkConnectionLost)
        ))
        XCTAssertFalse(SabrEarlySessionPrewarmPolicy.shouldPrepare(
            for: SabrFailure.unavailable
        ))
        XCTAssertFalse(SabrEarlySessionPrewarmPolicy.shouldPrepare(
            for: CancellationError()
        ))
    }


    func testEarlySessionUsesContiguousDiskCacheIfDecoderQueuesAreShallow() {
        // Real Apple TV log: ~22 seconds of compressed A/V were cached,
        // but no prewarm began. Queued renderer samples need not match cache.
        XCTAssertEqual(SabrEarlySessionPrewarmPolicy.startPosition(
            playheadMs: 547_875,
            audioQueuedEndMs: 549_000,
            videoQueuedEndMs: 550_000,
            cachedThroughMs: 569_600
        ), 567_600)
        XCTAssertEqual(SabrEarlySessionPrewarmPolicy.startPosition(
            playheadMs: 1_264_334,
            audioQueuedEndMs: 1_265_000,
            videoQueuedEndMs: 1_266_000,
            cachedThroughMs: 1_285_120
        ), 1_283_120)
        XCTAssertNil(SabrEarlySessionPrewarmPolicy.startPosition(
            playheadMs: 30_000,
            audioQueuedEndMs: 31_000,
            videoQueuedEndMs: 32_000,
            cachedThroughMs: 32_999
        ), "Do not prewarm with less than 3s of contiguous A/V media")
        XCTAssertEqual(SabrEarlySessionPrewarmPolicy.startPosition(
            playheadMs: 30_000,
            audioQueuedEndMs: 40_000,
            videoQueuedEndMs: 39_000,
            cachedThroughMs: 31_000
        ), 37_000, "Do not regress when native renderer is ahead of disk cache")
        XCTAssertTrue(SabrEarlySessionPrewarmPolicy.shouldPrepare(
            for: SabrFailure.server(503, "sabr/playback/opaque/position")
        ))
        XCTAssertFalse(SabrEarlySessionPrewarmPolicy.shouldPrepare(
            for: SabrFailure.server(401, "sabr/playback/opaque/position")
        ), "Authentication failure is not safe for speculative sessions")
    }

    func testInPlaceProducerHandoverNeedsActualAVCacheAndNetworkFailure() {
        // The November 18 Apple TV reboot: 20.9s contiguous compressed
        // A/V cache, only 1.4s submitted to the native renderer.
        XCTAssertTrue(SabrRecoverySplicePolicy.shouldSwitch(
            error: SabrFailure.server(404, "segments"),
            initialized: true, playheadMs: 132_407,
            cachedThroughMs: 153_280
        ))
        XCTAssertTrue(SabrRecoverySplicePolicy.shouldSwitch(
            error: URLError(.networkConnectionLost),
            initialized: true, playheadMs: 100_000,
            cachedThroughMs: 120_000
        ))
        XCTAssertFalse(SabrRecoverySplicePolicy.shouldSwitch(
            error: SabrFailure.server(404, "segments"),
            initialized: true, playheadMs: 132_407,
            cachedThroughMs: 137_000
        ), "Do not switch when there is no time to fill the new mailbox")
        XCTAssertFalse(SabrRecoverySplicePolicy.shouldSwitch(
            error: SabrFailure.server(404, "segments"),
            initialized: false, playheadMs: 132_407,
            cachedThroughMs: 153_280
        ), "Cold resume and attestation issues need the original recovery")
        XCTAssertFalse(SabrRecoverySplicePolicy.shouldSwitch(
            error: SabrFailure.server(401, "segments"),
            initialized: true, playheadMs: 132_407,
            cachedThroughMs: 153_280
        ), "Never start a fresh stream to bypass an authentication failure")
        XCTAssertFalse(SabrRecoverySplicePolicy.shouldSwitch(
            error: SabrFailure.stalled("decoder sample discontinuity"),
            initialized: true, playheadMs: 132_407,
            cachedThroughMs: 153_280
        ), "Media integrity problems need full recovery")
    }

    func testSplicePreflightSelectsActualFragmentsCoveringHandover() {
        let audio = [
            SabrFragment(url: "https://example.invalid/segment/44",
                         startMs: 429_336, durationMs: 9_985),
            SabrFragment(url: "https://example.invalid/segment/45",
                         startMs: 439_321, durationMs: 9_985)
        ]
        let video = [
            SabrFragment(url: "https://example.invalid/segment/82",
                         startMs: 426_800, durationMs: 5_840),
            SabrFragment(url: "https://example.invalid/segment/83",
                         startMs: 432_640, durationMs: 5_840)
        ]
        let target: Int64 = 436_480  // From November 18 Apple TV hardware log.
        XCTAssertEqual(SabrSplicePreflightPolicy.segment(audio, covering: target)?.startMs,
                       429_336)
        XCTAssertEqual(SabrSplicePreflightPolicy.segment(video, covering: target)?.startMs,
                       432_640)
        XCTAssertNil(SabrSplicePreflightPolicy.segment(video, covering: 439_000),
                     "Do not claim unverified media coverage in a gap")
        XCTAssertNil(SabrSplicePreflightPolicy.segment(video, covering: Int64.max),
                     "Overflowing timestamps are always invalid")
    }

    func testSplicePreflightRequiresActualAudioAndReliableVideoKeyframe() {
        let target: Int64 = 436_480
        XCTAssertTrue(SabrSplicePreflightPolicy.accepts(
            targetMs: target,
            audioFirstMs: 436_486, audioEndMs: 439_321,
            videoRAPMs: 432_640, videoEndMs: 438_480
        ), "Contiguous AAC samples and a preceding RAP permit a live splice")
        XCTAssertFalse(SabrSplicePreflightPolicy.accepts(
            targetMs: target,
            audioFirstMs: 436_486, audioEndMs: 439_321,
            videoRAPMs: nil, videoEndMs: 438_480
        ), "No inferred or fabricated keyframe")
        XCTAssertFalse(SabrSplicePreflightPolicy.accepts(
            targetMs: target,
            audioFirstMs: 437_100, audioEndMs: 439_321,
            videoRAPMs: 432_640, videoEndMs: 438_480
        ), "Cached bytes alone must not conceal a missing audio interval")
        XCTAssertFalse(SabrSplicePreflightPolicy.accepts(
            targetMs: target,
            audioFirstMs: 436_486, audioEndMs: 439_321,
            videoRAPMs: 436_600, videoEndMs: 438_480
        ), "Starting from a future RAP would leave an undecodable video gap")
        XCTAssertFalse(SabrSplicePreflightPolicy.accepts(
            targetMs: target,
            audioFirstMs: 436_486, audioEndMs: 436_700,
            videoRAPMs: 432_640, videoEndMs: 438_480
        ), "Audio must reach beyond the handover point")
        XCTAssertFalse(SabrSplicePreflightPolicy.accepts(
            targetMs: target,
            audioFirstMs: 436_486, audioEndMs: 439_321,
            videoRAPMs: 432_640, videoEndMs: 436_600
        ), "Video must reach beyond the handover point")
    }

    func testSuccessiveServerRestartsCanReSpliceWithinBoundedBudget() {
        let networkLoss = SabrFailure.server(404, "opaque")
        // We have already switched once. A second and third server restart
        // can replace the producer without resetting native A/V renderers.
        for previousSessions in 1..<SabrRecoverySplicePolicy.maximumSessionsPerIncident {
            XCTAssertTrue(SabrRecoverySplicePolicy.canReSplice(
                error: networkLoss, initialized: true,
                playheadMs: 324_545, cachedThroughMs: 345_400,
                sessionsSoFar: previousSessions
            ))
        }
        XCTAssertFalse(SabrRecoverySplicePolicy.canReSplice(
            error: networkLoss, initialized: true,
            playheadMs: 324_545, cachedThroughMs: 345_400,
            sessionsSoFar: SabrRecoverySplicePolicy.maximumSessionsPerIncident
        ), "The number of speculative server sessions must be bounded")
        XCTAssertFalse(SabrRecoverySplicePolicy.canReSplice(
            error: networkLoss, initialized: true,
            playheadMs: 215_338, cachedThroughMs: 217_320,
            sessionsSoFar: 1
        ), "Near-empty cache must use the existing decoder fallback")
        XCTAssertFalse(SabrRecoverySplicePolicy.canReSplice(
            error: SabrFailure.expired, initialized: true,
            playheadMs: 324_545, cachedThroughMs: 345_400,
            sessionsSoFar: 1
        ), "Keep the separate attestation/expiry investigation untouched")
        XCTAssertFalse(SabrRecoverySplicePolicy.canReSplice(
            error: SabrFailure.server(401, "opaque"), initialized: true,
            playheadMs: 324_545, cachedThroughMs: 345_400,
            sessionsSoFar: 1
        ))
        XCTAssertEqual(SabrRecoverySplicePolicy.errorKind(
            SabrFailure.server(404, "/api/sabr/private/session-id")
        ), "http")
        XCTAssertEqual(SabrRecoverySplicePolicy.httpStatus(networkLoss), 404)
        XCTAssertEqual(SabrRecoverySplicePolicy.errorKind(
            SabrFailure.invalidResponse("SABR segment gap before next media sample")
        ), "segment-gap")
        XCTAssertEqual(SabrRecoverySplicePolicy.errorKind(
            SabrFailure.invalidResponse("private-id-or-token")
        ), "invalid-response")
    }

    func testSpliceCutsAudioAndVideoAtIndependentSubmittedFrontiers() {
        XCTAssertEqual(SabrRecoverySplicePolicy.clipBeforeMs(
            queuedEndMs: 159_753, parsedEndMs: 160_100,
            presentationStartMs: 132_407
        ), 160_100)
        XCTAssertEqual(SabrRecoverySplicePolicy.clipBeforeMs(
            queuedEndMs: 153_300, parsedEndMs: 153_280,
            presentationStartMs: 132_407
        ), 153_300)
        XCTAssertEqual(SabrRecoverySplicePolicy.clipBeforeMs(
            queuedEndMs: 0, parsedEndMs: nil, presentationStartMs: 5_000
        ), 5_000)
    }

    func testEarlyTransportRetriesOnlySafePlaybackRoutesAndTransientFailures() {
        let policy = SabrEarlyTransportRetryPolicy(delaysMilliseconds: [1, 2])
        XCTAssertEqual(SabrEarlyTransportRetryPolicy.route(
            method: "POST", path: "sabr/playback/opaque-session/prefetch"
        ), "prefetch")
        XCTAssertEqual(policy.delayNanoseconds(
            method: "POST", path: "sabr/playback/opaque-session/segments",
            retries: 0, status: 503
        ), 1_000_000)
        XCTAssertEqual(policy.delayNanoseconds(
            method: "GET", path: "segment", retries: 1,
            error: URLError(.networkConnectionLost)
        ), 2_000_000)
        XCTAssertNil(policy.delayNanoseconds(
            method: "POST", path: "sabr/playback/videoId",
            retries: 0, status: 503
        ), "Starting a session is not idempotent")
        XCTAssertNil(policy.delayNanoseconds(
            method: "POST", path: "sabr/playback/opaque-session/seek",
            retries: 0, status: 503
        ), "A user seek must not be replayed after failure")
        XCTAssertNil(policy.delayNanoseconds(
            method: "DELETE", path: "sabr/playback/opaque-session",
            retries: 0, status: 503
        ))
        XCTAssertNil(policy.delayNanoseconds(
            method: "GET", path: "segment", retries: 0, status: 404
        ), "A vanished SABR session requires fresh-session recovery")
        XCTAssertNil(policy.delayNanoseconds(
            method: "GET", path: "segment", retries: 0, status: 401
        ), "401 belongs to token refresh, not early transport retries")
        XCTAssertNil(policy.delayNanoseconds(
            method: "POST", path: "sabr/playback/s/segments", retries: 0,
            error: URLError(.cancelled)
        ))
        XCTAssertNil(policy.delayNanoseconds(
            method: "GET", path: "segment", retries: 2, status: 503
        ), "Retries must remain bounded")
    }


    let policy = SabrRecoveryPolicy()

    func testServerFreshSessionRecoveryDiagnosesAttestationWithoutLoggingSecrets() {
        let terminal = "SABR attestation remained pending without media for 3 consecutive responses: " +
            "privateToken=https://secret.invalid/session/token"
        XCTAssertEqual(SabrServerRecoveryDiagnostics.category(terminal), "attestation")
        XCTAssertEqual(SabrServerRecoveryDiagnostics.action("retry_fresh_session"),
                       "retry-fresh-session")
        XCTAssertEqual(SabrServerRecoveryDiagnostics.state("TERMINAL"), "terminal")
        XCTAssertEqual(SabrServerRecoveryDiagnostics.state("sensitive untrusted text"),
                       "other")
        XCTAssertEqual(SabrServerRecoveryDiagnostics.action("https://secret.invalid"),
                       "other")
    }

    func testServerRecoveryDistinguishesPersistentUpstreamFailures() {
        XCTAssertEqual(SabrServerRecoveryDiagnostics.category("SABR demand stalled for 137:14"),
                       "demand-stalled")
        XCTAssertEqual(SabrServerRecoveryDiagnostics.category("upstream unauthorized HTTP 403"),
                       "upstream-auth")
        XCTAssertEqual(SabrServerRecoveryDiagnostics.category("SABR token binding mismatch"),
                       "token-binding")
        XCTAssertEqual(SabrServerRecoveryDiagnostics.category("upstream timeout"),
                       "upstream-timeout")
        XCTAssertEqual(SabrServerRecoveryDiagnostics.category(nil), "unspecified")
        XCTAssertEqual(SabrServerRecoveryDiagnostics.category("unexpected unrelated details"),
                       "other")
    }

    func testRetryClassificationAvoidsPermanentClientAndDecoderFailures() {
        XCTAssertTrue(policy.canRetry(SabrFailure.expired,
            completedAttempts: 1, elapsedSeconds: 1))
        XCTAssertTrue(policy.canRetry(SabrFailure.server(503, "segment"),
            completedAttempts: 2, elapsedSeconds: 10))
        XCTAssertTrue(policy.canRetry(URLError(.networkConnectionLost),
            completedAttempts: 1, elapsedSeconds: 2))
        XCTAssertTrue(policy.canRetry(SabrFailure.stalled("renderer"),
            completedAttempts: 2, elapsedSeconds: 3))
        XCTAssertFalse(policy.canRetry(SabrFailure.server(403, "segment"),
            completedAttempts: 1, elapsedSeconds: 1))
        XCTAssertFalse(policy.canRetry(SabrFailure.unsupported("decoder"),
            completedAttempts: 1, elapsedSeconds: 1))
        XCTAssertFalse(policy.canRetry(SabrFailure.invalidResponse("MP4 corrupted"),
            completedAttempts: 1, elapsedSeconds: 1))
    }

    func testRecoveryIsBoundedAndBackoffCapped() {
        XCTAssertEqual(policy.delayNanoseconds(attempt: 1), 1_000_000_000)
        XCTAssertEqual(policy.delayNanoseconds(attempt: 2), 2_000_000_000)
        XCTAssertEqual(policy.delayNanoseconds(attempt: 4), 8_000_000_000)
        XCTAssertEqual(policy.delayNanoseconds(attempt: 7), 8_000_000_000)
        XCTAssertFalse(policy.canRetry(SabrFailure.expired,
            completedAttempts: 8, elapsedSeconds: 1))
        XCTAssertFalse(policy.canRetry(SabrFailure.expired,
            completedAttempts: 1, elapsedSeconds: 130))
    }
    func testRetryAfterBackoffAndPermanentUnavailable() {
        XCTAssertEqual(SabrRetryAfter.seconds("30"), 30)
        XCTAssertEqual(SabrRetryAfter.seconds(" 15 "), 15)
        XCTAssertNil(SabrRetryAfter.seconds("not-a-delay"))
        let error = SabrFailure.throttled(503, "sabr", 30)
        XCTAssertEqual(policy.delayNanoseconds(for: error, attempt: 2),
                       30_000_000_000)
        XCTAssertTrue(policy.canRetry(error,
            completedAttempts: 1, elapsedSeconds: 30))
        XCTAssertFalse(policy.canRetry(error,
            completedAttempts: 1, elapsedSeconds: 110))
        XCTAssertFalse(policy.canRetry(SabrFailure.unavailable,
            completedAttempts: 1, elapsedSeconds: 1))
    }

    func testFirstErrorAfterTenMinuteMovieStillAllowsRecovery() {
        var budget = SabrRecoveryBudget()
        let afterTenMinutes = Date(timeIntervalSince1970: 1_700_000_600)
        let decision = budget.evaluate(
            SabrFailure.stalled("media queue exhausted"),
            playbackAdvancedMs: 610_374,
            now: afterTenMinutes
        )
        XCTAssertEqual(decision.attempt, 1)
        XCTAssertTrue(decision.allowed,
                      "The 120-second budget must start at failure, not at movie start")
        XCTAssertEqual(budget.incidentStartedAt, afterTenMinutes)
    }

    func testRecoveryRemainsBoundedDuringOneStallAndResetsAfterStablePlayback() {
        var budget = SabrRecoveryBudget()
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let first = budget.evaluate(SabrFailure.expired,
                                    playbackAdvancedMs: 40_000, now: start)
        XCTAssertEqual(first.attempt, 1)
        XCTAssertTrue(first.allowed)
        let second = budget.evaluate(SabrFailure.expired,
                                     playbackAdvancedMs: 0, now: start.addingTimeInterval(10))
        XCTAssertEqual(second.attempt, 2)
        XCTAssertTrue(second.allowed)
        let deadline = budget.evaluate(SabrFailure.expired,
                                       playbackAdvancedMs: 5_000, now: start.addingTimeInterval(125))
        XCTAssertFalse(deadline.allowed)
        // A later 31-second run is a new successful playback interval; a
        // fresh, unrelated failure gets a fresh but bounded recovery budget.
        let later = budget.evaluate(SabrFailure.expired,
                                    playbackAdvancedMs: 31_000, now: start.addingTimeInterval(500))
        XCTAssertEqual(later.attempt, 1)
        XCTAssertTrue(later.allowed)
    }

    func testRepeatedImmediateStallsExhaustRecoveryAttempts() {
        var budget = SabrRecoveryBudget()
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        var last: (attempt: Int, allowed: Bool) = (0, false)
        for attempt in 1...SabrRecoveryPolicy().maxAttempts {
            last = budget.evaluate(SabrFailure.expired,
                                   playbackAdvancedMs: 0,
                                   now: start.addingTimeInterval(Double(attempt)))
        }
        XCTAssertEqual(last.attempt, SabrRecoveryPolicy().maxAttempts)
        XCTAssertFalse(last.allowed)
    }

    func testRepeatedSamePositionStallEscalatesToBootstrapOnce() {
        XCTAssertFalse(SabrRecoveryRefreshPolicy.shouldRefresh(
            attempt: 1, currentFailurePositionMs: 50_800,
            previousFailurePositionMs: nil, alreadyRefreshed: false))
        XCTAssertTrue(SabrRecoveryRefreshPolicy.shouldRefresh(
            attempt: 2, currentFailurePositionMs: 50_800,
            previousFailurePositionMs: 51_554, alreadyRefreshed: false))
        XCTAssertFalse(SabrRecoveryRefreshPolicy.shouldRefresh(
            attempt: 3, currentFailurePositionMs: 50_800,
            previousFailurePositionMs: 51_554, alreadyRefreshed: true))
        XCTAssertFalse(SabrRecoveryRefreshPolicy.shouldRefresh(
            attempt: 2, currentFailurePositionMs: 65_000,
            previousFailurePositionMs: 50_800, alreadyRefreshed: false))
        XCTAssertFalse(SabrRecoveryRefreshPolicy.shouldRefresh(
            attempt: 2, currentFailurePositionMs: 50_800,
            previousFailurePositionMs: nil, alreadyRefreshed: false))
    }

    func testSeekSessionReuseRequiresTheSameAudioAndVideoRepresentation() {
        XCTAssertTrue(SabrSessionReusePolicy.matches(
            priorVideoItag: 137, priorAudioItag: 140, priorAudioTrackId: nil,
            selectedVideoItag: 137, selectedAudioItag: 140,
            selectedAudioTrackId: nil
        ))
        XCTAssertFalse(SabrSessionReusePolicy.matches(
            priorVideoItag: 137, priorAudioItag: 140, priorAudioTrackId: nil,
            selectedVideoItag: 136, selectedAudioItag: 140,
            selectedAudioTrackId: nil
        ))
        XCTAssertFalse(SabrSessionReusePolicy.matches(
            priorVideoItag: 137, priorAudioItag: 140, priorAudioTrackId: "de",
            selectedVideoItag: 137, selectedAudioItag: 140,
            selectedAudioTrackId: "en"
        ))
    }

    func testColdResumeSwitchesAtMostOneAutomaticTrackAfterExpiry() {
        XCTAssertTrue(SabrResumeTrackFallbackPolicy.shouldTryNext(
            error: SabrFailure.expired, positionMs: 2_821_957,
            initialized: false, currentIndex: 0, candidateCount: 7,
            manuallySelected: false
        ))
        XCTAssertFalse(SabrResumeTrackFallbackPolicy.shouldTryNext(
            error: SabrFailure.expired, positionMs: 2_821_957,
            initialized: false, currentIndex: 1, candidateCount: 7,
            manuallySelected: false
        ))
        XCTAssertFalse(SabrResumeTrackFallbackPolicy.shouldTryNext(
            error: SabrFailure.expired, positionMs: 0,
            initialized: false, currentIndex: 0, candidateCount: 7,
            manuallySelected: false
        ))
        XCTAssertFalse(SabrResumeTrackFallbackPolicy.shouldTryNext(
            error: SabrFailure.expired, positionMs: 2_821_957,
            initialized: true, currentIndex: 0, candidateCount: 7,
            manuallySelected: false
        ))
        XCTAssertFalse(SabrResumeTrackFallbackPolicy.shouldTryNext(
            error: SabrFailure.expired, positionMs: 2_821_957,
            initialized: false, currentIndex: 0, candidateCount: 7,
            manuallySelected: true
        ))
        XCTAssertFalse(SabrResumeTrackFallbackPolicy.shouldTryNext(
            error: SabrFailure.stalled("queue"), positionMs: 2_821_957,
            initialized: false, currentIndex: 0, candidateCount: 7,
            manuallySelected: false
        ))
    }

    func testColdResumeEscalatesOnlyAfterFreshAndRefreshedSessions() {
        XCTAssertFalse(SabrResumeTrackFallbackPolicy.shouldEscalateToAlternateTrack(
            error: SabrFailure.expired, positionMs: 2_821_957,
            initialized: false, attempt: 2
        ))
        XCTAssertTrue(SabrResumeTrackFallbackPolicy.shouldEscalateToAlternateTrack(
            error: SabrFailure.expired, positionMs: 2_821_957,
            initialized: false, attempt: 3
        ))
        XCTAssertFalse(SabrResumeTrackFallbackPolicy.shouldEscalateToAlternateTrack(
            error: SabrFailure.expired, positionMs: 2_821_957,
            initialized: true, attempt: 3
        ))
        XCTAssertFalse(SabrResumeTrackFallbackPolicy.shouldEscalateToAlternateTrack(
            error: SabrFailure.expired, positionMs: 0,
            initialized: false, attempt: 3
        ))
    }

    func testGuestLoginNeverOverwritesAuthenticatedAccount() {
        XCTAssertTrue(SabrGuestAuthPolicy.shouldAttemptGuest(
            responseCode: 401, existingToken: nil
        ))
        XCTAssertTrue(SabrGuestAuthPolicy.shouldAttemptGuest(
            responseCode: 403, existingToken: ""
        ))
        XCTAssertFalse(SabrGuestAuthPolicy.shouldAttemptGuest(
            responseCode: 401, existingToken: "account-token"
        ))
        XCTAssertFalse(SabrGuestAuthPolicy.shouldAttemptGuest(
            responseCode: 403, existingToken: "account-token"
        ))
        XCTAssertFalse(SabrGuestAuthPolicy.shouldAttemptGuest(
            responseCode: 429, existingToken: nil
        ))
        XCTAssertTrue(SabrGuestAuthPolicy.mayStoreGuestToken(existingToken: nil))
        XCTAssertFalse(SabrGuestAuthPolicy.mayStoreGuestToken(existingToken: "new-device-login"))
    }

    func testRetryAfterHTTPDate() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        let header = formatter.string(from: now.addingTimeInterval(25))
        XCTAssertEqual(SabrRetryAfter.seconds(header, now: now), 25)
    }

}
