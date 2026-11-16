import Foundation
import SwiftUI
import UIKit
import AVFoundation
import CoreMedia
import VideoToolbox

/// A resumed stream can have a nonzero playhead before the initial SABR
/// response tells us its duration. Clamp the HUD value explicitly; SwiftUI
/// otherwise reports out-of-bounds ProgressView warnings every second.
enum SabrProgressDisplay {
    static func total(durationMs: Int64) -> Double {
        max(1, Double(max(0, durationMs)) / 1_000)
    }

    static func value(_ seconds: Double, durationMs: Int64) -> Double {
        guard seconds.isFinite else { return 0 }
        return min(total(durationMs: durationMs), max(0, seconds))
    }
}

/// Some tvOS AVAssetReader builds deliver compressed fMP4 CMSampleBuffers
/// without their CMFormatDescription. Recover it from the AVAssetTrack rather
/// than passing an undecodable sample into VideoToolbox. Preserve each sample's
/// timing and byte boundaries (important for B-frames and multi-sample audio).
enum SabrSampleFormatRepair {
    static func repair(_ sample: CMSampleBuffer,
                       fallback: CMFormatDescription?) throws -> CMSampleBuffer {
        if CMSampleBufferGetFormatDescription(sample) != nil { return sample }
        guard let fallback else {
            throw SabrFailure.invalidResponse("SABR MP4 track has no codec format description")
        }
        guard let block = CMSampleBufferGetDataBuffer(sample) else {
            throw SabrFailure.invalidResponse("SABR compressed sample has no data buffer")
        }
        let count = CMSampleBufferGetNumSamples(sample)
        guard count > 0 && count <= 2_000 else {
            throw SabrFailure.invalidResponse("SABR sample count out of bounds")
        }
        var timings: [CMSampleTimingInfo] = []
        var sizes: [Int] = []
        timings.reserveCapacity(count)
        sizes.reserveCapacity(count)
        for index in 0..<count {
            var timing = CMSampleTimingInfo()
            guard CMSampleBufferGetSampleTimingInfo(
                sample, at: index, timingInfoOut: &timing
            ) == noErr else {
                throw SabrFailure.invalidResponse("SABR sample timing unavailable")
            }
            let size = CMSampleBufferGetSampleSize(sample, at: index)
            guard size > 0 else {
                throw SabrFailure.invalidResponse("SABR sample byte length unavailable")
            }
            timings.append(timing)
            sizes.append(size)
        }
        var repaired: CMSampleBuffer?
        let status = timings.withUnsafeBufferPointer { timingBuffer in
            sizes.withUnsafeBufferPointer { sizeBuffer in
                CMSampleBufferCreateReady(
                    allocator: kCFAllocatorDefault,
                    dataBuffer: block, formatDescription: fallback,
                    sampleCount: count,
                    sampleTimingEntryCount: count, sampleTimingArray: timingBuffer.baseAddress,
                    sampleSizeEntryCount: count, sampleSizeArray: sizeBuffer.baseAddress,
                    sampleBufferOut: &repaired
                )
            }
        }
        guard status == noErr, let repaired else {
            throw SabrFailure.invalidResponse("SABR codec format repair failed (CM \(status))")
        }
        return repaired
    }
}

/// Count compressed samples belonging to the media interval covered by
/// BOTH tracks. Samples remain in original per-track decode order (including
/// B-frames); the boundary is a prefix so we never reorder decode dependencies.
enum SabrSampleWindow {
    static func prefixCount(_ samples: [CMSampleBuffer],
                            endingBeforeMs edge: Int64) -> Int {
        guard edge > 0 else { return 0 }
        var count = 0
        for sample in samples {
            // AVC B-frames arrive in decode order, not PTS order. Prefer
            // monotonic DTS when present; checking PTS can strand earlier
            // B-frames behind a future P-frame at a segment boundary.
            let sampleCount = CMSampleBufferGetNumSamples(sample)
            guard sampleCount > 0 else { break }
            var tail = CMSampleTimingInfo()
            guard CMSampleBufferGetSampleTimingInfo(
                sample, at: sampleCount - 1, timingInfoOut: &tail
            ) == noErr else { break }
            let dts = CMTimeGetSeconds(tail.decodeTimeStamp)
            let pts = CMTimeGetSeconds(tail.presentationTimeStamp)
            let time = dts.isFinite ? dts : pts
            // Boundary is exclusive: an exact sample at 5.000s belongs to
            // the NEXT A/V window, not the one ending at 5.000s.
            guard time.isFinite, time * 1_000 < Double(edge) else { break }
            count += 1
        }
        return count
    }
}

/// An isolated fMP4 fragment can be demuxed with timestamps relative to its
/// own beginning, even when the server delivered an absolute timeline window.
/// Anchor each track's presentation timestamps to the server segment start,
/// preserving sample durations, decode ordering and A/V offsets within a track.
/// Without this, each fragment can replay at time zero and the renderers
/// display frames as fast as they are enqueued.
enum SabrSampleTimeline {
    static func aligned(_ samples: [CMSampleBuffer],
                        segmentStartMs: Int64) throws -> [CMSampleBuffer] {
        guard !samples.isEmpty else { return samples }
        var earliest: CMTime?
        for sample in samples {
            for i in 0..<CMSampleBufferGetNumSamples(sample) {
                var timing = CMSampleTimingInfo()
                guard CMSampleBufferGetSampleTimingInfo(
                    sample, at: i, timingInfoOut: &timing
                ) == noErr,
                CMTimeGetSeconds(timing.presentationTimeStamp).isFinite else {
                    throw SabrFailure.invalidResponse("SABR sample has invalid presentation time")
                }
                if earliest == nil ||
                    CMTimeCompare(timing.presentationTimeStamp, earliest!) < 0 {
                    earliest = timing.presentationTimeStamp
                }
            }
        }
        guard let earliest else { return samples }
        let desired = CMTime(value: max(0, segmentStartMs), timescale: 1_000)
        let offset = CMTimeSubtract(desired, earliest)
        if CMTimeCompare(offset, .zero) == 0 { return samples }

        return try samples.map { sample in
            let count = CMSampleBufferGetNumSamples(sample)
            var timings: [CMSampleTimingInfo] = []
            timings.reserveCapacity(count)
            for i in 0..<count {
                var item = CMSampleTimingInfo()
                guard CMSampleBufferGetSampleTimingInfo(
                    sample, at: i, timingInfoOut: &item
                ) == noErr else {
                    throw SabrFailure.invalidResponse("SABR sample timing unavailable")
                }
                item.presentationTimeStamp = CMTimeAdd(item.presentationTimeStamp, offset)
                if CMTimeGetSeconds(item.decodeTimeStamp).isFinite {
                    item.decodeTimeStamp = CMTimeAdd(item.decodeTimeStamp, offset)
                }
                timings.append(item)
            }
            var copy: CMSampleBuffer?
            let code = timings.withUnsafeBufferPointer {
                CMSampleBufferCreateCopyWithNewTiming(
                    allocator: kCFAllocatorDefault, sampleBuffer: sample,
                    sampleTimingEntryCount: count,
                    sampleTimingArray: $0.baseAddress, sampleBufferOut: &copy
                )
            }
            guard code == noErr, let copy else {
                throw SabrFailure.invalidResponse("SABR timestamp alignment failed (CM \(code))")
            }
            return copy
        }
    }
}

/// Diagnostics only: compare raw fMP4 presentation times with the
/// server-provided fragment metadata before applying the tvOS timestamp
/// alignment. We cannot assume a metadata gap means missing decoded frames.
enum SabrSampleTimingProbe {
    /// The native compressed sample clock begins at the first actual PTS,
    /// which can differ slightly from the server's rounded segmentStartMs.
    static func actualStartMs(_ samples: [CMSampleBuffer]) -> Int64? {
        var firstSeconds = Double.infinity
        for sample in samples {
            for index in 0..<CMSampleBufferGetNumSamples(sample) {
                var timing = CMSampleTimingInfo()
                guard CMSampleBufferGetSampleTimingInfo(
                    sample, at: index, timingInfoOut: &timing
                ) == noErr else { continue }
                let pts = CMTimeGetSeconds(timing.presentationTimeStamp)
                guard pts.isFinite, pts >= 0, pts <= 7 * 24 * 60 * 60 else { continue }
                firstSeconds = min(firstSeconds, pts)
            }
        }
        guard firstSeconds.isFinite else { return nil }
        return Int64((firstSeconds * 1_000).rounded())
    }

    /// Actual presentation end, including the duration of the final frame.
    /// Unlike the SABR header, this is measured from decoded fMP4 sample
    /// timing, without assuming the advertised fragment duration is correct.
    static func actualEndMs(_ samples: [CMSampleBuffer]) -> Int64? {
        var endSeconds = -Double.infinity
        for sample in samples {
            for index in 0..<CMSampleBufferGetNumSamples(sample) {
                var timing = CMSampleTimingInfo()
                guard CMSampleBufferGetSampleTimingInfo(
                    sample, at: index, timingInfoOut: &timing
                ) == noErr else { continue }
                let pts = CMTimeGetSeconds(timing.presentationTimeStamp)
                let duration = CMTimeGetSeconds(timing.duration)
                guard pts.isFinite, pts >= 0, pts <= 7 * 24 * 60 * 60,
                      duration.isFinite, duration > 0, duration <= 5 else { continue }
                endSeconds = max(endSeconds, pts + duration)
            }
        }
        guard endSeconds.isFinite else { return nil }
        return Int64(ceil(endSeconds * 1_000))
    }

    /// Use sample evidence to correct a fragment's *coverage*, without
    /// extending it beyond a bounded duration or inventing compressed frames.
    static func measuredFragment(_ segment: SabrFragment, startMs: Int64,
                                 actualEndMs: Int64?) -> SabrFragment {
        guard startMs >= 0, segment.durationMs > 0,
              startMs <= Int64.max - segment.durationMs else { return segment }
        let nominalEnd = startMs + segment.durationMs
        let extra = max(30_000, min(120_000, min(segment.durationMs, 60_000) * 2))
        let cap = startMs <= Int64.max - extra ? startMs + extra : Int64.max
        let measuredEnd = actualEndMs.flatMap { $0 >= startMs && $0 <= cap ? $0 : nil }
        let end = max(nominalEnd, measuredEnd ?? nominalEnd)
        return SabrFragment(url: segment.url, startMs: startMs,
                            durationMs: end - startMs)
    }

    #if DEBUG
    static func logEvidence(track: String, itag: Int, sequence: Int?,
                            metadataStartMs: Int64, metadataDurationMs: Int64,
                            nativeStartMs: Int64?, resolvedStartMs: Int64,
                            priorSampleEndMs: Int64?, actualEndMs: Int64?,
                            corrected: Bool) {
        guard metadataStartMs >= 0, metadataDurationMs > 0,
              metadataStartMs <= Int64.max - metadataDurationMs else { return }
        let metadataEnd = metadataStartMs + metadataDurationMs
        let durationDifference = actualEndMs.map { $0 - metadataEnd } ?? 0
        let sampleGap = priorSampleEndMs.map { resolvedStartMs - $0 } ?? 0
        guard corrected || abs(durationDifference) > 250 || abs(sampleGap) > 250 else { return }
        NSLog("TypeType SABR TIMELINE track=%@ itag=%d seq=%d metadataStartMs=%lld metadataEndMs=%lld nativeDecodeMs=%lld resolvedStartMs=%lld priorSampleEndMs=%lld actualSampleEndMs=%lld sampleGapMs=%lld corrected=%d",
              track, itag, sequence ?? -1, metadataStartMs, metadataEnd,
              nativeStartMs ?? -1, resolvedStartMs, priorSampleEndMs ?? -1,
              actualEndMs ?? -1, sampleGap, corrected ? 1 : 0)
    }
    #endif
}

/// AVAssetReader opens each fMP4 segment as a temporary standalone MP4.
/// It therefore emits a file-start AAC priming trim on every fragment, even
/// though the compressed AAC packets are fed into one continuous audio
/// renderer. That repeated trim caused reproducible ~48ms audio dropouts
/// at 44.1kHz. Retain the trim for the first/seek/discontinuous segment, but
/// remove the redundant start trim on strictly contiguous subsequent chunks.
enum SabrAACPrimingPolicy {
    static func isSeamlessContinuation(
        previousSequence: Int?, sequence: Int?,
        previousEndMs: Int64?, startMs: Int64
    ) -> Bool {
        guard let previousSequence, let sequence, let previousEndMs,
              sequence == previousSequence + 1,
              startMs >= 0, previousEndMs >= 0 else { return false }
        let delta = startMs - previousEndMs
        return delta >= -80 && delta <= 80
    }

    struct Markers {
        var startTrim = 0
        var endTrim = 0
        var decoderReset = 0
        var decoderDrain = 0
    }

    static func inspect(_ samples: [CMSampleBuffer]) -> Markers {
        var markers = Markers()
        for sample in samples {
            if CMGetAttachment(sample, key: kCMSampleBufferAttachmentKey_TrimDurationAtStart,
                               attachmentModeOut: nil) != nil { markers.startTrim += 1 }
            if CMGetAttachment(sample, key: kCMSampleBufferAttachmentKey_TrimDurationAtEnd,
                               attachmentModeOut: nil) != nil { markers.endTrim += 1 }
            if CMGetAttachment(sample, key: kCMSampleBufferAttachmentKey_ResetDecoderBeforeDecoding,
                               attachmentModeOut: nil) != nil { markers.decoderReset += 1 }
            if CMGetAttachment(sample, key: kCMSampleBufferAttachmentKey_DrainAfterDecoding,
                               attachmentModeOut: nil) != nil { markers.decoderDrain += 1 }
        }
        return markers
    }

    /// Never override an actual decoder/discontinuity instruction or a
    /// nonstandard fragment that has multiple trim markers.
    static func shouldRemoveRepeatedTrim(continuation: Bool, markers: Markers) -> Bool {
        continuation && markers.startTrim == 1 && markers.endTrim == 0
            && markers.decoderReset == 0 && markers.decoderDrain == 0
    }

    /// A legitimate repeated *file-start* marker belongs on the first
    /// CMSampleBuffer. Do not strip markers from later buffers in the fragment.
    @discardableResult
    static func removeRepeatedStartTrim(_ samples: [CMSampleBuffer]) -> Bool {
        guard let first = samples.first,
              CMGetAttachment(first, key: kCMSampleBufferAttachmentKey_TrimDurationAtStart,
                              attachmentModeOut: nil) != nil else { return false }
        CMRemoveAttachment(first, key: kCMSampleBufferAttachmentKey_TrimDurationAtStart)
        return CMGetAttachment(first, key: kCMSampleBufferAttachmentKey_TrimDurationAtStart,
                               attachmentModeOut: nil) == nil
    }
}

