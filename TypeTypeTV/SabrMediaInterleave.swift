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
}
