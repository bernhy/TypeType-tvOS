// SPDX-License-Identifier: MPL-2.0
// Adapted from TypeType-Video/TypeType-tvOS TypeTypePlayerKit (MP4/MP4SampleEntry.swift).
// Original sources: https://github.com/TypeType-Video/TypeType-tvOS
// The original MPL-2.0 license is available in LICENSES/MPL-2.0.txt.
import Foundation

struct MP4SampleEntry {
  var configuration = Data()
  var width = 0
  var height = 0
  var channelCount = 0
  var sampleRate = 0.0

  // Child boxes follow 78 bytes of VisualSampleEntry, 28 of AudioSampleEntry v0.
  private static let visualHeader = 78
  private static let audioHeader = 28

  static func parse(
    _ reader: MP4ByteReader,
    entry: MP4Box,
    kind: MP4TrackKind
  ) throws -> MP4SampleEntry {
    let base = entry.content.lowerBound
    var result = MP4SampleEntry()
    switch kind {
    case .video:
      let configType: MP4FourCC
      switch entry.type {
      case MP4FourCC("avc1"), MP4FourCC("avc3"): configType = MP4FourCC("avcC")
      case MP4FourCC("hvc1"), MP4FourCC("hev1"): configType = MP4FourCC("hvcC")
      default: throw MP4Error.unsupportedCodec(entry.type.description)
      }
      result.width = Int(try reader.uint16(at: base + 24))
      result.height = Int(try reader.uint16(at: base + 26))
      let config = try reader.requiredBox(configType, in: (base + visualHeader)..<entry.end)
      result.configuration = try reader.data(config.content)
    case .audio:
      guard entry.type == MP4FourCC("mp4a") else {
        throw MP4Error.unsupportedCodec(entry.type.description)
      }
      result.channelCount = Int(try reader.uint16(at: base + 16))
      result.sampleRate = Double(try reader.uint32(at: base + 24) >> 16)
      let esds = try reader.requiredBox(MP4FourCC("esds"), in: (base + audioHeader)..<entry.end)
      // Core Audio's cookie is the ES descriptor, without the full-box header.
      result.configuration = try reader.data((esds.content.lowerBound + 4)..<esds.end)
    }
    return result
  }
}
