import XCTest
@testable import TypeTypeTV

final class TVPlayerNoticesTests: XCTestCase {
    func testIndependentMessagesAreStackedNewestFirst() {
        var stack = TVPlayerNoticeStack()
        let first = stack.push("AV1 1440p failed")
        let second = stack.push("Trying VP9 1440p")
        let third = stack.push("Using H.264 1080p")
        XCTAssertEqual(stack.items.map(\.text), [
            "Using H.264 1080p",
            "Trying VP9 1440p",
            "AV1 1440p failed"
        ])
        stack.dismiss(second)
        XCTAssertEqual(stack.items.map(\.id), [third, first],
                       "Expiring a middle notice must not remove the others")
        stack.dismiss(first)
        XCTAssertEqual(stack.items.map(\.id), [third])
        stack.dismiss(third)
        XCTAssertTrue(stack.items.isEmpty)
    }

    func testDiagnosticLogCodeNeverExposesUpstreamTokens() {
        let message = "SABR upstream https://example.invalid/private/token=secret"
        XCTAssertEqual(
            SabrManualQualityFallbackPolicy.diagnosticCode(
                for: SabrFailure.invalidResponse(message)),
            "invalid-response-other"
        )
        XCTAssertEqual(
            SabrManualQualityFallbackPolicy.diagnosticCode(
                for: SabrFailure.unsupported("Native fMP4 sample format unavailable")),
            "compressed-unsupported"
        )
        XCTAssertEqual(
            SabrManualQualityFallbackPolicy.diagnosticCode(
                for: SabrFailure.unsupported("compressed codec not supported")),
            "compressed-unsupported"
        )
    }

    func testEveryNoticeLastsAtLeastTenSeconds() {
        XCTAssertEqual(TVPlayerNoticePolicy.seconds(0), 10)
        XCTAssertEqual(TVPlayerNoticePolicy.seconds(-1), 10)
        XCTAssertEqual(TVPlayerNoticePolicy.seconds(4), 10)
        XCTAssertEqual(TVPlayerNoticePolicy.seconds(10), 10)
        XCTAssertEqual(TVPlayerNoticePolicy.seconds(30), 30)
        XCTAssertEqual(TVPlayerNoticePolicy.seconds(500), 120)
        XCTAssertTrue(TVPlayerNoticePolicy.choices.allSatisfy { $0 >= 10 })
    }

    func testManualFallbackDoesNotStopAtSecondCodec() {
        let candidateCount = 5
        for index in 0..<(candidateCount - 1) {
            XCTAssertTrue(SabrManualQualityFallbackPolicy.shouldTryNext(
                error: SabrFailure.unsupported("VideoToolbox decoder unavailable"),
                initialized: false, currentIndex: index,
                candidateCount: candidateCount))
        }
        XCTAssertFalse(SabrManualQualityFallbackPolicy.shouldTryNext(
            error: SabrFailure.unsupported("decoder unavailable"),
            initialized: false, currentIndex: candidateCount - 1,
            candidateCount: candidateCount))
        XCTAssertFalse(SabrManualQualityFallbackPolicy.shouldTryNext(
            error: SabrFailure.unsupported("decoder unavailable"),
            initialized: true, currentIndex: 0, candidateCount: candidateCount))
    }

    func testManualFallbackSeparatesTrackFailuresFromAccountOrCancellation() {
        let allowed: [Error] = [
            SabrFailure.expired,
            SabrFailure.stalled("upstream"),
            SabrFailure.invalidResponse("compressed sample has no data buffer"),
            SabrFailure.server(503, "server failure")
        ]
        for error in allowed {
            XCTAssertTrue(SabrManualQualityFallbackPolicy.shouldTryNext(
                error: error, initialized: false,
                currentIndex: 1, candidateCount: 4))
        }
        let denied: [Error] = [
            CancellationError(),
            SabrFailure.unavailable,
            SabrFailure.stopped,
            SabrFailure.server(403, "forbidden"),
            SabrFailure.invalidResponse("invalid bootstrap credentials"),
            SabrFailure.throttled(429, "limited", 120)
        ]
        for error in denied {
            XCTAssertFalse(SabrManualQualityFallbackPolicy.shouldTryNext(
                error: error, initialized: false,
                currentIndex: 1, candidateCount: 4))
        }
        XCTAssertEqual(
            SabrManualQualityFallbackPolicy.reasonKey(
                for: SabrFailure.unsupported("VideoToolbox decoder unavailable for stream")),
            "player.formatErrorDecoder")
        XCTAssertEqual(
            SabrManualQualityFallbackPolicy.reasonKey(for: SabrFailure.expired),
            "player.formatErrorSession")
    }
}
