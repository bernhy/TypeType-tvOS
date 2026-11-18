// SPDX-License-Identifier: MPL-2.0
// Adapted from TypeType-Video/TypeType-tvOS TypeTypePlayerKit (Media/MP4SampleBuffers.swift).
// Original sources: https://github.com/TypeType-Video/TypeType-tvOS
// The original MPL-2.0 license is available in LICENSES/MPL-2.0.txt.
import CoreMedia
import Foundation

public enum MP4SampleBuffers {
  // `hiddenBefore`: frames presented earlier are decoded but not shown, so a seek can start from the previous
  // keyframe without flashing it.
  public static func make(
    samples: [MP4Sample],
    data: Data,
    timescale: UInt32,
    format: CMFormatDescription,
    hiddenBefore: CMTime? = nil
  ) throws -> CMSampleBuffer {
    guard let first = samples.first, let last = samples.last else {
      throw MP4MediaError.emptySegment
    }
    let blockBuffer = try makeBlockBuffer(samples: samples, data: data, first: first, last: last)
    let scale = CMTimeScale(timescale)
    var timings = samples.map { sample in
      CMSampleTimingInfo(
        duration: CMTime(value: CMTimeValue(sample.duration), timescale: scale),
        presentationTimeStamp: CMTime(value: sample.presentationTime, timescale: scale),
        decodeTimeStamp: CMTime(value: sample.decodeTime, timescale: scale)
      )
    }
    var sizes = samples.map(\.size)
    var sampleBuffer: CMSampleBuffer?
    #if DEBUG && COREMEDIA_12710_TRACE
    // v11: trace the actual audio CMSampleBuffer constructor boundary.
    // All rendering and packet/timing data remain unchanged. Matching
    // before/after markers distinguish synchronous failures from downstream
    // work or calls made elsewhere in CoreMedia.
    let traceAudio = CMFormatDescriptionGetMediaType(format) == kCMMediaType_Audio
    if traceAudio {
      NSLog("TypeType AUDIO-CREATE phase=before count=%d firstPtsMs=%.3f bytes=%d",
            samples.count,
            CMTimeGetSeconds(timings[0].presentationTimeStamp) * 1_000,
            sizes.reduce(0, +))
    }
    #endif
    let status = CMSampleBufferCreateReady(
      allocator: kCFAllocatorDefault,
      dataBuffer: blockBuffer,
      formatDescription: format,
      sampleCount: samples.count,
      sampleTimingEntryCount: timings.count,
      sampleTimingArray: &timings,
      sampleSizeEntryCount: sizes.count,
      sampleSizeArray: &sizes,
      sampleBufferOut: &sampleBuffer
    )
    #if DEBUG && COREMEDIA_12710_TRACE
    if traceAudio {
      NSLog("TypeType AUDIO-CREATE phase=after status=%d ready=%d count=%d",
            status, sampleBuffer == nil ? 0 : 1, samples.count)
    }
    #endif
    guard status == noErr, let sampleBuffer else { throw MP4MediaError.sampleBuffer(status) }
    if CMFormatDescriptionGetMediaType(format) == kCMMediaType_Video {
      markFrames(sampleBuffer, samples: samples, timescale: scale, hiddenBefore: hiddenBefore)
    }
    return sampleBuffer
  }

  private static func makeBlockBuffer(
    samples: [MP4Sample],
    data: Data,
    first: MP4Sample,
    last: MP4Sample
  ) throws -> CMBlockBuffer {
    let contiguous = zip(samples, samples.dropFirst()).allSatisfy { $0.offset + $0.size == $1.offset }
    let length = contiguous
      ? last.offset + last.size - first.offset
      : samples.reduce(0) { $0 + $1.size }
    var block: CMBlockBuffer?
    var status = CMBlockBufferCreateWithMemoryBlock(
      allocator: kCFAllocatorDefault,
      memoryBlock: nil,
      blockLength: length,
      blockAllocator: kCFAllocatorDefault,
      customBlockSource: nil,
      offsetToData: 0,
      dataLength: length,
      flags: kCMBlockBufferAssureMemoryNowFlag,
      blockBufferOut: &block
    )
    guard status == noErr, let block else { throw MP4MediaError.blockBuffer(status) }
    status = data.withUnsafeBytes { bytes -> OSStatus in
      guard let base = bytes.baseAddress else { return kCMBlockBufferBadPointerParameterErr }
      if contiguous {
        return CMBlockBufferReplaceDataBytes(
          with: base + first.offset,
          blockBuffer: block,
          offsetIntoDestination: 0,
          dataLength: length
        )
      }
      var destination = 0
      for sample in samples {
        let result = CMBlockBufferReplaceDataBytes(
          with: base + sample.offset,
          blockBuffer: block,
          offsetIntoDestination: destination,
          dataLength: sample.size
        )
        guard result == noErr else { return result }
        destination += sample.size
      }
      return noErr
    }
    guard status == noErr else { throw MP4MediaError.blockBuffer(status) }
    return block
  }

  private static func markFrames(
    _ sampleBuffer: CMSampleBuffer,
    samples: [MP4Sample],
    timescale: CMTimeScale,
    hiddenBefore: CMTime?
  ) {
    guard let attachments = CMSampleBufferGetSampleAttachmentsArray(
      sampleBuffer,
      createIfNecessary: true
    ) as? [NSMutableDictionary] else {
      return
    }
    for (sample, attachment) in zip(samples, attachments) {
      if !sample.isSync {
        attachment[kCMSampleAttachmentKey_NotSync] = true
      }
      attachment[kCMSampleAttachmentKey_DependsOnOthers] = !sample.isSync
      if let hiddenBefore,
        CMTime(value: sample.presentationTime, timescale: timescale) < hiddenBefore {
        attachment[kCMSampleAttachmentKey_DoNotDisplay] = true
      }
    }
  }
}
