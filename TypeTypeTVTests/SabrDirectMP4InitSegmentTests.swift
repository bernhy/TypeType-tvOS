// SPDX-License-Identifier: MPL-2.0
// Adapted from TypeTypePlayerKitTests in TypeType-Video/TypeType-tvOS.
import XCTest
@testable import TypeTypeTV

final class MP4InitSegmentTests: XCTestCase {
  func testReadsVideoTrack() throws {
    let data = Data(MP4TestBoxes.initSegment(video: true, trackID: 1, timescale: 90_000, defaultDuration: 3_000))
    let tracks = try MP4InitSegment.tracks(in: data)
    XCTAssertEqual(tracks.count, 1)
    let track = try XCTUnwrap(tracks.first)
    XCTAssertEqual(track.kind, .video)
    XCTAssertEqual(track.trackID, 1)
    XCTAssertEqual(track.timescale, 90_000)
    XCTAssertEqual(track.codec, MP4FourCC("avc1"))
    XCTAssertEqual(track.width, 1920)
    XCTAssertEqual(track.height, 1080)
    XCTAssertEqual(track.configuration, Data([1, 0x64, 0, 0x28]))
    XCTAssertEqual(track.defaults.duration, 3_000)
  }

  func testReadsAudioTrackWithDescriptorAsCookie() throws {
    let descriptor: [UInt8] = [0x03, 0x19, 0x00, 0x01]
    let data = Data(MP4TestBoxes.initSegment(video: false, trackID: 2, timescale: 44_100, configuration: descriptor))
    let track = try XCTUnwrap(try MP4InitSegment.tracks(in: data).first)
    XCTAssertEqual(track.kind, .audio)
    XCTAssertEqual(track.channelCount, 2)
    XCTAssertEqual(track.sampleRate, 44_100)
    XCTAssertEqual(track.configuration, Data(descriptor))
  }

  func testRejectsTruncatedInit() {
    let bytes = MP4TestBoxes.initSegment(video: true)
    XCTAssertThrowsError(try MP4InitSegment.tracks(in: Data(bytes.dropLast(10))))
  }

  func testReadsVP9CodecConfiguration() throws {
    // vpcC: FullBox version/flags + VP codec fields.
    let config: [UInt8] = [1, 0, 0, 0, 0, 41, 8, 1, 1, 1, 1, 0, 0, 0]
    let bytes = MP4TestBoxes.initSegment(
      video: true, configuration: config, codec: "vp09"
    )
    let track = try XCTUnwrap(try MP4InitSegment.tracks(in: Data(bytes)).first)
    XCTAssertEqual(track.codec, MP4FourCC("vp09"))
    XCTAssertEqual(track.configuration, Data(config))
    XCTAssertEqual(track.width, 1920)
  }

  func testReadsAV1CodecConfiguration() throws {
    let config: [UInt8] = [0x81, 0x00, 0x0C, 0x00]
    let bytes = MP4TestBoxes.initSegment(
      video: true, configuration: config, codec: "av01"
    )
    let track = try XCTUnwrap(try MP4InitSegment.tracks(in: Data(bytes)).first)
    XCTAssertEqual(track.codec, MP4FourCC("av01"))
    XCTAssertEqual(track.configuration, Data(config))
  }

  func testRejectsMalformedAV1CodecConfig() {
    let bytes = MP4TestBoxes.initSegment(
      video: true, configuration: [0x00, 0, 0, 0], codec: "av01"
    )
    XCTAssertThrowsError(try MP4InitSegment.tracks(in: Data(bytes)))
  }
}
