import Foundation

/// Holds a small amount of compressed startup media until both audio and
/// video tracks are available. SABR track segment boundaries are independent;
/// requiring the first audio and video segments at the same index is invalid.
struct SabrStartupAccumulator<Sample> {
    private(set) var audio: [Sample] = []
    private(set) var video: [Sample] = []
    let maxSamplesPerTrack: Int

    init(maxSamplesPerTrack: Int = 8_192) {
        self.maxSamplesPerTrack = max(1, maxSamplesPerTrack)
    }

    mutating func append(audio nextAudio: [Sample], video nextVideo: [Sample])
        throws -> (audio: [Sample], video: [Sample])? {
        guard nextAudio.count <= maxSamplesPerTrack - audio.count,
              nextVideo.count <= maxSamplesPerTrack - video.count else {
            throw SabrFailure.invalidResponse(
                "SABR startup track data exceeded bounded pre-roll"
            )
        }
        audio.append(contentsOf: nextAudio)
        video.append(contentsOf: nextVideo)
        guard !audio.isEmpty, !video.isEmpty else { return nil }
        let result = (audio: audio, video: video)
        audio.removeAll(keepingCapacity: false)
        video.removeAll(keepingCapacity: false)
        return result
    }
}
