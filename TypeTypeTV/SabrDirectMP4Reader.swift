import AVFoundation
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
        guard let source = try MP4Fragment.samples(
            in: fragment, tracks: [track]
        )[track.trackID], !source.isEmpty, source.count <= 50_000 else {
            throw MP4Error.invalidBox("empty or oversized media fragment")
        }

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
                throw MP4Error.invalidBox("empty compressed payload")
            }
            buffers.append(buffer)
        }
        return SabrCompressedSampleBatch(buffers: buffers,
                                         selectedRAPMs: selectedRAPMs)
    }
}
