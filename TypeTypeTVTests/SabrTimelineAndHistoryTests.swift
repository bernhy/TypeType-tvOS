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

    private func bigEndian(_ value: UInt64, count: Int) -> Data {
        Data((0..<count).reversed().map { index in
            UInt8((value >> (index * 8)) & 0xff)
        })
    }

    private func mp4Box(_ type: String, payload: Data) -> Data {
        bigEndian(UInt64(payload.count + 8), count: 4) + Data(type.utf8) + payload
    }

    func testReadsNativeDecodeTimeFromRealIsoBmffBoxLayout() {
        let mdhd = mp4Box("mdhd", payload:
            Data([0, 0, 0, 0]) + bigEndian(0, count: 4) +
            bigEndian(0, count: 4) + bigEndian(90_000, count: 4) +
            bigEndian(0, count: 4))
        let initBytes = mp4Box("ftyp", payload: Data([0, 0, 0, 0])) +
            mp4Box("moov", payload:
                mp4Box("trak", payload: mp4Box("mdia", payload: mdhd)))
        let tfdt = mp4Box("tfdt", payload:
            Data([1, 0, 0, 0]) + bigEndian(90_000 * 644, count: 8))
        let media = mp4Box("moof", payload:
            mp4Box("traf", payload: tfdt)) +
            mp4Box("mdat", payload: Data(repeating: 1, count: 500))
        XCTAssertEqual(SabrMP4NativeTiming.decodeStartMs(
            initialization: initBytes, fragment: media
        ), 644_000)
        XCTAssertNil(SabrMP4NativeTiming.decodeStartMs(
            initialization: initBytes, fragment: Data([0, 0, 0, 8])
        ))
        XCTAssertNil(SabrMP4NativeTiming.decodeStartMs(
            initialization: initBytes, fragment: Data()
        ))
    }

    func testNativeTimelineCorrectsOnlyVerifiedContiguousMetadataJump() {
        var tracker = SabrNativeTimelineResolver()
        for index in 0..<3 {
            let begin = Int64(60_000 + index * 6_000)
            let decision = tracker.resolve(
                sequence: 10 + index, metadataStartMs: begin,
                decodeStartMs: begin + 10
            )
            XCTAssertEqual(decision.startMs, begin)
            XCTAssertFalse(decision.corrected)
            tracker.recordActualEndMs(begin + 6_000)
        }
        // Metadata claims 80s, but tfdt progression and the real preceding
        // sample end independently establish that the next sample starts at 78s.
        let corrected = tracker.resolve(
            sequence: 13, metadataStartMs: 80_000, decodeStartMs: 78_010
        )
        XCTAssertTrue(corrected.corrected)
        XCTAssertEqual(corrected.startMs, 78_000)

        tracker.recordActualEndMs(84_000)
        let followup = tracker.resolve(
            sequence: 14, metadataStartMs: 86_000, decodeStartMs: 84_010
        )
        // Keep the corrected native timebase while server metadata is still
        // offset by 2 seconds on subsequent consecutive fragments.
        XCTAssertTrue(followup.corrected)
        XCTAssertEqual(followup.startMs, 84_000)
    }

    func testNativeTimelineRejectsUnprovenOrMissingSequenceCorrection() {
        var insufficient = SabrNativeTimelineResolver()
        _ = insufficient.resolve(sequence: 10, metadataStartMs: 60_000,
                                 decodeStartMs: 60_010)
        // No direct continuity evidence: the preceding sample ended 300ms
        // before the candidate native start, so preserve metadata.
        insufficient.recordActualEndMs(65_700)
        let firstJump = insufficient.resolve(sequence: 11, metadataStartMs: 70_000,
                                             decodeStartMs: 66_010)
        XCTAssertFalse(firstJump.corrected)
        XCTAssertEqual(firstJump.startMs, 70_000)

        var missing = SabrNativeTimelineResolver()
        for index in 0..<3 {
            let begin = Int64(60_000 + index * 6_000)
            _ = missing.resolve(sequence: 10 + index,
                                metadataStartMs: begin, decodeStartMs: begin + 10)
            missing.recordActualEndMs(begin + 6_000)
        }
        let discontinuous = missing.resolve(sequence: 14,
                                            metadataStartMs: 80_000,
                                            decodeStartMs: 78_010)
        XCTAssertFalse(discontinuous.corrected)

        // A reset to zero tfdt on every fragment is not a valid timebase.
        var zeroDecode = SabrNativeTimelineResolver()
        _ = zeroDecode.resolve(sequence: 1, metadataStartMs: 10_000, decodeStartMs: 0)
        zeroDecode.recordActualEndMs(15_000)
        XCTAssertFalse(zeroDecode.resolve(
            sequence: 2, metadataStartMs: 18_000, decodeStartMs: 0
        ).corrected)
    }

    func testNativeTimelineCorrectsObservedSevenSecondJumpWithoutWarmup() {
        var tracker = SabrNativeTimelineResolver()
        let preceding = tracker.resolve(
            sequence: 397, metadataStartMs: 2_170_968,
            decodeStartMs: 2_170_968
        )
        XCTAssertFalse(preceding.corrected)
        tracker.recordActualEndMs(2_177_975)
        let shifted = tracker.resolve(
            sequence: 398, metadataStartMs: 2_184_915,
            decodeStartMs: 2_177_975
        )
        XCTAssertTrue(shifted.corrected)
        XCTAssertEqual(shifted.startMs, 2_177_975)
    }

    func testSampleTimingExtendsCoverageOnlyWhenFramesProveIt() throws {
        let observed = try [sample(at: 0), sample(at: 1), sample(at: 3)]
        XCTAssertEqual(SabrSampleTimingProbe.actualEndMs(observed), 3_034)
        let segment = SabrFragment(
            url: "https://example.org/sabr/playback/session/137/segment/119",
            startMs: 0, durationMs: 2_000
        )
        let adjusted = SabrSampleTimingProbe.measuredFragment(
            segment, startMs: 0, actualEndMs: 3_034
        )
        XCTAssertEqual(adjusted.durationMs, 3_034)
        XCTAssertEqual(SabrSampleTimingProbe.measuredFragment(
            segment, startMs: 0, actualEndMs: 200_000
        ).durationMs, 2_000)
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
