import Foundation
import SwiftUI
import UIKit
import AVFoundation
import CoreMedia
import VideoToolbox

// Client-local fMP4 reader. TypeType Server remains untouched.
// A track consists of the init box sequence (ftyp/moov) and a single media fragment (moof/mdat).
// AVAssetReader is asked for compressed samples (outputSettings:nil) so decoding stays in VideoToolbox.
enum FragmentedMP4Reader {
    static func compressedSamples(initialization: Data, fragment: Data, mediaType: AVMediaType) async throws -> [CMSampleBuffer] {
        guard !initialization.isEmpty && !fragment.isEmpty else {
            throw SabrFailure.invalidResponse("empty MP4 fragment")
        }
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("typetype-\(UUID().uuidString).mp4")
        // Validate structure before asking AVAssetReader to inspect untrusted
        // bytes. Write two parts separately: '+' copies potentially huge 4K
        // fragments into a second Data allocation on memory-limited Apple TVs.
        try SabrMP4Boxes.validate(initialization: initialization, fragment: fragment)
        guard FileManager.default.createFile(atPath: file.path, contents: nil) else {
            throw SabrFailure.invalidResponse("Cannot create temporary MP4 segment")
        }
        defer { try? FileManager.default.removeItem(at: file) }
        do {
            let writer = try FileHandle(forWritingTo: file)
            defer { try? writer.close() }
            try writer.write(contentsOf: initialization)
            try writer.write(contentsOf: fragment)
        }
        let asset = AVURLAsset(url: file)
        let tracks = try await asset.loadTracks(withMediaType: mediaType)
        guard let track = tracks.first else {
            throw SabrFailure.unsupported("AVAssetReader couldn't find an \(mediaType.rawValue) track in the SABR fragment")
        }
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw SabrFailure.unsupported("Compressed \(mediaType.rawValue) reader unavailable") }
        reader.add(output)
        guard reader.startReading() else {
            throw reader.error ?? SabrFailure.invalidResponse("MP4 reader could not start")
        }
        var samples: [CMSampleBuffer] = []
        while reader.status == .reading {
            guard let sample = output.copyNextSampleBuffer() else { break }
            samples.append(sample)
            if samples.count > 2_000 {
                reader.cancelReading()
                throw SabrFailure.invalidResponse("unreasonably large media fragment")
            }
        }
        if reader.status == .failed { throw reader.error ?? SabrFailure.invalidResponse("MP4 read failed") }
        return samples
    }
}

// A native sample-buffer synchronizer instead of a fake HLS playlist or server-side bridge.
// Samples still require real-device validation: AVAssetReader can reject some fMP4 fragments.
@MainActor
final class SabrPlayerController: ObservableObject {
    @Published var state = TVL10n.value("player.starting")
    @Published var failure: String?
    @Published private(set) var playbackUnavailable = false
    @Published private(set) var playbackFinished = false
    @Published var selectionDescription = ""
    @Published var isPlaying = false
    @Published var durationMs: Int64 = 0
    @Published var positionMs: Int64 = 0
    @Published var cachedThroughMs: Int64 = 0
    @Published var diskCacheBytes = 0
    @Published private(set) var availableVideos: [SabrBootstrap.Video] = []
    @Published private(set) var availableAudios: [SabrBootstrap.Audio] = []
    @Published private(set) var currentVideoItag: Int?
    @Published private(set) var currentAudioItag: Int?
    @Published private(set) var currentAudioTrackId: String?
    @Published private(set) var fixedVideoItag: Int?
    @Published private(set) var availableSubtitles: [SabrBootstrap.Subtitle] = []
    @Published private(set) var selectedSubtitleURL: String?
    @Published private(set) var subtitleCues: [SabrCaptionCue] = []
    @Published private(set) var subtitleError: String?

    let videoLayer = AVSampleBufferDisplayLayer()
    private let audioRenderer = AVSampleBufferAudioRenderer()
    private let synchronizer = AVSampleBufferRenderSynchronizer()
    private var running: Task<Void, Never>?
    // Incremented on every stop/start so late replies from previous playback
    // cannot overwrite the active video's state.
    private var playbackEpoch: UInt64 = 0
    private var sessionId = ""
    private var generation: Int64 = 0
    private var selection: SabrSelection?
    private var playbackPositionMs: Int64 = 0
    private var isInitialized = false
    private var hasQueuedFirstAudio = false
    private var hasQueuedFirstVideo = false
    private var hardwareDecoder: HardwareVideoDecoder?
    private var playbackService: SabrService?
    private var segmentCache: SabrFragmentCache?
    private var windowProducerTask: Task<Void, Never>?
    private var activeMailbox: SabrWindowMailbox?
    private let progressWriter = TVPlaybackProgressWriter()
    private let presenceOwner = UUID()
    private var presenceReported = false
    private var currentAPI: TypeTypeAPI?
    private var currentVideo: VideoItem?
    private var hasRecordedHistory = false
    private var historyEnabled = false
    private var prefersPause = false
    private var requestedVideoItag: Int?
    private var requestedAudioItag: Int?
    private var requestedAudioTrackId: String?
    private var subtitleTask: Task<Void, Never>?
    private var subtitlePreferenceChanged = false

    init() {
        videoLayer.videoGravity = .resizeAspect
        synchronizer.addRenderer(videoLayer)
        synchronizer.addRenderer(audioRenderer)
    }

