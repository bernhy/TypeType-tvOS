// SPDX-License-Identifier: MPL-2.0
// Adapted from TypeTypePlayerKitTests in TypeType-Video/TypeType-tvOS.
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
    // Real playback used AAC-LC / 44.1 kHz / two channels yet CoreMedia
    // reported no layout. This A/B path must now actually embed stereo,
    // not merely log the requested layout.
    var layoutBytes = 0
    let layout = try XCTUnwrap(
      CMAudioFormatDescriptionGetChannelLayout(format, sizeOut: &layoutBytes)
    )
    XCTAssertGreaterThan(layoutBytes, 0)
    XCTAssertEqual(layout.pointee.mChannelLayoutTag, kAudioChannelLayoutTag_Stereo)
    XCTAssertEqual(layout.pointee.mNumberChannelDescriptions, 0)
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
