import Foundation
import TVServices

/// Publishes a small, replaceable five-item snapshot to the shared App Group
/// preferences. No filesystem writes, polling, or new server API requests.
/// New public posters are checked asynchronously using bounded image GETs;
/// progress updates never recheck already-resolved images.
 /// All published state belongs to a verified, opted-in account.
@MainActor
final class TVTopShelfPublisher {
    static let shared = TVTopShelfPublisher()
    private static let candidateLimit = 24

    private var candidates: [VideoItem] = []
    private var candidateScope: String?
    private var candidateOrigin: String?
    private var verifiedOrigin: String?
    private var verifiedAccountID: String?
    private var historyValidatedOrigin: String?
    private var serverAvailable = false
    private var lastSignature: String?
    // In-memory only: a newly selected source is probed once per app process.
    // The account-specific snapshot itself stays small and token-free.
    private var resolvedPosters: [String: URL] = [:]
    private var posterCheckTask: Task<Void, Never>?
    private var posterCheckSignature: String?
    private var posterCheckGeneration = 0
    private let accountPreferences = TVTopShelfAccountPreferences()

    private init() {}

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
        serverAvailable = historyValidatedOrigin == origin
        guard mayPublish(api: api) else {
            hideSnapshot()
            return
        }
        if candidateOrigin == origin,
           let scope = candidateScope,
           scope == Self.accountFingerprint(for: api) {
            schedule(api: api, scope: scope)
        }
    }

    func serverUnavailable(api: TypeTypeAPI, unauthorized: Bool = false) {
        let origin = api.origin.absoluteString
        guard (verifiedOrigin == nil || verifiedOrigin == origin),
              (candidateOrigin == nil || candidateOrigin == origin) else { return }
        serverAvailable = false
        historyValidatedOrigin = nil
        if unauthorized {
            verifiedOrigin = nil
            verifiedAccountID = nil
        }
        hideSnapshot()
        diagnostics("showing static artwork: server unavailable or authorization failed")
    }

    func serverRecovered(api: TypeTypeAPI) {
        historyValidatedOrigin = api.origin.absoluteString
        guard verifiedOrigin == api.origin.absoluteString,
              verifiedAccountID != nil else { return }
        serverAvailable = true
        if mayPublish(api: api),
           candidateOrigin == api.origin.absoluteString,
           let scope = candidateScope,
           scope == Self.accountFingerprint(for: api) {
            schedule(api: api, scope: scope)
        }
    }

    func accountPermissionChanged(accountID: String, api: TypeTypeAPI) {
        guard verifiedOrigin == api.origin.absoluteString,
              verifiedAccountID == accountID else { return }
        guard mayPublish(api: api) else {
            hideSnapshot()
            diagnostics("static artwork: account opt-in disabled or unavailable")
            return
        }
        if candidateOrigin == api.origin.absoluteString,
           let scope = candidateScope,
           scope == Self.accountFingerprint(for: api) {
            schedule(api: api, scope: scope)
        }
    }

    private func mayPublish(api: TypeTypeAPI) -> Bool {
        guard serverAvailable, verifiedOrigin == api.origin.absoluteString,
              let id = verifiedAccountID else { return false }
        return accountPreferences.isAllowed(accountID: id, origin: api.origin)
    }

    /// Stable account identity, rather than the rotating access token.
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
        guard api.origin.host != "preview.invalid" else { return }
        let scope = Self.accountFingerprint(for: api)
        adoptScope(scope, origin: api.origin.absoluteString)
        candidates = Array(videos.prefix(Self.candidateLimit))
        if TVContentPreferences.shared.settings?.hideContinueWatching == true ||
           !mayPublish(api: api) {
            hideSnapshot()
            return
        }
        schedule(api: api, scope: scope)
    }

    /// Only existing pause/stop/background checkpoints and explicit watched
    /// changes can update Top Shelf; no new per-position observer or timer.
    func notePlayback(_ video: VideoItem, positionMs: Int64, api: TypeTypeAPI) {
        guard api.origin.host != "preview.invalid", positionMs >= 0,
              mayPublish(api: api),
              TVContentPreferences.shared.settings?.hideContinueWatching != true
        else { return }
        let scope = Self.accountFingerprint(for: api)
        adoptScope(scope, origin: api.origin.absoluteString)
        guard mayPublish(api: api) else { return }
        candidates = Array(TVContinueWatchingLocalUpdate.applying(
            candidates, video: video, positionMs: positionMs,
            thresholdPercent: TVContentPreferences.shared.watchedThresholdPercent
        ).prefix(Self.candidateLimit))
        schedule(api: api, scope: scope)
    }

    private func adoptScope(_ scope: String, origin: String) {
        if candidateScope != nil &&
            (candidateScope != scope || candidateOrigin != origin) {
            clear()
        }
        candidateScope = scope
        candidateOrigin = origin
    }

    private func schedule(api: TypeTypeAPI, scope: String) {
        let threshold = TVContentPreferences.shared.watchedThresholdPercent
        let chosen = Array(candidates.filter {
            TVContinueWatchingPolicy.isEligible(
                $0, positionMs: TVLocalProgress.shared.position(for: $0.url) ??
                    $0.watchPositionMs, thresholdPercent: threshold
            )
        }.prefix(TVTopShelfSnapshotStore.maximumItems))

        let checks: [TVTopShelfPosterPolicy.Check] = chosen.map { video in
            let primary = api.relativeMediaURL(video.thumbnailUrl)
            return TVTopShelfPosterPolicy.Check(
                identity: TVTopShelfPosterPolicy.identity(
                    for: video.url, primary: primary, origin: api.origin
                ),
                candidates: TVTopShelfPosterPolicy.candidates(
                    primary: primary, videoURL: video.url, origin: api.origin
                )
            )
        }
        let items: [TVTopShelfSnapshotStore.Item] = zip(chosen, checks).map { pair in
            let video = pair.0
            let check = pair.1
            let url = resolvedPosters[check.identity] ?? check.candidates.first
            return TVTopShelfSnapshotStore.Item(
                key: TVTopShelfSnapshotStore.key(for: video.url),
                videoID: video.id, title: video.title,
                channelName: video.uploaderName,
                videoURL: video.url,
                thumbnailURL: url?.absoluteString,
                duration: video.duration ?? 0,
                positionMs: TVLocalProgress.shared.position(for: video.url) ??
                    video.watchPositionMs ?? 0
            )
        }
        let snapshot = TVTopShelfSnapshotStore.make(
            origin: api.origin.absoluteString,
            scopeFingerprint: scope, items: items
        )
        let signature = scope + "|" + api.origin.absoluteString + "|" +
            items.map {
                "\($0.key)|\($0.title)|\($0.channelName ?? "")|" +
                "\($0.duration)|\($0.positionMs)|" +
                "\($0.thumbnailURL ?? "")"
            }.joined(separator: "\n")
        if signature != lastSignature {
            let previous = TVTopShelfSnapshotStore.read()
            if snapshot == previous {
                lastSignature = signature
            } else if TVTopShelfSnapshotStore.write(snapshot) {
                lastSignature = signature
                TVTopShelfContentProvider.topShelfContentDidChange()
                diagnostics("shared preferences updated; item count=\(items.count)")
            } else {
                // Do not retry across every progress checkpoint if the group
                // preferences are unavailable. Preserve the failure signal.
                lastSignature = nil
                diagnostics("shared preferences write failed")
                return
            }
        }
        startPosterChecks(checks, api: api, scope: scope)
    }

    /// Reuse public image choices while the app is alive. Changing only a
    /// playback position does not trigger new GETs. Every revision cancels
    /// outstanding checks before launching replacements.
    private func startPosterChecks(
        _ checks: [TVTopShelfPosterPolicy.Check], api: TypeTypeAPI, scope: String
    ) {
        let fingerprint = checks.map(\.identity).joined(separator: "|")
        guard posterCheckSignature != fingerprint else { return }
        posterCheckGeneration += 1
        let generation = posterCheckGeneration
        posterCheckSignature = fingerprint
        posterCheckTask?.cancel()
        posterCheckTask = nil

        let unresolved = checks.filter {
            resolvedPosters[$0.identity] == nil && !$0.candidates.isEmpty
        }
        guard !unresolved.isEmpty else { return }
        let origin = api.origin

        posterCheckTask = Task(priority: .utility) { [weak self] in
            var checked: [(String, URL)] = []
            await withTaskGroup(of: (String, URL?).self) { group in
                // Maximum five concurrent checks. Each video only tries its
                // next candidate when the previous one really failed.
                for check in unresolved {
                    group.addTask {
                        let url = await TVTopShelfPosterPolicy.firstReachable(
                            candidates: check.candidates, origin: origin
                        )
                        return (check.identity, url)
                    }
                }
                for await (identity, url) in group {
                    if Task.isCancelled {
                        group.cancelAll()
                        break
                    }
                    if let url { checked.append((identity, url)) }
                }
            }
            guard !Task.isCancelled, let self,
                  posterCheckGeneration == generation,
                  candidateOrigin == origin.absoluteString,
                  candidateScope == scope, mayPublish(api: api) else { return }
            posterCheckTask = nil

            var changed = false
            for (identity, url) in checked where resolvedPosters[identity] != url {
                resolvedPosters[identity] = url
                changed = true
            }
            if changed {
                // One publication after the entire batch, not five repeated
                // updates that would refresh the TV Home screen unnecessarily.
                schedule(api: api, scope: scope)
            }
        }
    }

    private func cancelPosterChecks() {
        posterCheckGeneration += 1
        posterCheckTask?.cancel()
        posterCheckTask = nil
        posterCheckSignature = nil
    }

    func clear() {
        candidates = []
        candidateScope = nil
        candidateOrigin = nil
        verifiedOrigin = nil
        verifiedAccountID = nil
        historyValidatedOrigin = nil
        serverAvailable = false
        hideSnapshot()
    }

    private func hideSnapshot() {
        cancelPosterChecks()
        resolvedPosters.removeAll()
        lastSignature = nil
        if TVTopShelfSnapshotStore.clear() {
            TVTopShelfContentProvider.topShelfContentDidChange()
            diagnostics("shared snapshot cleared")
        }
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

