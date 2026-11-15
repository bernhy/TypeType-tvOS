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

    /// Audio fragments sometimes contain only a few compressed buffers, each
    /// spanning roughly three seconds. Strict PTS interleaving waits for many
    /// video frames before submitting the next audio buffer; backpressure on
    /// the video renderer can then cause an audible audio underrun even when
    /// both media fragments are already cached.
    ///
    /// Feed the next *already available* audio buffer slightly early when the
    /// audio renderer is ready and its queued headroom is under 1.5 seconds.
    /// The shared AVSampleBufferRenderSynchronizer still presents it at its
    /// original timestamp. Both tracks retain their own original decode order.
    /// Never jump over a large timestamp gap or change startup/paused behavior.
    static func next(
        audioSeconds: Double?, videoSeconds: Double?,
        playbackSeconds: Double, queuedAudioEndSeconds: Double,
        audioRendererReady: Bool, playbackRunning: Bool
    ) -> Track? {
        let chronological = next(audioSeconds: audioSeconds, videoSeconds: videoSeconds)
        guard playbackRunning, audioRendererReady,
              let audioSeconds, let videoSeconds,
              audioSeconds.isFinite, videoSeconds.isFinite,
              playbackSeconds.isFinite, queuedAudioEndSeconds.isFinite,
              queuedAudioEndSeconds - playbackSeconds < 1.5,
              audioSeconds - playbackSeconds <= 2.0,
              audioSeconds - videoSeconds <= 1.5 else {
            return chronological
        }
        return .audio
    }
}
