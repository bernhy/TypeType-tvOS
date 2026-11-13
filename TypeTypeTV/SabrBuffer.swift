import Foundation

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

struct SabrMediaReference: Sendable {
    let url: String
    let itag: Int
    let startMs: Int64
    let durationMs: Int64
}

/// Bounded, session-local disk cache for *compressed* media only.
/// VideoToolbox render buffers are not used as long-term storage.
/// Keys are kept in memory; disk filenames contain UUIDs, not bearer tokens or session IDs.
actor SabrFragmentCache {
    private struct Entry {
        let file: URL
        let count: Int
        var access: UInt64
    }

    let capacityBytes: Int
    private let directory: URL
    private var entries: [String: Entry] = [:]
    private var pending: [String: Task<Data, Error>] = [:]
    private var used = 0
    private var clock: UInt64 = 0
    private var invalidated = false

    init(maxMiB: Int) {
        capacityBytes = max(64, min(1024, maxMiB)) * 1_048_576
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("typetype-sabr-cache-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    var bytesInUse: Int { used }
    var itemCount: Int { entries.count }

    func data(for key: String, load: @escaping @Sendable () async throws -> Data) async throws -> Data {
        guard !invalidated else { throw CancellationError() }
        clock &+= 1
        if var entry = entries[key] {
            if let bytes = try? Data(contentsOf: entry.file) {
                entry.access = clock
                entries[key] = entry
                return bytes
            }
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
                    entries[key] = Entry(file: file, count: value.count, access: clock)
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

    /// Prefetches at most two media segments in parallel; does not hammer the
    /// TypeType server or continuously poll for windows that it cannot yet provide.
    /// Returns the greatest media end-time downloaded in this particular window.
    func prefetch(
        _ references: [SabrMediaReference], service: SabrService,
        sessionId: String, generation: Int64
    ) async -> Int64 {
        let ordered = references.sorted { $0.startMs < $1.startMs }
        var loadedThrough: Int64 = 0
        for offset in stride(from: 0, to: ordered.count, by: 2) {
            if Task.isCancelled || invalidated { break }
            let subset = Array(ordered[offset..<min(offset + 2, ordered.count)])
            let ends = await withTaskGroup(of: Int64?.self) { group -> [Int64?] in
                for part in subset {
                    group.addTask {
                        do {
                            _ = try await self.data(for: part.url) {
                                try await service.fragmentData(
                                    part.url, sessionId: sessionId,
                                    itag: part.itag, generation: generation
                                )
                            }
                            return part.startMs + part.durationMs
                        } catch {
                            return nil
                        }
                    }
                }
                var collected: [Int64?] = []
                for await result in group { collected.append(result) }
                return collected
            }
            for end in ends { if let end { loadedThrough = max(loadedThrough, end) } }
        }
        return loadedThrough
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