    /// nil means resume from the account's recorded position; explicit values
    /// (including zero) are used for seeking and quality/audio changes.
    func start(api: TypeTypeAPI, video: VideoItem, positionMs: Int64? = nil) {
        stop()
        currentAPI = api
        currentVideo = video
        historyEnabled = false
        prefersPause = false
        playbackPositionMs = positionMs ?? 0
        failure = nil
        playbackUnavailable = false
        playbackFinished = false
        state = TVL10n.value("player.connecting")
        let settings = SabrBufferSettings.preferences(live: video.isLive == true)
        segmentCache = SabrFragmentCache(maxMiB: settings.cacheMiB)
        let epoch = playbackEpoch
        running = Task {
            await run(api: api, video: video, explicitPositionMs: positionMs,
                      buffer: settings, epoch: epoch)
        }
    }

    func stop() {
        playbackEpoch &+= 1
        if isInitialized { recordProgress(force: true) }
        TVPlaybackPresenceReporter.shared.stop(owner: presenceOwner)
        presenceReported = false
        currentAPI = nil
        currentVideo = nil
        hasRecordedHistory = false
        running?.cancel()
        running = nil
        subtitleTask?.cancel()
        subtitleTask = nil
        subtitleCues = []
        let previousService = playbackService
        playbackService = nil
        let previousSession = sessionId
        if let previousService, !previousSession.isEmpty {
            Task { try? await previousService.release(sessionId: previousSession) }
        }
        windowProducerTask?.cancel()
        windowProducerTask = nil
        if let activeMailbox { Task { await activeMailbox.finish(error: CancellationError()) } }
        activeMailbox = nil
        let previousCache = segmentCache
        segmentCache = nil
        if let previousCache { Task { await previousCache.clear() } }
        cachedThroughMs = 0
        diskCacheBytes = 0
        hardwareDecoder?.invalidate()
        hardwareDecoder = nil
        synchronizer.setRate(0, time: synchronizer.currentTime())
        videoLayer.flushAndRemoveImage()
        audioRenderer.flush()
        isInitialized = false
        hasQueuedFirstAudio = false
        hasQueuedFirstVideo = false
        isPlaying = false
        sessionId = ""
    }

    func caption(at timeMs: Int64) -> String? {
        SabrCaptionCue.showing(subtitleCues, at: timeMs)
    }

    func selectSubtitle(_ track: SabrBootstrap.Subtitle?, origin: URL) {
        subtitlePreferenceChanged = true
        subtitleTask?.cancel()
        subtitleCues = []
        subtitleError = nil
        selectedSubtitleURL = track?.url
        guard let track else { return }
        subtitleTask = Task { [weak self] in
            do {
                let loaded = try await SabrCaptionLoader.load(track, origin: origin)
                guard !Task.isCancelled,
                      self?.selectedSubtitleURL == track.url else { return }
                self?.subtitleCues = loaded
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled,
                      self?.selectedSubtitleURL == track.url else { return }
                self?.subtitleError = error.localizedDescription
            }
        }
    }

    func selectQuality(api: TypeTypeAPI, video: VideoItem, itag: Int?) {
        requestedVideoItag = itag
        let wasPaused = prefersPause
        let position = max(0, Int64(playbackSeconds() * 1_000))
        start(api: api, video: video, positionMs: position)
        prefersPause = wasPaused
        fixedVideoItag = itag
    }

    func selectAudio(api: TypeTypeAPI, video: VideoItem,
                     itag: Int, trackId: String?) {
        requestedAudioItag = itag
        requestedAudioTrackId = trackId
        let wasPaused = prefersPause
        let position = max(0, Int64(playbackSeconds() * 1_000))
        start(api: api, video: video, positionMs: position)
        prefersPause = wasPaused
    }

    func seek(api: TypeTypeAPI, video: VideoItem, offsetMs: Int64) {
        let seconds = CMTimeGetSeconds(synchronizer.currentTime())
        let anchor = isInitialized && seconds.isFinite ? Int64(seconds * 1000) : playbackPositionMs
        let upper = durationMs > 0 ? max(0, durationMs - 1_000) : Int64.max
        let wasPaused = prefersPause
        start(api: api, video: video, positionMs: min(upper, max(0, anchor + offsetMs)))
        prefersPause = wasPaused
    }

    func playbackSeconds() -> Double {
        let seconds = CMTimeGetSeconds(synchronizer.currentTime())
        return isInitialized && seconds.isFinite ? max(0, seconds) : Double(playbackPositionMs) / 1_000
    }

    func totalTimeLabel() -> String {
        let seconds = max(0, durationMs / 1_000)
        return String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }

    func timeLabel() -> String {
        let seconds = CMTimeGetSeconds(synchronizer.currentTime())
        let current = isInitialized && seconds.isFinite ? Int64(seconds) : playbackPositionMs / 1000
        return String(format: "%02d:%02d", max(0,current) / 60, max(0,current) % 60)
    }

    func togglePause() {
        guard isInitialized else { return }
        let rate: Float = isPlaying ? 0 : 1
        synchronizer.setRate(rate, time: synchronizer.currentTime())
        isPlaying.toggle()
        prefersPause = !isPlaying
        hardwareDecoder?.playbackPaused = prefersPause
        state = isPlaying ? TVL10n.value("player.playing") : TVL10n.value("player.paused")
        recordProgress(force: true)
    }

