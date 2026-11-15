import Foundation

/// Select samples by PTS across media tracks without reordering the original
/// decode order inside either audio or video.
enum SabrMediaInterleave {
    enum Track: Equatable { case audio, video }

    static func next(audioSeconds: Double?, videoSeconds: Double?) -> Track? {
        switch (audioSeconds, videoSeconds) {
        case (nil, nil): return nil
        case (_?, nil): return .audio
        case (nil, _?): return .video
        case (let a?, let v?):
            if !a.isFinite { return .audio }
            if !v.isFinite { return .video }
            return a <= v ? .audio : .video
        }
    }

    /// Small, reversible follow-up experiment AFTER the verified AAC priming
    /// repair. A ready 3-second AAC sample can safely be submitted slightly
    /// before the next video frame when the already queued audio is about to
    /// fall below ~1.2 seconds. AVSampleBufferRenderSynchronizer preserves PTS.
    /// No clock jump, silence insertion, codec conversion or sample reordering.
    static func next(
        audioSeconds: Double?, videoSeconds: Double?,
        playbackSeconds: Double, queuedAudioEndSeconds: Double,
        audioRendererReady: Bool, playbackRunning: Bool
    ) -> Track? {
        let normal = next(audioSeconds: audioSeconds, videoSeconds: videoSeconds)
        guard normal == .video,
              playbackRunning, audioRendererReady,
              let a = audioSeconds, let v = videoSeconds,
              a.isFinite, v.isFinite, playbackSeconds.isFinite,
              queuedAudioEndSeconds.isFinite,
              queuedAudioEndSeconds - playbackSeconds < 1.2,
              a >= playbackSeconds - 0.05,
              a - playbackSeconds <= 1.25,
              a - v <= 1.25 else { return normal }
        return .audio
    }
}
