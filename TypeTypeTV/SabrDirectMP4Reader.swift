import AVFoundation
import AudioToolbox
import CoreMedia
import CryptoKit
import Foundation

/// Native fMP4 compressed samples: no AVAssetReader or temporary MP4 files.
enum SabrNativePlaybackPolicy {
    static func supports(videoCodec: String, audioCodec: String?,
                         audioMIME: String?) -> Bool {
        let codec = videoCodec.lowercased()
        let video = ["avc1", "avc3", "hvc1", "hev1", "vp09", "vp9", "av01"]
            .contains(where: { codec.hasPrefix($0) })
        let audio = (audioCodec ?? "").lowercased()
        let mime = (audioMIME ?? "").lowercased()
        return video && (audio.hasPrefix("mp4a") || mime.contains("audio/mp4"))
    }
}

/// Only malformed *media fragment bytes* use this marker; an unsupported
/// codec, bad initialization segment or CoreMedia setup error must not
/// trigger pointless segment redownloads.
enum SabrMalformedCompressedMedia: Error {
    case mediaFragment
}

struct SabrCompressedSampleBatch {
    let buffers: [CMSampleBuffer]
    /// Last *reliably flagged* random access frame not after the seek target.
    /// nil means no trustworthy RAP found; retain the existing preroll.
    let selectedRAPMs: Int64?
}

#if DEBUG
/// One-time reference reader for comparing CoreMedia metadata, NOT a playback
/// fallback. All bytes come from an already-downloaded SABR window, so this
/// introduces zero additional network traffic.
private final class SabrAudioReferenceOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var scheduled = false

    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !scheduled else { return false }
        scheduled = true
        return true
    }
}

