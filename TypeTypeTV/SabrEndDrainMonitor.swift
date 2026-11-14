import Foundation

/// Prevent endless end-of-stream waits when a renderer stops making progress.
/// An intentional pause does not count against the deadline and resets it.
struct SabrEndDrainMonitor {
    private var lastPositionMs: Int64?
    private var stationarySince: Date?
    let timeoutSeconds: TimeInterval

    init(timeoutSeconds: TimeInterval = 20) {
        self.timeoutSeconds = timeoutSeconds
    }

    mutating func isStalled(positionMs: Int64, paused: Bool,
                           now: Date = Date()) -> Bool {
        let changed = lastPositionMs == nil ||
            abs(positionMs - (lastPositionMs ?? positionMs)) >= 50
        if paused || changed {
            lastPositionMs = positionMs
            stationarySince = paused ? nil : now
            return false
        }
        if stationarySince == nil {
            stationarySince = now
            return false
        }
        return now.timeIntervalSince(stationarySince!) >= timeoutSeconds
    }
}
