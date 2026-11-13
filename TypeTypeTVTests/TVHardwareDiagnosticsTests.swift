import XCTest
import CoreMedia
@testable import TypeTypeTV

@MainActor
final class TVHardwareDiagnosticsTests: XCTestCase {
    func testCodecProbesMatchStrictVideoToolboxQuery() {
        let info = TVHardwareDiagnostics.shared
        info.refresh()
        XCTAssertFalse(info.deviceIdentifier.isEmpty)
        XCTAssertFalse(info.systemVersion.isEmpty)
        XCTAssertEqual(info.probes.map(\.codec), ["avc1", "hvc1", "vp09", "av01"])
        for probe in info.probes {
            XCTAssertEqual(probe.hardwareAvailable,
                           HardwareCodec.supported(probe.codec))
        }
    }

    func testActualDecoderResultIsSeparateFromCodecCapability() {
        let info = TVHardwareDiagnostics.shared
        info.recordDecoderSession(
            codec: CMVideoCodecType(0x61766331),
            width: 1920, height: 1080,
            status: OSStatus(-12900), hardwareUsed: nil
        )
        XCTAssertEqual(info.lastAttempt?.codec, "avc1")
        XCTAssertEqual(info.lastAttempt?.resolution, "1920 × 1080")
        XCTAssertEqual(info.lastAttempt?.status, -12900)
        XCTAssertNil(info.lastAttempt?.hardwareUsed)
        XCTAssertEqual(info.lastAttempt?.decodedFrame, false)
        info.recordDecodedFrame()
        XCTAssertEqual(info.lastAttempt?.decodedFrame, true)
    }
}
