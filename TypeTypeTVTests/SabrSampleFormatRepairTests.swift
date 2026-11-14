import Foundation
import CoreMedia
import XCTest
@testable import TypeTypeTV

final class SabrSampleFormatRepairTests: XCTestCase {
    func testTrackFormatCanRestoreMissingSampleFormat() throws {
        var block: CMBlockBuffer?
        XCTAssertEqual(CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil, blockLength: 4,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0, dataLength: 4,
            flags: 0, blockBufferOut: &block
        ), noErr)
        let sampleData = try XCTUnwrap(block)
        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: 30),
            presentationTimeStamp: CMTime(value: 10, timescale: 30),
            decodeTimeStamp: CMTime(value: 9, timescale: 30)
        )
        var size = 4
        var incomplete: CMSampleBuffer?
        XCTAssertEqual(CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault,
            dataBuffer: sampleData,
            formatDescription: nil,
            sampleCount: 1,
            sampleTimingEntryCount: 1, sampleTimingArray: &timing,
            sampleSizeEntryCount: 1, sampleSizeArray: &size,
            sampleBufferOut: &incomplete
        ), noErr)
        let original = try XCTUnwrap(incomplete)
        XCTAssertNil(CMSampleBufferGetFormatDescription(original))

        var format: CMVideoFormatDescription?
        XCTAssertEqual(CMVideoFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            codecType: kCMVideoCodecType_H264,
            width: 1920, height: 1080,
            extensions: nil, formatDescriptionOut: &format
        ), noErr)
        let restored = try SabrSampleFormatRepair.repair(
            original, fallback: try XCTUnwrap(format)
        )
        XCTAssertNotNil(CMSampleBufferGetFormatDescription(restored))
        XCTAssertEqual(CMSampleBufferGetNumSamples(restored), 1)
        XCTAssertEqual(CMSampleBufferGetPresentationTimeStamp(restored),
                       CMSampleBufferGetPresentationTimeStamp(original))
        XCTAssertEqual(CMSampleBufferGetSampleSize(restored, at: 0), 4)
    }
}
