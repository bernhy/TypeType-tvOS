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
    @Published var state = "Starte SABR …"
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
    private var prefetchTask: Task<Void, Never>?

    init() {
        videoLayer.videoGravity = .resizeAspect
        synchronizer.addRenderer(videoLayer)
        synchronizer.addRenderer(audioRenderer)
    }

    func start(api: TypeTypeAPI, video: VideoItem, positionMs: Int64 = 0) {
        stop()
        playbackPositionMs = positionMs
        failure = nil
        state = "Verbinde mit TypeType …"
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
        prefetchTask?.cancel()
        prefetchTask = nil
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
        state = isPlaying ? "Wiedergabe läuft" : "Pausiert"
    }

    private func run(api: TypeTypeAPI, video: VideoItem, positionMs: Int64,
                     buffer: SabrBufferSettings) async {
        let service = SabrService(api: api)
        playbackService = service
        do {
            guard let id = VideoAddress.youtubeID(video.url) else {
                throw SabrFailure.unsupported("kein YouTube-Video")
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
                throw SabrFailure.unsupported("Kein geeigneter Hardwaredecoder/Audioformat gefunden. Softwaredecoding ist standardmäßig ausgeschaltet.")
            }
            selection = choice
            selectionDescription = choice.description
            hardwareDecoder = HardwareVideoDecoder(display: videoLayer, allowSoftware: allowSoftware)
            hardwareDecoder?.onFailure = { [weak self] message in
                self?.failure = message
                self?.stop()
            }
            state = "SABR-Sitzung …"
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
            state = "Wiedergabe fehlgeschlagen"
        }
    }

    private func consume(service: SabrService, videoId: String,
                         choice: SabrSelection, positionMs start: Int64,
                         buffer: SabrBufferSettings) async throws {
        var nextTime = start
        var audioInit = Data()
        var videoInit = Data()
        var audioInitLocation = ""
        var videoInitLocation = ""
        var seen = Set<String>()
        var freshAttempts = 0
        var coverage = SabrPlaybackCoverage(audioItag: choice.audio.itag,
                                            videoItag: choice.video.itag, positionMs: start)
        while !Task.isCancelled {
            let response: SabrWindow
            do {
                response = try await service.window(sessionId: sessionId, selection: choice,
                                                    generation: generation, positionMs: nextTime,
                                                    ranges: coverage.requestRanges(
                                                        retainFromMs: max(0, Int64(playbackSeconds() * 1_000)
                                                                        - Int64(buffer.backMilliseconds))
                                                    ),
                                                    buffer: buffer)
            } catch SabrFailure.expired {
                guard freshAttempts < 2 else { throw SabrFailure.expired }
                freshAttempts += 1
                let renewed = try await service.start(videoId: videoId, selection: choice, positionMs: nextTime)
                sessionId = renewed.sessionId
                generation = renewed.generation
                seen.removeAll()
                coverage = SabrPlaybackCoverage(audioItag: choice.audio.itag,
                                                videoItag: choice.video.itag,
                                                positionMs: nextTime)
                prefetchTask?.cancel()
                let expiredCache = segmentCache
                segmentCache = SabrFragmentCache(maxMiB: buffer.cacheMiB)
                if let expiredCache { Task { await expiredCache.clear() } }
                audioInitLocation = ""
                videoInitLocation = ""
                continue
            }
            if let ms = response.durationMs { durationMs = ms }
            // Start the shared clock before feeding samples: queued renderers would otherwise
            // hit backpressure while the clock is still stopped.
            if !isInitialized {
                synchronizer.setRate(1, time: CMTime(value: start, timescale: 1000))
                isInitialized = true
                isPlaying = true
            }
            guard let audio = response.audio, let videoTrack = response.video else {
                throw SabrFailure.invalidResponse("SABR audio/video missing")
            }
            if audioInitLocation != audio.initUrl {
                audioInit = try await service.fragmentData(audio.initUrl, sessionId: sessionId,
                                                           itag: choice.audio.itag, generation: generation)
                audioInitLocation = audio.initUrl
            }
            if videoInitLocation != videoTrack.initUrl {
                videoInit = try await service.fragmentData(videoTrack.initUrl, sessionId: sessionId,
                                                           itag: choice.video.itag, generation: generation)
                videoInitLocation = videoTrack.initUrl
            }
            // Fill the compressed-data disk cache independently of decoder
            // backpressure, without exceeding two simultaneous segment fetches.
            // Server SABR windows may cap the requested 180 s of forward buffering.
            prefetchTask?.cancel()
            if let cache = segmentCache {
                let refs = audio.segments.map { segment in
                    SabrMediaReference(url: segment.url, itag: choice.audio.itag,
                                       startMs: segment.startMs, durationMs: segment.durationMs)
                } + videoTrack.segments.map { segment in
                    SabrMediaReference(url: segment.url, itag: choice.video.itag,
                                       startMs: segment.startMs, durationMs: segment.durationMs)
                }
                let sid = sessionId
                let gen = generation
                prefetchTask = Task { [weak self] in
                    let through = await cache.prefetch(refs, service: service,
                                                       sessionId: sid, generation: gen)
                    if !Task.isCancelled {
                        self?.cachedThroughMs = max(self?.cachedThroughMs ?? 0, through)
                        self?.diskCacheBytes = await cache.bytesInUse
                    }
                }
            }

            // Request order by media timeline; audio/video are interleaved in the render queue.
            let count = max(audio.segments.count, videoTrack.segments.count)
            for index in 0..<count {
                try Task.checkCancellation()
                if index < audio.segments.count {
                    let fragment = audio.segments[index]
                    let key = "a:\(fragment.url)"
                    if seen.insert(key).inserted {
                        state = isInitialized ? "Wiedergabe läuft" : "Lade Audio …"
                        let bytes: Data
                        if let cache = segmentCache {
                            let sid = sessionId
                            let gen = generation
                            let ref = fragment.url
                            bytes = try await cache.data(for: ref) {
                                try await service.fragmentData(ref, sessionId: sid,
                                                               itag: choice.audio.itag, generation: gen)
                            }
                        } else {
                            bytes = try await service.fragmentData(fragment.url, sessionId: sessionId,
                                                                  itag: choice.audio.itag, generation: generation)
                        }
                        let samples = try await FragmentedMP4Reader.compressedSamples(
                            initialization: audioInit, fragment: bytes, mediaType: .audio)
                        try await enqueue(samples, audio: true)
                        try coverage.acceptAudio(fragment)
                    }
                }
                if index < videoTrack.segments.count {
                    let fragment = videoTrack.segments[index]
                    let key = "v:\(fragment.url)"
                    if seen.insert(key).inserted {
                        state = isInitialized ? "Wiedergabe läuft" : "Lade Video …"
                        let bytes: Data
                        if let cache = segmentCache {
                            let sid = sessionId
                            let gen = generation
                            let ref = fragment.url
                            bytes = try await cache.data(for: ref) {
                                try await service.fragmentData(ref, sessionId: sid,
                                                               itag: choice.video.itag, generation: gen)
                            }
                        } else {
                            bytes = try await service.fragmentData(fragment.url, sessionId: sessionId,
                                                                  itag: choice.video.itag, generation: generation)
                        }
                        let samples = try await FragmentedMP4Reader.compressedSamples(
                            initialization: videoInit, fragment: bytes, mediaType: .video)
                        try await enqueue(samples, audio: false)
                        try coverage.acceptVideo(fragment)
                    }
                }
                if !isInitialized && index > 0 {
                    synchronizer.setRate(1, time: CMTime(value: start, timescale: 1000))
                    isInitialized = true
                    isPlaying = true
                }
            }
            if !isInitialized {
                synchronizer.setRate(1, time: CMTime(value: start, timescale: 1000))
                isInitialized = true
                isPlaying = true
            }
            let synchronizedEnd = coverage.safeEndMs
            if response.endOfStream == true && synchronizedEnd >= (response.durationMs ?? synchronizedEnd) {
                state = "Ende des Videos"
                return
            }
            if synchronizedEnd <= nextTime {
                throw SabrFailure.invalidResponse("SABR window not advancing")
            }
            nextTime = synchronizedEnd
            positionMs = nextTime
            state = "Wiedergabe läuft"
            // Make sure requests don't race ahead of playback and consume the full video.
            while !Task.isCancelled && nextTime > Int64(CMTimeGetSeconds(synchronizer.currentTime()) * 1000) + 25_000 {
                try await Task.sleep(nanoseconds: 150_000_000)
            }
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
                }
            )
            .ignoresSafeArea()

            if let failure = engine.failure {
                VStack(spacing: 22) {
                    Text("SABR-Wiedergabe fehlgeschlagen").font(.largeTitle)
                    Text(failure).multilineTextAlignment(.center)
                    Button("Erneut versuchen") {
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
                                Text("Cache \(engine.diskCacheBytes / 1_048_576) MiB")
                                    .font(.caption).foregroundStyle(.white.opacity(0.8))
                                let aheadSeconds = max(0, Double(engine.cachedThroughMs) / 1_000
                                                       - engine.playbackSeconds())
                                Text("Vorgeladen \(Int(aheadSeconds)) s")
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
                        HStack(spacing: 36) {
                            Button { skip(-1) } label: {
                                Label("\(skipSeconds) s", systemImage: "gobackward")
                            }
                            Button {
                                engine.togglePause()
                                reveal()
                            } label: {
                                Label(engine.isPlaying ? "Pause" : "Fortsetzen",
                                      systemImage: engine.isPlaying ? "pause.fill" : "play.fill")
                            }
                            Button { skip(1) } label: {
                                Label("\(skipSeconds) s", systemImage: "goforward")
                            }
                        }
                        .buttonStyle(.bordered)
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
