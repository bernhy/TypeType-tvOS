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
                    description == "SABR window stopped advancing"
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
