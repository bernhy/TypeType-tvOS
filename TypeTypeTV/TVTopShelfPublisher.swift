import Foundation
import UIKit
import TVServices

/// Publishes only when Home's existing Continue Watching data changes.
/// No additional /history calls and no per-card or focus-driven work.
@MainActor
final class TVTopShelfPublisher {
    static let shared = TVTopShelfPublisher()
    private var lastSignature: String?
    private var generation = 0
    private var active: Task<Void, Never>?

    private init() {}

    // The access JWT rotates. Never use it as a durable snapshot identity:
    // Top Shelf links must still resolve after an ordinary token refresh.
    // Profile switches explicitly clear the entire snapshot and image cache.
    static func accountFingerprint(for api: TypeTypeAPI) -> String {
        let credentials = TypeTypeCredentials.shared
        let label = credentials.displayIdentifier(for: api.origin)
        let identity = label ?? (credentials.token(for: api.origin) == nil
                                ? "guest" : "signed-in")
        return TVTopShelfSnapshotStore.fingerprint(
            api.origin.absoluteString + "|profile:" + identity
        )
    }

    func publish(_ videos: [VideoItem], api: TypeTypeAPI) {
        guard api.origin.host != "preview.invalid",
              let container = TVTopShelfSnapshotStore.container() else { return }
        let chosen = Array(videos.prefix(TVTopShelfSnapshotStore.maximumItems))
        let thresholdPercent = TVContentPreferences.shared.watchedThresholdPercent
        let scope = Self.accountFingerprint(for: api)
        let signature = scope + "|" + chosen.map {
            "\($0.url)|\($0.title)|\($0.duration ?? 0)|\($0.thumbnailUrl ?? "")|" +
            "\(TVLocalProgress.shared.position(for: $0.url) ?? $0.watchPositionMs ?? 0)"
        }.joined(separator: "\n")
        guard signature != lastSignature else { return }
        lastSignature = signature
        generation &+= 1
        let expected = generation
        active?.cancel()

        active = Task { [weak self] in
            guard let self else { return }
            var snapshotItems: [TVTopShelfSnapshotStore.Item] = []
            for video in chosen {
                guard !Task.isCancelled, self.generation == expected else { return }
                let duration = video.duration ?? 0
                let positionMs = TVLocalProgress.shared.position(for: video.url) ??
                    video.watchPositionMs ?? 0
                guard TVContinueWatchingPolicy.isEligible(
                    video, positionMs: positionMs, thresholdPercent: thresholdPercent
                ), duration > 0 else { continue }
                let thumbnail = api.relativeMediaURL(video.thumbnailUrl)
                let imageName = await self.prepareImage(
                    primary: thumbnail, videoURL: video.url,
                    origin: api.origin, container: container
                )
                guard !Task.isCancelled, self.generation == expected else { return }
                snapshotItems.append(.init(
                    key: TVTopShelfSnapshotStore.key(for: video.url),
                    videoID: video.id, title: video.title,
                    videoURL: video.url, thumbnailURL: thumbnail?.absoluteString,
                    imageName: imageName, duration: duration, positionMs: positionMs
                ))
            }
            guard !Task.isCancelled, self.generation == expected else { return }
            let snapshot = TVTopShelfSnapshotStore.make(
                origin: api.origin.absoluteString, scopeFingerprint: scope,
                items: snapshotItems
            )
            if TVTopShelfSnapshotStore.write(snapshot, to: container) {
                self.pruneImages(in: container, keeping: snapshotItems)
                TVTopShelfContentProvider.topShelfContentDidChange()
            }
        }
    }

    func clear() {
        generation &+= 1
        active?.cancel()
        active = nil
        lastSignature = nil
        guard let container = TVTopShelfSnapshotStore.container() else { return }
        try? FileManager.default.removeItem(
            at: container.appendingPathComponent("resume.json")
        )
        try? FileManager.default.removeItem(
            at: container.appendingPathComponent("images", isDirectory: true)
        )
        // Never display another household profile's activity after switching.
        TVTopShelfContentProvider.topShelfContentDidChange()
    }

    // Prevent months of history changes from accumulating unlimited JPEGs.
    // Keep the five visible images and at most 24 recently cached files.
    private func pruneImages(
        in container: URL, keeping items: [TVTopShelfSnapshotStore.Item]
    ) {
        let directory = container.appendingPathComponent("images", isDirectory: true)
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.contentModificationDateKey]
        ) else { return }
        let jpegFiles = urls.filter { $0.pathExtension.lowercased() == "jpg" }
        guard jpegFiles.count > 24 else { return }
        let protected = Set(items.compactMap(\.imageName))
        let obsolete = jpegFiles.filter { !protected.contains($0.lastPathComponent) }
            .sorted {
                let a = (try? $0.resourceValues(forKeys: [.contentModificationDateKey])
                    .contentModificationDate) ?? .distantPast
                let b = (try? $1.resourceValues(forKeys: [.contentModificationDateKey])
                    .contentModificationDate) ?? .distantPast
                return a < b
            }
        for url in obsolete.prefix(jpegFiles.count - 24) {
            try? FileManager.default.removeItem(at: url)
        }
    }

    private func prepareImage(primary: URL?, videoURL: String, origin: URL,
                              container: URL) async -> String? {
        let images = container.appendingPathComponent("images", isDirectory: true)
        try? FileManager.default.createDirectory(
            at: images, withIntermediateDirectories: true
        )
        let candidates = TVThumbnailSources.urls(
            primary: primary, videoURL: videoURL, quality: .hero
        )
        for candidate in candidates {
            guard !Task.isCancelled else { return nil }
            let firstParty = candidate.scheme == origin.scheme &&
                candidate.host?.lowercased() == origin.host?.lowercased() &&
                candidate.port == origin.port
            guard candidate.scheme == "https" ||
                (firstParty && candidate.scheme == "http") else { continue }
            let name = TVTopShelfSnapshotStore.fingerprint(candidate.absoluteString) + ".jpg"
            let path = images.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: path.path) { return name }
            var request = URLRequest(url: candidate)
            request.timeoutInterval = 12
            request.setValue("image/jpeg,image/png,image/webp,image/avif,*/*",
                             forHTTPHeaderField: "Accept")
            if firstParty, let token = TypeTypeCredentials.shared.token(for: origin) {
                request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
            }
            do {
                let session = firstParty ? TVNetwork.session(for: origin) : URLSession.shared
                let (data, response) = try await session.data(for: request)
                guard let response = response as? HTTPURLResponse,
                      response.statusCode == 200, data.count < 8_000_000,
                      !Task.isCancelled else { continue }
                let jpeg = await Task.detached(priority: .utility) {
                    TVThumbnailDecoder.decode(data, maximumDimension: 1280)?
                        .jpegData(compressionQuality: 0.84)
                }.value
                if let jpeg {
                    try jpeg.write(to: path, options: .atomic)
                    return name
                }
            } catch {
                continue // Static artwork remains until the app can retrieve it.
            }
        }
        return nil
    }
}