// Client-local fMP4 reader. TypeType Server remains untouched.
// A track consists of the init box sequence (ftyp/moov) and a single media fragment (moof/mdat).
// AVAssetReader is asked for compressed samples (outputSettings:nil) so decoding stays in VideoToolbox.
enum FragmentedMP4Reader {
    static func compressedSamples(initialization: Data, fragment: Data,
                                  mediaType: AVMediaType) async throws -> [CMSampleBuffer] {
        guard !initialization.isEmpty && !fragment.isEmpty else {
            throw SabrFailure.invalidResponse("empty MP4 fragment")
        }
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("typetype-\(UUID().uuidString).mp4")
        // Do not log the filename or segment URLs: these are session-private.
        var stage = "validate-boxes"
        var codec: FourCharCode = 0
        var sourceSamples = 0
        var noDataSamples = 0
        do {
            try SabrMP4Boxes.validate(initialization: initialization, fragment: fragment)
            stage = "create-temp"
            guard FileManager.default.createFile(atPath: file.path, contents: nil) else {
                throw SabrFailure.invalidResponse("Cannot create temporary MP4 segment")
            }
            defer { try? FileManager.default.removeItem(at: file) }
            stage = "write-temp"
            do {
                let writer = try FileHandle(forWritingTo: file)
                defer { try? writer.close() }
                // Do not concatenate large fragments in memory.
                try writer.write(contentsOf: initialization)
                try writer.write(contentsOf: fragment)
            }
            let asset = AVURLAsset(url: file)
            stage = "load-track"
            let tracks = try await asset.loadTracks(withMediaType: mediaType)
            guard let track = tracks.first else {
                throw SabrFailure.unsupported(
                    "AVAssetReader could not find a \(mediaType.rawValue) track")
            }
            stage = "load-format"
            let trackFormat = try await track.load(.formatDescriptions).first
            if let trackFormat {
                codec = CMFormatDescriptionGetMediaSubType(trackFormat)
            }
            stage = "reader-create"
            let reader = try AVAssetReader(asset: asset)
            let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
            output.alwaysCopiesSampleData = false
            stage = "reader-add"
            guard reader.canAdd(output) else {
                throw SabrFailure.unsupported(
                    "Compressed \(mediaType.rawValue) reader unavailable")
            }
            reader.add(output)
            stage = "reader-start"
            guard reader.startReading() else {
                throw reader.error ?? SabrFailure.invalidResponse("MP4 reader could not start")
            }
            var samples: [CMSampleBuffer] = []
            stage = "sample-read"
            while reader.status == .reading {
                guard let sample = output.copyNextSampleBuffer() else { break }
                // A zero-count CMSampleBuffer is a marker, not compressed data.
                let count = CMSampleBufferGetNumSamples(sample)
                guard count > 0 else { continue }
                sourceSamples += count
                if CMSampleBufferGetDataBuffer(sample) == nil {
                    noDataSamples += count
                    #if DEBUG
                    // A nonzero-count image buffer with no compressed bytes
                    // means the native reader is NOT providing the compressed
                    // samples required by our VideoToolbox pipeline.
                    NSLog("TypeType SABR DEMUX-NODATA media=%@ codec=0x%08x samples=%d imageBuffer=%d",
                          mediaType.rawValue, codec, count,
                          CMSampleBufferGetImageBuffer(sample) == nil ? 0 : 1)
                    #endif
                }
                stage = "sample-format"
                samples.append(try SabrSampleFormatRepair.repair(
                    sample, fallback: trackFormat
                ))
                if samples.count > 2_000 {
                    reader.cancelReading()
                    throw SabrFailure.invalidResponse("unreasonably large media fragment")
                }
                stage = "sample-read"
            }
            stage = "reader-finish"
            if reader.status == .failed {
                throw reader.error ?? SabrFailure.invalidResponse("MP4 read failed")
            }
            if samples.isEmpty && mediaType == .video {
                throw SabrFailure.unsupported(
                    "AVAssetReader could not expose compressed video samples")
            }
            return samples
        } catch {
            #if DEBUG
            // The error's localized text may contain upstream media URLs.
            // Only log a fixed stage, numeric code, codec and byte counts.
            let ns = error as NSError
            let safeDomain = ns.domain == "AVFoundationErrorDomain" ? "AVFoundation" :
                (ns.domain == "NSOSStatusErrorDomain" ? "OSStatus" : "other")
            NSLog("TypeType SABR DEMUX-FAIL stage=%@ media=%@ codec=0x%08x errorDomain=%@ errorCode=%d initBytes=%d fragmentBytes=%d sourceSamples=%d noDataSamples=%d",
                  stage, mediaType.rawValue, codec, safeDomain, ns.code,
                  initialization.count, fragment.count, sourceSamples, noDataSamples)
            #endif
            // AVAssetReader can reject a codec before it emits even one
            // compressed sample. That is a track-specific format failure,
            // not a terminal SABR/login failure: allow the player to try
            // the next representation (e.g. H.264 1080p).
            if mediaType == .video &&
                SabrDemuxFallbackPolicy.isCodecSpecificReaderFailure(
                    stage: stage, errorDomain: (error as NSError).domain
                ) {
                throw SabrFailure.unsupported(
                    "AVAssetReader cannot demux this video representation")
            }
            throw error
        }
    }
}

/// Some AVFoundation errors arise before VideoToolbox can be reached. Treat
/// only native *video reader* failures as codec-specific; do not turn network,
/// access, or temporary-file errors into representation retries.
enum SabrDemuxFallbackPolicy {
    static func isCodecSpecificReaderFailure(stage: String, errorDomain: String) -> Bool {
        // A native reader can surface unsupported codec errors under
        // either the AVFoundation or CoreMedia/VideoToolbox OSStatus domain.
        guard errorDomain == "AVFoundationErrorDomain" ||
              errorDomain == "NSOSStatusErrorDomain" else { return false }
        return [
            "load-track", "load-format", "reader-create",
            "reader-add", "reader-start", "sample-read",
            "sample-format", "reader-finish"
        ].contains(stage)
    }
}

/// An existing SABR session and its original selected formats. Reusing a
/// healthy session for user seeks avoids a new YouTube player identity,
/// attestation handshake and unnecessary TypeType session bootstrap.
private struct SabrSeekReuse {
    let service: SabrService
    let sessionId: String
    let selection: SabrSelection
}

// A native sample-buffer synchronizer instead of a fake HLS playlist or server-side bridge.
// Samples still require real-device validation: AVAssetReader can reject some fMP4 fragments.
@MainActor
final class SabrPlayerController: ObservableObject {
    @Published var state = TVL10n.value("player.starting")
    @Published var failure: String?
    @Published private(set) var playbackUnavailable = false
    @Published private(set) var playbackFinished = false
    @Published var selectionDescription = ""
    @Published var isPlaying = false
    @Published var durationMs: Int64 = 0
    @Published var positionMs: Int64 = 0
    @Published var cachedThroughMs: Int64 = 0
    @Published var diskCacheBytes = 0
    // Unlike the network cache, this is the last media timestamp actually
    // handed to BOTH sample renderers. Show it separately in the HUD.
    @Published private(set) var rendererReadyThroughMs: Int64 = 0
    @Published private(set) var availableVideos: [SabrBootstrap.Video] = []
    @Published private(set) var availableAudios: [SabrBootstrap.Audio] = []
    @Published private(set) var currentVideoItag: Int?
    @Published private(set) var currentAudioItag: Int?
    @Published private(set) var currentAudioTrackId: String?
    @Published private(set) var fixedVideoItag: Int?
    @Published private(set) var qualityFallbackNotice: String?
    @Published private(set) var playerNotices = TVPlayerNoticeStack()
    @Published private(set) var availableSubtitles: [SabrBootstrap.Subtitle] = []
    @Published private(set) var selectedSubtitleURL: String?
    @Published private(set) var subtitleCues: [SabrCaptionCue] = []
    @Published private(set) var subtitleError: String?
    @Published private(set) var sponsorSegments: [TVSponsorBlockSegment] = []
    @Published private(set) var sponsorSettings: TVServerSettings?
    @Published private(set) var sponsorStreamCategory: String?

    let videoLayer = AVSampleBufferDisplayLayer()
    private let audioRenderer = AVSampleBufferAudioRenderer()
    private let synchronizer = AVSampleBufferRenderSynchronizer()
    private var running: Task<Void, Never>?
    // Incremented on every stop/start so late replies from previous playback
    // cannot overwrite the active video's state.
    private var playbackEpoch: UInt64 = 0
    private var sessionId = ""
    private var generation: Int64 = 0
    private var selection: SabrSelection?
    private var playbackPositionMs: Int64 = 0
    private var isInitialized = false
    private var hasQueuedFirstAudio = false
    private var hasQueuedFirstVideo = false
    private var bufferingClockPaused = false
    private var bufferingNeedsAudio = false
    private var bufferingNeedsVideo = false
    private var queuedAudioEndMs: Int64 = 0
    private var queuedVideoEndMs: Int64 = 0
    private var hardwareDecoder: HardwareVideoDecoder?
    // Direct compressed-sample renderer for H.264/HEVC + AAC, legacy VT for others.
    private var usesDirectMP4 = false
    #if DEBUG
    private var rendererProbeTask: Task<Void, Never>?
    private var maxVideoDeliveryMs = 0
    private var lateVideoSamples = 0
    private var videoSamplesDelivered = 0
    private var maxVideoReadyWaitMs = 0
    private var videoReadyWaits = 0
    #endif
    private var playbackService: SabrService?
    private var segmentCache: SabrFragmentCache?
    private var windowProducerTask: Task<Void, Never>?
    private var activeMailbox: SabrWindowMailbox?
    private let progressWriter = TVPlaybackProgressWriter()
    // Main-actor handoff guarantees the stop checkpoint reaches the actor
    // before a fast seek/quality restart changes the history permission.
    private var lastProgressSubmission: Task<Void, Never>?
    private let presenceOwner = UUID()
    private var presenceReported = false
    private var currentAPI: TypeTypeAPI?
    private var currentVideo: VideoItem?
    private var hasRecordedHistory = false
    private var historyEnabled = false
    private var prefersPause = false
    private var requestedVideoItag: Int?
    private var failedManualFormat: String?
    private var requestedAudioItag: Int?
    private var requestedAudioTrackId: String?
    private var sponsorLookupTask: Task<Void, Never>?
    private var subtitleTask: Task<Void, Never>?
    private var subtitlePreferenceChanged = false

    init() {
        videoLayer.videoGravity = .resizeAspect
        // Explicitly select the tvOS media playback audio route.
        try? AVAudioSession.sharedInstance().setCategory(.playback)
        try? AVAudioSession.sharedInstance().setActive(true)
        // Attach the same video renderer that receives the decoded frames.
        // The display layer owns this renderer, but enqueuing on a different
        // legacy layer queue would bypass our shared A/V media timeline.
        synchronizer.addRenderer(videoLayer.sampleBufferRenderer)
        synchronizer.addRenderer(audioRenderer)
        // A/V startup is gated by the actual first samples below.
        // Avoid a second implicit rate gate on tvOS after a seek.
        synchronizer.delaysRateChangeUntilHasSufficientMediaData = false
    }

    /// Each message has its own expiry. New messages appear at the top and
    /// push older ones downward; deleting one never affects its neighbors.
    private func postPlayerNotice(_ text: String) {
        let id = playerNotices.push(text)
        let selectedSeconds = UserDefaults.standard.integer(
            forKey: TVPlayerNoticePolicy.settingsKey
        )
        let duration = TVPlayerNoticePolicy.seconds(selectedSeconds)
        Task { [weak self] in
            do { try await Task.sleep(for: .seconds(duration)) }
            catch { return }
            guard !Task.isCancelled else { return }
            self?.playerNotices.dismiss(id)
        }
    }

    private func formatLabel(_ video: SabrBootstrap.Video) -> String {
        let codec = SabrVideoCodecFamily(codec: video.codec)?.title ?? video.codec
        return "\(codec) \(video.height ?? 0)p"
    }

    /// nil means resume from the account's recorded position; explicit values
    /// (including zero) are used for seeking and quality/audio changes.
    func start(api: TypeTypeAPI, video: VideoItem, positionMs: Int64? = nil) {
        prepareStart(api: api, video: video, positionMs: positionMs, reusing: nil)
    }

    private func prepareStart(api: TypeTypeAPI, video: VideoItem,
                              positionMs: Int64?, reusing: SabrSeekReuse?) {
        stop(preservingSessionId: reusing?.sessionId)
        currentAPI = api
        currentVideo = video
        historyEnabled = false
        prefersPause = false
        playbackPositionMs = positionMs ?? 0
        failure = nil
        playbackUnavailable = false
        playbackFinished = false
        state = TVL10n.value("player.connecting")
        let settings = SabrBufferSettings.preferences(live: video.isLive == true)
        segmentCache = SabrFragmentCache(maxMiB: settings.cacheMiB)
        let epoch = playbackEpoch
        running = Task {
            await run(api: api, video: video, explicitPositionMs: positionMs,
                      buffer: settings, epoch: epoch, reusing: reusing)
        }
    }

    func stop(preservingSessionId: String? = nil) {
        playbackEpoch &+= 1
        if isInitialized { recordProgress(force: true) }
        TVPlaybackPresenceReporter.shared.stop(owner: presenceOwner)
        presenceReported = false
        currentAPI = nil
        currentVideo = nil
        qualityFallbackNotice = nil
        failedManualFormat = nil
        hasRecordedHistory = false
        running?.cancel()
        running = nil
        subtitleTask?.cancel()
        subtitleTask = nil
        sponsorLookupTask?.cancel()
        sponsorLookupTask = nil
        subtitleCues = []
        sponsorSegments = []
        sponsorSettings = nil
        sponsorStreamCategory = nil
        audioRenderer.isMuted = false
        let previousService = playbackService
        playbackService = nil
        let previousSession = sessionId
        if let previousService, !previousSession.isEmpty,
           previousSession != preservingSessionId {
            Task { try? await previousService.release(sessionId: previousSession) }
        }
        windowProducerTask?.cancel()
        windowProducerTask = nil
        if let activeMailbox { Task { await activeMailbox.finish(error: CancellationError()) } }
        activeMailbox = nil
        let previousCache = segmentCache
        segmentCache = nil
        if let previousCache { Task { await previousCache.clear() } }
        cachedThroughMs = 0
        diskCacheBytes = 0
        hardwareDecoder?.invalidate()
        hardwareDecoder = nil
        usesDirectMP4 = false
        #if DEBUG
        rendererProbeTask?.cancel()
        rendererProbeTask = nil
        #endif
        synchronizer.setRate(0, time: synchronizer.currentTime())
        videoLayer.sampleBufferRenderer.flush(removingDisplayedImage: true, completionHandler: nil)
        audioRenderer.flush()
        isInitialized = false
        hasQueuedFirstAudio = false
        hasQueuedFirstVideo = false
        resetBufferClock()
        isPlaying = false
        sessionId = ""
    }

    func caption(at timeMs: Int64) -> String? {
        SabrCaptionCue.showing(subtitleCues, at: timeMs)
    }

    func selectSubtitle(_ track: SabrBootstrap.Subtitle?, origin: URL) {
        subtitlePreferenceChanged = true
        subtitleTask?.cancel()
        subtitleCues = []
        subtitleError = nil
        selectedSubtitleURL = track?.url
        guard let track else { return }
        subtitleTask = Task { [weak self] in
            do {
                let loaded = try await SabrCaptionLoader.load(track, origin: origin)
                guard !Task.isCancelled,
                      self?.selectedSubtitleURL == track.url else { return }
                self?.subtitleCues = loaded
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled,
                      self?.selectedSubtitleURL == track.url else { return }
                self?.subtitleError = error.localizedDescription
            }
        }
    }

    func selectQuality(api: TypeTypeAPI, video: VideoItem, itag: Int?) {
        requestedVideoItag = itag
        let wasPaused = prefersPause
        let position = max(0, Int64(playbackSeconds() * 1_000))
        start(api: api, video: video, positionMs: position)
        prefersPause = wasPaused
        fixedVideoItag = itag
    }

