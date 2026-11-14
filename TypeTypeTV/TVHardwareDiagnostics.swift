import Foundation
import UIKit
import Combine
import CoreMedia
import VideoToolbox
import Darwin

/// Public tvOS APIs only. A codec-type capability check is not a test of
/// a specific bitstream profile, level, colour depth, or smooth 4K playback.
/// Bitstream verification happens when a real SABR video is decoded.
struct TVCodecProbe: Identifiable, Equatable {
    let name: String
    let codec: String
    let hardwareAvailable: Bool
    var id: String { codec }
}

struct TVDecoderAttempt: Equatable {
    let codec: String
    let resolution: String
    let status: Int32
    let hardwareUsed: Bool?
    let decodedFrame: Bool
    let timestamp: Date
}

/// Shared diagnostics from the same decoder paths actually used by playback.
/// This deliberately does not guess a marketed SoC name from the model ID.
@MainActor
final class TVHardwareDiagnostics: ObservableObject {
    static let shared = TVHardwareDiagnostics()

    @Published private(set) var probes: [TVCodecProbe] = []
    @Published private(set) var lastAttempt: TVDecoderAttempt?
    @Published private(set) var deviceIdentifier = ""
    @Published private(set) var deviceName = ""
    @Published private(set) var systemVersion = ""
    @Published private(set) var totalMemoryMiB: UInt64 = 0
    @Published private(set) var outputSize = ""

    private init() { refresh() }

    func refresh() {
        deviceIdentifier = Self.machineIdentifier()
        deviceName = UIDevice.current.model
        systemVersion = UIDevice.current.systemName + " " + UIDevice.current.systemVersion
        totalMemoryMiB = ProcessInfo.processInfo.physicalMemory / (1024 * 1024)
        // tvOS 26 no longer exposes a reliable global UIScreen.main.
        // Read the currently attached window scene's actual display instead.
        if let screen = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene }).first?.screen {
            let bounds = screen.nativeBounds
            outputSize = "\(Int(bounds.width)) × \(Int(bounds.height))"
        } else {
            outputSize = "–"
        }
        probes = [
            TVCodecProbe(name: "H.264 / AVC", codec: "avc1",
                         hardwareAvailable: HardwareCodec.supported("avc1")),
            TVCodecProbe(name: "H.265 / HEVC", codec: "hvc1",
                         hardwareAvailable: HardwareCodec.supported("hvc1")),
            TVCodecProbe(name: "VP9", codec: "vp09",
                         hardwareAvailable: HardwareCodec.supported("vp09")),
            TVCodecProbe(name: "AV1", codec: "av01",
                         hardwareAvailable: HardwareCodec.supported("av01"))
        ]
    }

    func recordDecoderSession(
        codec: CMVideoCodecType, width: Int32, height: Int32,
        status: OSStatus, hardwareUsed: Bool?
    ) {
        lastAttempt = TVDecoderAttempt(
            codec: Self.fourCCName(codec),
            resolution: "\(width) × \(height)",
            status: status,
            hardwareUsed: hardwareUsed,
            decodedFrame: false,
            timestamp: Date()
        )
    }

    func recordDecodedFrame() {
        guard var previous = lastAttempt else { return }
        previous = TVDecoderAttempt(
            codec: previous.codec,
            resolution: previous.resolution,
            status: previous.status,
            hardwareUsed: previous.hardwareUsed,
            decodedFrame: true,
            timestamp: previous.timestamp
        )
        lastAttempt = previous
    }

    private static func machineIdentifier() -> String {
        var info = utsname()
        guard uname(&info) == 0 else { return "unknown" }
        let byteCount = MemoryLayout.size(ofValue: info.machine)
        return withUnsafePointer(to: &info.machine) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: byteCount) {
                String(cString: $0)
            }
        }
    }

    private static func fourCCName(_ code: CMVideoCodecType) -> String {
        let parts: [UInt8] = [
            UInt8((code >> 24) & 0xff), UInt8((code >> 16) & 0xff),
            UInt8((code >> 8) & 0xff), UInt8(code & 0xff)
        ]
        return String(bytes: parts, encoding: .ascii) ?? String(code)
    }
}
