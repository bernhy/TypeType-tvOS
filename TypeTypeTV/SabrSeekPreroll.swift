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
/// exact sequence/segment mapping and the fMP4 reader finds real sync samples.
enum SabrSeekPreroll {
    static let maximumMilliseconds: Int64 = 20_000

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