    func selectAudio(api: TypeTypeAPI, video: VideoItem,
                     itag: Int, trackId: String?) {
        requestedAudioItag = itag
        requestedAudioTrackId = trackId
        let wasPaused = prefersPause
        let position = max(0, Int64(playbackSeconds() * 1_000))
        start(api: api, video: video, positionMs: position)
        prefersPause = wasPaused
    }

    func seek(api: TypeTypeAPI, video: VideoItem, offsetMs: Int64) {
        let seconds = CMTimeGetSeconds(synchronizer.currentTime())
        let anchor = isInitialized && seconds.isFinite ? Int64(seconds * 1000) : playbackPositionMs
        let upper = durationMs > 0 ? max(0, durationMs - 1_000) : Int64.max
        let wasPaused = prefersPause
        let target = min(upper, max(0, anchor + offsetMs))
        let reuse: SabrSeekReuse?
        if isInitialized && !bufferingClockPaused,
           !sessionId.isEmpty, let service = playbackService,
           let selection {
            reuse = SabrSeekReuse(
                service: service, sessionId: sessionId, selection: selection
            )
        } else {
            reuse = nil
        }
        NSLog("TypeType SABR SEEK fromMs=%lld toMs=%lld reuse=%d",
              anchor, target, reuse == nil ? 0 : 1)
        prepareStart(api: api, video: video, positionMs: target, reusing: reuse)
        prefersPause = wasPaused
    }

    func setSponsorMuted(_ muted: Bool) {
        if audioRenderer.isMuted != muted { audioRenderer.isMuted = muted }
    }

    func playbackSeconds() -> Double {
        let seconds = CMTimeGetSeconds(synchronizer.currentTime())
        return isInitialized && seconds.isFinite ? max(0, seconds) : Double(playbackPositionMs) / 1_000
    }

    func totalTimeLabel() -> String {
        TTTheme.time(Int(clamping: max(0, durationMs / 1_000)))
    }

    func timeLabel() -> String {
        let seconds = CMTimeGetSeconds(synchronizer.currentTime())
        let current = isInitialized && seconds.isFinite
            ? Int64(max(0, seconds)) : max(0, playbackPositionMs / 1_000)
        return TTTheme.time(Int(clamping: current))
    }

    /// An external Play/Pause command is an *absolute intent*, not a
    /// blind toggle. In particular, buffering leaves isPlaying=false while
    /// the user's desired state can still be "play".
    @discardableResult
    func setPaused(_ paused: Bool) -> Bool {
        guard currentVideo != nil, failure == nil, !playbackFinished else { return false }
        if prefersPause == paused { return true }
        prefersPause = paused
        hardwareDecoder?.playbackPaused = paused

        if bufferingClockPaused {
            // Keep the synchronizer paused until both media tracks are ready.
            state = TVL10n.value(paused ? "player.paused" : "player.buffering")
        } else if isInitialized {
            synchronizer.setRate(paused ? 0 : 1, time: synchronizer.currentTime())
            isPlaying = !paused
            state = TVL10n.value(paused ? "player.paused" : "player.playing")
        } else if paused {
            // Honor an AirPods pause sent during SABR startup. The initial
            // media clock uses prefersPause when both renderers are ready.
            state = TVL10n.value("player.paused")
        }
        if isInitialized { recordProgress(force: true) }
        return true
    }

    func togglePause() {
        guard isInitialized else { return }
        _ = setPaused(!prefersPause)
    }

    var userRequestedPause: Bool { prefersPause }

    private func resetBufferClock() {
        bufferingClockPaused = false
        bufferingNeedsAudio = false
        bufferingNeedsVideo = false
        queuedAudioEndMs = 0
        queuedVideoEndMs = 0
        rendererReadyThroughMs = 0
        #if DEBUG
        maxVideoDeliveryMs = 0
        lateVideoSamples = 0
        videoSamplesDelivered = 0
        maxVideoReadyWaitMs = 0
        videoReadyWaits = 0
        #endif
    }

    #if DEBUG
    /// Print measured renderer queue headroom *during* playback. Previous
    /// logs identified missing segment numbers but could not detect 100-500ms
    /// frame starvation with perfectly continuous fMP4 timestamps.
    private func startRendererProbe() {
        rendererProbeTask?.cancel()
        rendererProbeTask = Task { [weak self] in
            var lastSummary = ProcessInfo.processInfo.systemUptime
            var lastCritical = -Double.infinity
            while !Task.isCancelled {
                // A two-second snapshot can miss a 100-300ms glitch. Only
                // sample more frequently in Debug; report on actual
                // near-underflow and throttle repeated warnings.
                do { try await Task.sleep(nanoseconds: 100_000_000) }
                catch { return }
                guard let self, !Task.isCancelled else { return }
                guard self.isInitialized, !self.prefersPause else { continue }
                let seconds = self.playbackSeconds()
                guard seconds.isFinite, seconds >= 0,
                      seconds < Double(Int64.max) / 1_000 else { continue }
                let clockMs = Int64(seconds * 1_000)
                let audioAhead = self.queuedAudioEndMs - clockMs
                let videoAhead = self.queuedVideoEndMs - clockMs
                let uptime = ProcessInfo.processInfo.systemUptime
                if SabrRendererHeadroom.shouldReport(
                    audioAheadMs: audioAhead, videoAheadMs: videoAhead,
                    running: self.synchronizer.rate > 0,
                    buffering: self.bufferingClockPaused
                ), uptime - lastCritical >= 1.5 {
                    let diskAheadMs = max(0, self.cachedThroughMs - clockMs)
                    NSLog("TypeType SABR RENDER-UNDERFLOW clockMs=%lld audioAheadMs=%lld videoAheadMs=%lld cacheAheadMs=%lld audioReady=%d videoReady=%d rate=%.2f",
                          clockMs, audioAhead, videoAhead, diskAheadMs,
                          self.audioRenderer.isReadyForMoreMediaData ? 1 : 0,
                          self.videoLayer.sampleBufferRenderer.isReadyForMoreMediaData ? 1 : 0,
                          Double(self.synchronizer.rate))
                    lastCritical = uptime
                }
                guard uptime - lastSummary >= 2 else { continue }
                lastSummary = uptime
                NSLog("TypeType SABR RENDER clockMs=%lld audioAheadMs=%lld videoAheadMs=%lld audioQueuedMs=%lld videoQueuedMs=%lld deliveryMaxMs=%d delivered=%d lateVideo=%d videoWaitMaxMs=%d videoWaitCount=%d buffering=%d rate=%.2f",
                      clockMs, audioAhead, videoAhead, self.queuedAudioEndMs,
                      self.queuedVideoEndMs, self.maxVideoDeliveryMs,
                      self.videoSamplesDelivered, self.lateVideoSamples,
                      self.maxVideoReadyWaitMs, self.videoReadyWaits,
                      self.bufferingClockPaused ? 1 : 0,
                      Double(self.synchronizer.rate))
                self.maxVideoDeliveryMs = 0
                self.lateVideoSamples = 0
                self.videoSamplesDelivered = 0
                self.maxVideoReadyWaitMs = 0
                self.videoReadyWaits = 0
            }
        }
    }

    #endif

    /// Called while the decoder waits for a new, already downloaded media
    /// window. Do not allow audio to keep advancing beyond the shortest
    /// submitted track while video is starved.
    private func pauseForEmptyBufferIfNeeded() {
        guard isInitialized, !prefersPause, !bufferingClockPaused else { return }
        let now = max(0, Int64(playbackSeconds() * 1_000))
        guard SabrRendererCoverage.shouldPause(
            clockMs: now, audioEndMs: queuedAudioEndMs,
            videoEndMs: queuedVideoEndMs
        ) else { return }
        bufferingNeedsAudio = queuedAudioEndMs <= now + 450
        bufferingNeedsVideo = queuedVideoEndMs <= now + 450
        bufferingClockPaused = true
        NSLog("TypeType SABR BUFFER paused at %lldms audioQueued=%lldms videoQueued=%lldms",
              now, queuedAudioEndMs, queuedVideoEndMs)
        synchronizer.setRate(0, time: synchronizer.currentTime())
        isPlaying = false
        state = TVL10n.value("player.buffering")
    }

