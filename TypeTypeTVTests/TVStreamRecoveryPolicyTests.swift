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
