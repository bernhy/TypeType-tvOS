import Foundation

/// Initial HLS lookup and HLS manifest renewal share the same finite retry
/// budget. 429/503/504 responses can carry Retry-After from TypeType Server,
/// so honor the server's delay instead of hammering the instance.
struct TVStreamRecoveryPolicy {
    let maxAttempts = 4
    let maxRecoverySeconds: TimeInterval = 130

    func delayNanoseconds(error: Error, attempt: Int,
                          elapsedSeconds: TimeInterval) -> UInt64? {
        guard attempt < maxAttempts, elapsedSeconds < maxRecoverySeconds,
              !(error is CancellationError) else { return nil }

        let fallback = min(8, 1 << max(0, min(3, attempt - 1)))
        let seconds: Int
        if let failure = error as? TypeTypeError {
            switch failure {
            case .retryAfter(_, _, let wait):
                seconds = max(fallback, wait)
            case .http(let status, _)
                where status == 408 || status == 425 || status == 429 ||
                    (500...599).contains(status):
                seconds = fallback
            default:
                return nil
            }
        } else if let network = error as? URLError {
            switch network.code {
            case .timedOut, .networkConnectionLost, .notConnectedToInternet,
                 .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed:
                seconds = fallback
            default:
                return nil
            }
        } else {
            return nil
        }
        guard elapsedSeconds + Double(seconds) <= maxRecoverySeconds
        else { return nil }
        return UInt64(seconds) * 1_000_000_000
    }
}