    func recordProgress(started: Bool = false, force: Bool = false) {
        guard isInitialized,
              let api = currentAPI, let video = currentVideo else { return }
        let position = max(0, Int64(playbackSeconds() * 1_000))
        TVPlaybackPresenceReporter.shared.progress(
            owner: presenceOwner, video: video, positionMs: position,
            paused: !isPlaying
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

    /// Retry only genuinely transient bootstrap/session errors. Server
    /// authorization denials and malformed media remain terminal.
    private func retryTransient<T>(
        _ action: () async throws -> T
    ) async throws -> T {
        let policy = SabrRecoveryPolicy()
        let started = Date()
        for attempt in 1...policy.maxAttempts {
            try Task.checkCancellation()
            do {
                return try await action()
            } catch {
                guard policy.canRetry(
                    error, completedAttempts: attempt,
                    elapsedSeconds: Date().timeIntervalSince(started)
                ) else { throw error }
                state = TVL10n.value("player.connecting") + " (\(attempt))"
                try await Task.sleep(
                    nanoseconds: policy.delayNanoseconds(
                        for: error, attempt: attempt
                    )
                )
            }
        }
        throw SabrFailure.stalled("stream retry budget exhausted")
    }

    private func run(api: TypeTypeAPI, video: VideoItem,
                     explicitPositionMs: Int64?, buffer: SabrBufferSettings,
                     epoch: UInt64) async {
        guard playbackEpoch == epoch, !Task.isCancelled else { return }
        let service = SabrService(api: api)
        playbackService = service
        do {
            // Respect the server's privacy flag before reading/writing history.
            // If settings cannot be loaded, do not silently record history.
            let settings = try? await api.accountSettings()
            guard playbackEpoch == epoch, !Task.isCancelled else { return }
            let historyAllowed = settings != nil &&
                settings?.disableWatchHistory != true && video.isLive != true
            historyEnabled = historyAllowed
            await progressWriter.enable(historyAllowed)
            await progressWriter.flush()
            guard playbackEpoch == epoch, !Task.isCancelled else { return }
            let recordedPosition = historyAllowed && explicitPositionMs == nil
                ? (try? await api.savedPosition(videoURL: video.url)) : nil
            guard playbackEpoch == epoch, !Task.isCancelled else { return }
            var positionMs = max(0, explicitPositionMs ?? recordedPosition ?? 0)
            // Do not resume after the credits of a nearly completed video.
            if let duration = video.duration, duration > 0,
               positionMs >= Int64(duration) * 1_000 - 3_000 {
                positionMs = 0
            }
            playbackPositionMs = positionMs
            try Task.checkCancellation()
            guard let id = VideoAddress.youtubeID(video.url) else {
                throw SabrFailure.unsupported(TVL10n.value("player.notYoutube"))
            }
            let bootstrap: SabrBootstrap = try await retryTransient {
                do {
                    return try await service.bootstrap(videoURL: video.url)
                } catch SabrFailure.server(let code, _) where code == 401 || code == 403 {
                    try await service.guestLogin()
                    return try await service.bootstrap(videoURL: video.url)
                }
            }
            guard playbackEpoch == epoch, !Task.isCancelled else { return }
            let allowSoftware = UserDefaults.standard.bool(forKey: "typetype.allowSoftwareDecode")
            let maximum = UserDefaults.standard.integer(forKey: "typetype.maxHeight")

            let options = HardwareCodec.candidates(
                from: bootstrap, maxHeight: maximum > 0 ? maximum : 2160,
                allowSoftware: allowSoftware
            )
            availableVideos = options.map(\.video)
            availableAudios = HardwareCodec.audioCandidates(from: bootstrap)
            availableSubtitles = (bootstrap.subtitles ?? []).filter { !$0.url.isEmpty }
            if let current = selectedSubtitleURL {
                if let match = availableSubtitles.first(where: { $0.url == current }) {
                    selectSubtitle(match, origin: api.origin)
                } else {
                    selectSubtitle(nil, origin: api.origin)
                }
            } else if !subtitlePreferenceChanged &&
                        settings?.subtitlesEnabled == true {
                let language = settings?.defaultSubtitleLanguage?.isEmpty == false
                    ? (settings?.defaultSubtitleLanguage ?? TVLanguages.activeLanguage)
                    : TVLanguages.activeLanguage
                if let match = SabrPlaybackPreferences.preferredSubtitle(
                    availableSubtitles, language: language
                ) {
                    selectSubtitle(match, origin: api.origin)
                }
            }
            let orderedOptions: [SabrSelection]
            if let requested = requestedVideoItag,
               let selected = options.first(where: { $0.video.itag == requested }) {
                orderedOptions = [selected] + options.filter { $0.video.itag != requested }
            } else {
                let selected = SabrPlaybackPreferences.preferredVideo(
                    options, defaultQuality: settings?.defaultQuality,
                    deviceMax: maximum > 0 ? maximum : 2160
                )
                if let selected {
                    orderedOptions = [selected] +
                        options.filter { $0.video.itag != selected.video.itag }
                } else {
                    orderedOptions = options
                }
                requestedVideoItag = nil
                fixedVideoItag = nil
            }
            guard !orderedOptions.isEmpty else {
                throw SabrFailure.unsupported(TVL10n.value("player.noHardwareFormat"))
            }
            var playbackStart = positionMs
            for (index, option) in orderedOptions.enumerated() {
                try Task.checkCancellation()
                let audio = availableAudios.first {
                    $0.itag == requestedAudioItag &&
                    $0.audioTrackId == requestedAudioTrackId
                } ?? SabrPlaybackPreferences.preferredAudio(
                    availableAudios,
                    language: settings?.defaultAudioLanguage,
                    preferOriginal: settings?.preferOriginalLanguage == true
                ) ?? option.audio
                let choice = SabrSelection(video: option.video, audio: audio)
                selection = choice
                currentVideoItag = choice.video.itag
                currentAudioItag = choice.audio.itag
                currentAudioTrackId = choice.audio.audioTrackId
                selectionDescription = choice.description
                hardwareDecoder = HardwareVideoDecoder(
                    display: videoLayer, allowSoftware: allowSoftware
                )
                hardwareDecoder?.playbackPaused = prefersPause
                state = TVL10n.value("player.session")
                do {
                    let session = try await retryTransient {
                        try await service.start(
                            videoId: id, selection: choice, positionMs: playbackStart
                        )
                    }
                    guard !session.sessionId.isEmpty else {
                        throw SabrFailure.invalidResponse("sessionId")
                    }
                    // A user may leave while the POST is in flight. If its
                    // response arrives *after* stop(), the stop path could
                    // not have known this new token; release it explicitly.
                    if Task.isCancelled || playbackEpoch != epoch {
                        let abandoned = session.sessionId
                        Task.detached(priority: .utility) {
                            try? await service.release(sessionId: abandoned)
                        }
                        throw CancellationError()
                    }
                    sessionId = session.sessionId
                    generation = session.generation
                    try await consume(
                        service: service, videoId: id, choice: choice,
                        positionMs: playbackStart, buffer: buffer
                    )
                    return
                } catch SabrFailure.unsupported where index < orderedOptions.count - 1 {
                    if isInitialized {
                        recordProgress(force: true)
                        let lastSubmitted = max(0, self.positionMs - 1_000)
                        playbackStart = min(
                            max(0, Int64(playbackSeconds() * 1_000)),
                            lastSubmitted
                        )
                    }
                    // A codec may be reported hardware-capable even though
                    // the precise profile/level cannot create a decoder.
                    // Try the next candidate only before playback starts.
                    let oldSession = sessionId
                    sessionId = ""
                    generation = 0
                    if !oldSession.isEmpty {
                        Task { try? await service.release(sessionId: oldSession) }
                    }
                    windowProducerTask?.cancel()
                    windowProducerTask = nil
                    if let activeMailbox {
                        await activeMailbox.finish(error: CancellationError())
                    }
                    activeMailbox = nil
                    hardwareDecoder?.invalidate()
                    hardwareDecoder = nil
                    videoLayer.flushAndRemoveImage()
                    audioRenderer.flush()
                    synchronizer.setRate(
                        0, time: CMTime(value: playbackStart, timescale: 1_000)
                    )
                    playbackPositionMs = playbackStart
                    isInitialized = false
                    hasQueuedFirstAudio = false
                    hasQueuedFirstVideo = false
                    isPlaying = false
                    if fixedVideoItag != nil { fixedVideoItag = nil }
                    cachedThroughMs = playbackStart
                    diskCacheBytes = 0
                    if let oldCache = segmentCache { await oldCache.clear() }
                    segmentCache = SabrFragmentCache(maxMiB: buffer.cacheMiB)
                }
            }
        } catch is CancellationError {
            return
        } catch SabrFailure.unavailable {
            guard playbackEpoch == epoch, !Task.isCancelled else { return }
            failure = TVL10n.value("player.videoUnavailable")
            playbackUnavailable = true
            isPlaying = false
            state = TVL10n.value("player.failed")
        } catch {
            guard playbackEpoch == epoch, !Task.isCancelled else { return }
            failure = error.localizedDescription
            isPlaying = false
            state = TVL10n.value("player.failed")
        }
    }

    /// The network stage runs independently of sample-buffer decoder pressure.
    /// Producer sends complete metadata windows through a bounded mailbox and
    /// downloads the compressed bytes to the disk cache before advancing.
    private func consume(service: SabrService, videoId: String,
                         choice: SabrSelection, positionMs start: Int64,
                         buffer: SabrBufferSettings) async throws {
        var restartPosition = max(0, start)
        let recoveryStarted = Date()
        let policy = SabrRecoveryPolicy()
        for recoveryAttempt in 0..<policy.maxAttempts {
            try Task.checkCancellation()
            let mailbox = SabrWindowMailbox()
            activeMailbox = mailbox
            guard let cache = segmentCache else { throw SabrFailure.stopped }
            let currentSession = sessionId
            let currentGeneration = generation
            let producerStart = restartPosition
            let producer = Task { [weak self] in
                guard let self else {
                    await mailbox.finish(error: CancellationError())
                    return
                }
                do {
                    try await self.downloadWindows(
                        service: service, sessionId: currentSession,
                        generation: currentGeneration, choice: choice,
                        start: producerStart, buffer: buffer,
                        cache: cache, mailbox: mailbox
                    )
                    await mailbox.finish()
                } catch {
                    await mailbox.finish(error: error)
                }
            }
            windowProducerTask = producer
            do {
                try await playCachedWindows(mailbox: mailbox, service: service,
                                            choice: choice, start: restartPosition, cache: cache)
                producer.cancel()
                windowProducerTask = nil
                activeMailbox = nil
                return
            } catch {
                producer.cancel()
                await mailbox.finish(error: CancellationError())
                windowProducerTask = nil
                activeMailbox = nil
                guard policy.canRetry(
                    error, completedAttempts: recoveryAttempt + 1,
                    elapsedSeconds: Date().timeIntervalSince(recoveryStarted)
                ) else { throw error }
                // The clock may have advanced past the last actual rendered
                // segment during a network stall. Rewind a little and clamp
                // to the last submitted audio/video coverage.
                let clockMs = max(0, Int64(playbackSeconds() * 1_000))
                let confirmedMs = max(restartPosition, positionMs - 1_000)
                restartPosition = min(clockMs, confirmedMs)
                recordProgress(force: true)
                synchronizer.setRate(
                    0, time: CMTime(value: restartPosition, timescale: 1_000)
                )
                isPlaying = false
                state = TVL10n.value("player.connecting") +
                    " (\(recoveryAttempt + 1))"
                try await Task.sleep(
                    nanoseconds: policy.delayNanoseconds(
                        for: error, attempt: recoveryAttempt + 1
                    )
                )
                try Task.checkCancellation()
                let oldSession = sessionId
                let renewed = try await retryTransient {
                    try await service.start(
                        videoId: videoId, selection: choice,
                        positionMs: restartPosition
                    )
                }
                if Task.isCancelled {
                    let abandoned = renewed.sessionId
                    Task.detached(priority: .utility) {
                        try? await service.release(sessionId: abandoned)
                    }
                    throw CancellationError()
                }
                sessionId = renewed.sessionId
                generation = renewed.generation
                if oldSession != renewed.sessionId {
                    Task { try? await service.release(sessionId: oldSession) }
                }
                videoLayer.flushAndRemoveImage()
                audioRenderer.flush()
                hardwareDecoder?.invalidate()
                let allowSoftware = UserDefaults.standard.bool(
                    forKey: "typetype.allowSoftwareDecode"
                )
                hardwareDecoder = HardwareVideoDecoder(
                    display: videoLayer, allowSoftware: allowSoftware
                )
                hardwareDecoder?.playbackPaused = prefersPause
                playbackPositionMs = restartPosition
                isInitialized = false
                hasQueuedFirstAudio = false
                hasQueuedFirstVideo = false
                cachedThroughMs = restartPosition
                diskCacheBytes = 0
                await cache.clear()
                segmentCache = SabrFragmentCache(maxMiB: buffer.cacheMiB)
                state = TVL10n.value("player.session")
            }
        }
    }

    /// Uses the *actual playback clock* for the server's position updates.
    /// The bufferedRanges fields, rather than a fake forward seek, tell the
    /// server which completed audio/video intervals are already stored.
    private func downloadWindows(service: SabrService, sessionId: String,
                                 generation: Int64, choice: SabrSelection,
                                 start: Int64, buffer: SabrBufferSettings,
                                 cache: SabrFragmentCache,
                                 mailbox: SabrWindowMailbox) async throws {
        var coverage = SabrPlaybackCoverage(audioItag: choice.audio.itag,
                                            videoItag: choice.video.itag, positionMs: start)
        var previousEnd = start
        var first = true
        var stalled = 0
        let target = SabrLookaheadPolicy.targetMilliseconds(
            buffer, videoBitrate: choice.video.bitrate
        )
        while !Task.isCancelled {
            let seconds = playbackSeconds()
            let playhead = seconds.isFinite ? max(start, Int64(max(0, seconds) * 1_000)) : start
            let retainedEnd = await cache.cachedThroughMs(
                audioItag: choice.audio.itag, videoItag: choice.video.itag,
                positionMs: playhead
            )
            cachedThroughMs = retainedEnd
            diskCacheBytes = await cache.bytesInUse
            if !first && !SabrLookaheadPolicy.shouldRequestMore(
                cachedThroughMs: retainedEnd, playheadMs: playhead, targetMs: target
            ) {
                try await Task.sleep(nanoseconds: 250_000_000)
                continue
            }
            let requested = try await service.window(
                sessionId: sessionId, selection: choice, generation: generation,
                positionMs: playhead,
                ranges: await cache.cachedRanges(
                    retainFromMs: max(0, playhead - Int64(buffer.backMilliseconds))
                ),
                buffer: buffer
            )
            try Task.checkCancellation()
            guard let audio = requested.audio, let video = requested.video else {
                throw SabrFailure.invalidResponse("SABR window has no audio/video pair")
            }

            // Show the first window promptly. Subsequent windows are delivered
            // only when all compressed fragments are already in the local cache.
            let isFirstWindow = first
            if first {
                try await mailbox.offer(requested)
                first = false
            }
            let refs = audio.segments.map {
                SabrMediaReference(url: $0.url, itag: choice.audio.itag,
                                   startMs: $0.startMs, durationMs: $0.durationMs)
            } + video.segments.map {
                SabrMediaReference(url: $0.url, itag: choice.video.itag,
                                   startMs: $0.startMs, durationMs: $0.durationMs)
            }
            try await cache.preloadFully(refs, service: service,
                                         sessionId: sessionId, generation: generation)
            try Task.checkCancellation()
            for part in audio.segments.sorted(by: { $0.startMs < $1.startMs }) {
                try coverage.acceptAudio(part)
            }
            for part in video.segments.sorted(by: { $0.startMs < $1.startMs }) {
                try coverage.acceptVideo(part)
            }
            let downloadedEnd = coverage.safeEndMs
            cachedThroughMs = await cache.cachedThroughMs(
                audioItag: choice.audio.itag, videoItag: choice.video.itag,
                positionMs: playhead
            )
            diskCacheBytes = await cache.bytesInUse

            // The server can finish with an empty or overlapping final window.
            // Always deliver EOS to the decoder instead of treating it as a
            // stalled prefetch, even when no timestamps advance.
            if requested.endOfStream == true {
                if !isFirstWindow { try await mailbox.offer(requested) }
                return
            }
            if downloadedEnd > previousEnd {
                previousEnd = downloadedEnd
                stalled = 0
            } else {
                stalled += 1
                guard stalled <= 8 else {
                    throw SabrFailure.invalidResponse("SABR window stopped advancing")
                }
                try await Task.sleep(nanoseconds: 350_000_000)
                continue
            }
            if !isFirstWindow {
                try await mailbox.offer(requested)
            }
        }
    }

    /// Audio and video are rendered in media-time order from the queued window.
    /// This path never calls /position, /prefetch or /segments and therefore
    /// cannot hold up the next server window while the renderer is busy.
    private func playCachedWindows(mailbox: SabrWindowMailbox, service: SabrService,
                                   choice: SabrSelection, start: Int64,
                                   cache: SabrFragmentCache) async throws {
        var audioInit = Data()
        var videoInit = Data()
        var audioInitLocation = ""
        var videoInitLocation = ""
        var seen = Set<String>()
        var coverage = SabrPlaybackCoverage(audioItag: choice.audio.itag,
                                            videoItag: choice.video.itag, positionMs: start)
        while let response = try await mailbox.next() {
            try Task.checkCancellation()
            if let ms = response.durationMs { durationMs = ms }
            guard let audio = response.audio, let video = response.video else {
                throw SabrFailure.invalidResponse("SABR audio/video missing")
            }
            if audioInitLocation != audio.initUrl {
                audioInit = try await service.fragmentData(
                    audio.initUrl, sessionId: sessionId,
                    itag: choice.audio.itag, generation: generation
                )
                audioInitLocation = audio.initUrl
            }
            if videoInitLocation != video.initUrl {
                videoInit = try await service.fragmentData(
                    video.initUrl, sessionId: sessionId,
                    itag: choice.video.itag, generation: generation
                )
                videoInitLocation = video.initUrl
            }

            // Both tracks must have a first segment before the playback clock
            // starts. An advancing clock without decoded samples makes the
            // first video frame late, especially over a slower LAN connection.
            if !isInitialized && (audio.segments.isEmpty || video.segments.isEmpty) {
                throw SabrFailure.invalidResponse("first SABR window lacks an audio/video segment pair")
            }

            let count = max(audio.segments.count, video.segments.count)
            for index in 0..<count {
                try Task.checkCancellation()
                var audioSamples: [CMSampleBuffer] = []
                var videoSamples: [CMSampleBuffer] = []
                var audioPart: SabrFragment?
                var videoPart: SabrFragment?

                if index < audio.segments.count {
                    let segment = audio.segments[index]
                    if !seen.contains("a:\(segment.url)") {
                        let sid = sessionId, gen = generation
                        let bytes = try await cache.data(for: segment.url) {
                            try await service.fragmentData(segment.url, sessionId: sid,
                                                           itag: choice.audio.itag, generation: gen)
                        }
                        audioSamples = try await FragmentedMP4Reader.compressedSamples(
                            initialization: audioInit, fragment: bytes, mediaType: .audio
                        )
                        guard !audioSamples.isEmpty else {
                            throw SabrFailure.unsupported("SABR audio segment contains no compressed samples")
                        }
                        audioPart = segment
                    }
                }
                if index < video.segments.count {
                    let segment = video.segments[index]
                    if !seen.contains("v:\(segment.url)") {
                        let sid = sessionId, gen = generation
                        let bytes = try await cache.data(for: segment.url) {
                            try await service.fragmentData(segment.url, sessionId: sid,
                                                           itag: choice.video.itag, generation: gen)
                        }
                        videoSamples = try await FragmentedMP4Reader.compressedSamples(
                            initialization: videoInit, fragment: bytes, mediaType: .video
                        )
                        guard !videoSamples.isEmpty else {
                            throw SabrFailure.unsupported("SABR video segment contains no compressed samples")
                        }
                        videoPart = segment
                    }
                }
                if !isInitialized && (audioSamples.isEmpty || videoSamples.isEmpty) {
                    throw SabrFailure.invalidResponse("initial SABR segment pair is incomplete")
                }
                // Alternating media-time-ordered samples prevents several
                // seconds of audio from entering the renderer before video.
                try await enqueueInterleaved(audio: audioSamples, video: videoSamples, startMs: start)
                if let part = audioPart {
                    try coverage.acceptAudio(part)
                    seen.insert("a:\(part.url)")
                }
                if let part = videoPart {
                    try coverage.acceptVideo(part)
                    seen.insert("v:\(part.url)")
                }
            }

            positionMs = coverage.safeEndMs
            if response.endOfStream == true {
                // A complete *network* window is not the same as fully
                // presented media. Keep renderers running to the common A/V
                // end before displaying the finished state.
                let endMs = durationMs > 0 ? min(durationMs, coverage.safeEndMs) : coverage.safeEndMs
                if isInitialized && endMs > start {
                    while playbackSeconds() * 1_000 < Double(endMs) {
                        try Task.checkCancellation()
                        try await Task.sleep(nanoseconds: 100_000_000)
                    }
                    synchronizer.setRate(0, time: synchronizer.currentTime())
                    isPlaying = false
                    recordProgress(force: true)
                }
                TVPlaybackPresenceReporter.shared.stop(owner: presenceOwner)
                presenceReported = false
                state = TVL10n.value("player.end")
                playbackFinished = true
                return
            }
            state = TVL10n.value("player.playing")
        }
    }

    /// Feed one compressed sample at a time, preserving the original decode
    /// order within each track and comparing PTS only across tracks.
    /// Starting after one sample of both tracks avoids a pre-roll deadlock:
    /// renderers have a bounded queue and may stop accepting data at rate zero.
    private func enqueueInterleaved(audio: [CMSampleBuffer], video: [CMSampleBuffer],
                                    startMs: Int64) async throws {
        var ai = 0
        var vi = 0
        while ai < audio.count || vi < video.count {
            try Task.checkCancellation()
            let choice: SabrMediaInterleave.Track
            if !isInitialized && !hasQueuedFirstAudio && ai < audio.count {
                choice = .audio
            } else if !isInitialized && !hasQueuedFirstVideo && vi < video.count {
                choice = .video
            } else {
                let aTime = ai < audio.count
                    ? CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(audio[ai])) : nil
                let vTime = vi < video.count
                    ? CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(video[vi])) : nil
                guard let pick = SabrMediaInterleave.next(
                    audioSeconds: aTime, videoSeconds: vTime
                ) else { break }
                choice = pick
            }

            switch choice {
            case .audio:
                var budget = SabrRendererWaitBudget()
                while !audioRenderer.isReadyForMoreMediaData {
                    try Task.checkCancellation()
                    guard audioRenderer.status != .failed else {
                        throw SabrFailure.stalled("audio renderer reported failure")
                    }
                    guard budget.shouldContinue(
                        paused: prefersPause, stepMilliseconds: 20
                    ) else {
                        throw SabrFailure.stalled("audio renderer stopped accepting samples")
                    }
                    try await Task.sleep(nanoseconds: 20_000_000)
                }
                audioRenderer.enqueue(audio[ai])
                ai += 1
                hasQueuedFirstAudio = true
            case .video:
                var budget = SabrRendererWaitBudget()
                while !videoLayer.isReadyForMoreMediaData {
                    try Task.checkCancellation()
                    guard videoLayer.status != .failed else {
                        throw SabrFailure.stalled("video display layer failed")
                    }
                    guard budget.shouldContinue(
                        paused: prefersPause, stepMilliseconds: 20
                    ) else {
                        throw SabrFailure.stalled("video renderer stopped accepting samples")
                    }
                    try await Task.sleep(nanoseconds: 20_000_000)
                }
                guard let hardwareDecoder else {
                    throw SabrFailure.invalidResponse("decoder missing")
                }
                try await hardwareDecoder.decode(video[vi])
                vi += 1
                hasQueuedFirstVideo = true
            }

            if !isInitialized && hasQueuedFirstAudio && hasQueuedFirstVideo {
                synchronizer.setRate(
                    prefersPause ? 0 : 1,
                    time: CMTime(value: startMs, timescale: 1_000)
                )
                isInitialized = true
                isPlaying = !prefersPause
                state = TVL10n.value(
                    prefersPause ? "player.paused" : "player.playing"
                )
                if !presenceReported, let api = currentAPI, let video = currentVideo {
                    TVPlaybackPresenceReporter.shared.start(
                        owner: presenceOwner, api: api, video: video,
                        positionMs: max(0, Int64(playbackSeconds() * 1_000)),
                        paused: prefersPause
                    )
                    presenceReported = true
                }
                recordProgress(started: !hasRecordedHistory, force: true)
                hasRecordedHistory = true
            }
        }
    }
}

