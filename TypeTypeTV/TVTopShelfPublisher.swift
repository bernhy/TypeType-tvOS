import Foundation
import UIKit
import TVServices

/// A single screen-level publisher; no focus observers, polling, or history requests.
/// The player supplies final checkpoints even if Home is no longer on screen.
@MainActor
final class TVTopShelfPublisher {
    static let shared = TVTopShelfPublisher()
    private static let candidateLimit = 24
    private var candidates: [VideoItem] = []
    private var candidateScope: String?
    private var candidateOrigin: String?
    // A real signed-in user must be confirmed by the existing /auth/me request.
    // A successfully completed request to Home history is not authentication:
    // the server can also allow guest access.
    private var verifiedOrigin: String?
    private var verifiedAccountID: String?
    private var historyValidatedOrigin: String?
    private var serverAvailable = false
    private var lastSignature: String?
    private var generation = 0
    private var active: Task<Void, Never>?

    private init() {}

    /// This is called from the existing sidebar /auth/me request. In particular,
    /// a guest token and a missing token are *not* a logged-in household user.
    func accountChecked(_ account: TVAccountIdentity?, api: TypeTypeAPI) {
        guard TVTopShelfVisibilityPolicy.permits(account), let account else {
            clear()
            diagnostics("showing static artwork: no signed-in account")
            return
        }
        let origin = api.origin.absoluteString
        if let oldID = verifiedAccountID,
           (oldID != account.id || verifiedOrigin != origin) {
            clear()
        }
        verifiedOrigin = origin
        verifiedAccountID = account.id
        // An authenticated /auth/me alone does not establish that the
        // history source succeeded. A failed Home request must keep the logo.
        serverAvailable = historyValidatedOrigin == origin
        if serverAvailable, let container = TVTopShelfSnapshotStore.container(),
           candidateOrigin == origin,
           candidateScope == Self.accountFingerprint(for: api) {
            schedule(api: api, scope: candidateScope!, container: container)
        }
    }

    /// React to existing Home history requests; never perform another probe.
    /// On errors hide stale personal posters, keeping JPEGs cached for recovery.
    func serverUnavailable(api: TypeTypeAPI, unauthorized: Bool = false) {
        let origin = api.origin.absoluteString
        guard verifiedOrigin == origin || candidateOrigin == origin else { return }
        serverAvailable = false
        historyValidatedOrigin = nil
        if unauthorized {
            verifiedOrigin = nil
            verifiedAccountID = nil
        }
        hideSnapshot(removeImages: false)
        diagnostics("showing static artwork: server unavailable or authorization failed")
    }

    func serverRecovered(api: TypeTypeAPI) {
        historyValidatedOrigin = api.origin.absoluteString
        guard verifiedOrigin == api.origin.absoluteString,
              verifiedAccountID != nil else { return }
        serverAvailable = true
        if candidateOrigin == api.origin.absoluteString,
           candidateScope == Self.accountFingerprint(for: api),
           let container = TVTopShelfSnapshotStore.container() {
            schedule(api: api, scope: candidateScope!, container: container)
        }
    }

    private func mayPublish(api: TypeTypeAPI) -> Bool {
        serverAvailable && verifiedOrigin == api.origin.absoluteString &&
            verifiedAccountID != nil
    }

    /// Use the stable account identity, not the rotating access JWT.
    /// A profile change explicitly clears the snapshot.
    static func accountFingerprint(for api: TypeTypeAPI) -> String {
        let credentials = TypeTypeCredentials.shared
        let label = credentials.displayIdentifier(for: api.origin)
        let identity = label ?? (credentials.token(for: api.origin) == nil
                                ? "guest" : "signed-in")
        return TVTopShelfSnapshotStore.fingerprint(
            api.origin.absoluteString + "|profile:" + identity
        )
    }

    /// Home provides already-loaded resume entries; retain some extra rows so
    /// completing one of the visible five can promote the next without /history.
    func publish(_ videos: [VideoItem], api: TypeTypeAPI) {
        guard api.origin.host != "preview.invalid",
              let container = TVTopShelfSnapshotStore.container() else {
            diagnostics("publish skipped: shared container unavailable")
            return
        }
        let scope = Self.accountFingerprint(for: api)
        adoptScope(scope, origin: api.origin.absoluteString)
        candidates = Array(videos.prefix(Self.candidateLimit))
        // The user explicitly hid this rail. Do not leave a previously
        // published personalized snapshot behind, even if no history request
        // runs for the hidden section.
        if TVContentPreferences.shared.settings?.hideContinueWatching == true {
            hideSnapshot(removeImages: false)
            return
        }
        guard mayPublish(api: api) else { return }
        schedule(api: api, scope: scope, container: container)
    }

