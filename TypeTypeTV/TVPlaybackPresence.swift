import Foundation

/// TypeType 1.17.1 session-presence protocol. This is separate from saved
/// history (/progress) and from the SABR media resource DELETE endpoint.
/// A single owner per Apple TV prevents an old player's late "stop" from
/// removing the next video's now-playing state.
struct TVPlaybackPresenceIdentity: Encodable {
    let clientName: String
    let clientVersion: String
    let deviceId: String
    let deviceName: String
    let deviceType: String

    static var current: TVPlaybackPresenceIdentity {
        let key = "typetype.devicePresenceID"
        let saved = UserDefaults.standard.string(forKey: key)
        let id: String
        if let saved, !saved.isEmpty {
            id = saved
        } else {
            id = UUID().uuidString
            UserDefaults.standard.set(id, forKey: key)
        }
        return TVPlaybackPresenceIdentity(
            clientName: "TypeType tvOS",
            clientVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"]
                as? String ?? "development",
            deviceId: id,
            deviceName: "Apple TV",
            deviceType: "apple_tv"
        )
    }
}

struct TVPlaybackPresenceVideo: Encodable {
    let clientName: String
    let clientVersion: String
    let deviceId: String
    let deviceName: String
    let deviceType: String
    let videoUrl: String
    let title: String
    let thumbnail: String?
    let channelName: String?
    let positionMs: Int64
    let durationMs: Int64?
    let paused: Bool

    init(identity: TVPlaybackPresenceIdentity, video: VideoItem,
         positionMs: Int64, paused: Bool) {
        clientName = identity.clientName
        clientVersion = identity.clientVersion
        deviceId = identity.deviceId
        deviceName = identity.deviceName
        deviceType = identity.deviceType
        videoUrl = video.url
        title = video.title
        thumbnail = video.thumbnailUrl
        channelName = video.uploaderName
        self.positionMs = max(0, positionMs)
        durationMs = video.duration.map { Int64(max(0, $0)) * 1_000 }
        self.paused = paused
    }
}

/// Only on-demand videos are announced, matching the Android TV client.
/// Calls are ordered so stop can never overtake its start/progress requests.
@MainActor
final class TVPlaybackPresenceReporter {
    static let shared = TVPlaybackPresenceReporter()
    private var currentOwner: UUID?
    private var currentVideoURL: String?
    private var currentAPI: TypeTypeAPI?
    private var pending: Task<Void, Never>?
    private let identity: TVPlaybackPresenceIdentity

    init(identity: TVPlaybackPresenceIdentity = .current) {
        self.identity = identity
    }

    func start(owner: UUID, api: TypeTypeAPI, video: VideoItem,
               positionMs: Int64, paused: Bool) {
        guard let duration = video.duration, duration > 0 else { return }
        if currentOwner == owner && currentVideoURL == video.url {
            progress(owner: owner, video: video, positionMs: positionMs,
                     paused: paused)
            return
        }
        currentOwner = owner
        currentVideoURL = video.url
        currentAPI = api
        let payload = TVPlaybackPresenceVideo(
            identity: identity, video: video, positionMs: positionMs,
            paused: paused
        )
        enqueue { try await api.sessionPlaybackStart(payload) }
    }

    func progress(owner: UUID, video: VideoItem, positionMs: Int64,
                  paused: Bool) {
        guard currentOwner == owner,
              currentVideoURL == video.url, let api = currentAPI else { return }
        let payload = TVPlaybackPresenceVideo(
            identity: identity, video: video, positionMs: positionMs,
            paused: paused
        )
        enqueue { try await api.sessionPlaybackProgress(payload) }
    }

    func stop(owner: UUID) {
        guard currentOwner == owner, let api = currentAPI else { return }
        currentOwner = nil
        currentVideoURL = nil
        currentAPI = nil
        let payload = identity
        enqueue { try await api.sessionPlaybackStop(payload) }
    }

    func flush() async { await pending?.value }

    private func enqueue(_ work: @escaping () async throws -> Void) {
        let predecessor = pending
        pending = Task {
            await predecessor?.value
            // Presence is best-effort; media playback must never fail because
            // a presence endpoint is unsupported, unauthenticated, or offline.
            try? await work()
        }
    }
}
