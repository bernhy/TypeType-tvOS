#if DEBUG
import Foundation

/// Automatically enabled in all DEBUG builds. No launch argument.
/// The entire feature compiles out of Release builds. No timer, observer,
/// view layer or background task: one aggregate console line is emitted
/// per ~3 seconds while the user is actively navigating Home.
enum TVHomeFocusDiagnostics {
    enum Metric: Int, CaseIterable {
        case homeBody, focusChange, tileBuild, tileBody, videoCardBody, thumbnailBody
        case thumbnailTask, thumbnailCacheHit, recommendationAppear, resumeAppear
        case anchorReduce, filterRecommendations, filterRecent, buildFocusIDs
        case pageRequest, pageAppend, resumeMetadataLookup, resumeMetadataBatch
    }

    static let enabled = true
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

    /// The tile may not re-evaluate when an Equatable section shields
    /// its parent. Count only its body evaluations; never infer focus from
    /// the parent binding here.
    static func tileBody(focusedID: String?) {
        guard enabled else { return }
        recorder.hit(.tileBody)
    }

    /// VideoCard already reads @Environment(\.isFocused) to draw its zoom.
    /// Count focus transitions from that existing read, without introducing
    /// an extra observer or invalidating the optimized collection.
    static func videoCardBody(isFocused: Bool, videoURL: String) {
        guard enabled else { return }
        recorder.videoCardBody(isFocused: isFocused, videoURL: videoURL)
    }

    // PreferenceKey.reduce is not guaranteed to execute on the main actor.
    // Use one lock; all work outside profiling mode is gated by 'enabled'.
    private final class Recorder {
        private let lock = NSLock()
        private var counts = [Int](repeating: 0, count: Metric.allCases.count)
        private var milliseconds = [Double](repeating: 0, count: Metric.allCases.count)
        private var lastFocusID: String?
        private var windowStart = CFAbsoluteTimeGetCurrent()
        private var recommendations = 0
        private var recent = 0

        func hit(_ metric: Metric, milliseconds duration: Double = 0) {
            lock.lock()
            counts[metric.rawValue] += 1
            milliseconds[metric.rawValue] += duration
            lock.unlock()
        }

        func videoCardBody(isFocused: Bool, videoURL: String) {
            let now = CFAbsoluteTimeGetCurrent()
            lock.lock()
            counts[Metric.videoCardBody.rawValue] += 1
            if isFocused && videoURL != lastFocusID {
                lastFocusID = videoURL
                counts[Metric.focusChange.rawValue] += 1
            }
            // Flush on each focused card update: an Equatable collection
            // rightly suppresses parent/tile body calls on remote moves.
            let summary = snapshotIfDue(now: now)
            lock.unlock()
            logIfNeeded(summary)
        }

        func homeBody(focusedID: String?, recommendations: Int, recent: Int) {
            let now = CFAbsoluteTimeGetCurrent()
            lock.lock()
            counts[Metric.homeBody.rawValue] += 1
            self.recommendations = recommendations
            self.recent = recent
            // Parent focus is deliberately not observed in this experiment.
            // VideoCard's existing environment supplies the focus changes.
            let summary = snapshotIfDue(now: now)
            lock.unlock()
            logIfNeeded(summary)
        }

        /// Called only while holding the lock. Emit from either a Home
        /// render or a focused card, so isolating the parent does not
        /// accidentally silence the diagnostic output.
        private func snapshotIfDue(now: Double) -> String? {
            let elapsed = now - windowStart
            guard elapsed >= 3, counts[Metric.focusChange.rawValue] > 0 else {
                return nil
            }
            func count(_ metric: Metric) -> Int { counts[metric.rawValue] }
            func cost(_ metric: Metric) -> String {
                String(format: "%.2f", milliseconds[metric.rawValue])
            }
            let summary =
                "HomeFocus \(String(format: "%.1f", elapsed))s " +
                "focus=\(count(.focusChange)) home=\(count(.homeBody)) " +
                "tile=\(count(.tileBuild)) tileBody=\(count(.tileBody)) " +
                "videoBody=\(count(.videoCardBody)) " +
                "thumbnailBody=\(count(.thumbnailBody)) " +
                "thumbnailTask=\(count(.thumbnailTask)) " +
                "cacheHit=\(count(.thumbnailCacheHit)) " +
                "appear=\(count(.recommendationAppear))/\(count(.resumeAppear)) " +
                "anchorReduce=\(count(.anchorReduce)) " +
                "pages=\(count(.pageRequest))/\(count(.pageAppend)) " +
                "resumeMeta=\(count(.resumeMetadataLookup))/\(count(.resumeMetadataBatch)) " +
                "filterMs=\(cost(.filterRecommendations))/\(cost(.filterRecent)) " +
                "focusIDsMs=\(cost(.buildFocusIDs)) " +
                "items=\(recommendations)/\(recent)"
            counts = [Int](repeating: 0, count: Metric.allCases.count)
            milliseconds = [Double](repeating: 0, count: Metric.allCases.count)
            windowStart = now
            return summary
        }

        private func logIfNeeded(_ summary: String?) {
            guard let summary else { return }
            // As before, never write to the console synchronously during
            // the focus animation.
            DispatchQueue.global(qos: .utility).async {
                NSLog("TypeType %@", summary)
            }
        }
    }
}
#endif
