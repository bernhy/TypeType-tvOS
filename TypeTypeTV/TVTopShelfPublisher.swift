import Foundation
import TVServices

/// Publishes a small, replaceable five-item snapshot to the shared App Group
/// preferences. No filesystem writes, artwork downloads, polling or new API
/// requests. All published state belongs to a verified, opted-in account.
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

        let items: [TVTopShelfSnapshotStore.Item] = chosen.map { video in
            TVTopShelfSnapshotStore.Item(
                key: TVTopShelfSnapshotStore.key(for: video.url),
                videoID: video.id, title: video.title,
                channelName: video.uploaderName,
                videoURL: video.url,
                thumbnailURL: TVTopShelfPosterPolicy.publicThumbnail(
                    primary: api.relativeMediaURL(video.thumbnailUrl), videoURL: video.url
                ),
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
        guard signature != lastSignature else { return }

        let previous = TVTopShelfSnapshotStore.read()
        if snapshot == previous {
            lastSignature = signature
            return
        }
        if TVTopShelfSnapshotStore.write(snapshot) {
            lastSignature = signature
            TVTopShelfContentProvider.topShelfContentDidChange()
            diagnostics("shared preferences updated; item count=\(items.count)")
        } else {
            // Do not suppress a later retry if shared preferences are unavailable.
            lastSignature = nil
            diagnostics("shared preferences write failed")
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
        hideSnapshot()
    }

    private func hideSnapshot() {
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


/// Avoid leaking authenticated TypeType media URLs into a token-free
/// extension or an OS-managed image fetch. Public YouTube images only.
enum TVTopShelfPosterPolicy {
    static func publicThumbnail(primary: URL?, videoURL: String) -> String? {
        let options = TVThumbnailSources.urls(
            primary: primary, videoURL: videoURL, quality: .standard
        )
        return options.first(where: { url in
            let host = url.host?.lowercased() ?? ""
            return url.scheme == "https" && url.user == nil &&
                url.password == nil &&
                (host == "i.ytimg.com" || host == "img.youtube.com" ||
                 host == "ytimg.com" || host.hasSuffix(".ytimg.com"))
        })?.absoluteString
    }
}
