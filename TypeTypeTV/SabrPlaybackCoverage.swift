import Foundation

/// Tracks media that has actually been handed to the player, not merely advertised
/// by the server. The next SABR window may advance only to the shorter of the
/// audio/video track ends, otherwise a slower track can be silently skipped.
struct SabrPlaybackCoverage {
    private(set) var audioStartMs: Int64
    private(set) var videoStartMs: Int64
    private(set) var audioEndMs: Int64
    private(set) var videoEndMs: Int64
    private var lastAudioSequence: Int?
    private var lastVideoSequence: Int?
    let audioItag: Int
    let videoItag: Int
    let stage: String

    init(audioItag: Int, videoItag: Int, positionMs: Int64,
         stage: String = "unknown") {
        self.audioItag = audioItag
        self.videoItag = videoItag
        self.stage = stage
        let start = max(0, positionMs)
        audioStartMs = start
        videoStartMs = start
        audioEndMs = start
        videoEndMs = start
    }

    var safeEndMs: Int64 { min(audioEndMs, videoEndMs) }

    mutating func acceptAudio(_ segment: SabrFragment) throws {
        try Self.accept(segment, end: &audioEndMs,
                        lastSequence: &lastAudioSequence,
                        track: "audio", stage: stage, itag: audioItag)
    }

    mutating func acceptVideo(_ segment: SabrFragment) throws {
        try Self.accept(segment, end: &videoEndMs,
                        lastSequence: &lastVideoSequence,
                        track: "video", stage: stage, itag: videoItag)
    }

    var requestRanges: [SabrBufferedRange] { requestRanges(retainFromMs: 0) }

    func requestRanges(retainFromMs: Int64) -> [SabrBufferedRange] {
        let earliest = max(0, retainFromMs)
        var ranges: [SabrBufferedRange] = []
        if audioEndMs > audioStartMs {
            let start = max(audioStartMs, earliest)
            if audioEndMs > start {
                ranges.append(SabrBufferedRange(itag: audioItag, startMs: start,
                                                 endMs: audioEndMs))
            }
        }
        if videoEndMs > videoStartMs {
            let start = max(videoStartMs, earliest)
            if videoEndMs > start {
                ranges.append(SabrBufferedRange(itag: videoItag, startMs: start,
                                                 endMs: videoEndMs))
            }
        }
        return ranges
    }

    /// A VOD fragment's declared duration is sometimes shorter than its
    /// successor's start time, even for immediately adjacent *sequence numbers*.
    /// This happens on real SABR feeds with variable-duration fragments.
    /// It is not evidence that a network fragment went missing.
    ///
    /// Never bridge a missing sequence or an unverified gap: those still
    /// trigger session recovery. Keep the original diagnostic for both cases.
    private static func sequence(_ reference: String) -> Int? {
        guard let url = URL(string: reference),
              let last = url.pathComponents.last,
              let number = Int(last), number > 0 else { return nil }
        return number
    }

    private static func accept(_ segment: SabrFragment, end: inout Int64,
                               lastSequence: inout Int?,
                               track: String, stage: String, itag: Int) throws {
        guard segment.startMs >= 0 && segment.durationMs > 0,
              segment.startMs <= Int64.max - segment.durationMs else {
            throw SabrFailure.invalidResponse("invalid SABR media segment timestamps")
        }
        let nextSequence = sequence(segment.url)
        let consecutive: Bool
        if let lastSequence, let nextSequence, lastSequence < Int.max {
            consecutive = nextSequence == lastSequence + 1
        } else {
            consecutive = false
        }
        // 250 ms handles normal rounding when the sequence is unknown.
        // For verified consecutive media fragments, a bounded timestamp
        // discontinuity may be a valid edit/PTS jump; letting the renderer
        // hold the preceding frame is preferable to tearing down the session.
        let tolerance: Int64 = consecutive ? 4_000 : 250
        let toleratedEnd = end > Int64.max - tolerance ? Int64.max : end + tolerance
        if segment.startMs > end + min(Int64(250), Int64.max - end) {
            NSLog("TypeType SABR GAP stage=%@ track=%@ itag=%d lastEndMs=%lld nextStartMs=%lld nextDurationMs=%lld gapMs=%lld priorSeq=%d nextSeq=%d consecutive=%d",
                  stage, track, itag, end, segment.startMs,
                  segment.durationMs, segment.startMs - end,
                  lastSequence ?? -1, nextSequence ?? -1, consecutive ? 1 : 0)
        }
        guard segment.startMs <= toleratedEnd else {
            throw SabrFailure.invalidResponse("SABR segment gap before next media sample")
        }
        end = max(end, segment.startMs + segment.durationMs)
        if let nextSequence, nextSequence > (lastSequence ?? 0) {
            lastSequence = nextSequence
        }
    }
}

/// Network media coverage is not the same as samples handed to both renderers.
/// A stalled video decoder must pause the shared clock even if whole fragments
/// are already on disk and the producer advertised their time range.
enum SabrRendererCoverage {
    static func commonEnd(audioEndMs: Int64, videoEndMs: Int64) -> Int64? {
        guard audioEndMs > 0, videoEndMs > 0 else { return nil }
        return min(audioEndMs, videoEndMs)
    }

    static func shouldPause(clockMs: Int64, audioEndMs: Int64,
                            videoEndMs: Int64, marginMs: Int64 = 450) -> Bool {
        guard let end = commonEnd(audioEndMs: audioEndMs, videoEndMs: videoEndMs) else {
            return false
        }
        return max(0, clockMs) >= max(0, end - max(0, marginMs))
    }
}