    /// Called only for deliberate player checkpoints (pause/stop/background)
    /// and explicit watched toggles. No new timer, observer, or API request.
    func notePlayback(_ video: VideoItem, positionMs: Int64, api: TypeTypeAPI) {
        guard api.origin.host != "preview.invalid", positionMs >= 0,
              mayPublish(api: api),
              TVContentPreferences.shared.settings?.hideContinueWatching != true,
              let container = TVTopShelfSnapshotStore.container() else { return }
        let scope = Self.accountFingerprint(for: api)
        adoptScope(scope, origin: api.origin.absoluteString)
        candidates = Array(TVContinueWatchingLocalUpdate.applying(
            candidates, video: video, positionMs: positionMs,
            thresholdPercent: TVContentPreferences.shared.watchedThresholdPercent
        ).prefix(Self.candidateLimit))
        schedule(api: api, scope: scope, container: container)
    }

    private func adoptScope(_ scope: String, origin: String) {
        if candidateScope != nil &&
            (candidateScope != scope || candidateOrigin != origin) {
            clear()
        }
        candidateScope = scope
        candidateOrigin = origin
    }

    private func schedule(api: TypeTypeAPI, scope: String, container: URL) {
        let threshold = TVContentPreferences.shared.watchedThresholdPercent
        let chosen = Array(candidates.filter {
            TVContinueWatchingPolicy.isEligible(
                $0, positionMs: TVLocalProgress.shared.position(for: $0.url) ??
                    $0.watchPositionMs, thresholdPercent: threshold
            )
        }.prefix(TVTopShelfSnapshotStore.maximumItems))

        let signature = scope + "|" + api.origin.absoluteString + "|" + chosen.map {
            "\($0.url)|\($0.title)|\($0.id)|\($0.duration ?? 0)|" +
            "\($0.thumbnailUrl ?? "")|" +
            "\(TVLocalProgress.shared.position(for: $0.url) ?? $0.watchPositionMs ?? 0)"
        }.joined(separator: "\n")
        guard signature != lastSignature else { return }
        lastSignature = signature
        generation &+= 1
        let expected = generation
        active?.cancel()
        active = nil

        let previous = TVTopShelfSnapshotStore.read(from: container)
        let matching = previous?.origin == api.origin.absoluteString &&
            previous?.scopeFingerprint == scope ? previous : nil

        func savedImage(for video: VideoItem, thumbnail: URL?) -> String? {
            guard let item = matching?.items.first(where: {
                $0.key == TVTopShelfSnapshotStore.key(for: video.url)
            }), item.thumbnailURL == thumbnail?.absoluteString,
                  let name = item.imageName,
                  let url = TVTopShelfSnapshotStore.imageURL(named: name, in: container),
                  FileManager.default.fileExists(atPath: url.path) else { return nil }
            return name
        }

        // Progress-only snapshots never perform image work or launch a Task.
        // The synchronous atomic write also survives an immediate Home-button
        // background transition, without waiting for image downloads.
        let interimItems: [TVTopShelfSnapshotStore.Item] = chosen.map { video in
            let thumbnail = api.relativeMediaURL(video.thumbnailUrl)
            return makeItem(
                video, thumbnail: thumbnail,
                imageName: savedImage(for: video, thumbnail: thumbnail)
            )
        }
        let interim = TVTopShelfSnapshotStore.make(
            origin: api.origin.absoluteString, scopeFingerprint: scope,
            items: interimItems
        )
        // Commit the updated membership/progress before any image download.
        // tvOS can suspend the app immediately after the Home button; leaving
        // a completed video visible while its replacement poster loads is worse
        // than briefly showing a public HTTPS fallback or a smaller row.
        finish(interim, previous: previous, container: container,
               expected: expected)
        if chosen.isEmpty || interimItems.allSatisfy({ $0.imageName != nil }) {
            return
        }

        active = Task { [weak self] in
            guard let self else { return }
            var items: [TVTopShelfSnapshotStore.Item] = []
            for video in chosen {
                guard !Task.isCancelled, self.generation == expected else { return }
                let thumbnail = api.relativeMediaURL(video.thumbnailUrl)
                let imageName: String?
                if let cached = savedImage(for: video, thumbnail: thumbnail) {
                    imageName = cached
                } else {
                    imageName = await self.prepareImage(
                        primary: thumbnail, videoURL: video.url,
                        origin: api.origin, container: container
                    )
                }
                guard !Task.isCancelled, self.generation == expected else { return }
                items.append(self.makeItem(
                    video, thumbnail: thumbnail, imageName: imageName
                ))
            }
            guard !Task.isCancelled, self.generation == expected else { return }
            let snapshot = TVTopShelfSnapshotStore.make(
                origin: api.origin.absoluteString,
                scopeFingerprint: scope, items: items
            )
            self.finish(snapshot, previous: previous, container: container,
                        expected: expected)
            self.pruneImages(in: container, keeping: items)
        }
    }

