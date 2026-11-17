import Foundation

/// Debug instrumentation data only; never changes playback clocks or queues.
/// Stages are elapsed milliseconds from a start/seek request, not media PTS.
struct SabrStartupMetrics {
    enum Stage: Hashable {
        case bootstrap, session, audioQueued, videoQueued, clockStarted, displayReady
    }

    private var stages: [Stage: Int] = [:]

    mutating func record(_ stage: Stage, elapsedMs: Int) {
        guard elapsedMs >= 0, stages[stage] == nil else { return }
        stages[stage] = elapsedMs
    }

    func elapsedMs(for stage: Stage) -> Int? {
        stages[stage]
    }
}
