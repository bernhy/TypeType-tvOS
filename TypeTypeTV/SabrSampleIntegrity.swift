import Foundation
import CoreMedia

/// A gap in compressed sample timestamps is stronger evidence than a gap in
/// server window metadata. Sort by PTS rather than decode order, since AVC
/// B-frames legitimately have out-of-order presentation timestamps.
struct SabrMediaSpan: Equatable {
    let startMs: Int64
    let lengthMs: Int64
}

struct SabrMediaGap: Equatable {
    let startMs: Int64
    let lengthMs: Int64
}

struct SabrMediaIntegritySummary {
    let totalSamples: Int
    let sampleBytes: Int
    let invalidTimingSamples: Int
    let missingPayloadSamples: Int
    let largestGap: SabrMediaGap?
}

enum SabrSampleIntegrity {
    static func largestGap(in spans: [SabrMediaSpan]) -> SabrMediaGap? {
        let sorted = spans.filter {
            $0.startMs >= 0 && $0.lengthMs > 0 &&
                $0.startMs <= Int64.max - $0.lengthMs
        }.sorted {
            $0.startMs < $1.startMs
        }
        guard let first = sorted.first else { return nil }
        var coveredEnd = first.startMs + first.lengthMs
        var largest: SabrMediaGap?
        for span in sorted.dropFirst() {
            if span.startMs > coveredEnd {
                let gap = SabrMediaGap(
                    startMs: coveredEnd, lengthMs: span.startMs - coveredEnd
                )
                if (largest?.lengthMs ?? 0) < gap.lengthMs { largest = gap }
            }
            coveredEnd = max(coveredEnd, span.startMs + span.lengthMs)
        }
        return largest
    }

    static func coincident(_ audio: SabrMediaGap, _ video: SabrMediaGap,
                           toleranceMs: Int64 = 750) -> Bool {
        abs(Double(audio.startMs) - Double(video.startMs)) <=
            Double(max(0, toleranceMs))
    }

    /// Inspect compressed CMSampleBuffers, without modifying, reordering or
    /// dropping a single sample. Byte checks are diagnostic: a CoreMedia
    /// format without a contiguous CMBlockBuffer can be legitimate on some
    /// devices, so avoid introducing a new playback failure solely for this.
    static func inspect(_ buffers: [CMSampleBuffer]) -> SabrMediaIntegritySummary {
        var spans: [SabrMediaSpan] = []
        var count = 0
        var totalBytes = 0
        var missingPayload = 0
        var invalidTiming = 0
        for sample in buffers {
            let sampleCount = CMSampleBufferGetNumSamples(sample)
            guard sampleCount > 0 else { continue }
            let available = CMSampleBufferGetDataBuffer(sample)
                .map { CMBlockBufferGetDataLength($0) } ?? 0
            var consumedBytes = 0
            for index in 0..<sampleCount {
                count += 1
                let size = CMSampleBufferGetSampleSize(sample, at: index)
                if size <= 0 || available == 0 ||
                    size > available - min(available, consumedBytes) {
                    missingPayload += 1
                } else {
                    consumedBytes += size
                    totalBytes = totalBytes > Int.max - size
                        ? Int.max : totalBytes + size
                }
                var timing = CMSampleTimingInfo()
                guard CMSampleBufferGetSampleTimingInfo(
                    sample, at: index, timingInfoOut: &timing
                ) == noErr else {
                    invalidTiming += 1
                    continue
                }
                let pts = CMTimeGetSeconds(timing.presentationTimeStamp)
                let duration = CMTimeGetSeconds(timing.duration)
                guard pts.isFinite, pts >= 0, pts <= 7 * 24 * 60 * 60,
                      duration.isFinite, duration > 0, duration < 60 else {
                    invalidTiming += 1
                    continue
                }
                spans.append(SabrMediaSpan(
                    startMs: Int64((pts * 1_000).rounded()),
                    lengthMs: max(1, Int64((duration * 1_000).rounded()))
                ))
            }
        }
        return SabrMediaIntegritySummary(
            totalSamples: count, sampleBytes: totalBytes,
            invalidTimingSamples: invalidTiming,
            missingPayloadSamples: missingPayload,
            largestGap: largestGap(in: spans)
        )
    }

    #if DEBUG
    static func logAnomalies(_ summary: SabrMediaIntegritySummary,
                             track: String, sequence: Int?,
                             fragmentBytes: Int, thresholdMs: Int64) {
        let gap = summary.largestGap
        guard summary.invalidTimingSamples > 0 ||
              summary.missingPayloadSamples > 0 ||
              (gap?.lengthMs ?? 0) >= thresholdMs else { return }
        NSLog("TypeType SABR MEDIA-INTEGRITY stage=demux track=%@ seq=%d fragmentBytes=%d samples=%d compressedBytes=%d invalidTiming=%d invalidPayload=%d largestGapMs=%lld gapStartMs=%lld",
              track, sequence ?? -1, fragmentBytes, summary.totalSamples,
              summary.sampleBytes, summary.invalidTimingSamples,
              summary.missingPayloadSamples, gap?.lengthMs ?? 0,
              gap?.startMs ?? -1)
    }
    #endif
}
