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
    private static let trackCache: NSCache<NSString, SabrPreparedSampleTrack> = {
        let cache = NSCache<NSString, SabrPreparedSampleTrack>()
        cache.countLimit = 24
        return cache
    }()

    static func batchSize(for kind: MP4TrackKind) -> Int {
        switch kind {
        case .video: return 8
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
           CMFormatDescriptionGetMediaSubType(prepared.format) == kAudioFormatMPEG4AAC {
            var packetPointer: UnsafePointer<AudioStreamPacketDescription>?
            var packetBytes = 0
            let packetStatus = CMSampleBufferGetAudioStreamPacketDescriptionsPtr(
                firstBuffer,
                packetDescriptionsPointerOut: &packetPointer,
                sizeOut: &packetBytes
            )
            NSLog("TypeType AUDIO-PACKET-AB mode=packet-descriptions-v4 inputPackets=%d outputBuffers=%d firstBufferPackets=%d packetDescriptionBytes=%d packetStatus=%d packetPointer=%d",
                  samples.count, buffers.count,
                  CMSampleBufferGetNumSamples(firstBuffer),
                  packetBytes, packetStatus, packetPointer == nil ? 0 : 1)
        }
        #endif
        return SabrCompressedSampleBatch(buffers: buffers,
                                         selectedRAPMs: selectedRAPMs)
    }
}