private final class SampleBufferView: UIView {
    var displayLayer: AVSampleBufferDisplayLayer? {
        didSet {
            oldValue?.removeFromSuperlayer()
            if let displayLayer { layer.addSublayer(displayLayer) }
            setNeedsLayout()
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        displayLayer?.frame = bounds
    }
}

struct SabrVideoSurface: UIViewRepresentable {
    let displayLayer: AVSampleBufferDisplayLayer

    func makeUIView(context: Context) -> UIView {
        let view = SampleBufferView()
        view.backgroundColor = .black
        view.displayLayer = displayLayer
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {}
}

struct SabrPlayerView: View {
    let api: TypeTypeAPI
    let video: VideoItem
    var onPlaybackEvent: ((TVPlaybackEvent) -> Void)? = nil
    @StateObject private var engine = SabrPlayerController()
    @AppStorage("typetype.skipSeconds") private var skipSeconds = 10
    @State private var controlsVisible = true
    @State private var revealIndex = 0
    @State private var optionsVisible = false

    private func reveal() {
        controlsVisible = true
        revealIndex &+= 1
    }

    private func skip(_ direction: Int) {
        let duration = max(5, min(20, skipSeconds))
        engine.seek(api: api, video: video, offsetMs: Int64(direction * duration * 1_000))
        reveal()
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            SabrVideoSurface(displayLayer: engine.videoLayer).ignoresSafeArea()

            TimelineView(.periodic(from: .now, by: 0.25)) { _ in
                if let caption = engine.caption(
                    at: Int64(engine.playbackSeconds() * 1_000)
                ), !caption.isEmpty {
                    Text(caption)
                        .font(.system(size: 36, weight: .medium))
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 24)
                        .padding(.vertical, 10)
                        .background(.black.opacity(0.73),
                                    in: RoundedRectangle(cornerRadius: 8))
                        .frame(maxWidth: 1300)
                        .frame(maxWidth: .infinity, maxHeight: .infinity,
                               alignment: .bottom)
                        .padding(.bottom, controlsVisible ? 255 : 85)
                }
            }
            .allowsHitTesting(false)

