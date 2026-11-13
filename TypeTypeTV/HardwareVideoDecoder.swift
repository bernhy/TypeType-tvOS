import Foundation
import AVFoundation
import VideoToolbox
import CoreMedia
import CoreVideo

private final class DecodedFrameCollector: @unchecked Sendable {
    typealias Frame = (CVImageBuffer, CMTime, CMTime)
    private let lock = NSLock()
    private var values: [Frame] = []
    private var failure: OSStatus?

    func record(status: OSStatus, image: CVImageBuffer?, pts: CMTime, duration: CMTime) {
        lock.lock()
        defer { lock.unlock() }
        if status == noErr, let image {
            values.append((image, pts, duration))
        } else {
            failure = status
        }
    }

    func take() -> (frames: [Frame], error: OSStatus?) {
        lock.lock()
        defer { lock.unlock() }
        return (values, failure)
    }
}


// Enforce hardware decoding with VideoToolbox instead of depending on a
// sample-buffer renderer's undocumented hardware/software fallback behavior.
@MainActor
final class HardwareVideoDecoder {
    private var session: VTDecompressionSession?
    private var format: CMFormatDescription?
    private let display: AVSampleBufferDisplayLayer
    private let allowSoftware: Bool
    private var active = true
    var onFailure: ((String) -> Void)?

    init(display: AVSampleBufferDisplayLayer, allowSoftware: Bool) {
        self.display = display
        self.allowSoftware = allowSoftware
    }

    func invalidate() {
        active = false
        if let session {
            VTDecompressionSessionInvalidate(session)
            self.session = nil
        }
        format = nil
    }

    func decode(_ compressed: CMSampleBuffer) async throws {
        guard active else { throw SabrFailure.stopped }
        guard let description = CMSampleBufferGetFormatDescription(compressed) else {
            throw SabrFailure.invalidResponse("compressed sample without format description")
        }
        if session == nil || format.map({ !CMFormatDescriptionEqual($0, otherFormatDescription: description) }) == true {
            if let session { VTDecompressionSessionInvalidate(session) }
            session = nil
            format = description
            var created: VTDecompressionSession?
            let requirements: CFDictionary? = allowSoftware ? nil : [
                kVTVideoDecoderSpecification_RequireHardwareAcceleratedVideoDecoder as String: true
            ] as CFDictionary
            let result = VTDecompressionSessionCreate(
                allocator: kCFAllocatorDefault,
                formatDescription: description,
                decoderSpecification: requirements,
                imageBufferAttributes: nil,
                outputCallback: nil,
                decompressionSessionOut: &created
            )
            guard result == noErr, let created else {
                throw SabrFailure.unsupported("Hardwaredecoder für diesen Bitstream nicht verfügbar (VT \(result))")
            }
            session = created
        }

        guard let session else { throw SabrFailure.invalidResponse("VideoToolbox session") }
        // No async decode flag: the callback completes before the method returns.
        // This allows explicit backpressure, so 4K CVPixelBuffers cannot grow without bound.
        let collector = DecodedFrameCollector()
        let result = VTDecompressionSessionDecodeFrame(
            session, sampleBuffer: compressed, flags: [], infoFlagsOut: nil
        ) { status, _, image, pts, duration in
            collector.record(status: status, image: image, pts: pts, duration: duration)
        }
        let output = collector.take()
        guard result == noErr, output.error == nil else {
            throw SabrFailure.unsupported("VideoToolbox hardware decode error (\(output.error ?? result))")
        }
        for (image, pts, duration) in output.frames {
            try Task.checkCancellation()
            await present(image, pts: pts, duration: duration)
        }
    }

    private func present(_ image: CVImageBuffer, pts: CMTime, duration: CMTime) async {
        guard active else { return }
        var description: CMVideoFormatDescription?
        guard CMVideoFormatDescriptionCreateForImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: image,
            formatDescriptionOut: &description
        ) == noErr, let description else {
            onFailure?("Decoded pixel buffer has invalid format")
            return
        }
        var timing = CMSampleTimingInfo(
            duration: duration,
            presentationTimeStamp: pts,
            decodeTimeStamp: .invalid
        )
        var sample: CMSampleBuffer?
        guard CMSampleBufferCreateReadyWithImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: image,
            formatDescription: description,
            sampleTiming: &timing,
            sampleBufferOut: &sample
        ) == noErr, let sample else {
            onFailure?("Cannot enqueue decoded pixel buffer")
            return
        }
        while active && !display.isReadyForMoreMediaData {
            try? await Task.sleep(nanoseconds: 15_000_000)
        }
        if active { display.enqueue(sample) }
    }
}
