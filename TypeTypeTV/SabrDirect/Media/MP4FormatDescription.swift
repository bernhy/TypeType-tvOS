// SPDX-License-Identifier: MPL-2.0
// Adapted from TypeType-Video/TypeType-tvOS TypeTypePlayerKit (Media/MP4FormatDescription.swift).
// Original sources: https://github.com/TypeType-Video/TypeType-tvOS
// The original MPL-2.0 license is available in LICENSES/MPL-2.0.txt.
import AudioToolbox
import CoreMedia
import Foundation

public enum MP4MediaError: Error, Equatable {
  case formatDescription(OSStatus)
  case blockBuffer(OSStatus)
  case sampleBuffer(OSStatus)
  case emptySegment
}

public enum MP4FormatDescription {
  public static func make(for track: MP4TrackInfo) throws -> CMFormatDescription {
    switch track.kind {
    case .video: return try video(track)
    case .audio: return try audio(track)
    }
  }

  private static func video(_ track: MP4TrackInfo) throws -> CMFormatDescription {
    let codecType: CMVideoCodecType
    let atom: String
    switch track.codec {
    case MP4FourCC("avc1"), MP4FourCC("avc3"):
      codecType = kCMVideoCodecType_H264
      atom = "avcC"
    case MP4FourCC("hvc1"), MP4FourCC("hev1"):
      codecType = kCMVideoCodecType_HEVC
      atom = "hvcC"
    case MP4FourCC("vp09"):
      codecType = kCMVideoCodecType_VP9
      atom = "vpcC"
    case MP4FourCC("av01"):
      codecType = kCMVideoCodecType_AV1
      atom = "av1C"
    default:
      throw MP4Error.unsupportedCodec(track.codec.description)
    }
    let extensions = [
      kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms: [atom: track.configuration],
    ] as CFDictionary
    var description: CMFormatDescription?
    let status = CMVideoFormatDescriptionCreate(
      allocator: kCFAllocatorDefault,
      codecType: codecType,
      width: Int32(track.width),
      height: Int32(track.height),
      extensions: extensions,
      formatDescriptionOut: &description
    )
    guard status == noErr, let description else { throw MP4MediaError.formatDescription(status) }
    return description
  }

