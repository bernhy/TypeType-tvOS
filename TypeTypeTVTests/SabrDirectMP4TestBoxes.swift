// SPDX-License-Identifier: MPL-2.0
// Adapted from TypeTypePlayerKitTests in TypeType-Video/TypeType-tvOS.
import Foundation

enum MP4TestBoxes {
  static func box(_ type: String, _ payload: [UInt8]) -> [UInt8] {
    u32(UInt32(8 + payload.count)) + Array(type.utf8) + payload
  }

  static func fullBox(_ type: String, version: UInt8 = 0, flags: UInt32 = 0, _ payload: [UInt8]) -> [UInt8] {
    box(type, [version] + Array(u32(flags).dropFirst()) + payload)
  }

  static func u16(_ value: UInt16) -> [UInt8] {
    [UInt8(value >> 8), UInt8(value & 0xFF)]
  }

  static func u32(_ value: UInt32) -> [UInt8] {
    [24, 16, 8, 0].map { UInt8(truncatingIfNeeded: value >> $0) }
  }

  static func u64(_ value: UInt64) -> [UInt8] {
    u32(UInt32(value >> 32)) + u32(UInt32(value & 0xFFFF_FFFF))
  }

  static func zeros(_ count: Int) -> [UInt8] {
    [UInt8](repeating: 0, count: count)
  }

  static func initSegment(
    video: Bool,
    trackID: UInt32 = 1,
    timescale: UInt32 = 90_000,
    configuration: [UInt8] = [1, 0x64, 0, 0x28],
    codec: String = "avc1",
    defaultDuration: UInt32 = 0
  ) -> [UInt8] {
    let tkhd = fullBox("tkhd", u32(0) + u32(0) + u32(trackID) + zeros(68))
    let mdhd = fullBox("mdhd", u32(0) + u32(0) + u32(timescale) + u32(0) + zeros(4))
    let hdlr = fullBox("hdlr", u32(0) + Array((video ? "vide" : "soun").utf8) + zeros(12) + [0])
    let entry: [UInt8]
    if video {
      entry = box(
        codec,
        zeros(6) + u16(1) + zeros(16) + u16(1920) + u16(1080) + zeros(50)
          + box(codec == "vp09" ? "vpcC" : (codec == "av01" ? "av1C" : "avcC"), configuration)
      )
    } else {
      entry = box(
        "mp4a",
        zeros(6) + u16(1) + zeros(8) + u16(2) + u16(16) + zeros(4) + u32(44_100 << 16)
          + fullBox("esds", configuration)
      )
    }
    let stsd = fullBox("stsd", u32(1) + entry)
    let trak = box("trak", tkhd + box("mdia", mdhd + hdlr + box("minf", box("stbl", stsd))))
    let trex = fullBox("trex", u32(trackID) + u32(1) + u32(defaultDuration) + u32(0) + u32(0))
    return box("ftyp", Array("iso6".utf8) + u32(0)) + box("moov", trak + box("mvex", trex))
  }
}
