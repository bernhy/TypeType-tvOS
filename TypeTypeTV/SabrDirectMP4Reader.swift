import AVFoundation
import CoreMedia
import Foundation

/// Native fMP4 pipeline based on TypeTypePlayerKit's box/sample reader.
/// Unlike AVAssetReader, this reads moof/traf/trun/tfdt and copies only the
/// referenced mdat sample bytes into CoreMedia buffers without touching disk.
/// The MP4 parser is maintained under MPL-2.0 in SabrDirect/.
enum SabrNativePlaybackPolicy {
    static let defaultsKey = "typetype.sabrDirectMP4Enabled"

    static func usesDirectRenderer(videoCodec: String, audioCodec: String?,
                                   audioMIME: String?,
                                   defaults: UserDefaults = .standard) -> Bool {
        // Enabled for this experimental branch. Setting false explicitly
        // leaves the preexisting AVAssetReader + VideoToolbox path intact.
        if defaults.object(forKey: defaultsKey) as? Bool == false { return false }
        let video = videoCodec.lowercased()
        let h26x = video.hasPrefix("avc1") || video.hasPrefix("avc3")
            || video.hasPrefix("hvc1") || video.hasPrefix("hev1")
            || video.hasPrefix("vp09") || video.hasPrefix("vp9")
            || video.hasPrefix("av01")
        let audio = (audioCodec ?? "").lowercased()
        let mime = (audioMIME ?? "").lowercased()
        return h26x && (audio.hasPrefix("mp4a") || mime.contains("audio/mp4"))
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
                } catch {
                    continuation.resume(throwing: error)
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

/// A direct-parser failure is non-terminal: use the proven AVAssetReader
/// demuxer for this particular segment, without changing session generation
/// or losing the old SABR recovery, timestamp and AAC trim logic.
enum SabrMediaDemux {
    static func samples(initialization: Data, fragment: Data,
                        mediaType: AVMediaType, direct: Bool,
                        presentationStartMs: Int64? = nil) async throws -> [CMSampleBuffer] {
        guard direct else {
            return try await FragmentedMP4Reader.compressedSamples(
                initialization: initialization, fragment: fragment, mediaType: mediaType
            )
        }
        do {
            return try await SabrDirectMP4Reader.compressedSamples(
                initialization: initialization, fragment: fragment,
                mediaType: mediaType, presentationStartMs: presentationStartMs
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            // No URLs, session IDs, bearer tokens or private media bytes in logs.
            let family: String
            switch error {
            case is MP4Error: family = "box"
            case is MP4MediaError: family = "sample"
            default: family = "other"
            }
            NSLog("TypeType SABR DIRECT demux-fallback track=%@ family=%@ initBytes=%d mediaBytes=%d",
                  mediaType.rawValue, family, initialization.count, fragment.count)
            return try await FragmentedMP4Reader.compressedSamples(
                initialization: initialization, fragment: fragment, mediaType: mediaType
            )
        }
    }
}