private enum SabrAudioReferenceDiagnostics {
    static func describe(source: String, sample: CMSampleBuffer,
                         fallback: CMFormatDescription? = nil) {
        let format = CMSampleBufferGetFormatDescription(sample) ?? fallback
        let count = CMSampleBufferGetNumSamples(sample)
        let firstSize = count > 0 ? CMSampleBufferGetSampleSize(sample, at: 0) : 0
        let pts = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sample))
        let dts = CMTimeGetSeconds(CMSampleBufferGetDecodeTimeStamp(sample))
        var timing = CMSampleTimingInfo()
        let timingStatus: OSStatus = count > 0
            ? CMSampleBufferGetSampleTimingInfo(sample, at: 0, timingInfoOut: &timing)
            : -1
        let duration = CMTimeGetSeconds(timing.duration)
        var packetPointer: UnsafePointer<AudioStreamPacketDescription>?
        var packetBytes = 0
        let packetStatus = CMSampleBufferGetAudioStreamPacketDescriptionsPtr(
            sample,
            packetDescriptionsPointerOut: &packetPointer,
            sizeOut: &packetBytes
        )
        let attachments = CMSampleBufferGetSampleAttachmentsArray(
            sample, createIfNecessary: false
        )
        let attachmentCount = (attachments as? [Any])?.count ?? 0
        guard let format else {
            NSLog("TypeType AUDIO-REFERENCE source=%@ format=missing packets=%d bytes=%d",
                  source, count, CMSampleBufferGetTotalSampleSize(sample))
            return
        }
        let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee
        var cookieBytes = 0
        let cookie = CMAudioFormatDescriptionGetMagicCookie(
            format, sizeOut: &cookieBytes
        )
        let cookieDigest: String
        if let cookie, cookieBytes > 0 {
            let bytes = Data(bytes: cookie, count: cookieBytes)
            cookieDigest = SHA256.hash(data: bytes).prefix(6)
                .map { String(format: "%02x", $0) }.joined()
        } else {
            cookieDigest = "none"
        }
        var layoutBytes = 0
        let layoutExists = CMAudioFormatDescriptionGetChannelLayout(
            format, sizeOut: &layoutBytes
        ) != nil
        let extensions = CMFormatDescriptionGetExtensions(format)
        let extensionCount = extensions.map { CFDictionaryGetCount($0) } ?? 0
        NSLog("TypeType AUDIO-REFERENCE source=%@ packets=%d totalBytes=%d firstBytes=%d ptsMs=%.3f dtsMs=%.3f durationMs=%.3f timingStatus=%d packetStatus=%d packetBytes=%d hasPacketPointer=%d attachments=%d asbdRate=%.0f asbdChannels=%d asbdFlags=%u asbdFramesPerPacket=%d cookieBytes=%d cookieSha12=%@ channelLayoutBytes=%d hasLayout=%d extensionCount=%d",
              source, count, CMSampleBufferGetTotalSampleSize(sample), firstSize,
              pts * 1_000, dts * 1_000, duration * 1_000, timingStatus,
              packetStatus, packetBytes, packetPointer == nil ? 0 : 1,
              attachmentCount, asbd?.mSampleRate ?? -1,
              Int(asbd?.mChannelsPerFrame ?? 0),
              asbd?.mFormatFlags ?? 0,
              Int(asbd?.mFramesPerPacket ?? 0),
              cookieBytes, cookieDigest,
              layoutBytes, layoutExists ? 1 : 0, extensionCount)
        // v6: Identify the *actual* AVAssetReader extension key and compact
        // 12-byte channel-layout tag. Earlier stereo A/B supplied a 32-byte
        // layout with no extensions and was therefore not Apple-equivalent.
        // All of this remains offline reference metadata: no playback change.
        let layoutTag = layoutExists
            ? Int(CMAudioFormatDescriptionGetChannelLayout(
                format, sizeOut: &layoutBytes
              )!.pointee.mChannelLayoutTag) : -1
        let channelBitmap = layoutExists
            ? Int(CMAudioFormatDescriptionGetChannelLayout(
                format, sizeOut: &layoutBytes
              )!.pointee.mChannelBitmap.rawValue) : -1
        NSLog("TypeType AUDIO-REFERENCE-DETAIL source=%@ layoutTag=%d layoutBitmap=%d layoutBytes=%d asbdBytesPerPacket=%u asbdBytesPerFrame=%u asbdBitsPerChannel=%u asbdReserved=%u",
              source, layoutTag, channelBitmap, layoutBytes,
              asbd?.mBytesPerPacket ?? 0,
              asbd?.mBytesPerFrame ?? 0,
              asbd?.mBitsPerChannel ?? 0,
              asbd?.mReserved ?? 0)
        if let extensions {
            // Only log extension *names* and value types/sizes, not raw
            // media samples, encoded atoms, personal URLs or tokens.
            let dictionary = extensions as NSDictionary
            for key in dictionary.allKeys {
                guard let value = dictionary[key] else { continue }
                let dataCount = (value as? Data)?.count ?? 0
                let nestedKeys: String
                if let nested = value as? NSDictionary {
                    nestedKeys = nested.allKeys
                        .map { String(describing: $0) }.sorted().joined(separator: ",")
                } else {
                    nestedKeys = "-"
                }
                NSLog("TypeType AUDIO-REFERENCE-EXT source=%@ key=%@ valueType=%@ dataBytes=%d nestedKeys=%@",
                      source, String(describing: key),
                      String(describing: type(of: value)),
                      dataCount, nestedKeys)
            }
        }
    }

    static func readAlreadyDownloadedAudio(
        initialization: Data, fragment: Data
    ) async {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(
            "typetype-audio-reference-\(UUID().uuidString).mp4"
        )
        defer { try? FileManager.default.removeItem(at: file) }
        do {
            guard FileManager.default.createFile(atPath: file.path, contents: nil) else {
                NSLog("TypeType AUDIO-REFERENCE source=avassetreader unavailable=file-create")
                return
            }
            let writer = try FileHandle(forWritingTo: file)
            try writer.write(contentsOf: initialization)
            try writer.write(contentsOf: fragment)
            try writer.close()

            let asset = AVURLAsset(url: file)
            guard let track = try await asset.loadTracks(withMediaType: .audio).first else {
                NSLog("TypeType AUDIO-REFERENCE source=avassetreader unavailable=no-track")
                return
            }
            let fallbackFormat = try await track.load(.formatDescriptions).first
            let reader = try AVAssetReader(asset: asset)
            let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
            output.alwaysCopiesSampleData = false
            guard reader.canAdd(output) else {
                NSLog("TypeType AUDIO-REFERENCE source=avassetreader unavailable=no-output")
                return
            }
            reader.add(output)
            guard reader.startReading() else {
                NSLog("TypeType AUDIO-REFERENCE source=avassetreader unavailable=start status=%d",
                      reader.status.rawValue)
                return
            }
            var examined = 0
            while reader.status == .reading, examined < 12 {
                guard let sample = output.copyNextSampleBuffer() else { break }
                guard CMSampleBufferGetNumSamples(sample) > 0 else { continue }
                if examined == 0 {
                    describe(source: "avassetreader", sample: sample,
                             fallback: fallbackFormat)
                }
                examined += 1
            }
            reader.cancelReading()
            NSLog("TypeType AUDIO-REFERENCE source=avassetreader done=1 inspectedBuffers=%d",
                  examined)
        } catch {
            // Error reason only; do not log file path or media URL.
            NSLog("TypeType AUDIO-REFERENCE source=avassetreader unavailable=reader-error type=%@",
                  String(describing: type(of: error)))
        }
    }
}
#endif