    private func noteQueuedMedia(_ track: SabrMediaInterleave.Track,
                                 sample: CMSampleBuffer) {
        if usesDirectMP4, let actualEndMs = SabrSampleTimingProbe.actualEndMs([sample]) {
            noteQueuedTime(track, seconds: Double(actualEndMs) / 1_000)
            return
        }
        let pts = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sample))
        let duration = CMTimeGetSeconds(CMSampleBufferGetDuration(sample))
        noteQueuedTime(track, seconds: pts, duration: duration)
    }

    private func noteQueuedTime(_ track: SabrMediaInterleave.Track,
                                seconds pts: Double, duration: Double = 0) {
        guard pts.isFinite && pts >= 0 else { return }
        let endMs = Int64((pts + (duration.isFinite && duration > 0 ? duration : 0)) * 1_000)
        switch track {
        case .audio: queuedAudioEndMs = max(queuedAudioEndMs, endMs)
        case .video: queuedVideoEndMs = max(queuedVideoEndMs, endMs)
        }
        let shared = min(queuedAudioEndMs, queuedVideoEndMs)
        if shared > rendererReadyThroughMs + 250 {
            rendererReadyThroughMs = shared
        }
        guard bufferingClockPaused else { return }
        let clock = CMTimeGetSeconds(synchronizer.currentTime())
        guard clock.isFinite, pts >= clock - 0.05 else { return }
        switch track {
        case .audio: bufferingNeedsAudio = false
        case .video: bufferingNeedsVideo = false
        }
        guard !bufferingNeedsAudio && !bufferingNeedsVideo else { return }
        bufferingClockPaused = false
        NSLog("TypeType SABR BUFFER resumed audioQueued=%lldms videoQueued=%lldms",
              queuedAudioEndMs, queuedVideoEndMs)
        if !prefersPause {
            synchronizer.setRate(1, time: synchronizer.currentTime())
            isPlaying = true
            state = TVL10n.value("player.playing")
        }
    }

    func recordProgress(started: Bool = false, force: Bool = false) {
        guard isInitialized,
              let api = currentAPI, let video = currentVideo else { return }
        let position = max(0, Int64(playbackSeconds() * 1_000))
        TVPlaybackPresenceReporter.shared.progress(
            owner: presenceOwner, video: video, positionMs: position,
            paused: !isPlaying
        )
        guard historyEnabled else { return }
        TVLocalProgress.shared.record(video.url, positionMs: position)
        let predecessor = lastProgressSubmission
        let writer = progressWriter
        lastProgressSubmission = Task {
            await predecessor?.value
            await writer.checkpoint(
                api: api, video: video, positionMs: position,
                started: started, force: force
            )
        }
    }

    /// Retry only genuinely transient bootstrap/session errors. Server
    /// authorization denials and malformed media remain terminal.
    private func retryTransient<T>(
        _ action: () async throws -> T
    ) async throws -> T {
        let policy = SabrRecoveryPolicy()
        let started = Date()
        for attempt in 1...policy.maxAttempts {
            try Task.checkCancellation()
            do {
                return try await action()
            } catch {
                guard policy.canRetry(
                    error, completedAttempts: attempt,
                    elapsedSeconds: Date().timeIntervalSince(started)
                ) else { throw error }
                state = TVL10n.value("player.connecting") + " (\(attempt))"
                try await Task.sleep(
                    nanoseconds: policy.delayNanoseconds(
                        for: error, attempt: attempt
                    )
                )
            }
        }
        throw SabrFailure.stalled("stream retry budget exhausted")
    }

    private func run(api: TypeTypeAPI, video: VideoItem,
                     explicitPositionMs: Int64?, buffer: SabrBufferSettings,
                     epoch: UInt64, reusing: SabrSeekReuse?) async {
        guard playbackEpoch == epoch, !Task.isCancelled else { return }
        let service = reusing?.service ?? SabrService(api: api)
        playbackService = service
        // Retain ownership while the bootstrap resolves; stop() must still
        // be able to release the reused session if the user leaves meanwhile.
        if let reusing { sessionId = reusing.sessionId }
        do {
            // Respect the server's privacy flag before reading/writing history.
            // If settings cannot be loaded, do not silently record history.
            let settings = try? await api.accountSettings()
            guard playbackEpoch == epoch, !Task.isCancelled else { return }
            let historyAllowed = settings != nil &&
                settings?.disableWatchHistory != true && video.isLive != true
            historyEnabled = historyAllowed
            sponsorSettings = settings
            if settings?.disableWatchHistory == true && explicitPositionMs == nil &&
               reusing == nil && video.isLive != true {
                postPlayerNotice(TVL10n.value("player.historyRecordingDisabled"))
            }
            await lastProgressSubmission?.value
            guard playbackEpoch == epoch, !Task.isCancelled else { return }
            await progressWriter.flush()
            await progressWriter.enable(historyAllowed)
            guard playbackEpoch == epoch, !Task.isCancelled else { return }
            // Previously saved positions remain readable when NEW history
            // recording has been disabled; only future writes are suppressed.
            let recordedPosition = explicitPositionMs == nil && !video.isShort
                ? (try? await api.savedPosition(videoURL: video.url)) : nil
            guard playbackEpoch == epoch, !Task.isCancelled else { return }
            var positionMs = TVShortsPolicy.startPositionMs(
                video: video, explicitPositionMs: explicitPositionMs,
                savedPositionMs: recordedPosition
            )
            // Do not resume after the credits of a nearly completed video.
            if let duration = video.duration, duration > 0,
               positionMs >= Int64(duration) * 1_000 - 3_000 {
                positionMs = 0
            }
            playbackPositionMs = positionMs
            try Task.checkCancellation()
            guard let id = VideoAddress.youtubeID(video.url) else {
                throw SabrFailure.unsupported(TVL10n.value("player.notYoutube"))
            }
            let bootstrap: SabrBootstrap = try await retryTransient {
                do {
                    return try await service.bootstrap(videoURL: video.url)
                } catch SabrFailure.server(let code, _) where
                    SabrGuestAuthPolicy.shouldAttemptGuest(
                        responseCode: code,
                        existingToken: TypeTypeCredentials.shared.token(for: api.origin)
                    ) {
                    // Never replace an authenticated user's Keychain token
                    // with a guest token after a permission/expiry failure.
                    try await service.guestLogin()
                    return try await service.bootstrap(videoURL: video.url)
                }
            }
            guard playbackEpoch == epoch, !Task.isCancelled else { return }
            sponsorSegments = bootstrap.sponsorBlockSegments ?? []
            sponsorStreamCategory = bootstrap.category
            if sponsorSegments.isEmpty, let settings,
               settings.sponsorBlockMode != "disabled" {
                // The server's SABR fallback intentionally has no segments.
                // Query SponsorBlock's hash-prefix endpoint asynchronously:
                // a slow or unavailable third party must not delay playback.
                sponsorLookupTask = Task { [weak self] in
                    let segments = await TVSponsorBlockLookup.shared.segments(for: id)
                    guard !Task.isCancelled, self?.playbackEpoch == epoch else { return }
                    self?.sponsorSegments = segments
                }
            }
            let allowSoftware = UserDefaults.standard.bool(forKey: "typetype.allowSoftwareDecode")
            let maximum = UserDefaults.standard.integer(forKey: "typetype.maxHeight")

            let options = HardwareCodec.candidates(
                from: bootstrap, maxHeight: maximum > 0 ? maximum : 2160,
                allowSoftware: allowSoftware
            )
            #if DEBUG
            // The selection menu only shows server-advertised SABR tracks
            // supported by VideoToolbox. These counts explain absent codecs
            // without exposing the video ID, media URLs or auth credentials.
            func codecCounts(_ tracks: [SabrBootstrap.Video]) -> String {
                let grouped = Dictionary(grouping: tracks) {
                    $0.codec.lowercased().split(separator: ".").first.map(String.init) ?? "unknown"
                }
                return grouped.keys.sorted().map {
                    "\($0)=\(grouped[$0]?.count ?? 0)"
                }.joined(separator: ",")
            }
            let offered = bootstrap.videoOnlyStreams ?? []
            let sabrOffered = offered.filter { $0.deliveryMethod == "sabr" }
            NSLog("TypeType SABR CODECS server=%@ sabr=%@ playable=%@ maxHeight=%d allowSoftware=%d",
                  codecCounts(offered), codecCounts(sabrOffered),
                  codecCounts(options.map(\.video)),
                  maximum > 0 ? maximum : 2160, allowSoftware ? 1 : 0)
            #endif
            availableVideos = options.map(\.video)
            availableAudios = HardwareCodec.audioCandidates(from: bootstrap)
            availableSubtitles = (bootstrap.subtitles ?? []).filter { !$0.url.isEmpty }
            if let current = selectedSubtitleURL {
                if let match = availableSubtitles.first(where: { $0.url == current }) {
                    selectSubtitle(match, origin: api.origin)
                } else {
                    selectSubtitle(nil, origin: api.origin)
                }
            } else if !subtitlePreferenceChanged &&
                        settings?.subtitlesEnabled == true {
                let language = settings?.defaultSubtitleLanguage?.isEmpty == false
                    ? (settings?.defaultSubtitleLanguage ?? TVLanguages.activeLanguage)
                    : TVLanguages.activeLanguage
                if let match = SabrPlaybackPreferences.preferredSubtitle(
                    availableSubtitles, language: language
                ) {
                    selectSubtitle(match, origin: api.origin)
                }
            }
            // Automatic selection prefers an actual hardware decoder, even
            // when the optional software-decoding setting is enabled. A
            // manual codec/itag choice still has absolute precedence.
            let automaticOrder = SabrPlaybackPreferences.orderedAutomaticVideos(
                options, defaultQuality: settings?.defaultQuality,
                deviceMax: maximum > 0 ? maximum : 2160
            )
            let orderedOptions: [SabrSelection]
            if let requested = requestedVideoItag,
               let selected = options.first(where: { $0.video.itag == requested }) {
                orderedOptions = SabrPlaybackPreferences.orderedForManualVideo(
                    selected, automaticOrder: automaticOrder
                )
            } else if let reusing,
                      let selected = automaticOrder.first(where: {
                          $0.video.itag == reusing.selection.video.itag
                      }) {
                orderedOptions = [selected] +
                    automaticOrder.filter {
                        $0.video.itag != reusing.selection.video.itag
                    }
                requestedVideoItag = nil
                fixedVideoItag = nil
            } else {
                orderedOptions = automaticOrder
                requestedVideoItag = nil
                fixedVideoItag = nil
            }
            guard !orderedOptions.isEmpty else {
                throw SabrFailure.unsupported(TVL10n.value("player.noHardwareFormat"))
            }
            // This must not change when the first failed manual format is
            // unselected. Otherwise the legacy automatic resume rule stops
            // the second attempt before reaching 1080p.
            let manualFallbackActive = requestedVideoItag != nil &&
                orderedOptions.first?.video.itag == requestedVideoItag
            var playbackStart = positionMs
            for (index, option) in orderedOptions.enumerated() {
                try Task.checkCancellation()
                let audio = availableAudios.first {
                    $0.itag == requestedAudioItag &&
                    $0.audioTrackId == requestedAudioTrackId
                } ?? availableAudios.first {
                    $0.itag == reusing?.selection.audio.itag &&
                    $0.audioTrackId == reusing?.selection.audio.audioTrackId
                } ?? SabrPlaybackPreferences.preferredAudio(
                    availableAudios,
                    language: settings?.defaultAudioLanguage,
                    preferOriginal: settings?.preferOriginalLanguage == true
                ) ?? option.audio
                let choice = SabrSelection(video: option.video, audio: audio)
                let hardwareReported = HardwareCodec.supported(choice.video.codec)
                // A first-generation Apple TV 4K does not have an AV1
                // hardware decoder. If AV1 appears in a log while software
                // is OFF, the exact runtime codec/setting mismatch is now
                // visible instead of merely inferred from a menu label.
                NSLog("TypeType SABR SELECT itag=%d codec=%@ resolution=%dp fps=%d hwProbe=%d softwareAllowed=%d manual=%d",
                      choice.video.itag, choice.video.codec,
                      choice.video.height ?? 0, choice.video.fps ?? 0,
                      hardwareReported ? 1 : 0, allowSoftware ? 1 : 0,
                      requestedVideoItag == choice.video.itag ? 1 : 0)
                guard hardwareReported || allowSoftware else {
                    throw SabrFailure.unsupported(
                        "Selected SABR stream has no hardware decoder while software decoding is disabled"
                    )
                }
                selection = choice
                currentVideoItag = choice.video.itag
                currentAudioItag = choice.audio.itag
                currentAudioTrackId = choice.audio.audioTrackId
                selectionDescription = choice.description
                usesDirectMP4 = SabrNativePlaybackPolicy.usesDirectRenderer(
                    videoCodec: choice.video.codec,
                    audioCodec: choice.audio.codec,
                    audioMIME: choice.audio.mimeType
                )
                NSLog("TypeType SABR PIPELINE native=%d codec=%@",
                      usesDirectMP4 ? 1 : 0, choice.video.codec)
                // The sample renderer decodes H.264/HEVC compressed buffers
                // itself. No duplicate VTDecompressionSession is needed.
                hardwareDecoder = usesDirectMP4 ? nil : HardwareVideoDecoder(
                    display: videoLayer, allowSoftware: allowSoftware
                )
                hardwareDecoder?.playbackPaused = prefersPause
                state = TVL10n.value("player.session")
                // Request earlier compressed media for decoder/keyframe
                // preroll while keeping the presentation clock at the exact
                // requested position. Do not emit audio before that position.
                let transportStart = SabrSeekPreroll.requestStart(
                    targetMs: playbackStart,
                    explicit: usesDirectMP4 && playbackStart > 0
                )
                if transportStart != playbackStart {
                    NSLog("TypeType SABR SEEK-PREROLL transportMs=%lld targetMs=%lld",
                          transportStart, playbackStart)
                }
                do {
                    let reuseSession = reusing.flatMap { prior in
                        SabrSessionReusePolicy.matches(
                            priorVideoItag: prior.selection.video.itag,
                            priorAudioItag: prior.selection.audio.itag,
                            priorAudioTrackId: prior.selection.audio.audioTrackId,
                            selectedVideoItag: choice.video.itag,
                            selectedAudioItag: choice.audio.itag,
                            selectedAudioTrackId: choice.audio.audioTrackId
                        ) ? prior : nil
                    }
                    let session = try await retryTransient {
                        if let reuseSession {
                            return try await service.seek(
                                sessionId: reuseSession.sessionId,
                                selection: choice, positionMs: transportStart
                            )
                        }
                        return try await service.start(
                            videoId: id, selection: choice, positionMs: transportStart
                        )
                    }
                    if let reusing,
                       reusing.sessionId != session.sessionId {
                        Task { try? await service.release(sessionId: reusing.sessionId) }
                    }
                    if reuseSession != nil {
                        NSLog("TypeType SABR SEEK session-reused=%d generation=%lld",
                              session.sessionId == reusing?.sessionId ? 1 : 0,
                              session.generation)
                    }
                    guard !session.sessionId.isEmpty else {
                        throw SabrFailure.invalidResponse("sessionId")
                    }
                    // A user may leave while the POST is in flight. If its
                    // response arrives *after* stop(), the stop path could
                    // not have known this new token; release it explicitly.
                    if Task.isCancelled || playbackEpoch != epoch {
                        let abandoned = session.sessionId
                        Task.detached(priority: .utility) {
                            try? await service.release(sessionId: abandoned)
                        }
                        throw CancellationError()
                    }
                    sessionId = session.sessionId
                    generation = session.generation
                    try await consume(
                        service: service, videoId: id, choice: choice,
                        positionMs: transportStart, presentationStartMs: playbackStart,
                        buffer: buffer
                    )
                    return
                } catch {
                    // Cancellation/teardown is never a format failure.
                    guard playbackEpoch == epoch, !Task.isCancelled else {
                        throw CancellationError()
                    }
                    let codecFallback: Bool
                    if manualFallbackActive {
                        codecFallback = SabrManualQualityFallbackPolicy.shouldTryNext(
                            error: error, initialized: isInitialized,
                            currentIndex: index, candidateCount: orderedOptions.count
                        )
                    } else if case SabrFailure.unsupported = error {
                        codecFallback = !isInitialized && index < orderedOptions.count - 1
                    } else {
                        codecFallback = SabrResumeTrackFallbackPolicy.shouldTryNext(
                            error: error, positionMs: playbackStart,
                            initialized: isInitialized, currentIndex: index,
                            candidateCount: orderedOptions.count,
                            manuallySelected: false
                        )
                    }
                    if !codecFallback {
                        if manualFallbackActive && !isInitialized {
                            let label = failedManualFormat ?? formatLabel(choice.video)
                            if index == orderedOptions.count - 1 {
                                postPlayerNotice(String(
                                    format: TVL10n.value("player.formatExhausted"), label
                                ))
                            } else {
                                let reason = TVL10n.value(
                                    SabrManualQualityFallbackPolicy.reasonKey(for: error)
                                )
                                postPlayerNotice(String(
                                    format: TVL10n.value("player.formatStopped"),
                                    formatLabel(choice.video), reason
                                ))
                            }
                        }
                        NSLog("TypeType SABR QUALITY stop itag=%d index=%d total=%d initialized=%d manual=%d reason=%@ detail=%@",
                              choice.video.itag, index + 1, orderedOptions.count,
                              isInitialized ? 1 : 0, manualFallbackActive ? 1 : 0,
                              SabrManualQualityFallbackPolicy.reasonKey(for: error),
                              SabrManualQualityFallbackPolicy.diagnosticCode(for: error))
                        throw error
                    }
                    if manualFallbackActive {
                        let current = formatLabel(choice.video)
                        let next = formatLabel(orderedOptions[index + 1].video)
                        if failedManualFormat == nil {
                            failedManualFormat = current
                        }
                        let reason = TVL10n.value(
                            SabrManualQualityFallbackPolicy.reasonKey(for: error)
                        )
                        postPlayerNotice(String(
                            format: TVL10n.value("player.formatTryNext"),
                            current, reason, next
                        ))
                        NSLog("TypeType SABR QUALITY manual-fallback failedItag=%d failedCodec=%@ failedHeight=%d nextItag=%d reason=%@ detail=%@",
                              choice.video.itag, choice.video.codec,
                              choice.video.height ?? 0, orderedOptions[index + 1].video.itag,
                              SabrManualQualityFallbackPolicy.reasonKey(for: error),
                              SabrManualQualityFallbackPolicy.diagnosticCode(for: error))
                        // Only the chosen track was manual; alternatives
                        // remain in this run's bounded manual fallback chain.
                        requestedVideoItag = nil
                    }
                    if case SabrFailure.expired = error {
                        NSLog("TypeType SABR RESUME alternate-track firstItag=%d nextItag=%d positionMs=%lld reason=expired",
                              choice.video.itag, orderedOptions[index + 1].video.itag,
                              playbackStart)
                    }
                    if isInitialized {
                        recordProgress(force: true)
                        let lastSubmitted = max(0, self.positionMs - 1_000)
                        playbackStart = min(
                            max(0, Int64(playbackSeconds() * 1_000)),
                            lastSubmitted
                        )
                    }
                    // A codec may be reported hardware-capable even though
                    // the precise profile/level cannot create a decoder.
                    // Try the next candidate only before playback starts.
                    let oldSession = sessionId
                    sessionId = ""
                    generation = 0
                    if !oldSession.isEmpty {
                        Task { try? await service.release(sessionId: oldSession) }
                    }
                    windowProducerTask?.cancel()
                    windowProducerTask = nil
                    if let activeMailbox {
                        await activeMailbox.finish(error: CancellationError())
                    }
                    activeMailbox = nil
                    hardwareDecoder?.invalidate()
                    hardwareDecoder = nil
                    await videoLayer.sampleBufferRenderer.flush(removingDisplayedImage: true)
                    audioRenderer.flush()
                    synchronizer.setRate(
                        0, time: CMTime(value: playbackStart, timescale: 1_000)
                    )
                    playbackPositionMs = playbackStart
                    isInitialized = false
                    hasQueuedFirstAudio = false
                    hasQueuedFirstVideo = false
                    resetBufferClock()
                    isPlaying = false
                    if fixedVideoItag != nil { fixedVideoItag = nil }
                    cachedThroughMs = playbackStart
                    diskCacheBytes = 0
                    if let oldCache = segmentCache { await oldCache.clear() }
                    segmentCache = SabrFragmentCache(maxMiB: buffer.cacheMiB)
                }
            }
        } catch is CancellationError {
            return
        } catch SabrFailure.unavailable {
            guard playbackEpoch == epoch, !Task.isCancelled else { return }
            failure = TVL10n.value("player.videoUnavailable")
            playbackUnavailable = true
            isPlaying = false
            state = TVL10n.value("player.failed")
        } catch {
            guard playbackEpoch == epoch, !Task.isCancelled else { return }
            failure = error.localizedDescription
            isPlaying = false
            state = TVL10n.value("player.failed")
        }
    }

    /// The network stage runs independently of sample-buffer decoder pressure.
    /// Producer sends complete metadata windows through a bounded mailbox and
    /// downloads the compressed bytes to the disk cache before advancing.
    private func consume(service: SabrService, videoId: String,
                         choice: SabrSelection, positionMs start: Int64,
                         presentationStartMs target: Int64,
                         buffer: SabrBufferSettings) async throws {
        var restartPosition = max(0, start)
        var presentationStart = max(restartPosition, target)
        let policy = SabrRecoveryPolicy()
        var recoveryBudget = SabrRecoveryBudget()
        var previousStallPositionMs: Int64?
        var refreshedForIncident = false
        while true {
            try Task.checkCancellation()
            let mailbox = SabrWindowMailbox()
            activeMailbox = mailbox
            guard let cache = segmentCache else { throw SabrFailure.stopped }
            let currentSession = sessionId
            let currentGeneration = generation
            let producerStart = restartPosition
            let producer = Task { [weak self] in
                guard let self else {
                    await mailbox.finish(error: CancellationError())
                    return
                }
                do {
                    try await self.downloadWindows(
                        service: service, sessionId: currentSession,
                        generation: currentGeneration, choice: choice,
                        start: producerStart, buffer: buffer,
                        cache: cache, mailbox: mailbox
                    )
                    await mailbox.finish()
                } catch {
                    // This error can occur minutes before the renderer drains
                    // its already-queued data and discovers the closed mailbox.
                    // Log now, without the URL, session ID or bearer token.
                    let reason: String
                    if let failure = error as? SabrFailure {
                        switch failure {
                        case .invalidResponse: reason = "invalidResponse"
                        case .stalled: reason = "stalled"
                        case .expired: reason = "expired"
                        case .server: reason = "http"
                        case .throttled: reason = "throttled"
                        case .unsupported: reason = "unsupported"
                        case .unavailable: reason = "unavailable"
                        case .stopped: reason = "stopped"
                        }
                    } else {
                        reason = error is CancellationError ? "cancelled" : "other"
                    }
                    NSLog("TypeType SABR PRODUCER failed reason=%@ playbackMs=%lld cachedMs=%lld",
                          reason, max(0, Int64(self.playbackSeconds() * 1_000)),
                          self.cachedThroughMs)
                    await mailbox.finish(error: error)
                }
            }
            windowProducerTask = producer
            do {
                try await playCachedWindows(mailbox: mailbox, service: service,
                                            choice: choice, start: restartPosition,
                                            presentationStartMs: presentationStart,
                                            cache: cache)
                producer.cancel()
                windowProducerTask = nil
                activeMailbox = nil
                return
            } catch {
                producer.cancel()
                await mailbox.finish(error: CancellationError())
                windowProducerTask = nil
                activeMailbox = nil
                let lastPositionMs = max(0, Int64(playbackSeconds() * 1_000))
                let playbackAdvancedMs = max(0, lastPositionMs - producerStart)
                if playbackAdvancedMs >= SabrRecoveryBudget.stablePlaybackMs {
                    previousStallPositionMs = nil
                    refreshedForIncident = false
                }
                let recovery = recoveryBudget.evaluate(
                    error, playbackAdvancedMs: playbackAdvancedMs,
                    policy: policy
                )
                let allowed = recovery.allowed
                let recoveryAttempt = recovery.attempt
                if requestedVideoItag == nil &&
                    SabrResumeTrackFallbackPolicy.shouldEscalateToAlternateTrack(
                        error: error, positionMs: producerStart,
                        initialized: isInitialized, attempt: recoveryAttempt
                    ) {
                    NSLog("TypeType SABR RECOVERY cold-resume sessions-exhausted attempts=%d positionMs=%lld",
                          recoveryAttempt, producerStart)
                    throw error
                }
                // Never log the sessionId, bearer or media URL.
                NSLog("TypeType SABR RECOVERY attempt=%d retry=%d playbackMs=%lld contiguousMs=%lld",
                      recoveryAttempt, allowed ? 1 : 0, lastPositionMs, positionMs)
                guard allowed else { throw error }
                let refreshUpstream = SabrRecoveryRefreshPolicy.shouldRefresh(
                    attempt: recoveryAttempt,
                    currentFailurePositionMs: lastPositionMs,
                    previousFailurePositionMs: previousStallPositionMs,
                    alreadyRefreshed: refreshedForIncident
                )
                previousStallPositionMs = lastPositionMs
                // The clock may have advanced past the last actual rendered
                // segment during a network stall. Rewind a little and clamp
                // to the last submitted audio/video coverage.
                let clockMs = max(0, Int64(playbackSeconds() * 1_000))
                let confirmedMs = max(restartPosition, positionMs - 1_000)
                restartPosition = min(clockMs, confirmedMs)
                // A subsequent recovery resumes at its own position; the
                // original seek target is no longer an active preroll barrier.
                presentationStart = restartPosition
                recordProgress(force: true)
                synchronizer.setRate(
                    0, time: CMTime(value: restartPosition, timescale: 1_000)
                )
                isPlaying = false
                state = TVL10n.value("player.connecting") +
                    " (\(recoveryAttempt))"
                try await Task.sleep(
                    nanoseconds: policy.delayNanoseconds(
                        for: error, attempt: recoveryAttempt
                    )
                )
                try Task.checkCancellation()
                if refreshUpstream {
                    // Request the local server's isolated metadata refresh
                    // instead of GET /bootstrap (which can reuse a 10m cache).
                    // This is advisory until the local server patch is applied.
                    refreshedForIncident = true
                    NSLog("TypeType SABR RECOVERY upstream-refresh requested attempt=%d positionMs=%lld",
                          recoveryAttempt, restartPosition)
                }
                let oldSession = sessionId
                let renewed = try await retryTransient {
                    try await service.start(
                        videoId: videoId, selection: choice,
                        positionMs: restartPosition, refreshUpstream: refreshUpstream
                    )
                }
                if Task.isCancelled {
                    let abandoned = renewed.sessionId
                    Task.detached(priority: .utility) {
                        try? await service.release(sessionId: abandoned)
                    }
                    throw CancellationError()
                }
                // New session tokens are never printed. Confirm whether
                // a retry actually creates a different session, and whether
                // it is already ready when the server returns.
                NSLog("TypeType SABR RECOVERY session-start fresh=%d ready=%d state=%@ generation=%lld",
                      oldSession != renewed.sessionId ? 1 : 0,
                      renewed.ready == true ? 1 : 0,
                      SabrServerRecoveryDiagnostics.state(renewed.status),
                      renewed.generation)
                sessionId = renewed.sessionId
                generation = renewed.generation
                if oldSession != renewed.sessionId {
                    Task { try? await service.release(sessionId: oldSession) }
                }
                // Keep the last decoded picture visible while a stalled
                // upstream SABR session is renewed. Clearing it here produced
                // an entirely black screen at ~00:50 even though the UI was
                // still retrying. The old samples are discarded; only the
                // displayed still frame is retained until fresh video arrives.
                await videoLayer.sampleBufferRenderer.flush(removingDisplayedImage: false)
                audioRenderer.flush()
                hardwareDecoder?.invalidate()
                let allowSoftware = UserDefaults.standard.bool(
                    forKey: "typetype.allowSoftwareDecode"
                )
                hardwareDecoder = usesDirectMP4 ? nil : HardwareVideoDecoder(
                    display: videoLayer, allowSoftware: allowSoftware
                )
                hardwareDecoder?.playbackPaused = prefersPause
                playbackPositionMs = restartPosition
                isInitialized = false
                hasQueuedFirstAudio = false
                hasQueuedFirstVideo = false
                resetBufferClock()
                cachedThroughMs = restartPosition
                diskCacheBytes = 0
                await cache.clear()
                segmentCache = SabrFragmentCache(maxMiB: buffer.cacheMiB)
                state = TVL10n.value("player.session")
            }
        }
    }

    /// Uses the *actual playback clock* for the server's position updates.
    /// The bufferedRanges fields, rather than a fake forward seek, tell the
    /// server which completed audio/video intervals are already stored.
    private func downloadWindows(service: SabrService, sessionId: String,
                                 generation: Int64, choice: SabrSelection,
                                 start: Int64, buffer: SabrBufferSettings,
                                 cache: SabrFragmentCache,
                                 mailbox: SabrWindowMailbox) async throws {
        var coverage = SabrPlaybackCoverage(audioItag: choice.audio.itag,
                                            videoItag: choice.video.itag,
                                            positionMs: start,
                                            stage: "producer")
        var previousEnd = start
        var first = true
        var stalled = 0
        var lastAudioSequence: Int?
        var lastVideoSequence: Int?
        let target = SabrLookaheadPolicy.targetMilliseconds(
            buffer, videoBitrate: choice.video.bitrate
        )
        while !Task.isCancelled {
            let seconds = playbackSeconds()
            let playhead = seconds.isFinite ? max(start, Int64(max(0, seconds) * 1_000)) : start
            let retainedEnd = await cache.cachedThroughMs(
                audioItag: choice.audio.itag, videoItag: choice.video.itag,
                positionMs: playhead
            )
            cachedThroughMs = retainedEnd
            diskCacheBytes = await cache.bytesInUse
            if !first && !SabrLookaheadPolicy.shouldRequestMore(
                cachedThroughMs: retainedEnd, playheadMs: playhead, targetMs: target
            ) {
                try await Task.sleep(nanoseconds: 250_000_000)
                continue
            }
            // The server treats bufferedRanges as permission to SEEK over
            // entire cached intervals. Its 12-segment window limit means that
            // reporting the multi-minute disk cache can skip over a window
            // the consumer has not yet decoded and cause a gap ~20s in.
            // Walk media metadata sequentially, independent of the live
            // presentation clock. Compressed bytes remain cached by URL.
            let requestPosition = SabrSequentialWindowPolicy.requestPosition(
                first: first, startMs: start,
                continuousEndMs: coverage.safeEndMs
            )
            #if DEBUG
            NSLog("TypeType SABR PRODUCER window-request requestMs=%lld playbackMs=%lld cachedMs=%lld targetMs=%lld",
                  requestPosition, playhead, retainedEnd, target)
            #endif
            #if DEBUG
            let windowRequestStarted = Date()
            #endif
            let original = try await service.window(
                sessionId: sessionId, selection: choice, generation: generation,
                positionMs: requestPosition,
                ranges: SabrSequentialWindowPolicy.advertisedRanges,
                buffer: buffer, requestedBufferGoalMs: Int(target)
            )
            #if DEBUG
            let windowElapsedMs = Int(Date().timeIntervalSince(windowRequestStarted) * 1_000)
            #endif
            #if DEBUG
            if windowElapsedMs > 2_000 {
                NSLog("TypeType SABR PRODUCER slow-window requestMs=%lld elapsedMs=%d",
                      requestPosition, windowElapsedMs)
            }
            #endif
            try Task.checkCancellation()
            guard let originalAudio = original.audio, let originalVideo = original.video else {
                throw SabrFailure.invalidResponse("SABR window has no audio/video pair")
            }
            let audio = SabrTrack(
                mime: originalAudio.mime, initUrl: originalAudio.initUrl,
                segments: SabrMissingSegmentRepair.augmented(
                    originalAudio.segments, after: lastAudioSequence
                )
            )
            let video = SabrTrack(
                mime: originalVideo.mime, initUrl: originalVideo.initUrl,
                segments: SabrMissingSegmentRepair.augmented(
                    originalVideo.segments, after: lastVideoSequence
                )
            )
            let requested = SabrWindow(
                sessionId: original.sessionId, generation: original.generation,
                ready: original.ready, retryAfterMs: original.retryAfterMs,
                status: original.status, durationMs: original.durationMs,
                endOfStream: original.endOfStream, startTimeMs: original.startTimeMs,
                audio: audio, video: video, terminalError: original.terminalError,
                recoveryAction: original.recoveryAction,
                retryVideoItags: original.retryVideoItags
            )
            for (track, originalParts, repairedParts) in [
                ("audio", originalAudio.segments, audio.segments),
                ("video", originalVideo.segments, video.segments)
            ] {
                if repairedParts.count > originalParts.count {
                    let missing = Set(repairedParts.map(\.url))
                        .subtracting(originalParts.map(\.url))
                    for url in missing {
                        NSLog("TypeType SABR REPAIR stage=producer track=%@ seq=%d reason=missing-window-descriptor",
                              track, SabrSequenceOrder.sequence(url) ?? -1)
                    }
                }
            }
            #if DEBUG
            let audioFirst = audio.segments.first?.startMs ?? -1
            let audioLast = audio.segments.last.map { $0.startMs + $0.durationMs } ?? -1
            let videoFirst = video.segments.first?.startMs ?? -1
            let videoLast = video.segments.last.map { $0.startMs + $0.durationMs } ?? -1
            print("TypeType SABR WINDOW requestMs=\(requestPosition) a=\(audio.segments.count)[\(audioFirst)..\(audioLast)] v=\(video.segments.count)[\(videoFirst)..\(videoLast)] cachedMs=\(retainedEnd) playbackMs=\(playhead)")
            #endif

            // First window is delivered immediately for quick start. For
            // subsequent windows, deliver complete downloaded prefixes without
            // waiting for a later segment stalled upstream.
            let isFirstWindow = first
            if first {
                try await mailbox.offer(requested)
                first = false
            }
            let refs = audio.segments.map {
                SabrMediaReference(url: $0.url, itag: choice.audio.itag,
                                   startMs: $0.startMs, durationMs: $0.durationMs)
            } + video.segments.map {
                SabrMediaReference(url: $0.url, itag: choice.video.itag,
                                   startMs: $0.startMs, durationMs: $0.durationMs)
            }
            #if DEBUG
            let prefetchStarted = Date()
            #endif
            // /segments can report a ready window containing progressive
            // fragments that still return HTTP 202 on GET. The ordinary
            // window prefetch loop is already finished at this point. Nudge
            // the server's targeted-demand builder every 5 seconds while
            // the actual audio/video fragment downloads are outstanding.
            // Cancellation prevents any heartbeat from outliving a window.
            let mediaPrefetch = Task { @MainActor in
                // Retain the retry count in Release: failure logs still report it.
                var attempts = 0
                while !Task.isCancelled {
                    do {
                        try await Task.sleep(nanoseconds: 5_000_000_000)
                    } catch {
                        return
                    }
                    guard !Task.isCancelled else { return }
                    attempts += 1
                    #if DEBUG
                    NSLog("TypeType SABR MEDIA re-prefetch attempt=%d requestMs=%lld elapsedMs=%d",
                          attempts, requestPosition,
                          Int(Date().timeIntervalSince(prefetchStarted) * 1_000))
                    #endif
                    do {
                        try await service.refreshMediaPrefetch(
                            sessionId: sessionId, selection: choice,
                            generation: generation, positionMs: requestPosition,
                            buffer: buffer, requestedBufferGoalMs: Int(target)
                        )
                    } catch is CancellationError {
                        return
                    } catch {
                        // The segment GET loop remains authoritative for
                        // failures; an optional nudge must not interrupt
                        // otherwise valid compressed-media downloads.
                        NSLog("TypeType SABR MEDIA re-prefetch failed attempt=%d kind=%@",
                              attempts, String(describing: type(of: error)))
                    }
                }
            }
            var delivery = SabrPrefetchDelivery(
                audio: audio.segments, video: video.segments
            )
            let onBatch: @MainActor ([SabrMediaReference]) async throws -> Void = { batch in
                guard !isFirstWindow else { return }
                let next = delivery.completed(batch)
                guard !next.audio.isEmpty || !next.video.isEmpty else { return }
                let partial = SabrWindow(
                    sessionId: requested.sessionId,
                    generation: requested.generation,
                    ready: requested.ready,
                    retryAfterMs: requested.retryAfterMs,
                    status: requested.status,
                    durationMs: requested.durationMs,
                    endOfStream: false,
                    startTimeMs: requested.startTimeMs,
                    audio: SabrTrack(
                        mime: audio.mime, initUrl: audio.initUrl,
                        segments: next.audio
                    ),
                    video: SabrTrack(
                        mime: video.mime, initUrl: video.initUrl,
                        segments: next.video
                    ),
                    terminalError: requested.terminalError,
                    recoveryAction: requested.recoveryAction,
                    retryVideoItags: requested.retryVideoItags
                )
                #if DEBUG
                NSLog("TypeType SABR PRODUCER progressive-delivery requestMs=%lld audio=%d video=%d",
                      requestPosition, next.audio.count, next.video.count)
                #endif
                try await mailbox.offer(partial)
            }
            do {
                try await cache.preloadFully(
                    refs, service: service, sessionId: sessionId,
                    generation: generation, onBatch: onBatch
                )
            } catch {
                mediaPrefetch.cancel()
                throw error
            }
            mediaPrefetch.cancel()
            #if DEBUG
            let prefetchMs = Int(Date().timeIntervalSince(prefetchStarted) * 1_000)
            #endif
            #if DEBUG
            if prefetchMs > 2_000 {
                NSLog("TypeType SABR PRODUCER slow-prefetch requestMs=%lld audioSegments=%d videoSegments=%d elapsedMs=%d",
                      requestPosition, audio.segments.count, video.segments.count, prefetchMs)
            }
            #endif
            try Task.checkCancellation()
            for part in SabrSequenceOrder.ordered(audio.segments) {
                try coverage.acceptAudio(part)
            }
            for part in SabrSequenceOrder.ordered(video.segments) {
                try coverage.acceptVideo(part)
            }
            if let maximum = audio.segments.compactMap({ SabrSequenceOrder.sequence($0.url) }).max() {
                lastAudioSequence = max(maximum, lastAudioSequence ?? 0)
            }
            if let maximum = video.segments.compactMap({ SabrSequenceOrder.sequence($0.url) }).max() {
                lastVideoSequence = max(maximum, lastVideoSequence ?? 0)
            }
            let downloadedEnd = coverage.safeEndMs
            cachedThroughMs = await cache.cachedThroughMs(
                audioItag: choice.audio.itag, videoItag: choice.video.itag,
                positionMs: playhead
            )
            diskCacheBytes = await cache.bytesInUse

            // The server can finish with an empty or overlapping final window.
            // Always deliver EOS to the decoder instead of treating it as a
            // stalled prefetch, even when no timestamps advance.
            if requested.endOfStream == true {
                if !isFirstWindow { try await mailbox.offer(requested) }
                return
            }
            if downloadedEnd > previousEnd {
                previousEnd = downloadedEnd
                stalled = 0
            } else {
                stalled += 1
                guard stalled <= 8 else {
                    throw SabrFailure.invalidResponse("SABR window stopped advancing")
                }
                try await Task.sleep(nanoseconds: 350_000_000)
                continue
            }
            // All downloaded members were delivered incrementally above.
        }
    }

    /// Audio and video are rendered in media-time order from the queued window.
    /// This path never calls /position, /prefetch or /segments and therefore
    /// cannot hold up the next server window while the renderer is busy.
    private func playCachedWindows(mailbox: SabrWindowMailbox, service: SabrService,
                                   choice: SabrSelection, start: Int64,
                                   presentationStartMs: Int64,
                                   cache: SabrFragmentCache) async throws {
        var audioInit = Data()
        var videoInit = Data()
        var audioInitLocation = ""
        var videoInitLocation = ""
        var seen = Set<String>()
        // Audio (often ~10 s per fragment) and video (often ~5 s) do
        // not share fragment indices. Keep an independent queue per track;
        // only submit samples through the last contiguous COMMON timeline.
        var pendingAudio: [CMSampleBuffer] = []
        var pendingVideo: [CMSampleBuffer] = []
        var audioTimeline = SabrNativeTimelineResolver()
        var previousAACSequence: Int?
        var videoTimeline = SabrNativeTimelineResolver()
        var previousVideoSequence: Int?
        // A gap in *both* decoded tracks at nearly the same media time
        // suggests missing/corrupt source samples, not an audio-only trim.
        #if DEBUG
        var recentAudioGap: SabrMediaGap?
        #endif
        var coverage = SabrPlaybackCoverage(audioItag: choice.audio.itag,
                                            videoItag: choice.video.itag,
                                            positionMs: start, stage: "decoder")
        while let response = try await mailbox.next(onWait: { [weak self] in
            await self?.pauseForEmptyBufferIfNeeded()
        }) {
            try Task.checkCancellation()
            if let ms = response.durationMs { durationMs = ms }
            guard let audio = response.audio, let video = response.video else {
                throw SabrFailure.invalidResponse("SABR audio/video missing")
            }
            if audioInitLocation != audio.initUrl {
                audioInit = try await service.fragmentData(
                    audio.initUrl, sessionId: sessionId,
                    itag: choice.audio.itag, generation: generation
                )
                audioInitLocation = audio.initUrl
                audioTimeline = SabrNativeTimelineResolver()
                previousAACSequence = nil
            }
            if videoInitLocation != video.initUrl {
                videoInit = try await service.fragmentData(
                    video.initUrl, sessionId: sessionId,
                    itag: choice.video.itag, generation: generation
                )
                videoInitLocation = video.initUrl
                videoTimeline = SabrNativeTimelineResolver()
                previousVideoSequence = nil
            }

            // Merge segments by media time, NEVER by array index. Index pairing
            // incorrectly associates an audio fragment spanning 10 seconds
            // with a 5-second video fragment. When the next audio fragment
            // arrives, that can make video starve while audio runs ahead even
            // though the network cache holds minutes of media.
            for segment in SabrSequenceOrder.ordered(audio.segments) {
                try Task.checkCancellation()
                let key = "a:\(segment.url)"
                guard !seen.contains(key) else { continue }
                let sid = sessionId, gen = generation
                let bytes = try await cache.data(for: segment.url) {
                    try await service.fragmentData(segment.url, sessionId: sid,
                                                   itag: choice.audio.itag, generation: gen)
                }
                #if DEBUG
                let readStarted = ProcessInfo.processInfo.systemUptime
                #endif
                let rawSamples = try await SabrMediaDemux.samples(
                    initialization: audioInit, fragment: bytes,
                    mediaType: .audio, direct: usesDirectMP4,
                    presentationStartMs: presentationStartMs > start
                        ? presentationStartMs : nil
                )
                #if DEBUG
                let readMs = Int((ProcessInfo.processInfo.systemUptime - readStarted) * 1_000)
                #endif
                let sequence = Int(URL(string: segment.url)?.lastPathComponent ?? "")
                #if DEBUG
                if readMs >= 200 {
                    let now = Int64(max(0, playbackSeconds() * 1_000))
                    NSLog("TypeType SABR DEMUX track=audio seq=%d elapsedMs=%d samples=%d clockMs=%lld audioAheadMs=%lld videoAheadMs=%lld",
                          sequence ?? -1, readMs, rawSamples.count, now,
                          queuedAudioEndMs - now, queuedVideoEndMs - now)
                }
                #endif
                let nativeStart = SabrMP4NativeTiming.decodeStartMs(
                    initialization: audioInit, fragment: bytes
                )
                let previousSampleEnd = audioTimeline.lastActualEndMs
                guard let mediaStartMs = SabrRecoveredFragmentAnchor.startMs(
                    metadataStartMs: segment.startMs,
                    isRecovered: segment.durationMs == 1,
                    nativeDecodeStartMs: nativeStart,
                    priorSampleEndMs: previousSampleEnd
                ) else {
                    NSLog("TypeType SABR REPAIR stage=decoder track=audio seq=%d outcome=noncontiguous nativeMs=%lld previousEndMs=%lld",
                          sequence ?? -1, nativeStart ?? -1, previousSampleEnd ?? -1)
                    throw SabrFailure.invalidResponse(
                        "SABR recovered media has noncontiguous native timestamps"
                    )
                }
                let resolved = audioTimeline.resolve(
                    sequence: sequence, metadataStartMs: mediaStartMs,
                    decodeStartMs: nativeStart
                )
                // This continuity repair must run in Release builds as well.
                // The old DEBUG-only variant was tested on Apple TV but left
                // the ~48ms fragment gaps in production builds.
                let isContinuation = SabrAACPrimingPolicy.isSeamlessContinuation(
                    previousSequence: previousAACSequence, sequence: sequence,
                    previousEndMs: previousSampleEnd, startMs: resolved.startMs
                )
                let markers = SabrAACPrimingPolicy.inspect(rawSamples)
                let safeToRemove = SabrAACPrimingPolicy.shouldRemoveRepeatedTrim(
                    continuation: isContinuation, markers: markers
                )
                let removedTrim = safeToRemove
                    ? SabrAACPrimingPolicy.removeRepeatedStartTrim(rawSamples) : false
                #if DEBUG
                // Normal fragment transitions no longer generate noisy logs.
                // Keep exceptional cases observable while SABR recovery is
                // investigated independently.
                if (isContinuation && (!safeToRemove || !removedTrim))
                    || markers.decoderReset > 0 || markers.decoderDrain > 0 {
                    NSLog("TypeType SABR AAC PRIMING anomaly seq=%d continuation=%d startTrim=%d removedTrim=%d reset=%d endTrim=%d drain=%d",
                          sequence ?? -1, isContinuation ? 1 : 0,
                          markers.startTrim, removedTrim ? 1 : 0,
                          markers.decoderReset, markers.endTrim, markers.decoderDrain)
                }
                #endif
                // The direct parser already reports the true tfdt/trun time.
                // Re-snapping every AAC fragment to rounded server metadata
                // can introduce a repeatable 20-50ms discontinuity.
                let nativeSampleStartMs = SabrSampleTimingProbe.actualStartMs(rawSamples)
                let keepNative = usesDirectMP4 && SabrDirectTimestampPolicy.preserveNative(
                    nativeStartMs: nativeSampleStartMs,
                    expectedStartMs: resolved.startMs,
                    previousActualEndMs: previousSampleEnd,
                    previousSequence: previousAACSequence, sequence: sequence
                )
                let samples = keepNative ? rawSamples : try SabrSampleTimeline.aligned(
                    rawSamples, segmentStartMs: resolved.startMs
                )
                #if DEBUG
                if usesDirectMP4, let nativeSampleStartMs,
                   abs(Double(nativeSampleStartMs) - Double(resolved.startMs)) > 10 {
                    NSLog("TypeType SABR DIRECT-TIME track=audio seq=%d nativeStartMs=%lld expectedStartMs=%lld previousEndMs=%lld preserved=%d",
                          sequence ?? -1, nativeSampleStartMs, resolved.startMs,
                          previousSampleEnd ?? -1, keepNative ? 1 : 0)
                }
                #endif
                if samples.isEmpty {
                    // In a decoder preroll this entire audio fragment may
                    // end before the real seek target. Its metadata remains
                    // relevant to window continuity, but it must stay silent.
                    guard presentationStartMs > start else {
                        throw SabrFailure.unsupported("SABR audio segment contains no compressed samples")
                    }
                    try coverage.acceptAudio(segment)
                    previousAACSequence = sequence
                    seen.insert(key)
                    continue
                }
                let actualEnd = SabrSampleTimingProbe.actualEndMs(samples)
                #if DEBUG
                if usesDirectMP4, let previousSampleEnd,
                   let sampleStartMs = SabrSampleTimingProbe.actualStartMs(samples) {
                    let delta = Double(sampleStartMs) - Double(previousSampleEnd)
                    if abs(delta) > 12 {
                        NSLog("TypeType SABR AUDIO-BOUNDARY seq=%d previousEndMs=%lld actualStartMs=%lld deltaMs=%lld nativePreserved=%d rendererAudioAheadMs=%lld",
                              sequence ?? -1, previousSampleEnd, sampleStartMs,
                              Int64(delta.rounded()), keepNative ? 1 : 0,
                              queuedAudioEndMs - Int64(max(0, playbackSeconds() * 1_000)))
                    }
                }
                let integrity = SabrSampleIntegrity.inspect(samples)
                SabrSampleIntegrity.logAnomalies(
                    integrity, track: "audio", sequence: sequence,
                    fragmentBytes: bytes.count, thresholdMs: 80
                )
                recentAudioGap = (integrity.largestGap?.lengthMs ?? 0) >= 80
                    ? integrity.largestGap : nil
                #endif
                audioTimeline.recordActualEndMs(actualEnd)
                if segment.durationMs == 1 {
                    NSLog("TypeType SABR REPAIR stage=decoder track=audio seq=%d outcome=sample-verified nativeMs=%lld actualEndMs=%lld",
                          sequence ?? -1, nativeStart ?? -1, actualEnd ?? -1)
                }
                #if DEBUG
                SabrSampleTimingProbe.logEvidence(
                    track: "audio", itag: choice.audio.itag, sequence: sequence,
                    metadataStartMs: segment.startMs, metadataDurationMs: segment.durationMs,
                    nativeStartMs: nativeStart, resolvedStartMs: resolved.startMs,
                    priorSampleEndMs: previousSampleEnd, actualEndMs: actualEnd,
                    corrected: resolved.corrected
                )
                #endif
                pendingAudio.append(contentsOf: samples)
                previousAACSequence = sequence
                try coverage.acceptAudio(SabrSampleTimingProbe.measuredFragment(
                    segment, startMs: resolved.startMs, actualEndMs: actualEnd
                ))
                seen.insert(key)
            }
            for segment in SabrSequenceOrder.ordered(video.segments) {
                try Task.checkCancellation()
                let key = "v:\(segment.url)"
                guard !seen.contains(key) else { continue }
                let sid = sessionId, gen = generation
                let bytes = try await cache.data(for: segment.url) {
                    try await service.fragmentData(segment.url, sessionId: sid,
                                                   itag: choice.video.itag, generation: gen)
                }
                #if DEBUG
                let readStarted = ProcessInfo.processInfo.systemUptime
                #endif
                let rawSamples = try await SabrMediaDemux.samples(
                    initialization: videoInit, fragment: bytes,
                    mediaType: .video, direct: usesDirectMP4,
                    presentationStartMs: presentationStartMs > start
                        ? presentationStartMs : nil
                )
                #if DEBUG
                let readMs = Int((ProcessInfo.processInfo.systemUptime - readStarted) * 1_000)
                #endif
                let sequence = Int(URL(string: segment.url)?.lastPathComponent ?? "")
                #if DEBUG
                if readMs >= 200 {
                    let now = Int64(max(0, playbackSeconds() * 1_000))
                    NSLog("TypeType SABR DEMUX track=video seq=%d elapsedMs=%d samples=%d clockMs=%lld audioAheadMs=%lld videoAheadMs=%lld",
                          sequence ?? -1, readMs, rawSamples.count, now,
                          queuedAudioEndMs - now, queuedVideoEndMs - now)
                }
                #endif
                let nativeStart = SabrMP4NativeTiming.decodeStartMs(
                    initialization: videoInit, fragment: bytes
                )
                let previousSampleEnd = videoTimeline.lastActualEndMs
                guard let mediaStartMs = SabrRecoveredFragmentAnchor.startMs(
                    metadataStartMs: segment.startMs,
                    isRecovered: segment.durationMs == 1,
                    nativeDecodeStartMs: nativeStart,
                    priorSampleEndMs: previousSampleEnd
                ) else {
                    NSLog("TypeType SABR REPAIR stage=decoder track=video seq=%d outcome=noncontiguous nativeMs=%lld previousEndMs=%lld",
                          sequence ?? -1, nativeStart ?? -1, previousSampleEnd ?? -1)
                    throw SabrFailure.invalidResponse(
                        "SABR recovered media has noncontiguous native timestamps"
                    )
                }
                let resolved = videoTimeline.resolve(
                    sequence: sequence, metadataStartMs: mediaStartMs,
                    decodeStartMs: nativeStart
                )
                let nativeSampleStartMs = SabrSampleTimingProbe.actualStartMs(rawSamples)
                let keepNative = usesDirectMP4 && SabrDirectTimestampPolicy.preserveNative(
                    nativeStartMs: nativeSampleStartMs,
                    expectedStartMs: resolved.startMs,
                    previousActualEndMs: previousSampleEnd,
                    previousSequence: previousVideoSequence, sequence: sequence
                )
                let samples = keepNative ? rawSamples : try SabrSampleTimeline.aligned(
                    rawSamples, segmentStartMs: resolved.startMs
                )
                #if DEBUG
                if usesDirectMP4, let nativeSampleStartMs,
                   abs(Double(nativeSampleStartMs) - Double(resolved.startMs)) > 10 {
                    NSLog("TypeType SABR DIRECT-TIME track=video seq=%d nativeStartMs=%lld expectedStartMs=%lld previousEndMs=%lld preserved=%d",
                          sequence ?? -1, nativeSampleStartMs, resolved.startMs,
                          previousSampleEnd ?? -1, keepNative ? 1 : 0)
                }
                #endif
                guard !samples.isEmpty else {
                    throw SabrFailure.unsupported("SABR video segment contains no compressed samples")
                }
                let actualEnd = SabrSampleTimingProbe.actualEndMs(samples)
                #if DEBUG
                let integrity = SabrSampleIntegrity.inspect(samples)
                SabrSampleIntegrity.logAnomalies(
                    integrity, track: "video", sequence: sequence,
                    fragmentBytes: bytes.count, thresholdMs: 150
                )
                if let audioGap = recentAudioGap,
                   let videoGap = integrity.largestGap,
                   videoGap.lengthMs >= 150,
                   SabrSampleIntegrity.coincident(audioGap, videoGap) {
                    NSLog("TypeType SABR MEDIA-INTEGRITY correlated audioGapMs=%lld videoGapMs=%lld atMs=%lld",
                          audioGap.lengthMs, videoGap.lengthMs,
                          videoGap.startMs)
                }
                #endif
                videoTimeline.recordActualEndMs(actualEnd)
                if segment.durationMs == 1 {
                    NSLog("TypeType SABR REPAIR stage=decoder track=video seq=%d outcome=sample-verified nativeMs=%lld actualEndMs=%lld",
                          sequence ?? -1, nativeStart ?? -1, actualEnd ?? -1)
                }
                #if DEBUG
                SabrSampleTimingProbe.logEvidence(
                    track: "video", itag: choice.video.itag, sequence: sequence,
                    metadataStartMs: segment.startMs, metadataDurationMs: segment.durationMs,
                    nativeStartMs: nativeStart, resolvedStartMs: resolved.startMs,
                    priorSampleEndMs: previousSampleEnd, actualEndMs: actualEnd,
                    corrected: resolved.corrected
                )
                #endif
                pendingVideo.append(contentsOf: samples)
                previousVideoSequence = sequence
                try coverage.acceptVideo(SabrSampleTimingProbe.measuredFragment(
                    segment, startMs: resolved.startMs, actualEndMs: actualEnd
                ))
                seen.insert(key)
                // Feed the A/V common prefix immediately after this video
                // fragment, rather than extracting the entire ~28-second
                // window while both hardware renderer queues drain.
                try await enqueueReadyPrefix(
                    audio: &pendingAudio, video: &pendingVideo,
                    commonEndMs: coverage.safeEndMs, startMs: presentationStartMs
                )
            }

            // Also drain audio-only advancement if video samples were
            // already pending from an earlier window.
            try await enqueueReadyPrefix(
                audio: &pendingAudio, video: &pendingVideo,
                commonEndMs: coverage.safeEndMs, startMs: presentationStartMs
            )

            positionMs = coverage.safeEndMs
            if response.endOfStream == true {
                guard isInitialized else {
                    throw SabrFailure.invalidResponse(
                        "SABR stream ended without playable audio/video startup"
                    )
                }
                // A complete *network* window is not the same as fully
                // presented media. Keep renderers running to the common A/V
                // end before displaying the finished state.
                let endMs = durationMs > 0 ? min(durationMs, coverage.safeEndMs) : coverage.safeEndMs
                if isInitialized && endMs > start {
                    // Data downloaded to disk does not prove that the audio
                    // and video render clock is advancing. A renderer that
                    // stops draining at EOS must recover, not wait forever.
                    var drain = SabrEndDrainMonitor()
                    while true {
                        try Task.checkCancellation()
                        let time = playbackSeconds()
                        guard time.isFinite, time >= 0 else {
                            throw SabrFailure.stalled("invalid media clock at end of stream")
                        }
                        if time * 1_000 >= Double(endMs) { break }
                        if drain.isStalled(
                            positionMs: Int64(min(time * 1_000, Double(Int64.max / 2))),
                            paused: prefersPause
                        ) {
                            throw SabrFailure.stalled("media clock stalled before end of stream")
                        }
                        try await Task.sleep(nanoseconds: 100_000_000)
                    }
                    synchronizer.setRate(0, time: synchronizer.currentTime())
                    isPlaying = false
                    recordProgress(force: true)
                }
                TVPlaybackPresenceReporter.shared.stop(owner: presenceOwner)
                presenceReported = false
                state = TVL10n.value("player.end")
                playbackFinished = true
                return
            }
            state = TVL10n.value(
                !isInitialized ? "player.buffering" :
                    (prefersPause ? "player.paused" : "player.playing")
            )
        }
    }

    /// Submit the maximum verified common A/V prefix as soon as it exists.
    /// Preserve excess samples until their matching other track arrives;
    /// only the renderer owns the advancing presentation clock.
    private func enqueueReadyPrefix(audio pendingAudio: inout [CMSampleBuffer],
                                    video pendingVideo: inout [CMSampleBuffer],
                                    commonEndMs: Int64, startMs: Int64) async throws {
        let audioCount = SabrSampleWindow.prefixCount(
            pendingAudio, endingBeforeMs: commonEndMs
        )
        let videoCount = SabrSampleWindow.prefixCount(
            pendingVideo, endingBeforeMs: commonEndMs
        )
        guard audioCount > 0 || videoCount > 0 else { return }
        let audioReady = Array(pendingAudio.prefix(audioCount))
        let videoReady = Array(pendingVideo.prefix(videoCount))
        // Both tracks must be ready beyond the seek target before the new
        // clock starts, or we may freeze on pre-target reference frames.
        if !isInitialized && commonEndMs <= startMs + 250 { return }
        guard isInitialized || (!audioReady.isEmpty && !videoReady.isEmpty) else { return }
        try await enqueueInterleaved(
            audio: audioReady, video: videoReady, startMs: startMs
        )
        pendingAudio.removeFirst(audioCount)
        pendingVideo.removeFirst(videoCount)
    }

    /// In the native compressed path, audio and video MUST NOT wait on each
    /// other's renderer. The old single feed loop could be stuck waiting for
    /// video queue space while the audio queue ran dry, causing an audible
    /// interruption despite plenty of compressed media on disk.
    private func enqueueInterleaved(audio: [CMSampleBuffer], video: [CMSampleBuffer],
                                    startMs: Int64) async throws {
        if !usesDirectMP4 {
            try await enqueueInterleavedLegacy(audio: audio, video: video, startMs: startMs)
            return
        }
        // Both jobs are @MainActor-isolated for renderer state safety, but
        // proceed independently whenever either awaits its ready callback.
        // This is cooperative concurrency rather than two busy loops.
        async let audioDelivery: Void = feedNativeAudio(audio, startMs: startMs)
        async let videoDelivery: Void = feedNativeVideo(video, startMs: startMs)
        try await audioDelivery
        try await videoDelivery
    }

    private func feedNativeAudio(_ buffers: [CMSampleBuffer],
                                 startMs: Int64) async throws {
        for sample in buffers {
            try Task.checkCancellation()
            try await SabrNativeRendererReadiness.waitUntilReady(audioRenderer)
            guard audioRenderer.status != .failed else {
                throw SabrFailure.stalled("native audio renderer failed")
            }
            audioRenderer.enqueue(sample)
            noteQueuedMedia(.audio, sample: sample)
            hasQueuedFirstAudio = true
            startDirectClockIfReady(at: startMs)
        }
    }

    private func feedNativeVideo(_ buffers: [CMSampleBuffer],
                                 startMs: Int64) async throws {
        let renderer = videoLayer.sampleBufferRenderer
        for sample in buffers {
            try Task.checkCancellation()
            #if DEBUG
            let waitingSince = ProcessInfo.processInfo.systemUptime
            #endif
            try await SabrNativeRendererReadiness.waitUntilReady(renderer)
            guard renderer.status != .failed else {
                throw SabrFailure.stalled("native video renderer failed")
            }
            #if DEBUG
            let waitedMS = Int(
                (ProcessInfo.processInfo.systemUptime - waitingSince) * 1_000
            )
            if waitedMS > 0 {
                maxVideoReadyWaitMs = max(maxVideoReadyWaitMs, waitedMS)
                videoReadyWaits += 1
            }
            #endif
            renderer.enqueue(sample)
            if let endMs = SabrSampleTimingProbe.actualEndMs([sample]) {
                noteQueuedTime(.video, seconds: Double(endMs) / 1_000)
                hasQueuedFirstVideo = true
            }
            #if DEBUG
            videoSamplesDelivered += CMSampleBufferGetNumSamples(sample)
            #endif
            startDirectClockIfReady(at: startMs)
        }
    }

    private func startDirectClockIfReady(at startMs: Int64) {
        guard !isInitialized, hasQueuedFirstAudio && hasQueuedFirstVideo else {
            return
        }
        synchronizer.setRate(
            prefersPause ? 0 : 1,
            time: CMTime(value: startMs, timescale: 1_000)
        )
        isInitialized = true
        isPlaying = !prefersPause
        if let failedManualFormat, let selection {
            let activeFormat = "\(SabrVideoCodecFamily(codec: selection.video.codec)?.title ?? selection.video.codec) \(selection.video.height ?? 0)p"
            qualityFallbackNotice = String(
                format: TVL10n.value("player.qualityFallback"),
                failedManualFormat, activeFormat
            )
            postPlayerNotice(qualityFallbackNotice!)
            self.failedManualFormat = nil
        }
        #if DEBUG
        startRendererProbe()
        #endif
        state = TVL10n.value(
            prefersPause ? "player.paused" : "player.playing"
        )
        if !presenceReported, let api = currentAPI, let video = currentVideo {
            TVPlaybackPresenceReporter.shared.start(
                owner: presenceOwner, api: api, video: video,
                positionMs: max(0, Int64(playbackSeconds() * 1_000)),
                paused: prefersPause
            )
            presenceReported = true
        }
        recordProgress(started: !hasRecordedHistory, force: true)
        hasRecordedHistory = true
        NSLog("TypeType SABR DIRECT-FEED independent audio/video started")
    }

    /// Legacy serial interleave remains for unsupported direct MP4 codecs.
    /// Its explicit VideoToolbox decoder is deliberately left untouched.
    private func enqueueInterleavedLegacy(audio: [CMSampleBuffer], video: [CMSampleBuffer],
                                          startMs: Int64) async throws {
        var ai = 0
        var vi = 0
        while ai < audio.count || vi < video.count {
            try Task.checkCancellation()
            let choice: SabrMediaInterleave.Track
            if !isInitialized && !hasQueuedFirstAudio && ai < audio.count {
                choice = .audio
            } else if !isInitialized && !hasQueuedFirstVideo && vi < video.count {
                choice = .video
            } else {
                let aTime = ai < audio.count
                    ? CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(audio[ai])) : nil
                let vTime = vi < video.count
                    ? CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(video[vi])) : nil
                guard let pick = SabrMediaInterleave.next(
                    audioSeconds: aTime, videoSeconds: vTime
                ) else { break }
                choice = pick
            }

            switch choice {
            case .audio:
                var budget = SabrRendererWaitBudget()
                while !audioRenderer.isReadyForMoreMediaData {
                    try Task.checkCancellation()
                    guard audioRenderer.status != .failed else {
                        throw SabrFailure.stalled("audio renderer reported failure")
                    }
                    guard budget.shouldContinue(
                        paused: prefersPause, stepMilliseconds: SabrRendererPolling.milliseconds
                    ) else {
                        throw SabrFailure.stalled("audio renderer stopped accepting samples")
                    }
                    try await Task.sleep(nanoseconds: SabrRendererPolling.nanoseconds)
                }
                audioRenderer.enqueue(audio[ai])
                noteQueuedMedia(.audio, sample: audio[ai])
                ai += 1
                hasQueuedFirstAudio = true
            case .video:
                var budget = SabrRendererWaitBudget()
                #if DEBUG
                var waitedMs = 0
                #endif
                while !videoLayer.sampleBufferRenderer.isReadyForMoreMediaData {
                    try Task.checkCancellation()
                    guard videoLayer.sampleBufferRenderer.status != .failed else {
                        throw SabrFailure.stalled("video display layer failed")
                    }
                    guard budget.shouldContinue(
                        paused: prefersPause,
                        stepMilliseconds: SabrRendererPolling.milliseconds
                    ) else {
                        throw SabrFailure.stalled("video renderer stopped accepting samples")
                    }
                    #if DEBUG
                    waitedMs += SabrRendererPolling.milliseconds
                    #endif
                    try await Task.sleep(nanoseconds: SabrRendererPolling.nanoseconds)
                }
                #if DEBUG
                if waitedMs > 0 {
                    maxVideoReadyWaitMs = max(maxVideoReadyWaitMs, waitedMs)
                    videoReadyWaits += 1
                }
                #endif
                #if DEBUG
                let deliveryStarted = ProcessInfo.processInfo.systemUptime
                #endif
                let lastDeliveredPTS: CMTime?
                if usesDirectMP4 {
                    // This is the native path used by the official client:
                    // submit compressed H.264/HEVC directly to Apple's video
                    // sample renderer, which shares the audio clock.
                    guard videoLayer.sampleBufferRenderer.status != .failed else {
                        throw SabrFailure.stalled("native compressed video renderer failed")
                    }
                    videoLayer.sampleBufferRenderer.enqueue(video[vi])
                    lastDeliveredPTS = SabrSampleTimingProbe.actualEndMs([video[vi]]).map {
                        CMTime(value: $0, timescale: 1_000)
                    }
                } else {
                    guard let hardwareDecoder else {
                        throw SabrFailure.invalidResponse("decoder missing")
                    }
                    lastDeliveredPTS = try await hardwareDecoder.decode(video[vi])
                }
                #if DEBUG
                let deliveryMs = Int((ProcessInfo.processInfo.systemUptime -
                                      deliveryStarted) * 1_000)
                maxVideoDeliveryMs = max(maxVideoDeliveryMs, deliveryMs)
                videoSamplesDelivered += CMSampleBufferGetNumSamples(video[vi])
                if let lastDeliveredPTS, isInitialized, !prefersPause,
                   !bufferingClockPaused {
                    let ptsMs = Int64(CMTimeGetSeconds(lastDeliveredPTS) * 1_000)
                    let clockMs = Int64(max(0, playbackSeconds() * 1_000))
                    if ptsMs + 75 < clockMs { lateVideoSamples += 1 }
                }
                #endif
                // Count the latest actually submitted presentation time, not
                // just the first compressed sample in a multi-sample buffer.
                if let lastDeliveredPTS {
                    noteQueuedTime(.video, seconds: CMTimeGetSeconds(lastDeliveredPTS))
                    hasQueuedFirstVideo = true
                }
                vi += 1
            }

            if !isInitialized && hasQueuedFirstAudio && hasQueuedFirstVideo {
                synchronizer.setRate(
                    prefersPause ? 0 : 1,
                    time: CMTime(value: startMs, timescale: 1_000)
                )
                isInitialized = true
                isPlaying = !prefersPause
                if let failedManualFormat, let selection {
                    let activeFormat = "\(SabrVideoCodecFamily(codec: selection.video.codec)?.title ?? selection.video.codec) \(selection.video.height ?? 0)p"
                    qualityFallbackNotice = String(
                        format: TVL10n.value("player.qualityFallback"),
                        failedManualFormat, activeFormat
                    )
                    postPlayerNotice(qualityFallbackNotice!)
                    self.failedManualFormat = nil
                }
                #if DEBUG
                // High-frequency renderer probe is for diagnosing sporadic
                // Apple TV playback glitches, not production telemetry.
                startRendererProbe()
                #endif
                state = TVL10n.value(
                    prefersPause ? "player.paused" : "player.playing"
                )
                if !presenceReported, let api = currentAPI, let video = currentVideo {
                    TVPlaybackPresenceReporter.shared.start(
                        owner: presenceOwner, api: api, video: video,
                        positionMs: max(0, Int64(playbackSeconds() * 1_000)),
                        paused: prefersPause
                    )
                    presenceReported = true
                }
                recordProgress(started: !hasRecordedHistory, force: true)
                hasRecordedHistory = true
            }
        }
    }
}

