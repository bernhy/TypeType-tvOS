import Foundation

/// Extract ISO BMFF timebase evidence. A tfdt box contains decode time,
/// not necessarily the presentation time of the first B-frame.
enum SabrMP4NativeTiming {
    static func decodeStartMs(initialization: Data, fragment: Data) -> Int64? {
        guard let mdhd = payload(in: initialization, path: ["moov", "trak", "mdia", "mdhd"]),
              let tfdt = payload(in: fragment, path: ["moof", "traf", "tfdt"]),
              mdhd.lowerBound < initialization.count, tfdt.lowerBound < fragment.count
        else { return nil }
        let mdhdVersion = initialization[mdhd.lowerBound]
        let scaleOffset: Int
        switch mdhdVersion {
        case 0: scaleOffset = 12
        case 1: scaleOffset = 20
        default: return nil
        }
        guard let scale = unsigned(initialization, at: mdhd.lowerBound + scaleOffset,
                                   length: 4, within: mdhd), scale > 0 else { return nil }
        let tfdtVersion = fragment[tfdt.lowerBound]
        let decodeLength: Int
        switch tfdtVersion {
        case 0: decodeLength = 4
        case 1: decodeLength = 8
        default: return nil
        }
        guard let ticks = unsigned(fragment, at: tfdt.lowerBound + 4,
                                   length: decodeLength, within: tfdt) else { return nil }
        let seconds = ticks / scale
        guard seconds < UInt64(Int64.max / 1_000) else { return nil }
        let milliseconds = seconds * 1_000 + (ticks % scale) * 1_000 / scale
        guard milliseconds <= 7 * 24 * 60 * 60 * 1_000 else { return nil }
        return Int64(milliseconds)
    }

    private static func unsigned(_ data: Data, at start: Int, length: Int,
                                 within bounds: Range<Int>) -> UInt64? {
        guard length > 0, length <= 8, start >= bounds.lowerBound,
              start <= bounds.upperBound - length else { return nil }
        var value: UInt64 = 0
        for index in start..<(start + length) {
            value = (value << 8) | UInt64(data[index])
        }
        return value
    }

    /// Skip mdat payloads rather than scanning potentially large media data.
    private static func payload(in data: Data, path: [String]) -> Range<Int>? {
        var bounds = 0..<data.count
        for target in path {
            var offset = bounds.lowerBound
            var next: Range<Int>?
            while offset < bounds.upperBound {
                let remaining = bounds.upperBound - offset
                guard remaining >= 8,
                      let shortSize = unsigned(data, at: offset, length: 4, within: bounds),
                      let typeBytes = String(bytes: data[(offset + 4)..<(offset + 8)], encoding: .ascii)
                else { return nil }
                var headerLength = 8
                var size = shortSize
                if shortSize == 1 {
                    guard let extended = unsigned(data, at: offset + 8, length: 8, within: bounds) else { return nil }
                    headerLength = 16
                    size = extended
                } else if shortSize == 0 {
                    size = UInt64(remaining)
                }
                guard size >= UInt64(headerLength), size <= UInt64(remaining) else { return nil }
                let end = offset + Int(size)
                if typeBytes == target {
                    next = (offset + headerLength)..<end
                    break
                }
                offset = end
            }
            guard let found = next else { return nil }
            bounds = found
        }
        return bounds
    }
}

/// Do not splice media on an assumption. A native-time correction is permitted
/// only after several adjacent fragments establish the same timebase and the
/// previous *actual* samples end at the proposed start. Missing sequences fail.
struct SabrNativeTimelineResolver {
    struct Decision {
        let startMs: Int64
        let corrected: Bool
        let predictedMs: Int64?
    }

    private struct Previous {
        let sequence: Int
        let metadataStartMs: Int64
        let decodeStartMs: Int64
        let resolvedStartMs: Int64
        var actualEndMs: Int64?
    }
    private var previous: Previous?
    private var matchedDeltas = 0

    var lastActualEndMs: Int64? { previous?.actualEndMs }

    mutating func resolve(sequence: Int?, metadataStartMs: Int64,
                          decodeStartMs: Int64?) -> Decision {
        guard let sequence, sequence > 0,
              metadataStartMs >= 0, let decodeStartMs, decodeStartMs >= 0 else {
            previous = nil
            matchedDeltas = 0
            return Decision(startMs: metadataStartMs, corrected: false, predictedMs: nil)
        }
        var start = metadataStartMs
        var predicted: Int64?
        var corrected = false
        if let last = previous, last.sequence < Int.max,
           sequence == last.sequence + 1 {
            let nativeDelta = decodeStartMs - last.decodeStartMs
            let metadataDelta = metadataStartMs - last.metadataStartMs
            if nativeDelta > 0, nativeDelta <= 120_000,
               last.resolvedStartMs <= Int64.max - nativeDelta {
                let expected = last.resolvedStartMs + nativeDelta
                predicted = expected
                let difference = metadataStartMs - expected
                // Require proof from independent sample PTS/durations,
                // not just a disagreement between two metadata sources.
                if matchedDeltas >= 2,
                   abs(difference) >= 450,
                   abs(difference) <= 8_000,
                   let actualEnd = last.actualEndMs,
                   abs(expected - actualEnd) <= 250 {
                    start = expected
                    corrected = true
                }
                if abs(metadataDelta - nativeDelta) <= 250 {
                    matchedDeltas = min(4, matchedDeltas + 1)
                } else if !corrected {
                    matchedDeltas = 0
                }
            } else {
                matchedDeltas = 0
            }
        } else {
            matchedDeltas = 0
        }
        previous = Previous(sequence: sequence, metadataStartMs: metadataStartMs,
                            decodeStartMs: decodeStartMs, resolvedStartMs: start,
                            actualEndMs: nil)
        return Decision(startMs: start, corrected: corrected, predictedMs: predicted)
    }

    mutating func recordActualEndMs(_ end: Int64?) {
        guard let end, end >= 0, var current = previous else { return }
        current.actualEndMs = end
        previous = current
    }
}
