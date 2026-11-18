import XCTest
@testable import TypeTypeTV

final class TVStreamRecoveryPolicyTests: XCTestCase {
    private let policy = TVStreamRecoveryPolicy()

    func testRespectsRetryAfterAndBudget() {
        let error = TypeTypeError.retryAfter(503, "streams/bilibili", 30)
        XCTAssertEqual(policy.delayNanoseconds(
            error: error, attempt: 1, elapsedSeconds: 0
        ), 30_000_000_000)
        XCTAssertNil(policy.delayNanoseconds(
            error: error, attempt: 2, elapsedSeconds: 110
        ))
        XCTAssertEqual(policy.delayNanoseconds(
            error: TypeTypeError.http(502, "streams/niconico"),
            attempt: 3, elapsedSeconds: 3
        ), 4_000_000_000)
        XCTAssertNil(policy.delayNanoseconds(
            error: error, attempt: 4, elapsedSeconds: 1
        ))
    }

    func testStructuredTransientHTTPFailureRetriesLikePlainHTTP() {
        for status in [408, 425, 429, 502, 503, 504] {
            let plain = TypeTypeError.http(status, "streams/bilibili")
            let structured = TypeTypeError.serverDetails(
                status, "streams/bilibili", "Server request failed (ID: safe-1)"
            )
            XCTAssertEqual(
                policy.delayNanoseconds(error: structured, attempt: 2, elapsedSeconds: 0),
                policy.delayNanoseconds(error: plain, attempt: 2, elapsedSeconds: 0),
                "Structured HTTP \(status) must retain the same retry policy"
            )
        }
        for status in [400, 401, 403, 404, 422] {
            let structured = TypeTypeError.serverDetails(
                status, "streams/bilibili", "Permanent client failure"
            )
            XCTAssertNil(
                policy.delayNanoseconds(error: structured, attempt: 1, elapsedSeconds: 0),
                "HTTP \(status) must not be retried"
            )
        }
    }

    func testNeverRetriesUnavailableOrUnauthorizedMedia() {
        XCTAssertNil(policy.delayNanoseconds(
            error: TypeTypeError.videoUnavailable,
            attempt: 1, elapsedSeconds: 1
        ))
        XCTAssertNil(policy.delayNanoseconds(
            error: TypeTypeError.http(403, "streams"),
            attempt: 1, elapsedSeconds: 1
        ))
        XCTAssertNil(policy.delayNanoseconds(
            error: URLError(.cancelled),
            attempt: 1, elapsedSeconds: 1
        ))
        XCTAssertEqual(policy.delayNanoseconds(
            error: URLError(.networkConnectionLost),
            attempt: 1, elapsedSeconds: 1
        ), 1_000_000_000)
    }
}
