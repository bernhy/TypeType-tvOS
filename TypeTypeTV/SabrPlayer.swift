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
        // Each fragment is bounded; do not retain giant temporary files across the session.
        try (initialization + fragment).write(to: file, options: .atomic)
        defer { try? FileManager.default.removeItem(at: file) }
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
    @Published var selectionDescription = ""
    @Published var isPlaying = false
    @Published var durationMs: Int64 = 0
    @Published var positionMs: Int64 = 0
    @Published var cachedThroughMs: Int64 = 0
    @Published var diskCacheBytes = 0

    let videoLayer = AVSampleBufferDisplayLayer()
    private let audioRenderer = AVSampleBufferAudioRenderer()
    private let synchronizer = AVSampleBufferRenderSynchronizer()
    private var running: Task<Void, Never>?
    private var sessionId = ""
    private var generation: Int64 = 0
    private var selection: SabrSelection?
    private var playbackPositionMs: Int64 = 0
    private var isInitialized = false
    private var hardwareDecoder: HardwareVideoDecoder?
    private var playbackService: SabrService?
    private var segmentCache: SabrFragmentCache?
    private var windowProducerTask: Task<Void, Never>?
    private var activeMailbox: SabrWindowMailbox?

    init() {
        videoLayer.videoGravity = .resizeAspect
        synchronizer.addRenderer(videoLayer)
        synchronizer.addRenderer(audioRenderer)
    }

    func start(api: TypeTypeAPI, video: VideoItem, positionMs: Int64 = 0) {
        stop()
        playbackPositionMs = positionMs
        failure = nil
        state = TVL10n.value("player.connecting")
        let settings = SabrBufferSettings.preferences(live: video.isLive == true)
        segmentCache = SabrFragmentCache(maxMiB: settings.cacheMiB)
        running = Task { await run(api: api, video: video, positionMs: positionMs, buffer: settings) }
    }

    func stop() {
        running?.cancel()
        running = nil
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
        isPlaying = false
        sessionId = ""
    }

    func seek(api: TypeTypeAPI, video: VideoItem, offsetMs: Int64) {
        let seconds = CMTimeGetSeconds(synchronizer.currentTime())
        let anchor = isInitialized && seconds.isFinite ? Int64(seconds * 1000) : playbackPositionMs
        let upper = durationMs > 0 ? max(0, durationMs - 1_000) : Int64.max
        start(api: api, video: video, positionMs: min(upper, max(0, anchor + offsetMs)))
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
        state = isPlaying ? TVL10n.value("player.playing") : TVL10n.value("player.paused")
    }

    private func run(api: TypeTypeAPI, video: VideoItem, positionMs: Int64,
                     buffer: SabrBufferSettings) async {
        let service = SabrService(api: api)
        playbackService = service
        do {
            guard let id = VideoAddress.youtubeID(video.url) else {
                throw SabrFailure.unsupported(TVL10n.value("player.notYoutube"))
            }
            let bootstrap: SabrBootstrap
            do {
                bootstrap = try await service.bootstrap(videoURL: video.url)
            } catch SabrFailure.server(let code, _) where code == 401 || code == 403 {
                try await service.guestLogin()
                bootstrap = try await service.bootstrap(videoURL: video.url)
            }
            let allowSoftware = UserDefaults.standard.bool(forKey: "typetype.allowSoftwareDecode")
            let maximum = UserDefaults.standard.integer(forKey: "typetype.maxHeight")
            guard let choice = HardwareCodec.choose(from: bootstrap,
                                                   maxHeight: maximum > 0 ? maximum : 2160,
                                                   allowSoftware: allowSoftware) else {
                throw SabrFailure.unsupported(TVL10n.value("player.noHardwareFormat"))
            }
            selection = choice
            selectionDescription = choice.description
            hardwareDecoder = HardwareVideoDecoder(display: videoLayer, allowSoftware: allowSoftware)
            hardwareDecoder?.onFailure = { [weak self] message in
                self?.failure = message
                self?.stop()
            }
            state = TVL10n.value("player.session")
            let session = try await service.start(videoId: id, selection: choice, positionMs: positionMs)
            guard !session.sessionId.isEmpty else { throw SabrFailure.invalidResponse("sessionId") }
            sessionId = session.sessionId
            generation = session.generation
            try await consume(service: service, videoId: id, choice: choice,
                              positionMs: positionMs, buffer: buffer)
        } catch is CancellationError {
            return
        } catch {
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
        for recoveryAttempt in 0...2 {
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
                let refresh: Bool
                if case SabrFailure.expired = error {
                    refresh = true
                } else if case SabrFailure.server(let status, _) = error {
                    refresh = status == 404
                } else {
                    refresh = false
                }
                guard refresh && recoveryAttempt < 2 else { throw error }
                let now = playbackSeconds()
                restartPosition = now.isFinite ? max(0, Int64(now * 1_000)) : restartPosition
                let oldSession = sessionId
                let renewed = try await service.start(videoId: videoId, selection: choice,
                                                      positionMs: restartPosition)
                sessionId = renewed.sessionId
                generation = renewed.generation
                if oldSession != renewed.sessionId {
                    Task { try? await service.release(sessionId: oldSession) }
                }
                videoLayer.flushAndRemoveImage()
                audioRenderer.flush()
                hardwareDecoder?.invalidate()
                let allowSoftware = UserDefaults.standard.bool(forKey: "typetype.allowSoftwareDecode")
                hardwareDecoder = HardwareVideoDecoder(display: videoLayer,
                                                       allowSoftware: allowSoftware)
                hardwareDecoder?.onFailure = { [weak self] message in
                    self?.failure = message
                    self?.stop()
                }
                synchronizer.setRate(0, time: CMTime(value: restartPosition, timescale: 1_000))
                playbackPositionMs = restartPosition
                isInitialized = false
                isPlaying = false
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
            if !first && !SabrLookaheadPolicy.shouldRequestMore(
                cachedThroughMs: coverage.safeEndMs, playheadMs: playhead, targetMs: target
            ) {
                try await Task.sleep(nanoseconds: 250_000_000)
                continue
            }
            let requested = try await service.window(
                sessionId: sessionId, selection: choice, generation: generation,
                positionMs: playhead,
                ranges: coverage.requestRanges(
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
            cachedThroughMs = max(cachedThroughMs, downloadedEnd)
            diskCacheBytes = await cache.bytesInUse

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
            if requested.endOfStream == true { return }
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
            if !isInitialized {
                synchronizer.setRate(1, time: CMTime(value: start, timescale: 1_000))
                isInitialized = true
                isPlaying = true
            }

            let count = max(audio.segments.count, video.segments.count)
            for index in 0..<count {
                try Task.checkCancellation()
                if index < audio.segments.count {
                    let segment = audio.segments[index]
                    if seen.insert("a:\(segment.url)").inserted {
                        let sid = sessionId, gen = generation
                        let bytes = try await cache.data(for: segment.url) {
                            try await service.fragmentData(segment.url, sessionId: sid,
                                                           itag: choice.audio.itag, generation: gen)
                        }
                        let samples = try await FragmentedMP4Reader.compressedSamples(
                            initialization: audioInit, fragment: bytes, mediaType: .audio
                        )
                        try await enqueue(samples, audio: true)
                        try coverage.acceptAudio(segment)
                    }
                }
                if index < video.segments.count {
                    let segment = video.segments[index]
                    if seen.insert("v:\(segment.url)").inserted {
                        let sid = sessionId, gen = generation
                        let bytes = try await cache.data(for: segment.url) {
                            try await service.fragmentData(segment.url, sessionId: sid,
                                                           itag: choice.video.itag, generation: gen)
                        }
                        let samples = try await FragmentedMP4Reader.compressedSamples(
                            initialization: videoInit, fragment: bytes, mediaType: .video
                        )
                        try await enqueue(samples, audio: false)
                        try coverage.acceptVideo(segment)
                    }
                }
            }
            positionMs = coverage.safeEndMs
            if response.endOfStream == true {
                state = TVL10n.value("player.end")
                return
            }
            state = TVL10n.value("player.playing")
        }
    }

    private func enqueue(_ samples: [CMSampleBuffer], audio: Bool) async throws {
        guard !samples.isEmpty else { throw SabrFailure.unsupported("SABR segment contains no decodable samples") }
        for sample in samples {
            try Task.checkCancellation()
            while audio ? !audioRenderer.isReadyForMoreMediaData : !videoLayer.isReadyForMoreMediaData {
                try await Task.sleep(nanoseconds: 20_000_000)
            }
            if audio {
                audioRenderer.enqueue(sample)
            } else {
                guard let hardwareDecoder else { throw SabrFailure.invalidResponse("decoder missing") }
                try await hardwareDecoder.decode(sample)
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
    @StateObject private var engine = SabrPlayerController()
    @AppStorage("typetype.skipSeconds") private var skipSeconds = 10
    @State private var controlsVisible = true
    @State private var revealIndex = 0

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

            SiriRemotePlayerInput(
                onTouch: reveal,
                onDirection: skip,
                onTogglePlayback: {
                    engine.togglePause()
                    reveal()
                },
                onSelect: {
                    if controlsVisible {
                        engine.togglePause()
                    }
                    reveal()
                }
            )
            .accessibilityLabel("player.remoteAccessibility")
            .accessibilityHint("player.remoteAccessibilityHint")
            .ignoresSafeArea()

            if let failure = engine.failure {
                VStack(spacing: 22) {
                    Text("player.sabrError").font(.largeTitle)
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
        .task {
            engine.start(api: api, video: video)
            reveal()
        }
        .task(id: revealIndex) {
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            if !Task.isCancelled && engine.failure == nil && engine.isPlaying {
                withAnimation(.easeOut(duration: 0.25)) { controlsVisible = false }
            }
        }
        .onChange(of: engine.isPlaying) {
            if !engine.isPlaying { reveal() }
        }
        .onDisappear { engine.stop() }
    }
}
