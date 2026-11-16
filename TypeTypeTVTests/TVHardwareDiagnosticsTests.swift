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
        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: 30),
            presentationTimeStamp: .zero, decodeTimeStamp: .zero
        )
        var sample: CMSampleBuffer?
        XCTAssertEqual(CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault, dataBuffer: nil,
            formatDescription: format, sampleCount: 1,
            sampleTimingEntryCount: 1, sampleTimingArray: &timing,
            sampleSizeEntryCount: 0, sampleSizeArray: nil,
            sampleBufferOut: &sample
        ), noErr)
        TVHardwareDiagnostics.shared.recordNativeRendererSample(try XCTUnwrap(sample))
        XCTAssertEqual(TVHardwareDiagnostics.shared.lastAttempt?.codec, "avc1")
        XCTAssertEqual(TVHardwareDiagnostics.shared.lastAttempt?.resolution, "1920 × 1080")
    }
}
