// SPDX-License-Identifier: MPL-2.0
// Adapted from TypeType-Video/TypeType-tvOS TypeTypePlayerKit (MP4/MP4Box.swift).
// Original sources: https://github.com/TypeType-Video/TypeType-tvOS
// The original MPL-2.0 license is available in LICENSES/MPL-2.0.txt.
import Foundation

struct MP4Box {
  let type: MP4FourCC
  let start: Int
  let content: Range<Int>

  var end: Int { content.upperBound }
}

extension MP4ByteReader {
  func boxes(in range: Range<Int>) throws -> [MP4Box] {
    var boxes: [MP4Box] = []
    var offset = range.lowerBound
    while offset + 8 <= range.upperBound {
      let size32 = try uint32(at: offset)
      let type = try fourCC(at: offset + 4)
      var header = 8
      let size: Int
      switch size32 {
      case 0:
        size = range.upperBound - offset
      case 1:
        let large = try uint64(at: offset + 8)
        guard large <= UInt64(Int.max) else { throw MP4Error.invalidBox(type.description) }
        size = Int(large)
        header = 16
      default:
        size = Int(size32)
      }
      guard size >= header, offset + size <= range.upperBound else {
        throw MP4Error.truncated
      }
      boxes.append(MP4Box(type: type, start: offset, content: (offset + header)..<(offset + size)))
      offset += size
    }
    return boxes
  }

  func firstBox(_ type: MP4FourCC, in range: Range<Int>) throws -> MP4Box? {
    try boxes(in: range).first { $0.type == type }
  }

  func requiredBox(_ type: MP4FourCC, in range: Range<Int>) throws -> MP4Box {
    guard let box = try firstBox(type, in: range) else {
      throw MP4Error.missingBox(type.description)
    }
    return box
  }
}
