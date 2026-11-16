/// Reports real renderer data headroom (not the larger downloaded SABR cache).
/// A healthy cache can coexist with audio/video starvation at the renderer.
enum SabrRendererHeadroom {
    static let criticalMilliseconds: Int64 = 120

    static func shouldReport(audioAheadMs: Int64, videoAheadMs: Int64,
                             running: Bool, buffering: Bool) -> Bool {
        running && !buffering &&
            (audioAheadMs <= criticalMilliseconds ||
             videoAheadMs <= criticalMilliseconds)
    }
}
