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

    let videoLayer = AVSampleBufferDisplayLayer()
    private let audioRenderer = AVSampleBufferAudioRenderer()
    private let synchronizer = AVSampleBufferRenderSynchronizer()
    private var running: Task<Void, Never>?
    private var sessionId = ""
    private var generation: Int64 = 0
    private var selection: SabrSelection?
    private var playbackPositionMs: Int64 = 0
    private var isInitialized = false

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
        running = Task { await run(api: api, video: video, positionMs: positionMs) }
    }

    func stop() {
        running?.cancel()
        running = nil
        synchronizer.setRate(0, time: synchronizer.currentTime())
        videoLayer.flushAndRemoveImage()
        audioRenderer.flush()
        isInitialized = false
        isPlaying = false
        sessionId = ""
    }

    func togglePause() {
        guard isInitialized else { return }
        let rate: Float = isPlaying ? 0 : 1
        synchronizer.setRate(rate, time: synchronizer.currentTime())
        isPlaying.toggle()
        state = isPlaying ? "Wiedergabe läuft" : "Pausiert"
    }

    private func run(api: TypeTypeAPI, video: VideoItem, positionMs: Int64) async {
        let service = SabrService(api: api)
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
            state = "SABR-Sitzung …"
            let session = try await service.start(videoId: id, selection: choice, positionMs: positionMs)
            guard !session.sessionId.isEmpty else { throw SabrFailure.invalidResponse("sessionId") }
            sessionId = session.sessionId
            generation = session.generation
            try await consume(service: service, videoId: id, choice: choice, positionMs: positionMs)
        } catch is CancellationError {
            return
        } catch {
            failure = error.localizedDescription
            isPlaying = false
            state = "Wiedergabe fehlgeschlagen"
        }
    }

    private func consume(service: SabrService, videoId: String,
                         choice: SabrSelection, positionMs start: Int64) async throws {
        var nextTime = start
        var audioInit = Data()
        var videoInit = Data()
        var audioInitLocation = ""
        var videoInitLocation = ""
        var seen = Set<String>()
        var freshAttempts = 0
        while !Task.isCancelled {
            let response: SabrWindow
            do {
                response = try await service.window(sessionId: sessionId, selection: choice,
                                                    generation: generation, positionMs: nextTime)
            } catch SabrFailure.expired {
                guard freshAttempts < 2 else { throw SabrFailure.expired }
                freshAttempts += 1
                let renewed = try await service.start(videoId: videoId, selection: choice, positionMs: nextTime)
                sessionId = renewed.sessionId
                generation = renewed.generation
                seen.removeAll()
                audioInitLocation = ""
                videoInitLocation = ""
                continue
            }
            if let ms = response.durationMs { durationMs = ms }
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
            var newestEnd = nextTime
            // Request order by media timeline; audio/video are interleaved in the render queue.
            let count = max(audio.segments.count, videoTrack.segments.count)
            for index in 0..<count {
                try Task.checkCancellation()
                if index < audio.segments.count {
                    let fragment = audio.segments[index]
                    let key = "a:\(fragment.url)"
                    if seen.insert(key).inserted {
                        state = isInitialized ? "Wiedergabe läuft" : "Lade Audio …"
                        let bytes = try await service.fragmentData(fragment.url, sessionId: sessionId,
                                                              itag: choice.audio.itag, generation: generation)
                        let samples = try await FragmentedMP4Reader.compressedSamples(
                            initialization: audioInit, fragment: bytes, mediaType: .audio)
                        try await enqueue(samples, audio: true)
                        newestEnd = max(newestEnd, fragment.startMs + fragment.durationMs)
                    }
                }
                if index < videoTrack.segments.count {
                    let fragment = videoTrack.segments[index]
                    let key = "v:\(fragment.url)"
                    if seen.insert(key).inserted {
                        state = isInitialized ? "Wiedergabe läuft" : "Lade Video …"
                        let bytes = try await service.fragmentData(fragment.url, sessionId: sessionId,
                                                              itag: choice.video.itag, generation: generation)
                        let samples = try await FragmentedMP4Reader.compressedSamples(
                            initialization: videoInit, fragment: bytes, mediaType: .video)
                        try await enqueue(samples, audio: false)
                        newestEnd = max(newestEnd, fragment.startMs + fragment.durationMs)
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
            if response.endOfStream == true && newestEnd >= (response.durationMs ?? newestEnd) {
                state = "Ende des Videos"
                return
            }
            if newestEnd <= nextTime {
                throw SabrFailure.invalidResponse("SABR window not advancing")
            }
            nextTime = newestEnd
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
                videoLayer.enqueue(sample)
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

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            SabrVideoSurface(displayLayer: engine.videoLayer)
                .ignoresSafeArea()
            VStack {
                Spacer()
                if let failure = engine.failure {
                    VStack(spacing: 20) {
                        Text("SABR-Wiedergabe fehlgeschlagen").font(.title)
                        Text(failure).font(.body).multilineTextAlignment(.center)
                        Button("Erneut versuchen") { engine.start(api: api, video: video) }
                    }
                    .padding(40)
                    .background(.black.opacity(0.85))
                } else {
                    HStack {
                        Text(engine.state)
                        Spacer()
                        Text(engine.selectionDescription)
                        Button(engine.isPlaying ? "Pause" : "Fortsetzen") { engine.togglePause() }
                    }
                    .font(.callout)
                    .padding(24)
                    .background(.black.opacity(0.7))
                }
            }
            .padding(40)
        }
        .task { engine.start(api: api, video: video) }
        .onDisappear { engine.stop() }
    }
}
