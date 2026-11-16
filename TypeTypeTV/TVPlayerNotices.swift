import SwiftUI

/// Player notices are independent of SponsorBlock and one another. Insertion
/// is newest-first, pushing earlier notifications down until their OWN expiry.
struct TVPlayerNotice: Identifiable, Equatable {
    let id: UUID
    let text: String
}

struct TVPlayerNoticeStack {
    private(set) var items: [TVPlayerNotice] = []

    @discardableResult
    mutating func push(_ text: String) -> UUID {
        let id = UUID()
        items.insert(TVPlayerNotice(id: id, text: text), at: 0)
        return id
    }

    mutating func dismiss(_ id: UUID) {
        items.removeAll { $0.id == id }
    }
}

enum TVPlayerNoticePolicy {
    static let settingsKey = "typetype.playerNoticeSeconds"
    static let defaultSeconds = 10
    static let choices = [10, 15, 20, 30, 45, 60]

    static func seconds(_ selected: Int) -> Int {
        selected <= 0 ? defaultSeconds : max(10, min(120, selected))
    }
}

/// Appearance intentionally resembles the existing SponsorBlock capsule.
/// No focus, buttons, timers or input handlers live in the presentation.
struct TVPlayerNoticeView: View {
    let notice: TVPlayerNotice

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: "info.circle")
                .font(.system(size: 18))
                .foregroundStyle(.white.opacity(0.85))
                .accessibilityHidden(true)

            Text(notice.text)
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(.white)
                .fixedSize(horizontal: false, vertical: true)
                .multilineTextAlignment(.leading)
                .lineLimit(4)
        }
        .padding(.horizontal, 17)
        .padding(.vertical, 13)
        .frame(maxWidth: 620, alignment: .leading)
        .background(.black.opacity(0.65),
                    in: RoundedRectangle(cornerRadius: 22))
        .overlay(RoundedRectangle(cornerRadius: 22)
            .strokeBorder(.white.opacity(0.15), lineWidth: 1))
        .background {
            RoundedRectangle(cornerRadius: 22)
                .fill(.clear)
                .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 22))
        }
        .allowsHitTesting(false)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("player-notice")
    }
}

/// A user-selected representation has its own bounded, resolution-first
/// fallback policy. A decoder failure switches immediately; transient SABR
/// errors are allowed to exhaust consume()/retryTransient() first.
enum SabrManualQualityFallbackPolicy {
    static func shouldTryNext(error: Error, initialized: Bool,
                              currentIndex: Int, candidateCount: Int) -> Bool {
        guard !initialized, currentIndex >= 0,
              currentIndex + 1 < candidateCount,
              !(error is CancellationError) else { return false }

        guard let failure = error as? SabrFailure else { return false }
        switch failure {
        case .unsupported, .expired, .stalled:
            return true
        case .invalidResponse(let detail):
            let message = detail.lowercased()
            return message.contains("segment window") ||
                message.contains("compressed") ||
                message.contains("mp4") ||
                message.contains("media sample")
        case .server(let status, _):
            // A service denied to the account cannot be fixed by a codec.
            return status == 408 || status == 410 || status == 425 ||
                (500...599).contains(status)
        case .throttled, .unavailable, .stopped:
            return false
        }
    }

    /// Keep logs useful without ever emitting upstream terminalError text,
    /// playback URLs, or authentication/session data.
    static func diagnosticCode(for error: Error) -> String {
        guard let failure = error as? SabrFailure else {
            return error is CancellationError ? "cancelled" : "other-error"
        }
        switch failure {
        case .unsupported(let text):
            if text.contains("VideoToolbox") { return "decoder-session" }
            if text.contains("compressed") || text.contains("Native fMP4") { return "compressed-unsupported" }
            return "unsupported"
        case .invalidResponse(let text):
            if text.contains("sample timing") { return "sample-timing" }
            if text.contains("noncontiguous native timestamps") { return "native-timestamps" }
            if text.contains("segment window timed out") { return "window-timeout" }
            if text.contains("SABR window stopped advancing") { return "window-stalled" }
            if text.contains("SABR segment gap") { return "segment-gap" }
            if text.contains("SABR sample") { return "sample-invalid" }
            return "invalid-response-other"
        case .expired: return "session-expired"
        case .stalled: return "stalled"
        case .server(let status, _): return "http-\(status)"
        case .throttled: return "throttled"
        case .unavailable: return "unavailable"
        case .stopped: return "stopped"
        }
    }

    static func reasonKey(for error: Error) -> String {
        guard let failure = error as? SabrFailure else {
            return "player.formatErrorGeneral"
        }
        switch failure {
        case .unsupported(let description):
            if description.contains("VideoToolbox") ||
                description.lowercased().contains("decoder") {
                return "player.formatErrorDecoder"
            }
            return "player.formatErrorUnsupported"
        case .expired: return "player.formatErrorSession"
        case .stalled, .invalidResponse: return "player.formatErrorMedia"
        case .server: return "player.formatErrorServer"
        case .throttled: return "player.formatErrorThrottled"
        case .unavailable: return "player.formatErrorUnavailable"
        case .stopped: return "player.formatErrorGeneral"
        }
    }
}
