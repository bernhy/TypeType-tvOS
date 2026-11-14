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
    var streamMetadata: StreamInfo? = nil
    var onPlaybackEvent: ((TVPlaybackEvent) -> Void)? = nil
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var playback = TVHLSPlaybackController()

    var body: some View {
        ZStack {
            SystemVideoPlayer(player: playback.player)
            if let label = playback.sponsorLabel {
                Text(label)
                    .font(.callout.bold())
                    .padding(12)
                    .background(.black.opacity(0.8),
                                in: RoundedRectangle(cornerRadius: 8))
                    .frame(maxWidth: .infinity, maxHeight: .infinity,
                           alignment: .bottomTrailing)
                    .padding(.trailing, 80)
                    .padding(.bottom, 100)
                    .allowsHitTesting(false)
            }
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
            await playback.prepare(api: api, video: video, url: url,
                                   streamMetadata: streamMetadata)
        }
        .onChange(of: playback.playbackFinished) { _, finished in
            if finished { onPlaybackEvent?(.finished) }
        }
        .onChange(of: playback.playbackUnavailable) { _, unavailable in
            if unavailable { onPlaybackEvent?(.unavailable) }
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
    @Published private(set) var playbackFinished = false
    @Published private(set) var playbackUnavailable = false
    @Published private(set) var sponsorLabel: String?

    private var api: TypeTypeAPI?
    private var video: VideoItem?
    private var streamURL: URL?
    private let progressWriter = TVPlaybackProgressWriter()
    private var lastProgressSubmission: Task<Void, Never>?
    private let presenceOwner = UUID()
    private var presenceAnnounced = false
    private var periodicObserver: Any?
    private var sponsorObserver: Any?
    private var timeControlObservation: NSKeyValueObservation?
    private var itemFailureObservation: NSObjectProtocol?
    private var itemEndObservation: NSObjectProtocol?
    private var itemStallObservation: NSObjectProtocol?
    private var itemStatusObservation: NSKeyValueObservation?
    private var stallTask: Task<Void, Never>?
    private var historyEnabled = false
    private var historyRecorded = false
    private var lastPositionMs: Int64 = 0
    private var retryCount = 0
    private var lastRecoveryAttempt: Date?
    private var recoveryInFlight = false
    // Incrementing on teardown invalidates network replies that arrive after
    // a user leaves or a different HLS player item has been installed.
    private var playbackGeneration: UInt64 = 0
    private var isStopped = false
    private var initialSeekFinished = false
    private var sponsorSegments: [TVSponsorBlockSegment] = []
    private var sponsorSettings: TVServerSettings?
    private var sponsorStreamCategory: String?
    private var lastSponsorSeek = Date.distantPast

    func prepare(api: TypeTypeAPI, video: VideoItem, url: URL,
                 streamMetadata: StreamInfo? = nil) async {
        tearDown(save: true)
        self.api = api
        self.video = video
        self.streamURL = url
        sponsorSegments = streamMetadata?.sponsorBlockSegments ?? []
        sponsorLabel = nil
        sponsorStreamCategory = streamMetadata?.category
        lastSponsorSeek = .distantPast
        isStopped = false
        let generation = playbackGeneration
        historyRecorded = false
        retryCount = 0
        lastRecoveryAttempt = nil
        errorMessage = nil
        playbackFinished = false
        playbackUnavailable = false

        // If account preferences cannot be read, fail closed: never create
        // history entries while the server's privacy choice is unknown.
        let settings = try? await api.accountSettings()
        sponsorSettings = settings
        let allowed = settings != nil &&
            settings?.disableWatchHistory != true && video.isLive != true
        historyEnabled = allowed
        await lastProgressSubmission?.value
        guard !Task.isCancelled, !isStopped,
              playbackGeneration == generation else { return }
        await progressWriter.flush()
        await progressWriter.enable(allowed)
        let saved = allowed ? (try? await api.savedPosition(videoURL: video.url)) : nil
        guard !Task.isCancelled, !isStopped,
              playbackGeneration == generation else { return }
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
        sponsorObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.5, preferredTimescale: 600),
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.checkSponsorBlock() }
        }
        timeControlObservation = player.observe(
            \.timeControlStatus, options: [.new]
        ) { [weak self] player, _ in
            let status = player.timeControlStatus
            Task { @MainActor [weak self] in
                guard let self, !self.isStopped,
                      self.player.currentItem === item else { return }
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
                    guard let self, !self.isStopped,
                          self.player.currentItem === item else { return }
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
                guard let self, !self.isStopped,
                      self.player.currentItem === item else { return }
                self.scheduleStallRecovery(delay: 12)
            }
        }
        itemEndObservation = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: item, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, !self.isStopped,
                      self.player.currentItem === item else { return }
                self.checkpoint(force: true)
                self.playbackFinished = true
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
                Task { @MainActor [weak self] in
                    guard let self, !self.isStopped,
                          self.player.currentItem === item else { return }
                    if finished {
                        self.initialSeekFinished = true
                        self.player.play()
                    } else {
                        // A failed initial resume seek must not leave an
                        // indefinitely waiting player. Renew the stream.
                        self.errorMessage = TVL10n.value("player.seekFailed")
                        self.scheduleStallRecovery(delay: 3)
                    }
                }
            }
        } else {
            player.play()
        }
    }

    private func checkSponsorBlock() {
        guard !isStopped, initialSeekFinished, let settings = sponsorSettings else {
            sponsorLabel = nil
            return
        }
        let seconds = player.currentTime().seconds
        let duration = video?.duration.map(Double.init) ?? 0
        sponsorLabel = TVSponsorBlock.label(
            segments: sponsorSegments, settings: settings,
            position: seconds, duration: duration
        )
        guard player.timeControlStatus == .playing,
              Date().timeIntervalSince(lastSponsorSeek) >= 2.5 else { return }
        let end = TVSponsorBlock.target(
            segments: sponsorSegments, settings: settings,
            position: seconds, duration: duration,
            streamCategory: sponsorStreamCategory
        )
        if settings.sponsorBlockMuteInsteadOfSkip == true {
            player.isMuted = end != nil
            return
        }
        if player.isMuted { player.isMuted = false }
        guard let end, end > seconds + 0.15 else { return }
        lastSponsorSeek = Date()
        player.seek(to: CMTime(seconds: end, preferredTimescale: 600),
                    toleranceBefore: .zero, toleranceAfter: .zero)
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
        let predecessor = lastProgressSubmission
        let writer = progressWriter
        lastProgressSubmission = Task {
            await predecessor?.value
            await writer.checkpoint(
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
        playbackGeneration &+= 1
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
        if let sponsorObserver {
            player.removeTimeObserver(sponsorObserver)
            self.sponsorObserver = nil
        }
        player.isMuted = false
        if let itemFailureObservation {
            NotificationCenter.default.removeObserver(itemFailureObservation)
            self.itemFailureObservation = nil
        }
        if let itemEndObservation {
            NotificationCenter.default.removeObserver(itemEndObservation)
            self.itemEndObservation = nil
        }
        player.pause()
        player.replaceCurrentItem(with: nil)
    }

    func restartAfterFailure(userInitiated: Bool = false) async {
        guard !recoveryInFlight else { return }
        // Permit later, independent outages after a long healthy interval,
        // while bounding repeated reconnects during one sustained failure.
        let now = Date()
        if userInitiated || lastRecoveryAttempt.map({
            now.timeIntervalSince($0) > 120
        }) == true {
            retryCount = 0
        }
        guard !isStopped, retryCount < 3,
              let api, let video else { return }
        recoveryInFlight = true
        defer { recoveryInFlight = false }
        let generation = playbackGeneration
        retryCount += 1
        lastRecoveryAttempt = now
        checkpoint(force: true)
        let policy = TVStreamRecoveryPolicy()
        let started = Date()
        for attempt in 1...policy.maxAttempts {
            do {
                try Task.checkCancellation()
                // Request a fresh manifest after the old URL expired. Preserve
                // the last known playback position through a slow renewal.
                let stream = try await api.stream(for: video)
                guard let nextURL = api.relativeMediaURL(stream.hlsUrl) else {
                    throw TypeTypeError.unavailableFormat
                }
                guard !Task.isCancelled, !isStopped,
                      playbackGeneration == generation else { return }
                let seconds = max(0, Double(lastPositionMs) / 1_000)
                sponsorSegments = stream.sponsorBlockSegments ?? []
                sponsorStreamCategory = stream.category
                tearDown(save: false)
                isStopped = false
                streamURL = nextURL
                errorMessage = nil
                startItem(url: nextURL, positionSeconds: seconds)
                return
            } catch is CancellationError {
                return
            } catch TypeTypeError.videoUnavailable {
                guard !isStopped, playbackGeneration == generation else { return }
                errorMessage = TVL10n.value("player.videoUnavailable")
                playbackUnavailable = true
                return
            } catch {
                guard !isStopped, playbackGeneration == generation else { return }
                guard let delay = policy.delayNanoseconds(
                    error: error, attempt: attempt,
                    elapsedSeconds: Date().timeIntervalSince(started)
                ) else {
                    errorMessage = error.localizedDescription
                    return
                }
                do { try await Task.sleep(nanoseconds: delay) }
                catch { return }
            }
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
