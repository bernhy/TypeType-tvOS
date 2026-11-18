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

/// Retry a transient transport error immediately in the network producer,
/// while the native A/V renderer continues consuming its existing buffer.
/// Only replay requests that are idempotent under the SABR server protocol:
/// media GET, position, prefetch and segment-window polling. A fresh playback
/// POST, a seek or a release must never be replayed here.
struct SabrEarlyTransportRetryPolicy {
    let delaysMilliseconds: [UInt64]

    init(delaysMilliseconds: [UInt64] = [350, 700, 1_400, 2_800, 4_000]) {
        self.delaysMilliseconds = delaysMilliseconds
    }

    static func route(method: String, path: String) -> String? {
        if method == "GET", path == "segment" { return "segment" }
        let parts = path.split(separator: "/")
        guard method == "POST", parts.count == 4,
              parts[0] == "sabr", parts[1] == "playback",
              !parts[2].isEmpty else { return nil }
        switch parts[3] {
        case "position": return "position"
        case "prefetch": return "prefetch"
        case "segments": return "segments"
        default: return nil
        }
    }

    func delayNanoseconds(method: String, path: String, retries: Int,
                          status: Int? = nil, error: Error? = nil) -> UInt64? {
        guard Self.route(method: method, path: path) != nil,
              delaysMilliseconds.indices.contains(retries) else { return nil }
        if let status {
            guard status == 408 || status == 425 ||
                    [502, 503, 504].contains(status) else { return nil }
        } else if let url = error as? URLError {
            switch url.code {
            case .timedOut, .networkConnectionLost, .notConnectedToInternet,
                 .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed:
                break
            default: return nil
            }
        } else {
            return nil
        }
        return delaysMilliseconds[retries] * 1_000_000
    }
}

/// The network producer can prepare a new SABR session while media from the
/// old session is still playing. Only the common queued A/V time is safe to
/// use as an approximate prewarm anchor, never one track's high-water mark.
enum SabrEarlySessionPrewarmPolicy {
    static let minimumBufferedMs: Int64 = 3_000

    /// Decoder queues are deliberately shallow: a long, contiguous A/V
    /// fragment cache may exist even when <3s has been submitted to either
    /// renderer. Use the later of the two *shared* coverage frontiers.
    /// cachedThroughMs must be calculated for both selected tracks at the
    /// current playhead, not from the last requested server window.
    static func startPosition(playheadMs: Int64,
                              audioQueuedEndMs: Int64,
                              videoQueuedEndMs: Int64,
                              cachedThroughMs: Int64 = 0) -> Int64? {
        let rendererEnd = min(audioQueuedEndMs, videoQueuedEndMs)
        let end = max(rendererEnd, cachedThroughMs)
        guard playheadMs >= 0, end - playheadMs >= minimumBufferedMs else {
            return nil
        }
        return max(playheadMs, end - 2_000)
    }

    static func shouldPrepare(for error: Error) -> Bool {
        SabrRecoveryPolicy().canRetry(
            error, completedAttempts: 1, elapsedSeconds: 0
        )
    }
}

/// A producer-only session swap is safe only while a verified A/V cache
/// still covers the current playback position. Media integrity errors and
/// throttling are left to the existing bounded restart/fallback path.
enum SabrRecoverySplicePolicy {
    static let minimumCachedAheadMs: Int64 = 8_000
    // Bound repeated producer-only switches during successive server restarts.
    static let maximumSessionsPerIncident = 4

    /// Log only stable, sanitized error categories, never session-specific URLs,
    /// bearer tokens or untrusted server error bodies.
    static func errorKind(_ error: Error) -> String {
        if let failure = error as? SabrFailure {
            switch failure {
            case .server: return "http"
            case .expired: return "expired"
            case .throttled: return "throttled"
            case .stalled: return "stalled"
            case .unsupported: return "unsupported"
            case .unavailable: return "unavailable"
            case .stopped: return "stopped"
            case .invalidResponse(let description):
                switch description {
                case "SABR segment gap before next media sample": return "segment-gap"
                case "SABR window stopped advancing": return "window-stalled"
                case "segment window timed out": return "window-timeout"
                case "SABR recovered media has noncontiguous native timestamps":
                    return "native-time-gap"
                default: return "invalid-response"
                }
            }
        }
        return error is CancellationError ? "cancelled" :
            (error is URLError ? "network" : "other")
    }

    static func httpStatus(_ error: Error) -> Int {
        guard let failure = error as? SabrFailure else { return 0 }
        switch failure {
        case .server(let status, _), .throttled(let status, _, _):
            return status
        default: return 0
        }
    }

    static func canReSplice(error: Error, initialized: Bool,
                            playheadMs: Int64, cachedThroughMs: Int64,
                            sessionsSoFar: Int) -> Bool {
        sessionsSoFar >= 1 &&
            sessionsSoFar < maximumSessionsPerIncident &&
            shouldSwitch(error: error, initialized: initialized,
                         playheadMs: playheadMs, cachedThroughMs: cachedThroughMs)
    }

