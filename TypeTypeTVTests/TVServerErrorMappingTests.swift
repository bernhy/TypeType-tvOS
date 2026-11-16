import Foundation
import XCTest
@testable import TypeTypeTV

final class TVServerErrorMappingTests: XCTestCase {
    private func response(_ status: Int, headers: [String: String] = [:]) -> HTTPURLResponse {
        HTTPURLResponse(url: URL(string: "https://example.invalid/api/streams/youtube/sabr")!,
                        statusCode: status, httpVersion: "HTTP/1.1",
                        headerFields: headers)!
    }

    func testMissingOptionalErrorFieldsDecode() {
        let problem = TVServerErrorMapping.decoded(Data(#"{"error":"Not found"}"#.utf8))
        XCTAssertEqual(problem?.error, "Not found")
        XCTAssertNil(problem?.code)
        XCTAssertFalse(problem?.isPermanentlyUnavailable ?? true)
    }

    func testPermanentUnavailableAndTransientSabrErrorsStayDistinct() {
        let missing = Data(#"{"code":"video_unavailable"}"#.utf8)
        if case .unavailable = TVServerErrorMapping.sabrError(
            data: missing, response: response(404), route: "streams/youtube/sabr") {
        } else { XCTFail("Unavailable video must not be retried forever") }

        for code in ["provider_paced", "upstream_timeout", "live_not_started",
                     "no_playable_streams", "members_only"] {
            let body = Data(("{\"code\":\"" + code + "\"}").utf8)
            if case .unavailable = TVServerErrorMapping.sabrError(
                data: body, response: response(422), route: "streams/youtube/sabr"
            ) { XCTFail("Must not suppress structured failure: " + code) }
        }
    }

    func testRetryAfterAndCorrelationID() {
        let body = Data(#"{"code":"provider_rate_limited","retryAfterMs":1350}"#.utf8)
        let failure = TVServerErrorMapping.apiError(
            data: body, response: response(429), route: "search")
        if case .retryAfter(429, "search", 2) = failure {
        } else { XCTFail("Retry-After milliseconds must round up") }

        let detailed = TVServerErrorMapping.apiError(
            data: Data(#"{"code":"members_only","requestId":"api-A1"}"#.utf8),
            response: response(403), route: "stream"
        )
        XCTAssertTrue(detailed.localizedDescription.contains("api-A1"))
    }
}
