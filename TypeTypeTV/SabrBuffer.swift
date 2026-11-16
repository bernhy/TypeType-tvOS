import Foundation
import CryptoKit

/// Local buffering preferences. Each stream still obeys the existing TypeType
/// SABR window protocol and may be limited by server-side window ceilings.
struct SabrBufferSettings: Equatable {
    let forwardSeconds: Int
    let backSeconds: Int
    let cacheMiB: Int

    init(forwardSeconds: Int = 180, backSeconds: Int = 120, cacheMiB: Int = 512,
         live: Bool = false) {
        self.forwardSeconds = live ? 12 : min(600, max(30, forwardSeconds))
        self.backSeconds = live ? 15 : min(300, max(30, backSeconds))
        self.cacheMiB = min(1024, max(64, cacheMiB))
    }

    static func preferences(live: Bool = false, defaults: UserDefaults = .standard) -> SabrBufferSettings {
        let forward = defaults.integer(forKey: "typetype.bufferForwardSeconds")
        let back = defaults.integer(forKey: "typetype.bufferBackSeconds")
        let memory = defaults.integer(forKey: "typetype.bufferCacheMiB")
        return SabrBufferSettings(
            forwardSeconds: forward > 0 ? forward : 180,
            backSeconds: back > 0 ? back : 120,
            cacheMiB: memory > 0 ? memory : 512,
            live: live
        )
    }

    var forwardMilliseconds: Int { forwardSeconds * 1_000 }
    var backMilliseconds: Int { backSeconds * 1_000 }
}

/// Compare disk hits against the original HTTP payload, not just file size.
enum SabrCachedPayloadIntegrity {
    static func matches(_ data: Data, count: Int, sha256: SHA256.Digest) -> Bool {
        data.count == count && SHA256.hash(data: data) == sha256
    }
}

struct SabrMediaReference: Sendable {
    let url: String
    let itag: Int
    let startMs: Int64
    let durationMs: Int64
}

