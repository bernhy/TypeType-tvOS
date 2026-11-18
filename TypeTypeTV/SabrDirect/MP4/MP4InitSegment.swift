// SPDX-License-Identifier: MPL-2.0
// Adapted from TypeType-Video/TypeType-tvOS TypeTypePlayerKit (MP4/MP4InitSegment.swift).
// Original sources: https://github.com/TypeType-Video/TypeType-tvOS
// The original MPL-2.0 license is available in LICENSES/MPL-2.0.txt.
import Foundation

public enum MP4TrackKind: Hashable, Sendable {
  case video
  case audio
}

public struct MP4TrackInfo: Equatable, Sendable {
  public let trackID: UInt32
  public let kind: MP4TrackKind
  public let timescale: UInt32
  public let codec: MP4FourCC
  public let configuration: Data
  /// The exact big-endian ISO BMFF stsd sample-entry box (header + payload).
  /// Needed for the CoreMedia ISO-family AAC format A/B; empty for video.
  public let verbatimAudioSampleEntry: Data
  public let width: Int
  public let height: Int
  public let channelCount: Int
  public let sampleRate: Double
  public let defaults: MP4SampleDefaults
}

public struct MP4SampleDefaults: Equatable, Sendable {
  public var duration: UInt32 = 0
  public var size: UInt32 = 0
  public var flags: UInt32 = 0
}

public enum MP4InitSegment {
  public static func tracks(in data: Data) throws -> [MP4TrackInfo] {
    try data.withUnsafeBytes { bytes in
      let reader = MP4ByteReader(bytes: bytes)
      let moov = try reader.requiredBox(MP4FourCC("moov"), in: 0..<bytes.count)
      let defaults = try trackDefaults(reader, moov: moov)
      return try reader.boxes(in: moov.content)
        .filter { $0.type == MP4FourCC("trak") }
        .compactMap { try track(reader, trak: $0, defaults: defaults) }
    }
  }

  private static func trackDefaults(
    _ reader: MP4ByteReader,
    moov: MP4Box
  ) throws -> [UInt32: MP4SampleDefaults] {
    guard let mvex = try reader.firstBox(MP4FourCC("mvex"), in: moov.content) else {
      return [:]
    }
    var result: [UInt32: MP4SampleDefaults] = [:]
    for trex in try reader.boxes(in: mvex.content) where trex.type == MP4FourCC("trex") {
      let base = trex.content.lowerBound
      result[try reader.uint32(at: base + 4)] = MP4SampleDefaults(
        duration: try reader.uint32(at: base + 12),
        size: try reader.uint32(at: base + 16),
        flags: try reader.uint32(at: base + 20)
      )
    }
    return result
  }

  private static func track(
    _ reader: MP4ByteReader,
    trak: MP4Box,
    defaults: [UInt32: MP4SampleDefaults]
  ) throws -> MP4TrackInfo? {
    let tkhd = try reader.requiredBox(MP4FourCC("tkhd"), in: trak.content)
    let tkhdVersion = try reader.uint8(at: tkhd.content.lowerBound)
    let trackID = try reader.uint32(at: tkhd.content.lowerBound + (tkhdVersion == 1 ? 20 : 12))
    let mdia = try reader.requiredBox(MP4FourCC("mdia"), in: trak.content)
    let mdhd = try reader.requiredBox(MP4FourCC("mdhd"), in: mdia.content)
    let mdhdVersion = try reader.uint8(at: mdhd.content.lowerBound)
    let timescale = try reader.uint32(at: mdhd.content.lowerBound + (mdhdVersion == 1 ? 20 : 12))
    let hdlr = try reader.requiredBox(MP4FourCC("hdlr"), in: mdia.content)
    let handler = try reader.fourCC(at: hdlr.content.lowerBound + 8)
    let kind: MP4TrackKind
    switch handler {
    case MP4FourCC("vide"): kind = .video
    case MP4FourCC("soun"): kind = .audio
    default: return nil
    }
    let minf = try reader.requiredBox(MP4FourCC("minf"), in: mdia.content)
    let stbl = try reader.requiredBox(MP4FourCC("stbl"), in: minf.content)
    let stsd = try reader.requiredBox(MP4FourCC("stsd"), in: stbl.content)
    let entriesStart = stsd.content.lowerBound + 8
    guard let entry = try reader.boxes(in: entriesStart..<stsd.end).first else {
      throw MP4Error.missingBox("stsd entry")
    }
    let sampleEntry = try MP4SampleEntry.parse(reader, entry: entry, kind: kind)
    guard timescale > 0 else { throw MP4Error.invalidBox("mdhd") }
    return MP4TrackInfo(
      trackID: trackID,
      kind: kind,
      timescale: timescale,
      codec: entry.type,
      configuration: sampleEntry.configuration,
      verbatimAudioSampleEntry: kind == .audio
        ? try reader.data(entry.start..<entry.end) : Data(),
      width: sampleEntry.width,
      height: sampleEntry.height,
      channelCount: sampleEntry.channelCount,
      sampleRate: sampleEntry.sampleRate,
      defaults: defaults[trackID] ?? MP4SampleDefaults()
    )
  }
}
