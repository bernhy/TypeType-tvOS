import AVFoundation
import CoreMedia
import Foundation

/// Native fMP4 pipeline based on TypeTypePlayerKit's box/sample reader.
/// Unlike AVAssetReader, this reads moof/traf/trun/tfdt and copies only the
/// referenced mdat sample bytes into CoreMedia buffers without touching disk.
/// The MP4 parser is maintained under MPL-2.0 in SabrDirect/.
/// Native sample-buffer renderers are the only SABR decode path. Unsupported
/// sample entries trigger the existing quality/codec selection fallback,
/// rather than reviving the old temporary-file AVAssetReader pipeline.
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

enum SabrDirectMP4Reader {
    /// Keep compressed A/V within short enqueue units. One entire 5-20s
    /// segment per CMSampleBuffer would let the renderer hold audio/video
    /// for too long while the other track's queue becomes empty.
    static func batchSize(for kind: MP4TrackKind) -> Int {
        switch kind {
        case .video: return 8
        case .audio: return 16
        }
    }

    static func compressedSamples(initialization: Data, fragment: Data,
                                  mediaType: AVMediaType,
                                  presentationStartMs: Int64? = nil) async throws -> [CMSampleBuffer] {
        // The controller is @MainActor. Parsing and copying fMP4 payloads
        // must not block the tvOS UI thread while the playback clock runs.
        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<[CMSampleBuffer], Error>) in
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
                    // Native parser / CoreMedia format errors are a codec
                    // compatibility failure, so automatic selection can try
                    // a different representation. Never expose media URLs.
                    continuation.resume(throwing: SabrFailure.unsupported(
                        "Native fMP4 sample format unavailable"
                    ))
                }
            }
        }
    }

    private static func decode(initialization: Data, fragment: Data,
                               mediaType: AVMediaType,
                               presentationStartMs: Int64?) throws -> [CMSampleBuffer] {
        let kind: MP4TrackKind
        switch mediaType {
        case .video: kind = .video
        case .audio: kind = .audio
        default:
            throw MP4Error.unsupportedCodec(mediaType.rawValue)
        }
        let tracks = try MP4InitSegment.tracks(in: initialization)
        guard let track = tracks.first(where: { $0.kind == kind }) else {
            throw MP4Error.missingBox("trak")
        }
        let format = try MP4FormatDescription.make(for: track)
        guard let sourceSamples = try MP4Fragment.samples(
            in: fragment, tracks: [track]
        )[track.trackID], !sourceSamples.isEmpty, sourceSamples.count <= 50_000 else {
            throw MP4Error.invalidBox("empty or oversized media fragment")
        }
        // Only audio packets that overlap the actual seek target should play.
        // The decoder still receives older video samples for reference-frame
        // preroll, but they are marked DoNotDisplay below.
        let samples: [MP4Sample]
        if kind == .audio, let presentationStartMs, presentationStartMs > 0 {
            samples = sourceSamples.filter {
                !SabrSeekPreroll.isBeforePresentation(
                    sampleStartTicks: $0.presentationTime,
                    durationTicks: $0.duration,
                    timescale: track.timescale,
                    targetMs: presentationStartMs
                )
            }
        } else {
            samples = sourceSamples
        }

        var result: [CMSampleBuffer] = []
        let chunk = batchSize(for: kind)
        result.reserveCapacity((samples.count + chunk - 1) / chunk)
        for position in stride(from: 0, to: samples.count, by: chunk) {
            let end = min(samples.count, position + chunk)
            let buffer = try MP4SampleBuffers.make(
                samples: Array(samples[position..<end]),
                data: fragment, timescale: track.timescale, format: format,
                hiddenBefore: kind == .video ? presentationStartMs.map {
                    CMTime(value: $0, timescale: 1_000)
                } : nil
            )
            // A zero-byte compressed payload must never reach the renderer.
            guard let data = CMSampleBufferGetDataBuffer(buffer),
                  CMBlockBufferGetDataLength(data) > 0 else {
                throw MP4Error.invalidBox("empty compressed payload")
            }
            result.append(buffer)
        }
        return result
    }
}