/// Bounded, session-local disk cache for *compressed* media only.
/// Compressed-media files are cached, not decoded video renderer frames.
/// Keys are kept in memory; disk filenames contain UUIDs, not bearer tokens or session IDs.
actor SabrFragmentCache {
    private struct Entry {
        let file: URL
        let count: Int
        let sha256: SHA256.Digest
        var access: UInt64
        var media: SabrMediaReference?
    }

    let capacityBytes: Int
    private let directory: URL
    private var entries: [String: Entry] = [:]
    private var pending: [String: Task<Data, Error>] = [:]
    private var used = 0
    private var clock: UInt64 = 0
    private var invalidated = false

    init(maxMiB: Int, cacheDirectory: URL? = nil) {
        capacityBytes = max(64, min(1024, maxMiB)) * 1_048_576
        // An injectable private directory makes on-disk corruption and
        // eviction behavior testable without exposing internal cache paths.
        directory = cacheDirectory ?? FileManager.default.temporaryDirectory
            .appendingPathComponent("typetype-sabr-cache-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    var bytesInUse: Int { used }
    var itemCount: Int { entries.count }

    // Only completed, retained downloads may be advertised as buffered to the
    // server. Both the reported headroom and server ranges reflect evictions.
    func cachedRanges(retainFromMs: Int64) -> [SabrBufferedRange] {
        SabrCachedRangePlanner.ranges(
            from: entries.values.compactMap { $0.media },
            retainFromMs: retainFromMs
        )
    }

    func cachedThroughMs(audioItag: Int, videoItag: Int,
                         positionMs: Int64) -> Int64 {
        // Keep strict byte-exact cachedRanges for server protocols; the
        // local lookahead may bridge bounded gaps only when the two cached
        // fragments carry consecutive SABR sequence numbers.
        SabrCachedRangePlanner.cachedThrough(
            SabrCachedRangePlanner.playableRanges(
                from: entries.values.compactMap { $0.media }, retainFromMs: 0),
            audioItag: audioItag, videoItag: videoItag,
            positionMs: positionMs
        )
    }

    func recordCachedMedia(_ item: SabrMediaReference) {
        guard var entry = entries[item.url] else { return }
        entry.media = item
        entries[item.url] = entry
    }

    func data(for key: String, load: @escaping @Sendable () async throws -> Data) async throws -> Data {
        guard !invalidated else { throw CancellationError() }
        clock &+= 1
        if var entry = entries[key] {
            // Never hand altered or truncated compressed media to the native fMP4 parser.
            // The server does not supply content hashes, so this only proves
            // that the on-disk bytes still equal the successful HTTP payload.
            let bytes = try? Data(contentsOf: entry.file)
            if let bytes, SabrCachedPayloadIntegrity.matches(
                bytes, count: entry.count, sha256: entry.sha256
            ) {
                entry.access = clock
                entries[key] = entry
                return bytes
            }
            if bytes != nil {
                // This log deliberately excludes the session-scoped media URL.
                NSLog("TypeType SABR CACHE integrity-failure expectedBytes=%d actualBytes=%d",
                      entry.count, bytes?.count ?? -1)
            }
            try? FileManager.default.removeItem(at: entry.file)
            entries[key] = nil
            used = max(0, used - entry.count)
        }
        if let task = pending[key] { return try await task.value }
        let task = Task { try await load() }
        pending[key] = task
        do {
            let value = try await task.value
            pending[key] = nil
            guard !invalidated else { throw CancellationError() }
            if value.count > 0 && value.count <= capacityBytes && entries[key] == nil {
                evictUntilAvailable(value.count)
                let file = directory.appendingPathComponent(UUID().uuidString)
                do {
                    try value.write(to: file, options: .atomic)
                    clock &+= 1
                    entries[key] = Entry(
                        file: file, count: value.count, sha256: SHA256.hash(data: value),
                        access: clock, media: nil
                    )
                    used += value.count
                } catch {
                    try? FileManager.default.removeItem(at: file)
                    // Disk caching is best-effort; playback still receives its fragment.
                }
            }
            return value
        } catch {
            pending[key] = nil
            throw error
        }
    }

    /// Bounded two-download media prefetch, *before* advancing the next
    /// server window. A failed or cancelled segment never counts as buffered.
    func preloadFully(
        _ references: [SabrMediaReference], service: SabrService,
        sessionId: String, generation: Int64,
        onBatch: (@MainActor ([SabrMediaReference]) async throws -> Void)? = nil
    ) async throws {
        // Preserve each track's real segment sequence even when the SABR
        // metadata reports non-monotonic startMs. Never skip ahead to N+1
        // simply because the server advertised an earlier timestamp.
        for batch in SabrPrefetchOrder.batches(references) {
            try Task.checkCancellation()
            try await withThrowingTaskGroup(of: Void.self) { group in
                for item in batch {
                    group.addTask {
                        _ = try await self.data(for: item.url) {
                            try await service.fragmentData(
                                item.url, sessionId: sessionId,
                                itag: item.itag, generation: generation
                            )
                        }
                        await self.recordCachedMedia(item)
                    }
                }
                try await group.waitForAll()
            }
            // Publish only finished downloads, never in-flight HTTP 202s.
            if let onBatch { try await onBatch(batch) }
        }
    }

    func clear() {
        invalidated = true
        for task in pending.values { task.cancel() }
        pending.removeAll()
        entries.removeAll()
        used = 0
        try? FileManager.default.removeItem(at: directory)
    }

    private func evictUntilAvailable(_ count: Int) {
        while used + count > capacityBytes {
            guard let oldest = entries.min(by: { $0.value.access < $1.value.access }) else { break }
            try? FileManager.default.removeItem(at: oldest.value.file)
            used = max(0, used - oldest.value.count)
            entries[oldest.key] = nil
        }
    }
}