private final class SabrPreparedSampleTrack: NSObject {
    let track: MP4TrackInfo
    let format: CMFormatDescription

    init(track: MP4TrackInfo, format: CMFormatDescription) {
        self.track = track
        self.format = format
    }
}

enum SabrDirectMP4Reader {
    /// Same init segment and track means same format throughout a stream.
    /// Avoid re-parsing moov/stsd and rebuilding the CoreMedia description
    /// for every fragment. Content-hashed keys cannot mix two different inits.
    #if DEBUG
    private static let audioReferenceOnce = SabrAudioReferenceOnce()
    #endif

    private static let trackCache: NSCache<NSString, SabrPreparedSampleTrack> = {
        let cache = NSCache<NSString, SabrPreparedSampleTrack>()
        cache.countLimit = 24
        return cache
    }()

    static func batchSize(for kind: MP4TrackKind) -> Int {
        switch kind {
        case .video:
            #if DEBUG
            // v13 short diagnostic A/B: each grouped video buffer in v12
            // triggered a synchronous -12710 inside renderer.enqueue;
            // the sole one-frame video buffer did not. Test grouping only.
            // Keep native H.264 bytes, sample order, PTS/DTS, A/V clock and
            // SABR transport unchanged. Release retains the proven batch=8.
            NSLog("TypeType VIDEO-BATCH-AB mode=single-frame-v13 nativeBatchSize=1")
            return 1
            #else
            return 8
            #endif
        case .audio: return 16
        }
    }

    static func compressedSamples(initialization: Data, fragment: Data,
                                  mediaType: AVMediaType,
                                  presentationStartMs: Int64? = nil) async throws -> [CMSampleBuffer] {
        try await decodeOffMain(
            initialization: initialization, fragment: fragment,
            mediaType: mediaType, presentationStartMs: presentationStartMs
        ).buffers
    }

    /// Seek-specific decode also reports the last usable keyframe. The
    /// controller can then discard earlier pending (not yet enqueued) GOPs.
    static func compressedSeekVideo(initialization: Data, fragment: Data,
                                    presentationStartMs: Int64?) async throws -> SabrCompressedSampleBatch {
        try await decodeOffMain(
            initialization: initialization, fragment: fragment,
            mediaType: .video, presentationStartMs: presentationStartMs
        )
    }

