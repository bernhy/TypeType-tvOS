import Foundation
import XCTest
@testable import TypeTypeTV

final class SabrRecoveryPolicyTests: XCTestCase {
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
