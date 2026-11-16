// SPDX-License-Identifier: MPL-2.0
// Adapted from TypeType-Video/TypeType-tvOS TypeTypePlayerKit (MP4/MP4Fragment.swift).
// Original sources: https://github.com/TypeType-Video/TypeType-tvOS
// The original MPL-2.0 license is available in LICENSES/MPL-2.0.txt.
import Foundation

public struct MP4Sample: Equatable, Sendable {
  public let offset: Int
  public let size: Int
  public let decodeTime: Int64
  public let duration: UInt32
  public let compositionOffset: Int32
  public let isSync: Bool

  public var presentationTime: Int64 { decodeTime + Int64(compositionOffset) }
}

public enum MP4Fragment {
  public static func samples(
    in data: Data,
    tracks: [MP4TrackInfo]
  ) throws -> [UInt32: [MP4Sample]] {
    let defaults = Dictionary(uniqueKeysWithValues: tracks.map { ($0.trackID, $0.defaults) })
    return try data.withUnsafeBytes { bytes in
      let reader = MP4ByteReader(bytes: bytes)
      var result: [UInt32: [MP4Sample]] = [:]
      var nextDecodeTime: [UInt32: Int64] = [:]
      for moof in try reader.boxes(in: 0..<bytes.count) where moof.type == MP4FourCC("moof") {
        for traf in try reader.boxes(in: moof.content) where traf.type == MP4FourCC("traf") {
          let fragment = try MP4TrackFragment.parse(reader, traf: traf, moof: moof, defaults: defaults)
          var decodeTime = fragment.baseDecodeTime ?? nextDecodeTime[fragment.trackID] ?? 0
          var samples = result[fragment.trackID] ?? []
          for run in fragment.runs {
            try run.appendSamples(
              to: &samples,
              decodeTime: &decodeTime,
              fragment: fragment,
              dataSize: bytes.count
            )
          }
          result[fragment.trackID] = samples
          nextDecodeTime[fragment.trackID] = decodeTime
        }
      }
      return result
    }
  }
}
