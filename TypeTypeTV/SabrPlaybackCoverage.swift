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

    init(audioItag: Int, videoItag: Int, positionMs: Int64) {
        self.audioItag = audioItag
        self.videoItag = videoItag
        let start = max(0, positionMs)
        audioStartMs = start
        videoStartMs = start
        audioEndMs = start
        videoEndMs = start
    }

    var safeEndMs: Int64 { min(audioEndMs, videoEndMs) }

    mutating func acceptAudio(_ segment: SabrFragment) throws {
        try Self.accept(segment, end: &audioEndMs)
    }

    mutating func acceptVideo(_ segment: SabrFragment) throws {
        try Self.accept(segment, end: &videoEndMs)
    }

    var requestRanges: [SabrBufferedRange] {
        var ranges: [SabrBufferedRange] = []
        if audioEndMs > audioStartMs {
            ranges.append(SabrBufferedRange(itag: audioItag, startMs: audioStartMs,
                                             endMs: audioEndMs))
        }
        if videoEndMs > videoStartMs {
            ranges.append(SabrBufferedRange(itag: videoItag, startMs: videoStartMs,
                                             endMs: videoEndMs))
        }
        return ranges
    }

    private static func accept(_ segment: SabrFragment, end: inout Int64) throws {
        guard segment.startMs >= 0 && segment.durationMs > 0,
              segment.startMs <= Int64.max - segment.durationMs else {
            throw SabrFailure.invalidResponse("invalid SABR media segment timestamps")
        }
        // Allow small timestamp deviations at segment boundaries, but never claim
        // continuous buffered media across a real gap. Session recovery handles gaps.
        guard segment.startMs <= end + 250 else {
            throw SabrFailure.invalidResponse("SABR segment gap before next media sample")
        }
        end = max(end, segment.startMs + segment.durationMs)
    }
}
