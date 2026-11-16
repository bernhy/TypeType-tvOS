// SPDX-License-Identifier: MPL-2.0
// Adapted from TypeType-Video/TypeType-tvOS TypeTypePlayerKit (MP4/MP4TrackFragment.swift).
// Original sources: https://github.com/TypeType-Video/TypeType-tvOS
// The original MPL-2.0 license is available in LICENSES/MPL-2.0.txt.
import Foundation

struct MP4TrackFragment {
  var trackID: UInt32 = 0
  var baseDecodeTime: Int64?
  var defaultDuration: UInt32 = 0
  var defaultSize: UInt32 = 0
  var defaultFlags: UInt32 = 0
  var runs: [MP4TrackRun] = []

  static func parse(
    _ reader: MP4ByteReader,
    traf: MP4Box,
    moof: MP4Box,
    defaults: [UInt32: MP4SampleDefaults]
  ) throws -> MP4TrackFragment {
    var fragment = MP4TrackFragment()
    let tfhd = try reader.requiredBox(MP4FourCC("tfhd"), in: traf.content)
    let flags = try reader.uint24(at: tfhd.content.lowerBound + 1)
    var cursor = tfhd.content.lowerBound + 4
    fragment.trackID = try reader.uint32(at: cursor)
    cursor += 4
    let trackDefaults = defaults[fragment.trackID] ?? MP4SampleDefaults()
    var base = moof.start
    if flags & 0x000001 != 0 {
      let explicit = try reader.uint64(at: cursor)
      guard explicit <= UInt64(Int.max) else { throw MP4Error.invalidBox("tfhd") }
      base = Int(explicit)
      cursor += 8
    }
    if flags & 0x000002 != 0 { cursor += 4 }
    fragment.defaultDuration = trackDefaults.duration
    if flags & 0x000008 != 0 {
      fragment.defaultDuration = try reader.uint32(at: cursor)
      cursor += 4
    }
    fragment.defaultSize = trackDefaults.size
    if flags & 0x000010 != 0 {
      fragment.defaultSize = try reader.uint32(at: cursor)
      cursor += 4
    }
    fragment.defaultFlags = trackDefaults.flags
    if flags & 0x000020 != 0 {
      fragment.defaultFlags = try reader.uint32(at: cursor)
    }
    if let tfdt = try reader.firstBox(MP4FourCC("tfdt"), in: traf.content) {
      let version = try reader.uint8(at: tfdt.content.lowerBound)
      let time = version == 1
        ? try reader.uint64(at: tfdt.content.lowerBound + 4)
        : UInt64(try reader.uint32(at: tfdt.content.lowerBound + 4))
      fragment.baseDecodeTime = Int64(clamping: time)
    }
    var dataCursor = base
    for trun in try reader.boxes(in: traf.content) where trun.type == MP4FourCC("trun") {
      let run = try MP4TrackRun.parse(reader, trun: trun, base: base, continuingAt: dataCursor)
      dataCursor = run.dataEnd(fragment)
      fragment.runs.append(run)
    }
    return fragment
  }
}

struct MP4TrackRun {
  var dataOffset: Int
  var firstSampleFlags: UInt32?
  var durations: [UInt32]?
  var sizes: [UInt32]?
  var flags: [UInt32]?
  var compositionOffsets: [Int32]?
  var count: Int

  static func parse(
    _ reader: MP4ByteReader,
    trun: MP4Box,
    base: Int,
    continuingAt cursor: Int
  ) throws -> MP4TrackRun {
    let start = trun.content.lowerBound
    let flags = try reader.uint24(at: start + 1)
    let count = Int(try reader.uint32(at: start + 4))
    var offset = start + 8
    var run = MP4TrackRun(dataOffset: cursor, count: count)
    if flags & 0x000001 != 0 {
      run.dataOffset = base + Int(Int32(bitPattern: try reader.uint32(at: offset)))
      offset += 4
    }
    if flags & 0x000004 != 0 {
      run.firstSampleFlags = try reader.uint32(at: offset)
      offset += 4
    }
    let hasDuration = flags & 0x000100 != 0
    let hasSize = flags & 0x000200 != 0
    let hasFlags = flags & 0x000400 != 0
    let hasComposition = flags & 0x000800 != 0
    let fieldCount = [hasDuration, hasSize, hasFlags, hasComposition].filter { $0 }.count
    guard count >= 0, offset + count * fieldCount * 4 <= trun.end else {
      throw MP4Error.truncated
    }
    var durations: [UInt32] = []
    var sizes: [UInt32] = []
    var sampleFlags: [UInt32] = []
    var compositions: [Int32] = []
    for _ in 0..<count {
      if hasDuration {
        durations.append(try reader.uint32(at: offset))
        offset += 4
      }
      if hasSize {
        sizes.append(try reader.uint32(at: offset))
        offset += 4
      }
      if hasFlags {
        sampleFlags.append(try reader.uint32(at: offset))
        offset += 4
      }
      if hasComposition {
        compositions.append(Int32(bitPattern: try reader.uint32(at: offset)))
        offset += 4
      }
    }
    run.durations = hasDuration ? durations : nil
    run.sizes = hasSize ? sizes : nil
    run.flags = hasFlags ? sampleFlags : nil
    run.compositionOffsets = hasComposition ? compositions : nil
    return run
  }

  func dataEnd(_ fragment: MP4TrackFragment) -> Int {
    dataOffset + (0..<count).reduce(0) { $0 + Int(sizes?[$1] ?? fragment.defaultSize) }
  }

  func appendSamples(
    to samples: inout [MP4Sample],
    decodeTime: inout Int64,
    fragment: MP4TrackFragment,
    dataSize: Int
  ) throws {
    samples.reserveCapacity(samples.count + count)
    var offset = dataOffset
    for index in 0..<count {
      let size = Int(sizes?[index] ?? fragment.defaultSize)
      let duration = durations?[index] ?? fragment.defaultDuration
      let sampleFlags = flags?[index]
        ?? (index == 0 ? firstSampleFlags : nil)
        ?? fragment.defaultFlags
      guard offset >= 0, size >= 0, offset + size <= dataSize else { throw MP4Error.truncated }
      samples.append(
        MP4Sample(
          offset: offset,
          size: size,
          decodeTime: decodeTime,
          duration: duration,
          compositionOffset: compositionOffsets?[index] ?? 0,
          // sample_is_non_sync_sample
          isSync: sampleFlags & 0x0001_0000 == 0
        )
      )
      offset += size
      decodeTime += Int64(duration)
    }
  }
}