private final class SampleBufferView: UIView {
    var displayLayer: AVSampleBufferDisplayLayer? {
        didSet {
            oldValue?.removeFromSuperlayer()
            if let displayLayer { layer.addSublayer(displayLayer) }
            setNeedsLayout()
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        displayLayer?.frame = bounds
    }
}

struct SabrVideoSurface: UIViewRepresentable {
    let displayLayer: AVSampleBufferDisplayLayer

    func makeUIView(context: Context) -> UIView {
        let view = SampleBufferView()
        view.backgroundColor = .black
        view.displayLayer = displayLayer
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {}
}

/// tvOS-native modal error controls. The fullscreen SiriRemotePlayerInput is
/// removed while this is visible, so its focusable UIKit view cannot swallow
/// left/right/select presses intended for Retry and Back.
struct SabrPlaybackErrorDialog: View {
    let unavailable: Bool
    let failure: String
    let onRetry: () -> Void
    let onBack: () -> Void

    private enum Action: Hashable { case retry, back }
    @FocusState private var focusedAction: Action?

    var body: some View {
        VStack(spacing: 22) {
            Text(unavailable ? "player.videoUnavailable" : "player.sabrError")
                .font(.largeTitle)
            Text(failure)
                .multilineTextAlignment(.center)
            HStack(spacing: 28) {
                Button("common.retry", action: onRetry)
                    .buttonStyle(.borderedProminent)
                    .focused($focusedAction, equals: .retry)
                Button("common.back", action: onBack)
                    .buttonStyle(.bordered)
                    .focused($focusedAction, equals: .back)
            }
            .focusSection()
        }
        .padding(50)
        .background(.black.opacity(0.86), in: RoundedRectangle(cornerRadius: 20))
        .task {
            // Assign after insertion into the focus tree; otherwise the
            // removed full-screen UIKit remote view can retain focus.
            await Task.yield()
            focusedAction = .retry
        }
    }
}

struct SabrPlayerView: View {
    @Environment(\.dismiss) private var dismiss
    let api: TypeTypeAPI
    let video: VideoItem
    var onPlaybackEvent: ((TVPlaybackEvent) -> Void)? = nil
    @StateObject private var engine = SabrPlayerController()
    @AppStorage("typetype.skipSeconds") private var skipSeconds = 10
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var controlsVisible = true
    @State private var revealIndex = 0
    @State private var optionsVisible = false
    @State private var sponsorSkipCooldown: Date = .distantPast
    @State private var dismissedSponsorSegmentID: String?

