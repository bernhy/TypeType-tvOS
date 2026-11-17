import Foundation

/// Small, testable arithmetic for the exact user-visible seek position.
/// Transport preroll is a decoder implementation detail, not a new target.
enum SabrSeekTargetPolicy {
    static func target(anchorMs: Int64, offsetMs: Int64,
                       durationMs: Int64) -> Int64 {
        let safe = max(0, anchorMs)
        let (sum, overflow) = safe.addingReportingOverflow(offsetMs)
        let raw = overflow ? (offsetMs < 0 ? Int64.min : Int64.max) : sum
        let upper = durationMs > 0 ? max(0, durationMs - 1_000) : Int64.max
        return min(upper, max(0, raw))
    }

    static func recoveryPresentation(desiredMs: Int64, transportMs: Int64,
                                     initialized: Bool) -> Int64 {
        if !initialized {
            return max(desiredMs, transportMs)
        }
        return max(0, transportMs)
    }
}
