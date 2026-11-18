import Foundation

/// Decode a short interval *before* the requested seek time so the video
/// renderer receives a random-access picture before it must present frames.
/// The earlier pictures are marked DoNotDisplay by SabrDirectMP4Reader;
/// the playback clock and audio still start exactly at the user's target.
///
/// The server's seek endpoint positions the transport, not necessarily a
/// compressed video's IDR / intra frame. Starting at that arbitrary point can
/// otherwise leave the tvOS renderer waiting 10-20 seconds for its first RAP.
///
/// Keep this a bounded, deterministic look-behind: the server handles the
/// exact sequence/segment mapping and the fMP4 reader marks pre-target frames
/// invisible. Hardware validation remains important for unusually long GOPs.
enum SabrSeekPreroll {
    // Twenty seconds of hidden frames overwhelmed the paused video renderer:
    // seeking started the A/V clock while the video queue was still far before
    // the target. Bound preroll to one typical fMP4 keyframe interval instead.
    static let maximumMilliseconds: Int64 = 5_000

    static func requestStart(targetMs: Int64, explicit: Bool) -> Int64 {
        let target = max(0, targetMs)
        guard explicit && target > 0 else { return target }
        return target - min(target, maximumMilliseconds)
    }

    static func isBeforePresentation(sampleStartTicks: Int64,
                                     durationTicks: UInt32,
                                     timescale: UInt32,
                                     targetMs: Int64) -> Bool {
        guard timescale > 0, targetMs > 0 else { return false }
        let last = sampleStartTicks + Int64(durationTicks)
        return Double(last) * 1_000 / Double(timescale) <= Double(targetMs)
    }
}

/// Cold nonzero SABR sessions can get stuck in the server's demand builder
/// before /segments ever becomes ready. A playing session can seek correctly,
/// so first establish the transport at zero, then seek to the original
/// 5-second-preroll resume position. Keep the normal zero-start and fast
/// existing-session seek paths unchanged.
enum SabrColdResumePolicy {
    static func primeFromZero(transportStartMs: Int64,
                              reusingSession: Bool) -> Bool {
        transportStartMs > 0 && !reusingSession
    }
}

/// Pure MP4 sample-table keyframe choice; no media bytes or renderer state.
/// Missing/ambiguous sync flags leave samples untouched rather than
/// pretending every sample is independently decodable.
extension SabrSeekPreroll {
    static func lastReliableSyncBeforeTarget(samples: [MP4Sample],
                                             timescale: UInt32,
                                             targetMs: Int64) -> Int? {
        guard timescale > 0, targetMs > 0,
              // Some fMP4 streams omit explicit dependency flags; the
              // parser then marks everything as sync. Do not trust that.
              samples.contains(where: { !$0.isSync }) else { return nil }
        return samples.indices.last { index in
            let sample = samples[index]
            return sample.isSync && sample.presentationTime >= 0 &&
                Double(sample.presentationTime) * 1_000 /
                    Double(timescale) <= Double(targetMs)
        }
    }
}
