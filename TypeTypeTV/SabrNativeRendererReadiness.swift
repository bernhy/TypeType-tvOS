import AVFoundation
import Foundation

/// A cancellation-safe single notification from AVQueuedSampleBufferRendering.
/// Replaces repeated 5ms polls in the new direct compressed sample path.
/// The legacy VideoToolbox path retains its existing bounded polling.
private final class SabrReadinessContinuation: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Never>?
    private var signalled = false

    func install(_ newContinuation: CheckedContinuation<Void, Never>) {
        lock.lock()
        if signalled {
            lock.unlock()
            newContinuation.resume()
            return
        }
        continuation = newContinuation
        lock.unlock()
    }

    func signal() {
        lock.lock()
        guard !signalled else {
            lock.unlock()
            return
        }
        signalled = true
        let waiting = continuation
        continuation = nil
        lock.unlock()
        waiting?.resume()
    }
}

enum SabrNativeRendererReadiness {
    private static let feedQueue = DispatchQueue(
        label: "org.typetype.tv.sabr.direct-media-ready",
        qos: .userInitiated
    )

    /// Only call while one per-track feeding task owns the renderer. After
    /// cancellation the continuation is always released; a stale callback
    /// cannot resume the task twice.
    static func waitUntilReady(_ renderer: AVQueuedSampleBufferRendering) async throws {
        try Task.checkCancellation()
        guard !renderer.isReadyForMoreMediaData else { return }
        let gate = SabrReadinessContinuation()
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                gate.install(continuation)
                if renderer.isReadyForMoreMediaData {
                    gate.signal()
                    return
                }
                renderer.requestMediaDataWhenReady(on: feedQueue) {
                    gate.signal()
                }
                if Task.isCancelled { gate.signal() }
            }
        } onCancel: {
            gate.signal()
        }
        // A renderer must not keep an old readiness callback subscribed
        // after a seek, reset, or cancelled playback generation.
        renderer.stopRequestingMediaData()
        try Task.checkCancellation()
    }
}
