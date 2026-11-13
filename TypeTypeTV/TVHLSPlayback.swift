import SwiftUI
import AVKit
import Combine

/// Uses the same authenticated TypeType progress/history endpoints as SABR.
/// AVPlayerViewController continues to provide native tvOS playback controls
/// and automatic streaming-quality adaptation for HLS.
struct TVHLSPlaybackView: View {
    let api: TypeTypeAPI
    let video: VideoItem
    let url: URL
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var playback = TVHLSPlaybackController()

    var body: some View {
        ZStack {
            SystemVideoPlayer(player: playback.player)
            if let error = playback.errorMessage {
                VStack(spacing: 18) {
                    Text("player.unavailable").font(.title.bold())
                    Text(error).font(.callout)
                    Button("common.retry") {
                        Task { await playback.restartAfterFailure(userInitiated: true) }
                    }
                    .buttonStyle(.borderedProminent)
                }
                .padding(40)
                .background(.ultraThickMaterial, in: RoundedRectangle(cornerRadius: 16))
            }
        }
        .task(id: url.absoluteString) {
            await playback.prepare(api: api, video: video, url: url)
        }
        .onChange(of: scenePhase) { _, next in
            if next != .active { playback.checkpoint(force: true) }
        }
        .onDisappear { playback.stop() }
    }
}

@MainActor
final class TVHLSPlaybackController: ObservableObject {
    let player = AVPlayer()
    @Published private(set) var errorMessage: String?

    private var api: TypeTypeAPI?
    private var video: VideoItem?
    private var streamURL: URL?
    private let progressWriter = TVPlaybackProgressWriter()
    private let presenceOwner = UUID()
    private var presenceAnnounced = false
    private var periodicObserver: Any?
    private var timeControlObservation: NSKeyValueObservation?
    private var itemFailureObservation: NSObjectProtocol?
    private var itemStallObservation: NSObjectProtocol?
    private var itemStatusObservation: NSKeyValueObservation?
    private var stallTask: Task<Void, Never>?
    private var historyEnabled = false
    private var historyRecorded = false
    private var lastPositionMs: Int64 = 0
    private var retryCount = 0
    private var isStopped = false
    private var initialSeekFinished = false

    func prepare(api: TypeTypeAPI, video: VideoItem, url: URL) async {
        tearDown(save: true)
        self.api = api
        self.video = video
        self.streamURL = url
        isStopped = false
        historyRecorded = false
        retryCount = 0
        errorMessage = nil

        // If account preferences cannot be read, fail closed: never create
        // history entries while the server's privacy choice is unknown.
        let settings = try? await api.accountSettings()
        let allowed = settings != nil &&
            settings?.disableWatchHistory != true && video.isLive != true
        historyEnabled = allowed
        await progressWriter.enable(allowed)
        let saved = allowed ? (try? await api.savedPosition(videoURL: video.url)) : nil
        guard !Task.isCancelled, !isStopped else { return }
        let seconds = TVHLSResumePolicy.startSeconds(
            savedPositionMs: saved, durationSeconds: video.duration,
            isLive: video.isLive == true
        )
        startItem(url: url, positionSeconds: seconds)
    }