    private func makeItem(_ video: VideoItem, thumbnail: URL?,
                          imageName: String?) -> TVTopShelfSnapshotStore.Item {
        TVTopShelfSnapshotStore.Item(
            key: TVTopShelfSnapshotStore.key(for: video.url),
            videoID: video.id, title: video.title,
            videoURL: video.url, thumbnailURL: thumbnail?.absoluteString,
            imageName: imageName, duration: video.duration ?? 0,
            positionMs: TVLocalProgress.shared.position(for: video.url) ??
                video.watchPositionMs ?? 0
        )
    }

    private func finish(_ snapshot: TVTopShelfSnapshotStore.Snapshot,
                        previous: TVTopShelfSnapshotStore.Snapshot?,
                        container: URL, expected: Int) {
        guard generation == expected else { return }
        guard snapshot != previous else { return }
        if TVTopShelfSnapshotStore.write(snapshot, to: container) {
            TVTopShelfContentProvider.topShelfContentDidChange()
            diagnostics("snapshot updated; item count=\(snapshot.items.count)")
        } else {
            // A transient file-system error must not permanently suppress retry.
            lastSignature = nil
            diagnostics("snapshot write failed")
        }
    }

    func clear() {
        candidates = []
        candidateScope = nil
        candidateOrigin = nil
        verifiedOrigin = nil
        verifiedAccountID = nil
        historyValidatedOrigin = nil
        serverAvailable = false
        hideSnapshot(removeImages: true)
    }

    private func hideSnapshot(removeImages: Bool) {
        generation &+= 1
        active?.cancel()
        active = nil
        lastSignature = nil
        guard let container = TVTopShelfSnapshotStore.container() else {
            diagnostics("clear skipped: shared container unavailable")
            return
        }
        let path = container.appendingPathComponent("resume.json")
        let existed = FileManager.default.fileExists(atPath: path.path)
        if existed {
            do {
                try FileManager.default.removeItem(at: path)
            } catch {
                diagnostics("snapshot removal failed")
            }
        }
        if removeImages {
            try? FileManager.default.removeItem(
                at: container.appendingPathComponent("images", isDirectory: true)
            )
        }
        // Only invalidate tvOS when content has actually changed.
        if existed { TVTopShelfContentProvider.topShelfContentDidChange() }
        diagnostics("snapshot cleared")
    }

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
        // Check every candidate's disk cache first. A failed primary CDN
        // must not cause repeated downloads when the fallback is already saved.
        let allowed: [(url: URL, name: String)] = candidates.compactMap { candidate in
            let firstParty = candidate.scheme == origin.scheme &&
                candidate.host?.lowercased() == origin.host?.lowercased() &&
                candidate.port == origin.port
            guard candidate.scheme == "https" ||
                (firstParty && candidate.scheme == "http") else { return nil }
            return (candidate,
                    TVTopShelfSnapshotStore.fingerprint(candidate.absoluteString) + ".jpg")
        }
        for item in allowed {
            let path = images.appendingPathComponent(item.name)
            if FileManager.default.fileExists(atPath: path.path) {
                return item.name
            }
        }
        for item in allowed {
            guard !Task.isCancelled else { return nil }
            let candidate = item.url
            let path = images.appendingPathComponent(item.name)
            let firstParty = candidate.scheme == origin.scheme &&
                candidate.host?.lowercased() == origin.host?.lowercased() &&
                candidate.port == origin.port
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
                guard !Task.isCancelled else { return nil }
                if let jpeg {
                    try jpeg.write(to: path, options: .atomic)
                    return item.name
                }
            } catch {
                // The extension may still use a public HTTPS thumbnail.
                continue
            }
        }
        diagnostics("thumbnail unavailable; using extension fallback")
        return nil
    }

    private func diagnostics(_ event: String) {
        #if DEBUG
        NSLog("TypeType TOPSHELF %@", event)
        #endif
    }
}

/// Unit-testable policy: a guest token is not a signed-in household account.
enum TVTopShelfVisibilityPolicy {
    static func permits(_ account: TVAccountIdentity?) -> Bool {
        guard let account else { return false }
        return !account.isGuest && !account.id.isEmpty
    }
}
