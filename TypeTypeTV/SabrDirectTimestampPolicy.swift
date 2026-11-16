import Foundation

/// The direct ISO BMFF reader already supplies each sample's presentation
/// and decoding times from tfdt and trun. Unlike AVAssetReader (which can
/// rebase a standalone temporary MP4), those timestamps normally must NOT
/// be independently snapped to the server's approximate fragment start.
///
/// Re-anchoring every AAC fragment to the server metadata can inject a small
/// repeatable gap or overlap at the boundary. The original TypeTypePlayerKit
/// intentionally retains valid native fMP4 timestamps.
///
/// Preserve native time only if it is consistent with the declared start OR
/// contiguous with the previous observed sample end. When an explicit seek
/// trims pre-target AAC packets, the first *retained* sample naturally starts
/// later than its fragment metadata; do not shift it backwards.
enum SabrDirectTimestampPolicy {
    static let metadataSlackMS: Int64 = 250
    static let continuitySlackMS: Int64 = 160

    static func preserveNative(
        nativeStartMs: Int64?,
        expectedStartMs: Int64,
        previousActualEndMs: Int64?,
        previousSequence: Int?,
        sequence: Int?,
        seekTargetMs: Int64? = nil
    ) -> Bool {
        guard let nativeStartMs,
              nativeStartMs >= 0,
              nativeStartMs <= 7 * 24 * 60 * 60 * 1_000,
              expectedStartMs >= 0
        else { return false }

        if let seekTargetMs, seekTargetMs > 0,
           nativeStartMs >= seekTargetMs - min(100, seekTargetMs),
           nativeStartMs <= seekTargetMs + 10_000 {
            // Early AAC packets were intentionally discarded during preroll.
            // The first retained packet must use its original presentation
            // timestamp, not the earlier segment descriptor start.
            return true
        }

        if abs(Double(nativeStartMs) - Double(expectedStartMs))
            <= Double(metadataSlackMS) {
            return true
        }

        guard let previousActualEndMs, previousActualEndMs >= 0,
              let previousSequence, let sequence,
              previousSequence < Int.max,
              sequence == previousSequence + 1 else {
            return false
        }
        return abs(Double(nativeStartMs) - Double(previousActualEndMs))
            <= Double(continuitySlackMS)
    }
}