    private func currentSponsorSegment() -> TVSponsorBlockActive? {
        guard let settings = engine.sponsorSettings else { return nil }
        return TVSponsorBlock.activeSegment(
            segments: engine.sponsorSegments, settings: settings,
            position: engine.playbackSeconds(),
            duration: Double(engine.durationMs) / 1_000
        )
    }

    private func sponsorNoticeVisible(_ segment: TVSponsorBlockActive) -> Bool {
        !optionsVisible && engine.failure == nil &&
            dismissedSponsorSegmentID != segment.id
    }

    private func dismissSponsorNotice() {
        guard let segment = currentSponsorSegment() else { return }
        dismissedSponsorSegmentID = segment.id
    }

    private func skipSponsorNotice() {
        guard let segment = currentSponsorSegment(),
              sponsorNoticeVisible(segment) else { return }
        dismissedSponsorSegmentID = segment.id
        sponsorSkipCooldown = Date()
        let remainingMs = max(0, (segment.endTime - engine.playbackSeconds()) * 1_000)
        guard remainingMs > 0 else { return }
        engine.seek(api: api, video: video, offsetMs: Int64(remainingMs))
    }


    private func reveal() {
        controlsVisible = true
        revealIndex &+= 1
    }

    private func skip(_ direction: Int) {
        let duration = max(5, min(20, skipSeconds))
        engine.seek(api: api, video: video, offsetMs: Int64(direction * duration * 1_000))
        reveal()
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            SabrVideoSurface(displayLayer: engine.videoLayer).ignoresSafeArea()

            TimelineView(.periodic(from: .now, by: 0.25)) { _ in
                if let caption = engine.caption(
                    at: Int64(engine.playbackSeconds() * 1_000)
                ), !caption.isEmpty {
                    Text(caption)
                        .font(.system(size: 36, weight: .medium))
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 24)
                        .padding(.vertical, 10)
                        .background(.black.opacity(0.73),
                                    in: RoundedRectangle(cornerRadius: 8))
                        .frame(maxWidth: 1300)
                        .frame(maxWidth: .infinity, maxHeight: .infinity,
                               alignment: .bottom)
                        .padding(.bottom, controlsVisible ? 255 : 85)
                }
            }
            .allowsHitTesting(false)

