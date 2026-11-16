import Foundation

/// Plan bounded SABR media downloads in *per-track sequence order*.
///
/// The server's advertised startMs can run backwards (or overlap) between
/// consecutive media segments. Sorting every URL by startMs alone can then
/// request segment N+1 before N on the same track. This matters because the
/// SABR pump can reposition for each pending request.
///
/// Keep a cursor for each itag and interleave only the next eligible segment
/// of each track by its approximate playback time. Batch size remains two so
/// the existing cache/backpressure limits are unchanged.
enum SabrPrefetchOrder {
    static func batches(_ references: [SabrMediaReference]) -> [[SabrMediaReference]] {
        guard !references.isEmpty else { return [] }
        var tracks = Dictionary(grouping: references, by: \.itag)
        for itag in tracks.keys {
            guard let items = tracks[itag] else { continue }
            let fullySequenced = items.allSatisfy {
                SabrSequenceOrder.sequence($0.url) != nil
            }
            tracks[itag] = items.sorted { left, right in
                if fullySequenced {
                    let a = SabrSequenceOrder.sequence(left.url)!
                    let b = SabrSequenceOrder.sequence(right.url)!
                    if a != b { return a < b }
                }
                if left.startMs != right.startMs { return left.startMs < right.startMs }
                return left.url < right.url
            }
        }

        var cursors: [Int: Int] = [:]
        var remaining = references.count
        var result: [[SabrMediaReference]] = []
        while remaining > 0 {
            var batch: [SabrMediaReference] = []
            for _ in 0..<min(2, remaining) {
                let heads = tracks.keys.sorted().compactMap { itag -> SabrMediaReference? in
                    guard let items = tracks[itag] else { return nil }
                    let index = cursors[itag] ?? 0
                    return index < items.count ? items[index] : nil
                }
                guard let next = heads.min(by: {
                    if $0.startMs != $1.startMs { return $0.startMs < $1.startMs }
                    if $0.itag != $1.itag { return $0.itag < $1.itag }
                    return $0.url < $1.url
                }) else {
                    // Each iteration consumes one of the source references.
                    return result
                }
                batch.append(next)
                cursors[next.itag, default: 0] += 1
                remaining -= 1
            }
            result.append(batch)
        }
        return result
    }
}
