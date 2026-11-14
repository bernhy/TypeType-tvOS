/// Poll sooner than a 30 fps video frame (33.3ms). The prior 15ms and
/// 20ms wakeups could consume nearly a whole presentation interval when
/// both the compressed and decoded sample queues were full.
enum SabrRendererPolling {
    static let milliseconds = 5
    static let nanoseconds: UInt64 = UInt64(milliseconds) * 1_000_000
}

/// A paused clock naturally fills the hardware and audio renderer queues.
/// Only a *running* renderer should consume the 15-second stall budget.
struct SabrRendererWaitBudget {
    private(set) var milliseconds = 0

    mutating func shouldContinue(paused: Bool, stepMilliseconds: Int,
                                 limitMilliseconds: Int = 15_000) -> Bool {
        if paused {
            milliseconds = 0
            return true
        }
        guard stepMilliseconds > 0 && limitMilliseconds > 0 else { return false }
        milliseconds += stepMilliseconds
        return milliseconds <= limitMilliseconds
    }
}
