// SPDX-License-Identifier: MPL-2.0
// Adapted from TypeType-Video/TypeType-tvOS TypeTypePlayerKit (MP4/MP4ByteReader.swift).
// Original sources: https://github.com/TypeType-Video/TypeType-tvOS
// The original MPL-2.0 license is available in LICENSES/MPL-2.0.txt.
import Foundation

struct MP4ByteReader {
  let bytes: UnsafeRawBufferPointer

  func uint8(at offset: Int) throws -> UInt8 {
    try check(offset, 1)
    return bytes[offset]
  }

  func uint16(at offset: Int) throws -> UInt16 {
    try check(offset, 2)
    return UInt16(bytes[offset]) << 8 | UInt16(bytes[offset + 1])
  }

  func uint24(at offset: Int) throws -> UInt32 {
    try check(offset, 3)
    return UInt32(bytes[offset]) << 16 | UInt32(bytes[offset + 1]) << 8
      | UInt32(bytes[offset + 2])
  }

  func uint32(at offset: Int) throws -> UInt32 {
    try check(offset, 4)
    return UInt32(bytes[offset]) << 24 | UInt32(bytes[offset + 1]) << 16
      | UInt32(bytes[offset + 2]) << 8 | UInt32(bytes[offset + 3])
  }

  func uint64(at offset: Int) throws -> UInt64 {
    UInt64(try uint32(at: offset)) << 32 | UInt64(try uint32(at: offset + 4))
  }

  func fourCC(at offset: Int) throws -> MP4FourCC {
    MP4FourCC(rawValue: try uint32(at: offset))
  }

  func data(_ range: Range<Int>) throws -> Data {
    try check(range.lowerBound, range.count)
    return Data(bytes[range])
  }

  private func check(_ offset: Int, _ count: Int) throws {
    guard offset >= 0, count >= 0, offset + count <= bytes.count else {
      throw MP4Error.truncated
    }
  }
}

public struct MP4FourCC: Hashable, Sendable, CustomStringConvertible {
  public let rawValue: UInt32

  public init(rawValue: UInt32) {
    self.rawValue = rawValue
  }

  public init(_ text: StaticString) {
    var value: UInt32 = 0
    text.withUTF8Buffer { buffer in
      for byte in buffer.prefix(4) {
        value = value << 8 | UInt32(byte)
      }
    }
    rawValue = value
  }

  public var description: String {
    let scalars = [24, 16, 8, 0].map { UInt8(truncatingIfNeeded: rawValue >> $0) }
    return String(decoding: scalars, as: UTF8.self)
  }
}

public enum MP4Error: Error, Equatable {
  case truncated
  case missingBox(String)
  case unsupportedCodec(String)
  case invalidBox(String)
}
