import Foundation
import XCTest
@testable import TypeTypeTV

final class SabrRecoveryPolicyTests: XCTestCase {
    let policy = SabrRecoveryPolicy()

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
