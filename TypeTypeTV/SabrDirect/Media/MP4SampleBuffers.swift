// SPDX-License-Identifier: MPL-2.0
// Adapted from TypeType-Video/TypeType-tvOS TypeTypePlayerKit (Media/MP4SampleBuffers.swift).
// Original sources: https://github.com/TypeType-Video/TypeType-tvOS
// The original MPL-2.0 license is available in LICENSES/MPL-2.0.txt.
import AudioToolbox
import CoreMedia

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
    // A/B v4: For compressed AAC-LC use the CoreMedia audio-specific
    // constructor, which receives a packet description for each variable-size
    // AAC access unit. The earlier generic constructor only supplied sample
    // sizes and timings; the old AVAssetReader supplied audio packet metadata.
    // We retain ALL original per-packet timestamps with a timing-copy so
    // native A/V sync, seeking and presentation gaps remain unchanged.
    // Video, HE-AAC and other formats keep their proven original path.
    if CMFormatDescriptionGetMediaType(format) == kCMMediaType_Audio &&
       CMFormatDescriptionGetMediaSubType(format) == kAudioFormatMPEG4AAC {
      return try makeAACWithPacketDescriptions(
        blockBuffer: blockBuffer,
        samples: samples,
        timings: timings,
        format: format
      )
    }
    var sampleBuffer: CMSampleBuffer?
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
    guard status == noErr, let sampleBuffer else { throw MP4MediaError.sampleBuffer(status) }
    if CMFormatDescriptionGetMediaType(format) == kCMMediaType_Video {
      markFrames(sampleBuffer, samples: samples, timescale: scale, hiddenBefore: hiddenBefore)
    }
    return sampleBuffer
  }

  private static func makeAACWithPacketDescriptions(
    blockBuffer: CMBlockBuffer,
    samples: [MP4Sample],
    timings: [CMSampleTimingInfo],
    format: CMFormatDescription
  ) throws -> CMSampleBuffer {
    var descriptions: [AudioStreamPacketDescription] = []
    descriptions.reserveCapacity(samples.count)
    var byteOffset: Int64 = 0
    for sample in samples {
      guard let byteSize = UInt32(exactly: sample.size), byteSize > 0 else {
        throw MP4Error.invalidBox("AAC packet size")
      }
      descriptions.append(AudioStreamPacketDescription(
        mStartOffset: byteOffset,
        mVariableFramesInPacket: 0,  // ASBD supplies fixed 1024 AAC frames.
        mDataByteSize: byteSize
      ))
      byteOffset += Int64(byteSize)
    }
    var audioBuffer: CMSampleBuffer?
    let audioStatus = descriptions.withUnsafeBufferPointer { descriptions in
      CMAudioSampleBufferCreateReadyWithPacketDescriptions(
        allocator: kCFAllocatorDefault,
        dataBuffer: blockBuffer,
        formatDescription: format,
        sampleCount: samples.count,
        presentationTimeStamp: timings[0].presentationTimeStamp,
        packetDescriptions: descriptions.baseAddress,
        sampleBufferOut: &audioBuffer
      )
    }
    guard audioStatus == noErr, let audioBuffer else {
      throw MP4MediaError.sampleBuffer(audioStatus)
    }
    // Apple's audio-specific constructor derives nominal packet timing from
    // the ASBD. Restore the exact fMP4 per-packet PTS/DTS/duration, including
    // gaps or fragment offsets. This is essential for the existing SABR sync.
    var synchronized: CMSampleBuffer?
    let timingStatus = timings.withUnsafeBufferPointer { entries in
      CMSampleBufferCreateCopyWithNewTiming(
        allocator: kCFAllocatorDefault,
        sampleBuffer: audioBuffer,
        sampleTimingEntryCount: entries.count,
        sampleTimingArray: entries.baseAddress,
        sampleBufferOut: &synchronized
      )
    }
    guard timingStatus == noErr, let synchronized else {
      throw MP4MediaError.sampleBuffer(timingStatus)
    }
    return synchronized
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
