import Foundation

/// Policy for compressed media held locally, independent from decoded frame
/// backpressure. The server is allowed to deliver fewer segments than requested.
enum SabrLookaheadPolicy {
    static let maxQueuedWindows = 12

    static func targetMilliseconds(_ settings: SabrBufferSettings,
                                   videoBitrate: Int?) -> Int64 {
        let goal = Int64(settings.forwardMilliseconds)
        // Cache is shared between audio and video. Keep a sizeable safety
        // margin for bitrate spikes, cached back-buffer and MP4 overhead.
        guard let videoBitrate, videoBitrate > 0 else {
            return min(goal, 60_000) // unknown bitrate: conservative first pass
        }
        let rate = Int64(videoBitrate) + 256_000 // audio + transport margin
        let capacityBits = Int64(settings.cacheMiB) * 1_048_576 * 8
        let safeMilliseconds = (capacityBits / rate) * 1_000 * 65 / 100
        return min(goal, max(10_000, safeMilliseconds))
    }

    static func shouldRequestMore(cachedThroughMs: Int64, playheadMs: Int64,
                                  targetMs: Int64) -> Bool {
        max(0, cachedThroughMs - max(0, playheadMs)) < max(1_000, targetMs)
    }
}

/// Rebuild advertised SABR ranges only from fragments *currently on disk*.
/// A historic high-water mark is not proof that an evicted fragment is buffered.
enum SabrCachedRangePlanner {
    static func ranges(from fragments: [SabrMediaReference], retainFromMs: Int64) -> [SabrBufferedRange] {
        let earliest = max(0, retainFromMs)
        let ordered = fragments.compactMap { item -> SabrBufferedRange? in
            guard item.startMs >= 0, item.durationMs > 0,
                  item.startMs <= Int64.max - item.durationMs else { return nil }
            let end = item.startMs + item.durationMs
            let start = max(earliest, item.startMs)
            guard end > start else { return nil }
            return SabrBufferedRange(itag: item.itag, startMs: start, endMs: end)
        }.sorted {
            if $0.itag != $1.itag { return $0.itag < $1.itag }
            if $0.startMs != $1.startMs { return $0.startMs < $1.startMs }
            return $0.endMs < $1.endMs
        }
        var merged: [SabrBufferedRange] = []
        for item in ordered {
            if let last = merged.last, last.itag == item.itag,
               item.startMs <= last.endMs {
                merged[merged.count - 1] = SabrBufferedRange(
                    itag: item.itag, startMs: last.startMs,
                    endMs: max(last.endMs, item.endMs)
                )
            } else {
                merged.append(item)
            }
        }
        return merged
    }

    static func cachedThrough(_ ranges: [SabrBufferedRange],
                              audioItag: Int, videoItag: Int,
                              positionMs: Int64) -> Int64 {
        let position = max(0, positionMs)
        func end(_ itag: Int) -> Int64 {
            ranges.first(where: {
                $0.itag == itag && $0.startMs <= position && $0.endMs > position
            })?.endMs ?? position
        }
        return min(end(audioItag), end(videoItag))
    }
}

/// Bounded, ordered handoff between the SABR network/cache producer and the
/// A/V decoder consumer. No completed window may silently disappear.
/// Poll waits are cancellation-aware and do not block the UI thread.
actor SabrWindowMailbox {
    private var windows: [SabrWindow] = []
    private var closed = false
    private var terminalError: Error?
    let capacity: Int

    init(capacity: Int = SabrLookaheadPolicy.maxQueuedWindows) {
        self.capacity = max(1, capacity)
    }

    var queuedCount: Int { windows.count }

    func offer(_ window: SabrWindow) async throws {
        while windows.count >= capacity && !closed {
            try Task.checkCancellation()
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        try Task.checkCancellation()
        guard !closed else { throw CancellationError() }
        windows.append(window)
    }

    func next() async throws -> SabrWindow? {
        while windows.isEmpty {
            try Task.checkCancellation()
            if let terminalError { throw terminalError }
            if closed { return nil }
            try await Task.sleep(nanoseconds: 60_000_000)
        }
        return windows.removeFirst()
    }

    func finish(error: Error? = nil) {
        terminalError = error
        closed = true
    }
}
