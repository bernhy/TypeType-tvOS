// SPDX-License-Identifier: MPL-2.0
// Adapted from TypeType-Video/TypeType-tvOS TypeTypePlayerKit (MP4/MP4AudioConfiguration.swift).
// Original sources: https://github.com/TypeType-Video/TypeType-tvOS
// The original MPL-2.0 license is available in LICENSES/MPL-2.0.txt.
import Foundation

public struct MP4AudioConfiguration: Equatable, Sendable {
  public let objectType: Int
  public let sampleRate: Double
  public let channelCount: Int

  // ES_Descriptor (0x03) > DecoderConfigDescriptor (0x04) > DecoderSpecificInfo (0x05), which holds the
  // AudioSpecificConfig.
  public init(descriptor: Data) throws {
    let config = try descriptor.withUnsafeBytes { bytes -> Data in
      let reader = MP4ByteReader(bytes: bytes)
      var cursor = 0
      guard try reader.uint8(at: cursor) == 0x03 else { throw MP4Error.invalidBox("esds") }
      cursor = try Self.skipLength(reader, after: cursor + 1)
      let flags = try reader.uint8(at: cursor + 2)
      cursor += 3
      if flags & 0x80 != 0 { cursor += 2 }
      if flags & 0x40 != 0 { cursor += 1 + Int(try reader.uint8(at: cursor)) }
      if flags & 0x20 != 0 { cursor += 2 }
      guard try reader.uint8(at: cursor) == 0x04 else { throw MP4Error.invalidBox("esds") }
      cursor = try Self.skipLength(reader, after: cursor + 1) + 13
      guard try reader.uint8(at: cursor) == 0x05 else { throw MP4Error.invalidBox("esds") }
      let length = try Self.length(reader, at: cursor + 1)
      return try reader.data(length.next..<(length.next + length.value))
    }
    var bits = MP4BitReader(config)
    var objectType = try bits.read(5)
    if objectType == 31 { objectType = 32 + (try bits.read(6)) }
    let frequencyIndex = try bits.read(4)
    let frequencies = [96_000, 88_200, 64_000, 48_000, 44_100, 32_000, 24_000, 22_050, 16_000, 12_000, 11_025, 8_000, 7_350]
    if frequencyIndex == 0xF {
      sampleRate = Double(try bits.read(24))
    } else {
      guard frequencies.indices.contains(frequencyIndex) else { throw MP4Error.invalidBox("esds") }
      sampleRate = Double(frequencies[frequencyIndex])
    }
    self.objectType = objectType
    channelCount = try bits.read(4)
  }

  private static func length(_ reader: MP4ByteReader, at offset: Int) throws -> (value: Int, next: Int) {
    var value = 0
    var cursor = offset
    for _ in 0..<4 {
      let byte = try reader.uint8(at: cursor)
      cursor += 1
      value = value << 7 | Int(byte & 0x7F)
      if byte & 0x80 == 0 { break }
    }
    return (value, cursor)
  }

  private static func skipLength(_ reader: MP4ByteReader, after offset: Int) throws -> Int {
    try length(reader, at: offset).next
  }
}

struct MP4BitReader {
  private let data: Data
  private var position = 0

  init(_ data: Data) {
    self.data = data
  }

  mutating func read(_ count: Int) throws -> Int {
    var value = 0
    for _ in 0..<count {
      let byteIndex = position / 8
      guard byteIndex < data.count else { throw MP4Error.truncated }
      let byte = data[data.startIndex + byteIndex]
      value = value << 1 | Int((byte >> (7 - UInt8(position % 8))) & 1)
      position += 1
    }
    return value
  }
}
