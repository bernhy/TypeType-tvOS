import Foundation

/// Tracks media that has actually been handed to the player, not merely advertised
/// by the server. The next SABR window may advance only to the shorter of the
/// audio/video track ends, otherwise a slower track can be silently skipped.
struct SabrPlaybackCoverage {
    private(set) var audioStartMs: Int64
    private(set) var videoStartMs: Int64
    private(set) var audioEndMs: Int64
    private(set) var videoEndMs: Int64
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
                        track: "audio", stage: stage, itag: audioItag)
    }

    mutating func acceptVideo(_ segment: SabrFragment) throws {
        try Self.accept(segment, end: &videoEndMs,
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

    private static func accept(_ segment: SabrFragment, end: inout Int64,
                               track: String, stage: String, itag: Int) throws {
        guard segment.startMs >= 0 && segment.durationMs > 0,
              segment.startMs <= Int64.max - segment.durationMs else {
            throw SabrFailure.invalidResponse("invalid SABR media segment timestamps")
        }
        // Allow small timestamp deviations at segment boundaries, but never claim
        // continuous buffered media across a real gap. Session recovery handles gaps.
        let toleratedEnd = end > Int64.max - 250 ? Int64.max : end + 250
        guard segment.startMs <= toleratedEnd else {
            // NSLog is retained in the device's unified log. Swift print()
            // alone was absent from the Console export of the previous failure.
            NSLog("TypeType SABR GAP stage=%@ track=%@ itag=%d lastEndMs=%lld nextStartMs=%lld nextDurationMs=%lld gapMs=%lld",
                  stage, track, itag, end, segment.startMs,
                  segment.durationMs, segment.startMs - end)
            throw SabrFailure.invalidResponse("SABR segment gap before next media sample")
        }
        end = max(end, segment.startMs + segment.durationMs)
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