  private static func audio(_ track: MP4TrackInfo) throws -> CMFormatDescription {
    let config = try MP4AudioConfiguration(descriptor: track.configuration)
    let formatID: AudioFormatID
    switch config.objectType {
    case 5: formatID = kAudioFormatMPEG4AAC_HE
    case 29: formatID = kAudioFormatMPEG4AAC_HE_V2
    default: formatID = kAudioFormatMPEG4AAC
    }
    // A/B v7: derive the AAC-LC CoreMedia description directly from the
    // ORIGINAL ISO BMFF mp4a sample entry, not from reconstructed fields.
    // AVAssetReader produces a 12-byte stereo layout and preserves the
    // original 'VerbatimISOSampleEntry'; the prior manual stereo A/B did
    // neither exactly. This touches only format metadata, never timestamps,
    // sample sizes, renderer or the native A/V synchronizer.
    if config.objectType == 2,
       track.verbatimAudioSampleEntry.count >= 36,
       track.verbatimAudioSampleEntry.count <= 4_096 {
      var isoFormat: CMAudioFormatDescription?
      let isoStatus = track.verbatimAudioSampleEntry.withUnsafeBytes { bytes -> OSStatus in
        guard let pointer = bytes.bindMemory(to: UInt8.self).baseAddress else {
          return OSStatus(-50) // Standard parameter error; not exported as paramErr in tvOS Swift.
        }
        return CMAudioFormatDescriptionCreateFromBigEndianSoundDescriptionData(
          allocator: kCFAllocatorDefault,
          bigEndianSoundDescriptionData: pointer,
          size: bytes.count,
          flavor: CMSoundDescriptionFlavor.isoFamily,
          formatDescriptionOut: &isoFormat
        )
      }
      if isoStatus == noErr, let isoFormat,
         let actual = CMAudioFormatDescriptionGetStreamBasicDescription(isoFormat)?.pointee,
         actual.mFormatID == formatID,
         actual.mSampleRate == config.sampleRate,
         actual.mChannelsPerFrame == UInt32(config.channelCount),
         actual.mFramesPerPacket == 1_024 {
        var layoutBytes = 0
        let hasLayout = CMAudioFormatDescriptionGetChannelLayout(
          isoFormat, sizeOut: &layoutBytes
        ) != nil
        var cookieBytes = 0
        let hasCookie = CMAudioFormatDescriptionGetMagicCookie(
          isoFormat, sizeOut: &cookieBytes
        ) != nil
        let extensions = CMFormatDescriptionGetExtensions(isoFormat)
        let extensionCount = extensions.map { CFDictionaryGetCount($0) } ?? 0
        NSLog("TypeType AUDIO-FORMAT experiment=iso-sample-entry-v7 mode=iso status=%d entryBytes=%d rate=%.0f channels=%d flags=%u framesPerPacket=%d cookieBytes=%d hasCookie=%d channelLayoutBytes=%d hasLayout=%d extensionCount=%d",
              isoStatus, track.verbatimAudioSampleEntry.count,
              actual.mSampleRate, Int(actual.mChannelsPerFrame),
              actual.mFormatFlags, Int(actual.mFramesPerPacket),
              cookieBytes, hasCookie ? 1 : 0,
              layoutBytes, hasLayout ? 1 : 0, extensionCount)
        return isoFormat
      }
      // A malformed or unusual MP4 entry must NEVER interrupt playback;
      // fall back to the known-working manual esds format instead.
      NSLog("TypeType AUDIO-FORMAT experiment=iso-sample-entry-v7 mode=fallback status=%d entryBytes=%d",
            isoStatus, track.verbatimAudioSampleEntry.count)
    }
    var asbd = AudioStreamBasicDescription(
      mSampleRate: config.sampleRate > 0 ? config.sampleRate : track.sampleRate,
      mFormatID: formatID,
      // The isolated AAC-LC object-type-flags=2 A/B test did not change
      // the recurrent -12710 warnings. Restore the original ASBD to avoid
      // changing playback behavior during the next call-site trace.
      mFormatFlags: 0,
      mBytesPerPacket: 0,
      mFramesPerPacket: 1_024,
      mBytesPerFrame: 0,
      mChannelsPerFrame: UInt32(config.channelCount > 0 ? config.channelCount : track.channelCount),
      mBitsPerChannel: 0,
      mReserved: 0
    )
    var description: CMFormatDescription?
    // The preceding stereo-channel-layout experiment was disproved by
    // real Apple TV playback (same ~3.3 warnings/second despite hasLayout=1).
    // Revert it: retain the original no-layout/ESDS cookie path so that
    // mFormatFlags is the ONLY change relative to the verified baseline.
    let status = track.configuration.withUnsafeBytes { cookie -> OSStatus in
      CMAudioFormatDescriptionCreate(
        allocator: kCFAllocatorDefault,
        asbd: &asbd,
        layoutSize: 0,
        layout: nil,
        magicCookieSize: cookie.count,
        magicCookie: cookie.baseAddress,
        extensions: nil,
        formatDescriptionOut: &description
      )
    }
    guard status == noErr, let description else { throw MP4MediaError.formatDescription(status) }
    // Created once per unique init segment by SabrDirectMP4Reader's cache.
    // -12710 is CoreMedia's InvalidParameter, but the repeated internal
    // warnings may come from later format-layout queries by the renderer.
    // Report only stable numeric metadata: never audio bytes or media URLs.
    let actual = CMAudioFormatDescriptionGetStreamBasicDescription(description)?.pointee
    var channelLayoutBytes = 0
    let hasLayout = CMAudioFormatDescriptionGetChannelLayout(
      description, sizeOut: &channelLayoutBytes
    ) != nil
    var outputCookieBytes = 0
    let hasCookie = CMAudioFormatDescriptionGetMagicCookie(
      description, sizeOut: &outputCookieBytes
    ) != nil
    NSLog("TypeType AUDIO-FORMAT source=esds experiment=iso-sample-entry-v7 mode=manual-fallback objectType=%d inputRate=%.0f inputChannels=%d inputFlags=%u inputCookieBytes=%d actualRate=%.0f actualChannels=%d actualFlags=%u framesPerPacket=%d actualCookieBytes=%d hasCookie=%d channelLayoutBytes=%d hasLayout=%d",
          config.objectType, asbd.mSampleRate, Int(asbd.mChannelsPerFrame),
          asbd.mFormatFlags, track.configuration.count,
          actual?.mSampleRate ?? -1,
          Int(actual?.mChannelsPerFrame ?? 0),
          actual?.mFormatFlags ?? 0,
          Int(actual?.mFramesPerPacket ?? 0),
          outputCookieBytes, hasCookie ? 1 : 0,
          channelLayoutBytes, hasLayout ? 1 : 0)
    return description
  }
}
