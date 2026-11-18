// SPDX-License-Identifier: MPL-2.0
// Adapted from TypeTypePlayerKitTests in TypeType-Video/TypeType-tvOS.
import AudioToolbox
import CoreMedia
import XCTest
@testable import TypeTypeTV

final class MP4AudioConfigurationTests: XCTestCase {
  static let aacStereo44k: [UInt8] =
    [0x03, 0x19, 0x00, 0x01, 0x00]
    + [0x04, 0x11, 0x40, 0x15, 0x00, 0x00, 0x00, 0x00, 0x01, 0xF4, 0x00, 0x00, 0x01, 0xF4, 0x00]
    + [0x05, 0x02, 0x12, 0x10]
    + [0x06, 0x01, 0x02]

  func testReadsAudioSpecificConfig() throws {
    let config = try MP4AudioConfiguration(descriptor: Data(Self.aacStereo44k))
    XCTAssertEqual(config.objectType, 2)
    XCTAssertEqual(config.sampleRate, 44_100)
    XCTAssertEqual(config.channelCount, 2)
  }

  func testRejectsDescriptorWithoutDecoderConfig() {
    XCTAssertThrowsError(try MP4AudioConfiguration(descriptor: Data([0x03, 0x03, 0x00, 0x01, 0x00, 0x06])))
  }
}

final class MP4FormatDescriptionTests: XCTestCase {
  func testVideoDescriptionCarriesCodecAndSize() throws {
    let track = try XCTUnwrap(try MP4InitSegment.tracks(in: Data(MP4TestBoxes.initSegment(video: true))).first)
    let format = try MP4FormatDescription.make(for: track)
    XCTAssertEqual(CMFormatDescriptionGetMediaType(format), kCMMediaType_Video)
    XCTAssertEqual(format.mediaSubType, .h264)
    let dimensions = CMVideoFormatDescriptionGetDimensions(format)
    XCTAssertEqual(dimensions.width, 1920)
    XCTAssertEqual(dimensions.height, 1080)
  }

  func testAudioDescriptionReadsTheDescriptor() throws {
    let bytes = MP4TestBoxes.initSegment(
      video: false,
      timescale: 44_100,
      configuration: MP4AudioConfigurationTests.aacStereo44k
    )
    let track = try XCTUnwrap(try MP4InitSegment.tracks(in: Data(bytes)).first)
    let format = try MP4FormatDescription.make(for: track)
    let asbd = try XCTUnwrap(CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee)
    XCTAssertEqual(asbd.mFormatID, kAudioFormatMPEG4AAC)
    XCTAssertEqual(asbd.mSampleRate, 44_100)
    XCTAssertEqual(asbd.mChannelsPerFrame, 2)
    // Both isolated A/B trials (stereo layout and AAC-LC flags=2)
    // left the device's internal -12710 warnings unchanged. Keep the
    // original no-layout, flags=0 baseline for the call-site trace.
    XCTAssertEqual(asbd.mFormatFlags, 0)
    var layoutBytes = 0
    XCTAssertNil(CMAudioFormatDescriptionGetChannelLayout(format, sizeOut: &layoutBytes))
    XCTAssertEqual(layoutBytes, 0)
    var cookieBytes = 0
    XCTAssertNotNil(CMAudioFormatDescriptionGetMagicCookie(format, sizeOut: &cookieBytes))
    XCTAssertEqual(cookieBytes, MP4AudioConfigurationTests.aacStereo44k.count)
  }
}

final class MP4SampleBuffersTests: XCTestCase {
  func testOneBufferPerRunWithTimesAndFrameMarks() throws {
    let track = try XCTUnwrap(try MP4InitSegment.tracks(in: Data(MP4TestBoxes.initSegment(video: true))).first)
    let format = try MP4FormatDescription.make(for: track)
    let data = Data([9, 1, 1, 2, 2, 2, 3])
    let samples = [
      MP4Sample(offset: 1, size: 2, decodeTime: 0, duration: 3_000, compositionOffset: 3_000, isSync: true),
      MP4Sample(offset: 3, size: 3, decodeTime: 3_000, duration: 3_000, compositionOffset: 3_000, isSync: false),
      MP4Sample(offset: 6, size: 1, decodeTime: 6_000, duration: 3_000, compositionOffset: 3_000, isSync: false),
    ]
    let buffer = try MP4SampleBuffers.make(
      samples: samples,
      data: data,
      timescale: 90_000,
      format: format,
      hiddenBefore: CMTime(value: 9_000, timescale: 90_000)
    )
    XCTAssertEqual(CMSampleBufferGetNumSamples(buffer), 3)
    XCTAssertEqual(CMSampleBufferGetPresentationTimeStamp(buffer), CMTime(value: 3_000, timescale: 90_000))
    XCTAssertEqual(CMSampleBufferGetTotalSampleSize(buffer), 6)
    let attachments = try XCTUnwrap(
      CMSampleBufferGetSampleAttachmentsArray(buffer, createIfNecessary: false) as? [[CFString: Any]]
    )
    XCTAssertNil(attachments[0][kCMSampleAttachmentKey_NotSync])
    XCTAssertEqual(attachments[1][kCMSampleAttachmentKey_NotSync] as? Bool, true)
    XCTAssertEqual(attachments[0][kCMSampleAttachmentKey_DoNotDisplay] as? Bool, true)
    XCTAssertNil(attachments[2][kCMSampleAttachmentKey_DoNotDisplay])
  }

