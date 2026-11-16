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
/// contiguous with the previous observed sample end. A demuxer fallback that
/// returns local-to-file timestamps still needs the old timebase correction.
enum SabrDirectTimestampPolicy {
    static let metadataSlackMS: Int64 = 250
    static let continuitySlackMS: Int64 = 160

    static func preserveNative(
        nativeStartMs: Int64?,
        expectedStartMs: Int64,
        previousActualEndMs: Int64?,
        previousSequence: Int?,
        sequence: Int?
    ) -> Bool {
        guard let nativeStartMs,
              nativeStartMs >= 0,
              nativeStartMs <= 7 * 24 * 60 * 60 * 1_000,
              expectedStartMs >= 0
        else { return false }

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
