import Foundation

/// Policy for compressed media held locally, independent from decoded frame
/// backpressure. The server is allowed to deliver fewer segments than requested.
enum SabrLookaheadPolicy {
    static let maxQueuedWindows = 12

    static func targetMilliseconds(_ settings: SabrBufferSettings,
                                   videoBitrate: Int?) -> Int64 {
        let goal = Int64(settings.forwardMilliseconds)
        // The local disk cache may be 512 MiB, but the TypeType v1.17.1
        // *server* throttles its pump above 24 MiB of unconsumed media.
        // A 180s producer lookahead can therefore deadlock on a segment
        // still pending upstream (observed on video itag 137, seq 13).
        // Budget both audio and video within 65% of the smaller cache,
        // leaving space for server back-buffer, bursts and MP4 overhead.
        let serverBudgetBytes: Int64 = 24 * 1_048_576
        let localBudgetBytes = Int64(settings.cacheMiB) * 1_048_576
        let budgetBits = min(localBudgetBytes, serverBudgetBytes) * 8 * 65 / 100
        guard let videoBitrate, videoBitrate > 0 else {
            return min(goal, 12_000) // unknown bitrate: don't assume a low rate
        }
        let rate = Int64(videoBitrate) + 256_000
        let safeMilliseconds = budgetBits / rate * 1_000
        return min(goal, max(10_000, safeMilliseconds))
    }

    static func shouldRequestMore(cachedThroughMs: Int64, playheadMs: Int64,
                                  targetMs: Int64) -> Bool {
        max(0, cachedThroughMs - max(0, playheadMs)) < max(1_000, targetMs)
    }
}

/// Never jump the upstream SABR session past media that was not actually
/// downloaded for BOTH tracks. The playback clock may run ahead during a
/// renderer/network underrun; using it directly would skip the missing
/// segment and produce an unrecoverable timestamp gap.
enum SabrWindowRequestPosition {
    static func position(playheadMs: Int64, contiguousThroughMs: Int64) -> Int64 {
        min(max(0, playheadMs), max(0, contiguousThroughMs))
    }
}

/// Sequential VOD window discovery: the server's 'bufferedRanges' field is
/// NOT merely diagnostic. Its window builder treats a cached range covering
/// playerTimeMs as permission to advance directly to that range's end.
/// Supplying a multi-minute disk cache while the decoder has consumed only
/// the first window can therefore skip metadata windows and produce the
/// observable 20-25-second playback gap. Keep the discovery cursor at the
/// contiguous end of metadata windows we have actually delivered.
enum SabrSequentialWindowPolicy {
    static func requestPosition(first: Bool, startMs: Int64,
                                continuousEndMs: Int64) -> Int64 {
        first ? max(0, startMs) : max(0, continuousEndMs)
    }

    /// Let the server return the segment descriptors for the next window.
    /// The client still reuses the bytes in SabrFragmentCache by URL, without
    /// allowing its stored fragments to suppress important window metadata.
    static var advertisedRanges: [SabrBufferedRange] { [] }
}

/// Rebuild advertised SABR ranges only from fragments *currently on disk*.
/// A historic high-water mark is not proof that an evicted fragment is buffered.
enum SabrCachedRangePlanner {
    /// The local *lookahead* needs a playable frontier, not a byte-exact
    /// one. A stream may use adjacent SABR sequence numbers with a bounded
    /// PTS jump; use the same tolerance as the actual producer and decoder
    /// so cached-through cannot stall after successful playback admission.
    /// Without this, the lookahead is stuck at 24.391 forever and repeatedly
    /// fetches windows until the server hits its own 24 MiB throttle.
    ///
    /// Do not use these softened ranges in server bufferedRanges requests:
    /// those must still represent actually cached bytes. Do not bridge
    /// missing or unparseable sequence numbers.
    static func playableRanges(from fragments: [SabrMediaReference],
                               retainFromMs: Int64) -> [SabrBufferedRange] {
        struct Piece {
            var range: SabrBufferedRange
            var lastSequence: Int?
        }
        let earliest = max(0, retainFromMs)
        let prepared = fragments.compactMap { item -> (SabrBufferedRange, Int?)? in
            guard item.startMs >= 0, item.durationMs > 0,
                  item.startMs <= Int64.max - item.durationMs else { return nil }
            let end = item.startMs + item.durationMs
            let start = max(earliest, item.startMs)
            guard end > start else { return nil }
            let last = URL(string: item.url)?.lastPathComponent ?? ""
            let sequence = Int(last).flatMap { $0 > 0 ? $0 : nil }
            return (SabrBufferedRange(itag: item.itag, startMs: start, endMs: end),
                    sequence)
        }
        let sequencedTracks = Dictionary(grouping: prepared, by: { $0.0.itag })
            .mapValues { $0.allSatisfy { $0.1 != nil } }
        let ordered = prepared.sorted {
            if $0.0.itag != $1.0.itag { return $0.0.itag < $1.0.itag }
            if sequencedTracks[$0.0.itag] == true,
               let left = $0.1, let right = $1.1, left != right {
                return left < right
            }
            if $0.0.startMs != $1.0.startMs { return $0.0.startMs < $1.0.startMs }
            return $0.0.endMs < $1.0.endMs
        }
        var merged: [Piece] = []
        for (part, sequence) in ordered {
            if var previous = merged.last, previous.range.itag == part.itag {
                let touches = part.startMs <= previous.range.endMs
                let nextSequence = previous.lastSequence.flatMap { last in
                    last < Int.max && sequence == last + 1 ? true : nil
                } ?? false
                let allowedGap = nextSequence && part.startMs > previous.range.endMs &&
                    part.startMs - previous.range.endMs <=
                    SabrMediaGapPolicy.consecutiveSequenceToleranceMs
                if touches || allowedGap {
                    previous.range = SabrBufferedRange(
                        itag: part.itag,
                        startMs: min(previous.range.startMs, part.startMs),
                        endMs: max(previous.range.endMs, part.endMs))
                    previous.lastSequence = sequence
                    merged[merged.count - 1] = previous
                    continue
                }
            }
            merged.append(Piece(range: part, lastSequence: sequence))
        }
        return merged.map(\.range)
    }

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

    /// Optional heartbeat lets playback pause its shared A/V clock when the
    /// compressed-media queue is empty, while the server prepares the next
    /// SABR window. This prevents the audio clock running into a video gap.
    func next(onWait: (@Sendable () async -> Void)? = nil) async throws -> SabrWindow? {
        while windows.isEmpty {
            try Task.checkCancellation()
            if let terminalError { throw terminalError }
            if closed { return nil }
            if let onWait { await onWait() }
            try await Task.sleep(nanoseconds: 60_000_000)
        }
        return windows.removeFirst()
    }

    func finish(error: Error? = nil) {
        terminalError = error
        closed = true
    }
}
