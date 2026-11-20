#if DEBUG
import Foundation

/// Opt-in Home focus diagnostics. Enable in Xcode's scheme launch arguments:
///     -typetype.debug.homeFocusMetrics YES
///
/// Disabled by default. No timer, observer, view layer, background task or
/// logging runs in the normal app. Counter accumulation is cheap, and only
/// one aggregate console line is emitted per ~3 seconds of Home activity.
enum TVHomeFocusDiagnostics {
    enum Metric: Int, CaseIterable {
        case homeBody, focusChange, tileBuild, videoCardBody, thumbnailBody
        case thumbnailTask, thumbnailCacheHit, recommendationAppear, resumeAppear
        case anchorReduce, filterRecommendations, filterRecent, buildFocusIDs
        case pageRequest, pageAppend
    }

    static let enabled = UserDefaults.standard.bool(
        forKey: "typetype.debug.homeFocusMetrics"
    )
    private static let recorder = Recorder()

    static func hit(_ metric: Metric) {
        guard enabled else { return }
        recorder.hit(metric)
    }

    static func measure<T>(_ metric: Metric, _ operation: () -> T) -> T {
        guard enabled else { return operation() }
        let start = CFAbsoluteTimeGetCurrent()
        let value = operation()
        recorder.hit(metric, milliseconds: (CFAbsoluteTimeGetCurrent() - start) * 1_000)
        return value
    }

    static func homeBody(focusedID: String?, recommendations: Int, recent: Int) {
        guard enabled else { return }
        recorder.homeBody(focusedID: focusedID, recommendations: recommendations,
                          recent: recent)
    }

    // PreferenceKey.reduce is not guaranteed to execute on the main actor.
    // Use one lock; all work outside profiling mode is gated by 'enabled'.
    private final class Recorder {
        private let lock = NSLock()
        private var counts = [Int](repeating: 0, count: Metric.allCases.count)
        private var milliseconds = [Double](repeating: 0, count: Metric.allCases.count)
        private var lastFocusID: String?
        private var windowStart = CFAbsoluteTimeGetCurrent()

        func hit(_ metric: Metric, milliseconds duration: Double = 0) {
            lock.lock()
            counts[metric.rawValue] += 1
            milliseconds[metric.rawValue] += duration
            lock.unlock()
        }

        func homeBody(focusedID: String?, recommendations: Int, recent: Int) {
            let now = CFAbsoluteTimeGetCurrent()
            var summary: String?
            lock.lock()
            counts[Metric.homeBody.rawValue] += 1
            if focusedID != lastFocusID {
                lastFocusID = focusedID
                counts[Metric.focusChange.rawValue] += 1
            }
            let elapsed = now - windowStart
            if elapsed >= 3 && counts[Metric.focusChange.rawValue] > 0 {
                func count(_ metric: Metric) -> Int { counts[metric.rawValue] }
                func cost(_ metric: Metric) -> String {
                    String(format: "%.2f", milliseconds[metric.rawValue])
                }
                summary =
                    "HomeFocus \(String(format: "%.1f", elapsed))s " +
                    "focus=\(count(.focusChange)) home=\(count(.homeBody)) " +
                    "tile=\(count(.tileBuild)) videoBody=\(count(.videoCardBody)) " +
                    "thumbnailBody=\(count(.thumbnailBody)) " +
                    "thumbnailTask=\(count(.thumbnailTask)) " +
                    "cacheHit=\(count(.thumbnailCacheHit)) " +
                    "appear=\(count(.recommendationAppear))/\(count(.resumeAppear)) " +
                    "anchorReduce=\(count(.anchorReduce)) " +
                    "pages=\(count(.pageRequest))/\(count(.pageAppend)) " +
                    "filterMs=\(cost(.filterRecommendations))/\(cost(.filterRecent)) " +
                    "focusIDsMs=\(cost(.buildFocusIDs)) " +
                    "items=\(recommendations)/\(recent)"
                counts = [Int](repeating: 0, count: Metric.allCases.count)
                milliseconds = [Double](repeating: 0, count: Metric.allCases.count)
                windowStart = now
            }
            lock.unlock()
            if let summary {
                // Logging itself must not steal a frame from a fast swipe.
                // One low-priority submission every ~3s, and ONLY in the
                // explicitly enabled DEBUG tracing mode.
                DispatchQueue.global(qos: .utility).async {
                    NSLog("TypeType %@", summary)
                }
            }
        }
    }
}
#endif