    private static func decodeOffMain(
        initialization: Data, fragment: Data, mediaType: AVMediaType,
        presentationStartMs: Int64?
    ) async throws -> SabrCompressedSampleBatch {
        // Parsing and compressed-data copies must not block tvOS' UI actor.
        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<SabrCompressedSampleBatch, Error>) in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    continuation.resume(returning: try decode(
                        initialization: initialization, fragment: fragment,
                        mediaType: mediaType,
                        presentationStartMs: presentationStartMs
                    ))
                } catch is CancellationError {
                    continuation.resume(throwing: CancellationError())
                } catch let error as SabrMalformedCompressedMedia {
                    continuation.resume(throwing: error)
                } catch {
                    continuation.resume(throwing: SabrFailure.unsupported(
                        "Native fMP4 sample format unavailable"
                    ))
                }
            }
        }
    }

    private static func preparedTrack(initialization: Data,
                                      kind: MP4TrackKind) throws -> SabrPreparedSampleTrack {
        let digest = SHA256.hash(data: initialization)
            .map { String(format: "%02x", $0) }.joined()
        let key = "\(kind == .audio ? "a" : "v"):\(digest)" as NSString
        if let cached = trackCache.object(forKey: key) { return cached }
        let tracks = try MP4InitSegment.tracks(in: initialization)
        guard let track = tracks.first(where: { $0.kind == kind }) else {
            throw MP4Error.missingBox("trak")
        }
        let cached = SabrPreparedSampleTrack(
            track: track, format: try MP4FormatDescription.make(for: track)
        )
        trackCache.setObject(cached, forKey: key)
        return cached
    }

    /// Validate that an fMP4 media fragment actually contains a coherent
    /// sample run for the selected track. A failed box read is distinct
    /// from a hardware codec/format-creation failure in preparedTrack().
    static func mediaSamples(fragment: Data, track: MP4TrackInfo) throws -> [MP4Sample] {
        do {
            guard let samples = try MP4Fragment.samples(
                in: fragment, tracks: [track]
            )[track.trackID], !samples.isEmpty, samples.count <= 50_000 else {
                throw SabrMalformedCompressedMedia.mediaFragment
            }
            return samples
        } catch {
            throw SabrMalformedCompressedMedia.mediaFragment
        }
    }

    private static func decode(initialization: Data, fragment: Data,
                               mediaType: AVMediaType,
                               presentationStartMs: Int64?) throws -> SabrCompressedSampleBatch {
        let kind: MP4TrackKind
        switch mediaType {
        case .video: kind = .video
        case .audio: kind = .audio
        default: throw MP4Error.unsupportedCodec(mediaType.rawValue)
        }
        let prepared = try preparedTrack(initialization: initialization, kind: kind)
        let track = prepared.track
        let source = try mediaSamples(fragment: fragment, track: track)

        let samples: [MP4Sample]
        var selectedRAPMs: Int64?
        if kind == .audio, let presentationStartMs, presentationStartMs > 0 {
            samples = source.filter {
                !SabrSeekPreroll.isBeforePresentation(
                    sampleStartTicks: $0.presentationTime,
                    durationTicks: $0.duration,
                    timescale: track.timescale,
                    targetMs: presentationStartMs
                )
            }
        } else if kind == .video, let presentationStartMs, presentationStartMs > 0,
                  let index = SabrSeekPreroll.lastReliableSyncBeforeTarget(
                    samples: source, timescale: track.timescale,
                    targetMs: presentationStartMs
                  ) {
            // Keep only samples from the latest true RAP in this fragment.
            // Earlier GOPs are not required to decode this GOP.
            samples = Array(source[index...])
            selectedRAPMs = Int64((Double(source[index].presentationTime) *
                1_000 / Double(track.timescale)).rounded())
        } else {
            samples = source
        }

        var buffers: [CMSampleBuffer] = []
        let chunk = batchSize(for: kind)
        buffers.reserveCapacity((samples.count + chunk - 1) / chunk)
        for position in stride(from: 0, to: samples.count, by: chunk) {
            let end = min(samples.count, position + chunk)
            let buffer = try MP4SampleBuffers.make(
                samples: Array(samples[position..<end]),
                data: fragment, timescale: track.timescale,
                format: prepared.format,
                hiddenBefore: kind == .video ? presentationStartMs.map {
                    CMTime(value: $0, timescale: 1_000)
                } : nil
            )
            guard let bytes = CMSampleBufferGetDataBuffer(buffer),
                  CMBlockBufferGetDataLength(bytes) > 0 else {
                throw SabrMalformedCompressedMedia.mediaFragment
            }
            buffers.append(buffer)
        }
        #if DEBUG
        if kind == .audio, let firstBuffer = buffers.first,
           CMFormatDescriptionGetMediaSubType(prepared.format) == kAudioFormatMPEG4AAC,
           audioReferenceOnce.claim() {
            // Compare format/sample metadata only. AVAssetReader is NOT given
            // to the player and cannot affect our sample order or A/V clock.
            SabrAudioReferenceDiagnostics.describe(
                source: "native-generic", sample: firstBuffer
            )
            let referenceInitialization = initialization
            let referenceFragment = fragment
            Task.detached(priority: .utility) {
                await SabrAudioReferenceDiagnostics.readAlreadyDownloadedAudio(
                    initialization: referenceInitialization,
                    fragment: referenceFragment
                )
            }
        }
        #endif
        return SabrCompressedSampleBatch(buffers: buffers,
                                         selectedRAPMs: selectedRAPMs)
    }
}