    private func startItem(url: URL, positionSeconds: Double) {
        let item = AVPlayerItem(url: url)
        player.replaceCurrentItem(with: item)
        lastPositionMs = max(0, Int64(positionSeconds * 1_000))
        initialSeekFinished = positionSeconds == 0

        periodicObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 15, preferredTimescale: 600),
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.checkpoint()
            }
        }
        timeControlObservation = player.observe(
            \.timeControlStatus, options: [.new]
        ) { [weak self] player, _ in
            let status = player.timeControlStatus
            Task { @MainActor [weak self] in
                guard let self, !self.isStopped else { return }
                if status == .playing {
                    self.announcePresenceIfNeeded()
                    if !self.historyRecorded {
                        self.checkpoint(started: true, force: true)
                        self.historyRecorded = true
                    }
                } else if status == .paused {
                    self.checkpoint(force: true)
                }
            }
        }
        itemStatusObservation = item.observe(\.status, options: [.new]) {
            [weak self] item, _ in
            if item.status == .failed {
                let message = item.error?.localizedDescription ??
                    TVL10n.value("player.unavailable")
                Task { @MainActor [weak self] in
                    guard let self, !self.isStopped else { return }
                    self.errorMessage = message
                    self.scheduleStallRecovery(delay: 3)
                }
            }
        }
        itemStallObservation = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemPlaybackStalled,
            object: item, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.scheduleStallRecovery(delay: 12)
            }
        }
        itemFailureObservation = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemFailedToPlayToEndTime,
            object: item, queue: .main
        ) { [weak self] notification in
            let detail = notification.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey]
                as? Error
            Task { @MainActor [weak self] in
                guard let self, !self.isStopped,
                      self.player.currentItem === item else { return }
                self.errorMessage = detail?.localizedDescription ??
                    TVL10n.value("player.unavailable")
                self.scheduleStallRecovery(delay: 3)
            }
        }

        if positionSeconds > 0 {
            let target = CMTime(seconds: positionSeconds, preferredTimescale: 600)
            player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero) {
                [weak self] finished in
                guard finished else { return }
                Task { @MainActor [weak self] in
                    guard let self, !self.isStopped else { return }
                    self.initialSeekFinished = true
                    self.player.play()
                }
            }
        } else {
            player.play()
        }
    }

    private func announcePresenceIfNeeded() {
        guard !presenceAnnounced, !isStopped, initialSeekFinished,
              let api, let video, let duration = video.duration,
              duration > 0 else { return }
        let seconds = player.currentTime().seconds
        let position = seconds.isFinite && seconds >= 0
            ? Int64(min(seconds * 1_000, Double(Int64.max) / 2)) : lastPositionMs
        TVPlaybackPresenceReporter.shared.start(
            owner: presenceOwner, api: api, video: video,
            positionMs: position, paused: false
        )
        presenceAnnounced = true
    }

    func checkpoint(started: Bool = false, force: Bool = false) {
        guard !isStopped, initialSeekFinished,
              let api, let video, video.isLive != true else { return }
        let seconds = player.currentTime().seconds
        guard seconds.isFinite, seconds >= 0,
              seconds < Double(Int64.max) / 1_000 else { return }
        let position = Int64(seconds * 1_000)
        lastPositionMs = position
        TVPlaybackPresenceReporter.shared.progress(
            owner: presenceOwner, video: video, positionMs: position,
            paused: player.timeControlStatus != .playing
        )
        guard historyEnabled else { return }
        TVLocalProgress.shared.record(video.url, positionMs: position)
        Task {
            await progressWriter.checkpoint(
                api: api, video: video, positionMs: position,
                started: started, force: force
            )
        }
    }

    func stop() { tearDown(save: true) }

    private func scheduleStallRecovery(delay: UInt64) {
        guard !isStopped, retryCount < 3 else { return }
        stallTask?.cancel()
        let originalPosition = player.currentTime().seconds
        stallTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: delay * 1_000_000_000)
            guard !Task.isCancelled, let self, !self.isStopped else { return }
            let currentPosition = self.player.currentTime().seconds
            let moved = originalPosition.isFinite && currentPosition.isFinite &&
                currentPosition - originalPosition >= 0.5
            // AVPlayer may recover without our help; only replace a stream
            // that remains stalled, not one that is already playing again.
            guard TVHLSStallPolicy.shouldRecover(
                progressed: moved,
                status: self.player.timeControlStatus,
                hasFailure: self.errorMessage != nil
            ) else { return }
            await self.restartAfterFailure()
        }
    }

    private func tearDown(save: Bool) {
        if save {
            checkpoint(force: true)
            TVPlaybackPresenceReporter.shared.stop(owner: presenceOwner)
            presenceAnnounced = false
        }
        isStopped = true
        stallTask?.cancel()
        stallTask = nil
        itemStatusObservation?.invalidate()
        itemStatusObservation = nil
        if let itemStallObservation {
            NotificationCenter.default.removeObserver(itemStallObservation)
            self.itemStallObservation = nil
        }
        timeControlObservation?.invalidate()
        timeControlObservation = nil
        if let periodicObserver {
            player.removeTimeObserver(periodicObserver)
            self.periodicObserver = nil
        }
        if let itemFailureObservation {
            NotificationCenter.default.removeObserver(itemFailureObservation)
            self.itemFailureObservation = nil
        }
        player.pause()
        player.replaceCurrentItem(with: nil)
    }

    func restartAfterFailure(userInitiated: Bool = false) async {
        if userInitiated { retryCount = 0 }
        guard !isStopped, retryCount < 3,
              let api, let video else { return }
        retryCount += 1
        checkpoint(force: true)
        do {
            // Re-resolve the TypeType URL: the upstream HLS manifest may have
            // expired while the player was open.
            let stream = try await api.stream(for: video)
            guard let nextURL = api.relativeMediaURL(stream.hlsUrl) else {
                throw TypeTypeError.unavailableFormat
            }
            let seconds = max(0, Double(lastPositionMs) / 1_000)
            tearDown(save: false)
            isStopped = false
            streamURL = nextURL
            errorMessage = nil
            startItem(url: nextURL, positionSeconds: seconds)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

/// A player may pause intentionally after reporting a stalled item.
    /// Never restart a paused, otherwise healthy stream simply because the
    /// earlier stall timer fired late. Conversely, an apparently "playing"
    /// AVPlayer whose timeline has not advanced must be recoverable.
enum TVHLSStallPolicy {
    static func shouldRecover(progressed: Bool,
                              status: AVPlayer.TimeControlStatus,
                              hasFailure: Bool) -> Bool {
        if progressed { return false }
        if status == .paused && !hasFailure { return false }
        return true
    }
}

enum TVHLSResumePolicy {
    static func startSeconds(savedPositionMs: Int64?, durationSeconds: Int?,
                             isLive: Bool) -> Double {
        guard !isLive, let saved = savedPositionMs, saved > 0 else { return 0 }
        let seconds = Double(saved) / 1_000
        if let durationSeconds, durationSeconds > 0 {
            let nearEnd = max(0, Double(durationSeconds) - 3)
            if seconds >= nearEnd { return 0 }
        }
        return seconds
    }
}
