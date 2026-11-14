import Foundation

/// A sequential SABR fragment can start after the preceding fragment's
/// advertised end even when no sequence number is missing. This is a
/// timestamp discontinuity, not necessarily a missing network segment.
/// Keep producer, decoder and local-cache lookahead on one bounded policy.
enum SabrMediaGapPolicy {
    static let unknownSequenceToleranceMs: Int64 = 250
    // Real itag=137 VOD traces have shown 4.370s and 7.040s jumps between
    // adjacent sequence numbers. Do not restart the *same* segment forever.
    static let consecutiveSequenceToleranceMs: Int64 = 8_000

    static func toleranceMs(consecutive: Bool) -> Int64 {
        consecutive ? consecutiveSequenceToleranceMs : unknownSequenceToleranceMs
    }
}

/// SABR sequence numbers are stable even when a segment's advertised startMs
/// is incorrect. Sorting only by startMs can process seq 33 before seq 32 and
/// leave a false decoder gap at seq 34 (observed 2026-11-14 at 03:01).
enum SabrSequenceOrder {
    static func sequence(_ reference: String) -> Int? {
        guard let url = URL(string: reference),
              let candidate = url.pathComponents.last,
              let number = Int(candidate), number > 0 else { return nil }
        return number
    }

    static func ordered(_ fragments: [SabrFragment]) -> [SabrFragment] {
        guard fragments.allSatisfy({ sequence($0.url) != nil }) else {
            return fragments.sorted {
                if $0.startMs != $1.startMs { return $0.startMs < $1.startMs }
                return $0.url < $1.url
            }
        }
        return fragments.sorted {
            let left = sequence($0.url) ?? 0
            let right = sequence($1.url) ?? 0
            if left != right { return left < right }
            if $0.startMs != $1.startMs { return $0.startMs < $1.startMs }
            return $0.url < $1.url
        }
    }
}

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

    private static func accept(_ segment: SabrFragment, end: inout Int64,
                               lastSequence: inout Int?,
                               track: String, stage: String, itag: Int) throws {
        guard segment.startMs >= 0 && segment.durationMs > 0,
              segment.startMs <= Int64.max - segment.durationMs else {
            throw SabrFailure.invalidResponse("invalid SABR media segment timestamps")
        }
        let nextSequence = SabrSequenceOrder.sequence(segment.url)
        let consecutive: Bool
        if let lastSequence, let nextSequence, lastSequence < Int.max {
            consecutive = nextSequence == lastSequence + 1
        } else {
            consecutive = false
        }
        // Permit bounded PTS jumps only for immediately consecutive SABR
        // sequence numbers. Do not treat missing sequences as playable.
        // The renderer keeps the original PTS and can hold the last frame
        // during an actual video gap; this does not fabricate lost frames.
        let tolerance = SabrMediaGapPolicy.toleranceMs(consecutive: consecutive)
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