  func testAACPacketDescriptionsPreserveEverySizeAndExactTimeline() throws {
    let track = try XCTUnwrap(
      try MP4InitSegment.tracks(in: Data(MP4TestBoxes.initSegment(
        video: false,
        timescale: 44_100,
        configuration: MP4AudioConfigurationTests.aacStereo44k
      ))).first
    )
    let data = Data([11, 12, 13, 21, 22, 31, 32, 33, 34, 41])
    let samples = [
      MP4Sample(offset: 0, size: 3, decodeTime: 0,
                duration: 1_024, compositionOffset: 0, isSync: true),
      MP4Sample(offset: 3, size: 2, decodeTime: 1_024,
                duration: 1_024, compositionOffset: 0, isSync: true),
      MP4Sample(offset: 5, size: 4, decodeTime: 2_048,
                duration: 1_024, compositionOffset: 0, isSync: true),
      // Deliberate 1024-tick gap: the audio packet initializer derives a
      // contiguous timeline, but the native SABR player must keep this gap.
      MP4Sample(offset: 9, size: 1, decodeTime: 4_096,
                duration: 1_024, compositionOffset: 0, isSync: true),
    ]
    let result = try MP4SampleBuffers.make(
      samples: samples, data: data, timescale: 44_100,
      format: MP4FormatDescription.make(for: track)
    )
    XCTAssertEqual(CMSampleBufferGetNumSamples(result), 4)
    XCTAssertEqual(CMSampleBufferGetTotalSampleSize(result), data.count)
    for (index, sample) in samples.enumerated() {
      XCTAssertEqual(CMSampleBufferGetSampleSize(result, at: index), sample.size)
      var timing = CMSampleTimingInfo()
      XCTAssertEqual(
        CMSampleBufferGetSampleTimingInfo(
          result, at: index, timingInfoOut: &timing
        ), noErr
      )
      let expected = CMTime(value: CMTimeValue(sample.decodeTime), timescale: 44_100)
      XCTAssertEqual(timing.presentationTimeStamp, expected)
      XCTAssertEqual(timing.decodeTimeStamp, expected)
      XCTAssertEqual(
        timing.duration,
        CMTime(value: CMTimeValue(sample.duration), timescale: 44_100)
      )
    }
    // Crucial distinction from the original generic CMSampleBufferCreateReady:
    // the resulting compressed audio buffer must expose PACKET descriptors.
    var descriptionsPtr: UnsafePointer<AudioStreamPacketDescription>?
    var descriptionBytes = 0
    XCTAssertEqual(
      CMSampleBufferGetAudioStreamPacketDescriptionsPtr(
        result,
        packetDescriptionsPointerOut: &descriptionsPtr,
        sizeOut: &descriptionBytes
      ), noErr
    )
    let descriptions = try XCTUnwrap(descriptionsPtr)
    XCTAssertEqual(descriptionBytes,
                   MemoryLayout<AudioStreamPacketDescription>.stride * samples.count)
    for (index, expectedSize) in [3, 2, 4, 1].enumerated() {
      XCTAssertEqual(Int(descriptions[index].mDataByteSize), expectedSize)
    }
    let block = try XCTUnwrap(CMSampleBufferGetDataBuffer(result))
    var bytes = [UInt8](repeating: 0, count: data.count)
    XCTAssertEqual(CMBlockBufferCopyDataBytes(
      block, atOffset: 0, dataLength: bytes.count, destination: &bytes
    ), noErr)
    XCTAssertEqual(bytes, Array(data))
  }

  func testPacksSamplesThatAreNotContiguous() throws {
    let track = try XCTUnwrap(try MP4InitSegment.tracks(in: Data(MP4TestBoxes.initSegment(video: true))).first)
    let samples = [
      MP4Sample(offset: 0, size: 2, decodeTime: 0, duration: 1, compositionOffset: 0, isSync: true),
      MP4Sample(offset: 4, size: 2, decodeTime: 1, duration: 1, compositionOffset: 0, isSync: true),
    ]
    let buffer = try MP4SampleBuffers.make(
      samples: samples,
      data: Data([1, 1, 0, 0, 2, 2]),
      timescale: 90_000,
      format: try MP4FormatDescription.make(for: track)
    )
    let block = try XCTUnwrap(CMSampleBufferGetDataBuffer(buffer))
    var bytes = [UInt8](repeating: 0, count: 4)
    XCTAssertEqual(CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: 4, destination: &bytes), noErr)
    XCTAssertEqual(bytes, [1, 1, 2, 2])
  }
}
