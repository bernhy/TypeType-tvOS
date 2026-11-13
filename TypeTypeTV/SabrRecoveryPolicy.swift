import Foundation

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

    func canRetry(_ error: Error, completedAttempts: Int,
                  elapsedSeconds: TimeInterval) -> Bool {
        guard completedAttempts < maxAttempts,
              elapsedSeconds < maxRecoverySeconds else { return false }
        if error is CancellationError { return false }
        if let failure = error as? SabrFailure {
            switch failure {
            case .expired, .stalled: return true
            case .server(let code, _):
                return code == 404 || code == 408 || code == 410 ||
                    code == 425 || code == 429 || (500...599).contains(code)
            case .invalidResponse(let description):
                return description == "segment window timed out" ||
                    description == "SABR window stopped advancing"
            case .unsupported, .stopped: return false
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
