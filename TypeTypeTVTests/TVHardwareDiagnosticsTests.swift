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

    func testDirectRendererReportsFormatButNotUndocumentedHardwareUse() throws {
        var description: CMVideoFormatDescription?
        let status = CMVideoFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            codecType: kCMVideoCodecType_H264,
            width: 1920, height: 1080, extensions: nil,
            formatDescriptionOut: &description
        )
        XCTAssertEqual(status, noErr)
        let format = try XCTUnwrap(description)
        let sample = try MP4SampleBuffers.make(
            samples: [MP4Sample(
                offset: 0, size: 4, decodeTime: 0,
                duration: 3_000, compositionOffset: 0, isSync: true
            )],
            data: Data([0, 0, 0, 1]), timescale: 90_000, format: format
        )
        TVHardwareDiagnostics.shared.recordNativeRendererSample(sample)
        XCTAssertEqual(TVHardwareDiagnostics.shared.lastAttempt?.codec, "avc1")
        XCTAssertEqual(TVHardwareDiagnostics.shared.lastAttempt?.resolution, "1920 × 1080")
    }
}
