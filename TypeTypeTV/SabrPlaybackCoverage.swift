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

    private static func accept(_ segment: SabrFragment, end: inout Int64) throws {
        guard segment.startMs >= 0 && segment.durationMs > 0,
              segment.startMs <= Int64.max - segment.durationMs else {
            throw SabrFailure.invalidResponse("invalid SABR media segment timestamps")
        }
        // Allow small timestamp deviations at segment boundaries, but never claim
        // continuous buffered media across a real gap. Session recovery handles gaps.
        let toleratedEnd = end > Int64.max - 250 ? Int64.max : end + 250
        guard segment.startMs <= toleratedEnd else {
            #if DEBUG
            print("TypeType SABR gap: wanted start <= \(toleratedEnd) ms; next segment starts \(segment.startMs) ms (gap \(segment.startMs - end) ms), URL path \(URL(string: segment.url)?.path ?? "unknown")")
            #endif
            throw SabrFailure.invalidResponse("SABR segment gap before next media sample")
        }
        end = max(end, segment.startMs + segment.durationMs)
    }
}