    static func shouldSwitch(error: Error, initialized: Bool,
                             playheadMs: Int64, cachedThroughMs: Int64) -> Bool {
        guard initialized, playheadMs >= 0, cachedThroughMs >= playheadMs,
              cachedThroughMs - playheadMs >= minimumCachedAheadMs else {
            return false
        }
        if let failure = error as? SabrFailure {
            switch failure {
            // The unrelated ~one-minute attestation/expired condition
            // stays on the original recovery path, not this experiment.
            case .server(let status, _):
                return [404, 410, 502, 503, 504].contains(status)
            default: return false
            }
        }
        if let url = error as? URLError {
            switch url.code {
            case .timedOut, .networkConnectionLost, .notConnectedToInternet,
                 .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed:
                return true
            default: return false
            }
        }
        return false
    }

    /// Trim *each* track at its own last parsed/submitted sample frontier.
    /// Sharing a single A/V cutoff would duplicate audio or drop video
    /// whenever the fragment lengths differ.
    static func clipBeforeMs(queuedEndMs: Int64, parsedEndMs: Int64?,
                             presentationStartMs: Int64) -> Int64 {
        max(0, max(presentationStartMs,
                   max(queuedEndMs, parsedEndMs ?? 0)))
    }
}

/// Fail closed before joining two SABR sessions in a single native decoder.
/// Metadata alone is not evidence of playable future A/V; the producer also
/// verifies compressed sample timestamps and a real video RAP below.
enum SabrSplicePreflightPolicy {
    static let minimumForwardMs: Int64 = 250
    static let maximumAudioStartDelayMs: Int64 = 250
    static let maximumRAPLookbehindMs: Int64 = 10_000

    static func segment(_ segments: [SabrFragment], covering targetMs: Int64)
        -> SabrFragment? {
        guard targetMs >= 0,
              targetMs <= Int64.max - minimumForwardMs else { return nil }
        return segments.filter {
            $0.startMs >= 0 && $0.durationMs > 0 &&
            $0.startMs <= Int64.max - $0.durationMs &&
            $0.startMs <= targetMs &&
            $0.startMs + $0.durationMs >= targetMs + minimumForwardMs
        }.max { $0.startMs < $1.startMs }
    }

    static func accepts(targetMs: Int64, audioFirstMs: Int64?,
                        audioEndMs: Int64?, videoRAPMs: Int64?,
                        videoEndMs: Int64?) -> Bool {
        guard targetMs >= 0, targetMs <= Int64.max - minimumForwardMs,
              let audioFirstMs, let audioEndMs,
              let videoRAPMs, let videoEndMs,
              audioFirstMs <= targetMs + maximumAudioStartDelayMs,
              audioEndMs >= targetMs + minimumForwardMs,
              videoRAPMs <= targetMs,
              videoRAPMs >= max(0, targetMs - maximumRAPLookbehindMs),
              videoEndMs >= targetMs + minimumForwardMs else { return false }
        return true
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

/// A SABR seek may reuse a server session only while preserving the exact
/// video/audio representation and language track. A changed representation
/// must use a new playback session and its fresh initialization metadata.
enum SabrSessionReusePolicy {
    static func matches(priorVideoItag: Int, priorAudioItag: Int,
                        priorAudioTrackId: String?,
                        selectedVideoItag: Int, selectedAudioItag: Int,
                        selectedAudioTrackId: String?) -> Bool {
        priorVideoItag == selectedVideoItag &&
            priorAudioItag == selectedAudioItag &&
            priorAudioTrackId == selectedAudioTrackId
    }
}

/// A cold resume can be rejected on a particular video representation
/// (for example a high-frame-rate AVC itag) even after a fresh upstream
/// token. Try exactly one alternative *automatic* track at the same saved
/// position. Do not silently override an explicitly selected quality or
/// switch tracks in the middle of a successfully started stream.
enum SabrResumeTrackFallbackPolicy {
    static let maximumAlternateAttempts = 1

    static func shouldTryNext(error: Error, positionMs: Int64, initialized: Bool,
                              currentIndex: Int, candidateCount: Int,
                              manuallySelected: Bool) -> Bool {
        guard positionMs > 0, !initialized, !manuallySelected,
              currentIndex >= 0,
              currentIndex < maximumAlternateAttempts,
              currentIndex + 1 < candidateCount else { return false }
        guard case SabrFailure.expired = error else { return false }
        return true
    }

    /// First retry with a fresh session, then with refreshed upstream player
    /// info. If a *third* cold-start attempt fails with the same terminal
    /// expiry, changing representation is more useful than repeating an
    /// identical forward seek for the rest of the 120-second recovery budget.
    static func shouldEscalateToAlternateTrack(error: Error, positionMs: Int64,
                                               initialized: Bool, attempt: Int) -> Bool {
        guard positionMs > 0, !initialized, attempt >= 3 else { return false }
        guard case SabrFailure.expired = error else { return false }
        return true
    }
}

/// A new playback token alone cannot fix a VOD demand repeatedly stuck at the
/// same timestamp. Escalate once per incident to a refreshed upstream session.
/// This is intentionally *not* triggered by a later, unrelated buffering stall.
enum SabrRecoveryRefreshPolicy {
    static let sameStallToleranceMs: Int64 = 2_000

    static func shouldRefresh(
        attempt: Int,
        currentFailurePositionMs: Int64,
        previousFailurePositionMs: Int64?,
        alreadyRefreshed: Bool
    ) -> Bool {
        guard attempt >= 2, !alreadyRefreshed,
              let previousFailurePositionMs,
              currentFailurePositionMs >= 0, previousFailurePositionMs >= 0
        else { return false }
        return max(currentFailurePositionMs, previousFailurePositionMs) -
            min(currentFailurePositionMs, previousFailurePositionMs) <= sameStallToleranceMs
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
