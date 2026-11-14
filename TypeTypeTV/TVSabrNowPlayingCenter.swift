import Foundation
import MediaPlayer

/// Media commands from AirPods and Control Center do not arrive as the
/// UIPress events handled by SiriRemotePlayerInput. AVPlayerViewController
/// handles these automatically for HLS; custom SABR must register its own
/// media transport and publish Now Playing metadata.
enum TVMediaTransportCommand {
    case play, pause, toggle

    func wantsPause(currentlyPaused: Bool) -> Bool {
        switch self {
        case .play: return false
        case .pause: return true
        case .toggle: return !currentlyPaused
        }
    }
}

enum TVMediaTransportSource: Equatable {
    case siriRemote, system
}

/// tvOS can deliver one physical Siri Remote Play/Pause press through both
/// UIKit and MediaPlayer. Ignore only near-simultaneous *cross-source*
/// duplicates, never consecutive independent AirPods commands.
struct TVMediaCommandDeduplicator {
    private var previous: (source: TVMediaTransportSource, at: TimeInterval)?

    mutating func shouldHandle(source: TVMediaTransportSource, at uptime: TimeInterval) -> Bool {
        if let previous, source != previous.source,
           uptime >= previous.at && uptime - previous.at < 0.22 {
            return false
        }
        previous = (source, uptime)
        return true
    }
}

@MainActor
final class TVSabrNowPlayingCenter {
    static let shared = TVSabrNowPlayingCenter()

    private weak var engine: SabrPlayerController?
    private var activeID: ObjectIdentifier?
    private var video: VideoItem?
    private var commandTargets: [(MPRemoteCommand, Any)] = []
    private var deduplicator = TVMediaCommandDeduplicator()

    private init() {}

    func activate(for player: SabrPlayerController, video: VideoItem) {
        if activeID == ObjectIdentifier(player) {
            refresh(for: player)
            return
        }
        deactivateCurrent()
        engine = player
        activeID = ObjectIdentifier(player)
        self.video = video
        deduplicator = TVMediaCommandDeduplicator()

        let center = MPRemoteCommandCenter.shared()
        for (remoteCommand, intent) in [
            (center.playCommand, TVMediaTransportCommand.play),
            (center.pauseCommand, TVMediaTransportCommand.pause),
            (center.togglePlayPauseCommand, TVMediaTransportCommand.toggle)
        ] {
            remoteCommand.isEnabled = true
            let token = remoteCommand.addTarget { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.receive(intent, source: .system)
                }
                return .success
            }
            commandTargets.append((remoteCommand, token))
        }
        refresh(for: player)
    }

    func localToggle(for player: SabrPlayerController) {
        guard activeID == ObjectIdentifier(player) else {
            player.togglePause()
            return
        }
        receive(.toggle, source: .siriRemote)
    }

    private func receive(_ command: TVMediaTransportCommand, source: TVMediaTransportSource) {
        guard let engine, activeID == ObjectIdentifier(engine),
              deduplicator.shouldHandle(
                  source: source, at: ProcessInfo.processInfo.systemUptime
              ) else { return }
        let shouldPause = command.wantsPause(currentlyPaused: engine.userRequestedPause)
        if engine.setPaused(shouldPause) {
            NSLog("TypeType MEDIA remote=%@ intent=%@ paused=%d",
                  source == .system ? "system" : "siri",
                  shouldPause ? "pause" : "play", shouldPause ? 1 : 0)
            refresh(for: engine)
        }
    }

    func refresh(for player: SabrPlayerController) {
        guard activeID == ObjectIdentifier(player), let video else { return }

        var info: [String: Any] = [
            MPMediaItemPropertyTitle: video.title,
            MPMediaItemPropertyArtist: video.uploaderName ?? "TypeType",
            MPNowPlayingInfoPropertyPlaybackRate: player.isPlaying ? 1.0 : 0.0,
            MPNowPlayingInfoPropertyDefaultPlaybackRate: 1.0
        ]
        let position = player.playbackSeconds()
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] =
            position.isFinite && position >= 0 ? position : 0
        let seconds = player.durationMs > 0
            ? Double(player.durationMs) / 1_000
            : Double(video.duration ?? 0)
        if seconds > 0 {
            info[MPMediaItemPropertyPlaybackDuration] = seconds
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    func deactivate(for player: SabrPlayerController) {
        guard activeID == ObjectIdentifier(player) else { return }
        deactivateCurrent()
    }

    private func deactivateCurrent() {
        for (remoteCommand, token) in commandTargets {
            remoteCommand.removeTarget(token)
        }
        commandTargets.removeAll()
        if activeID != nil {
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        }
        engine = nil
        activeID = nil
        video = nil
        deduplicator = TVMediaCommandDeduplicator()
        // Do not disable commands on the shared center: AVPlayerViewController
        // must remain free to handle them when a native HLS video begins.
    }
}
