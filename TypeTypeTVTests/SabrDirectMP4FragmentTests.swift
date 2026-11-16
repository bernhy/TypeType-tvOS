// SPDX-License-Identifier: MPL-2.0
// Adapted from TypeTypePlayerKitTests in TypeType-Video/TypeType-tvOS.
import XCTest
@testable import TypeTypeTV

final class MP4FragmentTests: XCTestCase {
  private typealias B = MP4TestBoxes

  private func track(defaultDuration: UInt32 = 0) throws -> MP4TrackInfo {
    try XCTUnwrap(
      try MP4InitSegment.tracks(in: Data(B.initSegment(video: true, defaultDuration: defaultDuration))).first
    )
  }

  private func segment(
    baseTime: UInt64,
    sizes: [UInt32],
    durations: [UInt32]?,
    flags: [UInt32]?,
    compositions: [Int32]?
  ) -> [UInt8] {
    var trunFlags: UInt32 = 0x000001 | 0x000200
    if durations != nil { trunFlags |= 0x000100 }
    if flags != nil { trunFlags |= 0x000400 }
    if compositions != nil { trunFlags |= 0x000800 }
    func trun(dataOffset: UInt32) -> [UInt8] {
      var payload = B.u32(UInt32(sizes.count)) + B.u32(dataOffset)
      for index in sizes.indices {
        if let durations { payload += B.u32(durations[index]) }
        payload += B.u32(sizes[index])
        if let flags { payload += B.u32(flags[index]) }
        if let compositions { payload += B.u32(UInt32(bitPattern: compositions[index])) }
      }
      return B.fullBox("trun", version: 1, flags: trunFlags, payload)
    }
    func moof(dataOffset: UInt32) -> [UInt8] {
      let tfhd = B.fullBox("tfhd", flags: 0x020000, B.u32(1))
      let tfdt = B.fullBox("tfdt", version: 1, B.u64(baseTime))
      return B.box("moof", B.fullBox("mfhd", B.u32(1)) + B.box("traf", tfhd + tfdt + trun(dataOffset: dataOffset)))
    }
    let moofSize = UInt32(moof(dataOffset: 0).count)
    let payload = sizes.enumerated().flatMap { index, size in
      [UInt8](repeating: UInt8(index + 1), count: Int(size))
    }
    return moof(dataOffset: moofSize + 8) + B.box("mdat", payload)
  }

  func testReadsSampleRangesTimesAndKeyframes() throws {
    let bytes = segment(
      baseTime: 900_000,
      sizes: [5, 3, 4],
      durations: [3_000, 3_000, 3_000],
      flags: [0x0200_0000, 0x0101_0000, 0x0101_0000],
      compositions: [6_000, -3_000, 0]
    )
    let samples = try XCTUnwrap(try MP4Fragment.samples(in: Data(bytes), tracks: [try track()])[1])
    XCTAssertEqual(samples.count, 3)
    XCTAssertEqual(samples.map(\.size), [5, 3, 4])
    XCTAssertEqual(samples.map(\.decodeTime), [900_000, 903_000, 906_000])
    XCTAssertEqual(samples.map(\.presentationTime), [906_000, 900_000, 906_000])
    XCTAssertEqual(samples.map(\.isSync), [true, false, false])
    let first = try XCTUnwrap(samples.first)
    XCTAssertEqual(Array(bytes[first.offset..<(first.offset + first.size)]), [1, 1, 1, 1, 1])
    XCTAssertEqual(samples[1].offset, first.offset + 5)
  }

  func testUsesTrackDefaultsWhenTheRunOmitsFields() throws {
    let bytes = segment(baseTime: 0, sizes: [2, 2], durations: nil, flags: nil, compositions: nil)
    let samples = try XCTUnwrap(
      try MP4Fragment.samples(in: Data(bytes), tracks: [try track(defaultDuration: 1_001)])[1]
    )
    XCTAssertEqual(samples.map(\.decodeTime), [0, 1_001])
    XCTAssertEqual(samples.map(\.duration), [1_001, 1_001])
    XCTAssertEqual(samples.map(\.isSync), [true, true])
  }

  func testRejectsSamplesPastTheData() throws {
    let bytes = segment(baseTime: 0, sizes: [4], durations: [1], flags: nil, compositions: nil)
    XCTAssertThrowsError(try MP4Fragment.samples(in: Data(bytes.dropLast(2)), tracks: [try track()]))
  }
}
