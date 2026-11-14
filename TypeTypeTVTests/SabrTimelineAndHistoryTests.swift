import AVFoundation
import CoreMedia
import Foundation
import XCTest
@testable import TypeTypeTV

final class SabrTimelineAndHistoryTests: XCTestCase {
    private func sample(at seconds: Int64) throws -> CMSampleBuffer {
        var block: CMBlockBuffer?
        XCTAssertEqual(CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil, blockLength: 4,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0, dataLength: 4,
            flags: 0, blockBufferOut: &block
        ), noErr)
        var description: CMVideoFormatDescription?
        XCTAssertEqual(CMVideoFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            codecType: kCMVideoCodecType_H264, width: 1280, height: 720,
            extensions: nil, formatDescriptionOut: &description
        ), noErr)
        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: 30),
            presentationTimeStamp: CMTime(value: seconds, timescale: 1),
            decodeTimeStamp: CMTime(value: seconds, timescale: 1)
        )
        var size = 4
        var result: CMSampleBuffer?
        XCTAssertEqual(CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault,
            dataBuffer: try XCTUnwrap(block),
            formatDescription: try XCTUnwrap(description),
            sampleCount: 1,
            sampleTimingEntryCount: 1, sampleTimingArray: &timing,
            sampleSizeEntryCount: 1, sampleSizeArray: &size,
            sampleBufferOut: &result
        ), noErr)
        return try XCTUnwrap(result)
    }

    func testSabrFragmentTimelineStartsAtServerMediaTime() throws {
        let original = try [sample(at: 0), sample(at: 1)]
        let aligned = try SabrSampleTimeline.aligned(original, segmentStartMs: 12_000)
        XCTAssertEqual(aligned.count, 2)
        XCTAssertEqual(CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(aligned[0])), 12)
        XCTAssertEqual(CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(aligned[1])), 13)
        XCTAssertEqual(CMTimeGetSeconds(CMSampleBufferGetDecodeTimeStamp(aligned[0])), 12)
        XCTAssertEqual(CMSampleBufferGetSampleSize(aligned[0], at: 0), 4)
    }

    func testSabrRequestClampsClockAheadOfUnbufferedVideo() {
        XCTAssertEqual(
            SabrWindowRequestPosition.position(
                playheadMs: 14_700, contiguousThroughMs: 10_000
            ), 10_000
        )
        XCTAssertEqual(
            SabrWindowRequestPosition.position(
                playheadMs: 4_000, contiguousThroughMs: 10_000
            ), 4_000
        )
        XCTAssertEqual(
            SabrWindowRequestPosition.position(
                playheadMs: -5_000, contiguousThroughMs: 10_000
            ), 0
        )
    }

    func testSabrSegmentGapTriggersBoundedSessionRecovery() {
        let policy = SabrRecoveryPolicy()
        let gap = SabrFailure.invalidResponse(
            "SABR segment gap before next media sample"
        )
        XCTAssertTrue(policy.canRetry(gap, completedAttempts: 1, elapsedSeconds: 2))
        XCTAssertFalse(policy.canRetry(gap, completedAttempts: 8, elapsedSeconds: 2))
        XCTAssertFalse(policy.canRetry(gap, completedAttempts: 1, elapsedSeconds: 130))
        XCTAssertFalse(policy.canRetry(
            SabrFailure.invalidResponse("SABR sample has invalid presentation time"),
            completedAttempts: 1, elapsedSeconds: 2
        ))
    }

    func testDifferentAudioVideoSegmentLengthsUseCommonMediaBoundary() throws {
        // Typical SABR: an AAC fragment covers ten seconds, while the first
        // H.264 fragment covers only five. Segment index pairing would have
        // handed audio 5-10 s to the renderer too early.
        let audio = try (0..<10).map { try sample(at: Int64($0)) }
        let video = try (0..<5).map { try sample(at: Int64($0)) }
        XCTAssertEqual(
            SabrSampleWindow.prefixCount(audio, endingBeforeMs: 5_000), 5
        )
        XCTAssertEqual(
            SabrSampleWindow.prefixCount(video, endingBeforeMs: 5_000), 5
        )
        let nextVideo = try (5..<10).map { try sample(at: Int64($0)) }
        XCTAssertEqual(
            SabrSampleWindow.prefixCount(
                Array(audio.dropFirst(5)), endingBeforeMs: 10_000
            ), 5
        )
        XCTAssertEqual(
            SabrSampleWindow.prefixCount(nextVideo, endingBeforeMs: 10_000), 5
        )
    }

    func testHistoryKeepsOneEntryForRepeatedYouTubePlayback() {
        let a = VideoItem(id: "a", title: "Latest attempt",
                          url: "https://www.youtube.com/watch?v=abc123def45",
                          thumbnailUrl: nil, uploaderName: nil,
                          duration: 300, isLive: false)
        let b = VideoItem(id: "b", title: "Earlier attempt",
                          url: "https://youtu.be/abc123def45",
                          thumbnailUrl: nil, uploaderName: nil,
                          duration: 300, isLive: false)
        let c = VideoItem(id: "c", title: "Different video",
                          url: "https://youtu.be/xyz123def45",
                          thumbnailUrl: nil, uploaderName: nil,
                          duration: 300, isLive: false)
        let items = TVHistoryDeduplicator.unique([a, b, c])
        XCTAssertEqual(items.count, 2)
        XCTAssertEqual(items[0].title, "Latest attempt")
        XCTAssertEqual(items[1].title, "Different video")
    }
}
