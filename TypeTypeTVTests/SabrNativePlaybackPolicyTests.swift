import XCTest
@testable import TypeTypeTV

final class SabrNativePlaybackPolicyTests: XCTestCase {
    func testAllFourSupportedVideoFamiliesUseDirectPath() {
        for codec in [
            "avc1.640028", "avc3.4d401f", "hvc1.1.6.L120",
            "hev1.1.6.L120", "vp09.00.41.08", "vp9",
            "av01.0.08M.08"
        ] {
            XCTAssertTrue(SabrNativePlaybackPolicy.supports(
                videoCodec: codec, audioCodec: "mp4a.40.2", audioMIME: "audio/mp4"
            ), codec)
        }
    }

    func testUnsupportedCodecsAndNonAACAudioDoNotSilentlyProceed() {
        XCTAssertFalse(SabrNativePlaybackPolicy.supports(
            videoCodec: "unknown", audioCodec: "mp4a.40.2", audioMIME: "audio/mp4"
        ))
        XCTAssertFalse(SabrNativePlaybackPolicy.supports(
            videoCodec: "vp09", audioCodec: "opus", audioMIME: "audio/webm"
        ))
    }
}
