import XCTest
@testable import TypeTypeTV

final class SabrDemuxFallbackTests: XCTestCase {
    func testNativeVideoReaderFailuresAllowAlternativeRepresentation() {
        for stage in ["load-track", "load-format", "reader-create",
                      "reader-add", "reader-start", "sample-read",
                      "sample-format", "reader-finish"] {
            XCTAssertTrue(SabrDemuxFallbackPolicy.isCodecSpecificReaderFailure(
                stage: stage, errorDomain: "AVFoundationErrorDomain"),
                "Video reader failure at \(stage) should allow H.264 fallback")
        }
    }

    func testInvalidMP4OrTempFileErrorsAreNotMisclassifiedAsCodecFailures() {
        for stage in ["validate-boxes", "create-temp", "write-temp"] {
            XCTAssertFalse(SabrDemuxFallbackPolicy.isCodecSpecificReaderFailure(
                stage: stage, errorDomain: "AVFoundationErrorDomain"))
        }
    }

    func testSessionAndNetworkErrorsMustRemainTerminalToThisPolicy() {
        XCTAssertFalse(SabrDemuxFallbackPolicy.isCodecSpecificReaderFailure(
            stage: "reader-start", errorDomain: "NSURLErrorDomain"))
        XCTAssertFalse(SabrDemuxFallbackPolicy.isCodecSpecificReaderFailure(
            stage: "reader-start", errorDomain: "NSCocoaErrorDomain"))
        XCTAssertFalse(SabrDemuxFallbackPolicy.isCodecSpecificReaderFailure(
            stage: "load-track", errorDomain: "NSOSStatusErrorDomain"))
    }
}