            if !optionsVisible && engine.failure == nil {
                SiriRemotePlayerInput(
                    onTouch: reveal,
                    onDirection: skip,
                    onTogglePlayback: {
                        TVSabrNowPlayingCenter.shared.localToggle(for: engine)
                        reveal()
                    },
                    onSelect: {
                        // Fallback when the native remote capture retains focus.
                        if let segment = currentSponsorSegment(),
                           sponsorNoticeVisible(segment) {
                            skipSponsorNotice()
                        } else {
                            TVSabrNowPlayingCenter.shared.localToggle(for: engine)
                            reveal()
                        }
                    },
                    onOptions: {
                        controlsVisible = true
                        optionsVisible = true
                    },
                    onExit: {
                        if let segment = currentSponsorSegment(),
                           sponsorNoticeVisible(segment) {
                            dismissSponsorNotice()
                        } else {
                            engine.stop()
                            dismiss()
                        }
                    }
                )
                .accessibilityLabel("player.remoteAccessibility")
                .accessibilityHint("player.remoteAccessibilityHint")
                .ignoresSafeArea()
            }

            if let failure = engine.failure {
                SabrPlaybackErrorDialog(
                    unavailable: engine.playbackUnavailable,
                    failure: failure,
                    onRetry: {
                        engine.start(api: api, video: video)
                        reveal()
                    },
                    onBack: {
                        engine.stop()
                        dismiss()
                    }
                )
            } else if controlsVisible {
                VStack {
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 9) {
                            Text(video.title).font(.title.bold()).lineLimit(2)
                            Text(video.uploaderName ?? "")
                                .font(.callout).foregroundStyle(.white.opacity(0.8))
                            if let metadata = TVVideoMetadata.subtitle(for: video) {
                                Text(metadata)
                                    .font(.system(size: 14))
                                    .foregroundStyle(.white.opacity(0.65))
                                    .lineLimit(1)
                            }
                        }
                        Spacer()
                        Text(engine.selectionDescription)
                            .font(.caption).foregroundStyle(.white.opacity(0.8))
                    }
                    Spacer()
                    VStack(spacing: 20) {
                        HStack(spacing: 18) {
                            Text(engine.state).font(.callout)
                            Spacer()
                            if engine.diskCacheBytes > 0 {
                                Text(TVL10n.formatted("player.cache", engine.diskCacheBytes / 1_048_576))
                                    .font(.caption).foregroundStyle(.white.opacity(0.8))
                                let aheadSeconds = max(0, Double(engine.cachedThroughMs) / 1_000
                                                       - engine.playbackSeconds())
                                Text(TVL10n.formatted("player.ahead", Int(aheadSeconds)))
                                    .font(.caption).foregroundStyle(.white.opacity(0.8))
                                let readyAhead = max(0, Double(engine.rendererReadyThroughMs) / 1_000
                                                     - engine.playbackSeconds())
                                Text(TVL10n.formatted("player.rendererAhead", Int(readyAhead)))
                                    .font(.caption).foregroundStyle(.white.opacity(0.8))
                            }
                        }
                        TimelineView(.periodic(from: .now, by: 1)) { _ in
                            HStack(spacing: 20) {
                                Text(engine.timeLabel())
                                    .monospacedDigit()
                                    .frame(width: engine.durationMs >= 3_600_000 ? 140 : 105)
                                ProgressView(
                                    value: SabrProgressDisplay.value(
                                        engine.playbackSeconds(), durationMs: engine.durationMs),
                                    total: SabrProgressDisplay.total(durationMs: engine.durationMs)
                                )
                                Text(engine.totalTimeLabel())
                                    .monospacedDigit()
                                    .frame(width: engine.durationMs >= 3_600_000 ? 140 : 105)
                            }
                        }
                        // Only the full-screen remote capture view should receive
                        // directional presses. Focusable HUD buttons would cause the
                        // Siri Remote to navigate between buttons instead of seeking.
                        HStack(spacing: 48) {
                            Label("−\(skipSeconds) s", systemImage: "gobackward")
                            Label(TVL10n.value(engine.isPlaying ? "player.playPause" : "player.resume"),
                                  systemImage: engine.isPlaying ? "pause.fill" : "play.fill")
                            Label("+\(skipSeconds) s", systemImage: "goforward")
                        }
                        .font(.callout.weight(.medium))
                        .foregroundStyle(.white.opacity(0.9))
                        Text("player.remoteHelp")
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.65))
                    }
                }
                .padding(.horizontal, 80)
                .padding(.top, 70)
                .padding(.bottom, 65)
                .background(
                    LinearGradient(
                        colors: [.black.opacity(0.8), .clear, .clear, .black.opacity(0.9)],
                        startPoint: .top, endPoint: .bottom
                    )
                )
                .transition(.opacity)
            }
        }
        .overlay(alignment: .topTrailing) {
            VStack(alignment: .trailing, spacing: 12) {
                TimelineView(.periodic(from: .now, by: 0.5)) { _ in
                    let segment = currentSponsorSegment()
                    let visibleID = segment.flatMap {
                        sponsorNoticeVisible($0) ? $0.id : nil
                    }
                    Group {
                        if let segment, visibleID != nil {
                            TVSponsorBlockNotice(
                                category: segment.category,
                                onSkip: skipSponsorNotice,
                                onDismiss: dismissSponsorNotice
                            )
                            .id(segment.id)
                            .transition(TVStableMotion.noticeTransition(
                                reduceMotion: reduceMotion))
                        }
                    }
                    .animation(TVStableMotion.noticeAnimation(reduceMotion: reduceMotion),
                               value: visibleID)
                }
                // Newest notices come first. Each owns an independent timer,
                // so expiring one only moves the remaining notices upward.
                ForEach(engine.playerNotices.items) { notice in
                    TVPlayerNoticeView(notice: notice)
                        .transition(TVStableMotion.noticeTransition(
                            reduceMotion: reduceMotion))
                }
            }
            .frame(maxWidth: 660, alignment: .trailing)
            .padding(.top, 4)
            .padding(.trailing, 4)
            .animation(TVStableMotion.noticeAnimation(reduceMotion: reduceMotion),
                       value: engine.playerNotices.items.map(\.id))
        }
        .overlay {
            if optionsVisible {
                SabrPlayerOptions(
                    engine: engine,
                    onQuality: { itag in
                        engine.selectQuality(api: api, video: video, itag: itag)
                        optionsVisible = false
                        reveal()
                    },
                    onAudio: { track in
                        engine.selectAudio(
                            api: api, video: video,
                            itag: track.itag, trackId: track.audioTrackId
                        )
                        optionsVisible = false
                        reveal()
                    },
                    onSubtitle: { track in
                        engine.selectSubtitle(track, origin: api.origin)
                        optionsVisible = false
                        reveal()
                    },
                    onClose: {
                        optionsVisible = false
                        reveal()
                    }
                )
                .transition(TVStableMotion.noticeTransition(reduceMotion: reduceMotion))
            }
        }
        .animation(TVStableMotion.noticeAnimation(reduceMotion: reduceMotion),
                   value: optionsVisible)
        .task {
            engine.start(api: api, video: video)
            TVSabrNowPlayingCenter.shared.activate(for: engine, video: video)
            reveal()
        }
        .task {
            // A periodic snapshot keeps AirPods/Control Center's timeline
            // in sync, including after a seek or stream quality restart.
            while !Task.isCancelled {
                TVSabrNowPlayingCenter.shared.refresh(for: engine)
                do { try await Task.sleep(nanoseconds: 5_000_000_000) }
                catch { return }
            }
        }
        .task {
            while !Task.isCancelled {
                do { try await Task.sleep(nanoseconds: 350_000_000) }
                catch { return }
                guard engine.failure == nil, let settings = engine.sponsorSettings else {
                    engine.setSponsorMuted(false)
                    continue
                }
                let current = engine.playbackSeconds()
                if let hidden = dismissedSponsorSegmentID,
                   currentSponsorSegment()?.id != hidden {
                    dismissedSponsorSegmentID = nil
                }
                let end = TVSponsorBlock.target(
                    segments: engine.sponsorSegments, settings: settings,
                    position: current, duration: Double(engine.durationMs) / 1_000,
                    streamCategory: engine.sponsorStreamCategory
                )
                if settings.sponsorBlockMuteInsteadOfSkip == true {
                    engine.setSponsorMuted(end != nil)
                    continue
                }
                engine.setSponsorMuted(false)
                guard engine.isPlaying, Date().timeIntervalSince(sponsorSkipCooldown) >= 2.5,
                      let end, end > current + 0.15 else { continue }
                sponsorSkipCooldown = Date()
                engine.seek(api: api, video: video,
                            offsetMs: Int64((end - current) * 1_000))
            }
        }
        .task(id: revealIndex) {
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            if !Task.isCancelled && !optionsVisible && engine.failure == nil && engine.isPlaying {
                withAnimation(.easeOut(duration: 0.25)) { controlsVisible = false }
            }
        }
        .onChange(of: engine.isPlaying) {
            TVSabrNowPlayingCenter.shared.refresh(for: engine)
            if !engine.isPlaying { reveal() }
        }
        .onChange(of: engine.durationMs) { _, _ in
            TVSabrNowPlayingCenter.shared.refresh(for: engine)
        }
        .onChange(of: engine.failure) { _, failure in
            TVSabrNowPlayingCenter.shared.refresh(for: engine)
            // An error always takes precedence over the quality/options
            // overlay, so its Retry and Back buttons become the only active
            // controls and receive the Siri Remote focus.
            if failure != nil { optionsVisible = false }
        }
        .onChange(of: engine.playbackUnavailable) { _, unavailable in
            if unavailable { onPlaybackEvent?(.unavailable) }
        }
        .onChange(of: engine.playbackFinished) { _, finished in
            if finished {
                TVSabrNowPlayingCenter.shared.deactivate(for: engine)
                onPlaybackEvent?(.finished)
            }
        }
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 15_000_000_000)
                if Task.isCancelled { break }
                engine.recordProgress()
            }
        }
        .onExitCommand {
            if let segment = currentSponsorSegment(),
               sponsorNoticeVisible(segment) {
                dismissSponsorNotice()
            } else if optionsVisible {
                optionsVisible = false
                reveal()
            } else {
                engine.stop()
                dismiss()
            }
        }
        .onDisappear {
            TVSabrNowPlayingCenter.shared.deactivate(for: engine)
            engine.stop()
        }
    }
}