            if !optionsVisible {
                SiriRemotePlayerInput(
                    onTouch: reveal,
                    onDirection: skip,
                    onTogglePlayback: {
                        engine.togglePause()
                        reveal()
                    },
                    onSelect: {
                        // A Clickpad click always toggles playback; a simple
                        // touch only reveals the controls.
                        engine.togglePause()
                        reveal()
                    },
                    onOptions: {
                        controlsVisible = true
                        optionsVisible = true
                    }
                )
                .accessibilityLabel("player.remoteAccessibility")
                .accessibilityHint("player.remoteAccessibilityHint")
                .ignoresSafeArea()
            }

            if let failure = engine.failure {
                VStack(spacing: 22) {
                    Text(engine.playbackUnavailable
                        ? "player.videoUnavailable" : "player.sabrError")
                        .font(.largeTitle)
                    Text(failure).multilineTextAlignment(.center)
                    Button("common.retry") {
                        engine.start(api: api, video: video)
                        reveal()
                    }
                }
                .padding(50)
                .background(.black.opacity(0.86), in: RoundedRectangle(cornerRadius: 20))
            } else if controlsVisible {
                VStack {
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 9) {
                            Text(video.title).font(.title.bold()).lineLimit(2)
                            Text(video.uploaderName ?? "")
                                .font(.callout).foregroundStyle(.white.opacity(0.8))
                        }
                        Spacer()
                        Text(engine.selectionDescription)
                            .font(.caption).foregroundStyle(.white.opacity(0.8))
                    }
                    Spacer()
                    VStack(spacing: 20) {
                        HStack(spacing: 18) {
                            Text(engine.state).font(.callout)
                            Spacer()
                            if engine.diskCacheBytes > 0 {
                                Text(TVL10n.formatted("player.cache", engine.diskCacheBytes / 1_048_576))
                                    .font(.caption).foregroundStyle(.white.opacity(0.8))
                                let aheadSeconds = max(0, Double(engine.cachedThroughMs) / 1_000
                                                       - engine.playbackSeconds())
                                Text(TVL10n.formatted("player.ahead", Int(aheadSeconds)))
                                    .font(.caption).foregroundStyle(.white.opacity(0.8))
                            }
                        }
                        TimelineView(.periodic(from: .now, by: 1)) { _ in
                            HStack(spacing: 20) {
                                Text(engine.timeLabel())
                                    .monospacedDigit().frame(width: 105)
                                ProgressView(value: engine.playbackSeconds(),
                                             total: max(1.0, Double(engine.durationMs) / 1_000))
                                Text(engine.totalTimeLabel())
                                    .monospacedDigit().frame(width: 105)
                            }
                        }
                        // Only the full-screen remote capture view should receive
                        // directional presses. Focusable HUD buttons would cause the
                        // Siri Remote to navigate between buttons instead of seeking.
                        HStack(spacing: 48) {
                            Label("−\(skipSeconds) s", systemImage: "gobackward")
                            Label(TVL10n.value(engine.isPlaying ? "player.playPause" : "player.resume"),
                                  systemImage: engine.isPlaying ? "pause.fill" : "play.fill")
                            Label("+\(skipSeconds) s", systemImage: "goforward")
                        }
                        .font(.callout.weight(.medium))
                        .foregroundStyle(.white.opacity(0.9))
                        Text("player.remoteHelp")
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.65))
                    }
                }
                .padding(.horizontal, 80)
                .padding(.top, 70)
                .padding(.bottom, 65)
                .background(
                    LinearGradient(
                        colors: [.black.opacity(0.8), .clear, .clear, .black.opacity(0.9)],
                        startPoint: .top, endPoint: .bottom
                    )
                )
                .transition(.opacity)
            }
        }
        .overlay {
            if optionsVisible {
                SabrPlayerOptions(
                    engine: engine,
                    onQuality: { itag in
                        engine.selectQuality(api: api, video: video, itag: itag)
                        optionsVisible = false
                        reveal()
                    },
                    onAudio: { track in
                        engine.selectAudio(
                            api: api, video: video,
                            itag: track.itag, trackId: track.audioTrackId
                        )
                        optionsVisible = false
                        reveal()
                    },
                    onSubtitle: { track in
                        engine.selectSubtitle(track, origin: api.origin)
                        optionsVisible = false
                        reveal()
                    },
                    onClose: {
                        optionsVisible = false
                        reveal()
                    }
                )
            }
        }
        .task {
            engine.start(api: api, video: video)
            reveal()
        }
        .task(id: revealIndex) {
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            if !Task.isCancelled && !optionsVisible && engine.failure == nil && engine.isPlaying {
                withAnimation(.easeOut(duration: 0.25)) { controlsVisible = false }
            }
        }
        .onChange(of: engine.isPlaying) {
            if !engine.isPlaying { reveal() }
        }
        .onChange(of: engine.playbackUnavailable) { _, unavailable in
            if unavailable { onPlaybackEvent?(.unavailable) }
        }
        .onChange(of: engine.playbackFinished) { _, finished in
            if finished { onPlaybackEvent?(.finished) }
        }
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 15_000_000_000)
                if Task.isCancelled { break }
                engine.recordProgress()
            }
        }
        .onDisappear { engine.stop() }
    }
}
