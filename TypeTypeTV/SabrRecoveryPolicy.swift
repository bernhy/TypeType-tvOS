import Foundation

/// Retry-After may be an integer delay or a standard HTTP-date. Never turn a
/// long server backoff into repeated short requests. The recovery budget
/// decides whether playback should keep retrying at all.
enum SabrRetryAfter {
    static func seconds(_ header: String?, now: Date = Date()) -> Int? {
        guard let text = header?.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty else { return nil }
        if let value = Int(text), value >= 0 { return min(value, 86_400) }
        let format = DateFormatter()
        format.locale = Locale(identifier: "en_US_POSIX")
        format.timeZone = TimeZone(secondsFromGMT: 0)
        format.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        guard let date = format.date(from: text) else { return nil }
        return min(86_400, max(0, Int(ceil(date.timeIntervalSince(now)))))
    }
}

/// Bounded recovery patterned after Android's stream reconnect policy.
/// HTTP client/credential failures and malformed media stay terminal;
/// network outages, expired SABR sessions and renderer stalls are retried.
struct SabrRecoveryPolicy {
    let maxAttempts = 8
    let maxRecoverySeconds: TimeInterval = 120

    func delayNanoseconds(attempt: Int) -> UInt64 {
        let seconds = min(8, 1 << max(0, min(3, attempt - 1)))
        return UInt64(seconds) * 1_000_000_000
    }

    func delayNanoseconds(for error: Error, attempt: Int) -> UInt64 {
        let defaultDelay = delayNanoseconds(attempt: attempt)
        if case let SabrFailure.throttled(_, _, wait) = error {
            return max(defaultDelay, UInt64(wait) * 1_000_000_000)
        }
        return defaultDelay
    }

    func canRetry(_ error: Error, completedAttempts: Int,
                  elapsedSeconds: TimeInterval) -> Bool {
        guard completedAttempts < maxAttempts,
              elapsedSeconds < maxRecoverySeconds else { return false }
        if error is CancellationError { return false }
        if let failure = error as? SabrFailure {
            switch failure {
            case .expired, .stalled: return true
            case .throttled(_, _, let wait):
                return elapsedSeconds + Double(wait) <= maxRecoverySeconds
            case .server(let code, _):
                return code == 404 || code == 408 || code == 410 ||
                    code == 425 || code == 429 || (500...599).contains(code)
            case .invalidResponse(let description):
                return description == "segment window timed out" ||
                    description == "SABR window stopped advancing" ||
                    description == "SABR segment gap before next media sample"
            case .unsupported, .unavailable, .stopped: return false
            }
        }
        if let network = error as? URLError {
            switch network.code {
            case .timedOut, .networkConnectionLost, .notConnectedToInternet,
                 .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed,
                 .internationalRoamingOff, .dataNotAllowed:
                return true
            default: return false
            }
        }
        return false
    }
}

/// An uninterrupted movie is not a recovery incident. Count failures
/// from the first error, not from the time playback started. A stream that
/// played at least 30 seconds after the last restart re-arms the bounded
/// recovery budget for a later, unrelated interruption.
struct SabrRecoveryBudget {
    static let stablePlaybackMs: Int64 = 30_000
    private(set) var incidentStartedAt: Date?
    private(set) var failures = 0

    mutating func evaluate(_ error: Error, playbackAdvancedMs: Int64,
                           now: Date = Date(),
                           policy: SabrRecoveryPolicy = SabrRecoveryPolicy())
    -> (attempt: Int, allowed: Bool) {
        if playbackAdvancedMs >= Self.stablePlaybackMs {
            incidentStartedAt = nil
            failures = 0
        }
        if incidentStartedAt == nil { incidentStartedAt = now }
        failures += 1
        let elapsed = max(0, now.timeIntervalSince(incidentStartedAt!))
        return (failures, policy.canRetry(error,
                                          completedAttempts: failures,
                                          elapsedSeconds: elapsed))
    }
}

/// The TypeType server sends a free-form terminalError alongside
/// recoveryAction=retry_fresh_session. Keep the detailed error out of device
/// logs because upstream messages may embed URLs, visitor identifiers or
/// tokens. Categorize it to identify server-side failures safely.
enum SabrServerRecoveryDiagnostics {
    static func category(_ terminalError: String?) -> String {
        guard let error = terminalError?.lowercased(), !error.isEmpty
        else { return "unspecified" }
        if error.contains("attestation") || error.contains("protected no-media") {
            return "attestation"
        }
        if error.contains("binding") || error.contains("po token") ||
            error.contains("potoken") {
            return "token-binding"
        }
        if error.contains("unauthorized") || error.contains("http 403") ||
            error.contains("http 401") {
            return "upstream-auth"
        }
        if error.contains("demand stalled") || error.contains("no progress") {
            return "demand-stalled"
        }
        if error.contains("timeout") || error.contains("timed out") {
            return "upstream-timeout"
        }
        if error.contains("expected ump response") || error.contains("ump") {
            return "upstream-ump"
        }
        if error.contains("eof") || error.contains("connection") {
            return "upstream-transport"
        }
        if error.contains("initialization") { return "initialization" }
        return "other"
    }

    static func state(_ status: String?) -> String {
        switch status?.lowercased() {
        case "idle": return "idle"
        case "ready": return "ready"
        case "requesting": return "requesting"
        case "repositioning": return "repositioning"
        case "throttled": return "throttled"
        case "terminal": return "terminal"
        case "network_failed": return "network-failed"
        default: return "other"
        }
    }

    static func action(_ action: String?) -> String {
        if action == "retry_fresh_session" { return "retry-fresh-session" }
        return action == nil ? "none" : "other"
    }
}

/// A bootstrap 401/403 may request a guest session only when the client has
/// no existing user credentials. Replacing an account token with a guest
/// token would silently sign the user out and hide account history/playlists.
enum SabrGuestAuthPolicy {
    static func mayStoreGuestToken(existingToken: String?) -> Bool {
        existingToken == nil || existingToken?.isEmpty == true
    }

    static func shouldAttemptGuest(responseCode: Int, existingToken: String?) -> Bool {
        (responseCode == 401 || responseCode == 403) &&
            mayStoreGuestToken(existingToken: existingToken)
    }
}
