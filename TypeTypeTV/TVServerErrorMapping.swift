import Foundation

/// Typed, safe mapping of optional TypeType error JSON and HTTP diagnostics.
enum TVServerErrorMapping {
    static func decoded(_ data: Data) -> TVStreamProblem? {
        try? JSONDecoder().decode(TVStreamProblem.self, from: data)
    }

    private static let messageKeys: [String: String] = [
        "age_restricted": "apiError.ageRestricted",
        "geographic_restriction": "apiError.geographic",
        "members_only": "apiError.membersOnly",
        "paid_content": "apiError.paidContent",
        "private_content": "apiError.privateContent",
        "youtube_session_required": "apiError.youtubeSession",
        "youtube_session_rejected": "apiError.youtubeReconnect",
        "youtube_session_needs_reconnect": "apiError.youtubeReconnect",
        "live_not_started": "apiError.liveNotStarted",
        "scheduled_premiere": "apiError.liveNotStarted",
        "provider_rate_limited": "apiError.rateLimited",
        "provider_paced": "apiError.rateLimited",
        "provider_access_blocked": "apiError.providerBlocked",
        "upstream_timeout": "apiError.upstreamTimeout",
        "media_handle_unavailable": "apiError.temporary",
        "provider_data_missing": "apiError.temporary",
        "no_playable_streams": "apiError.noStreams",
        "content_unavailable": "player.videoUnavailable",
        "video_unavailable": "player.videoUnavailable",
        "sabr_content_unavailable": "player.videoUnavailable"
    ]

    static func safeRequestID(_ raw: String?) -> String? {
        guard let raw, raw.count <= 100, !raw.isEmpty,
              raw.range(of: "^[A-Za-z0-9_-]+$", options: .regularExpression) != nil
        else { return nil }
        return raw
    }

    static func displayedMessage(status: Int, route: String, problem: TVStreamProblem?,
                                 headerRequestID: String?) -> String {
        let code = problem?.code?.lowercased() ?? ""
        let title = messageKeys[code].map { TVL10n.value($0) } ??
                    TVL10n.formatted("error.http", status, route)
        let requestID = safeRequestID(headerRequestID) ??
                        safeRequestID(problem?.requestId)
        return requestID.map { title + " (ID: " + $0 + ")" } ?? title
    }

    static func retrySeconds(_ response: HTTPURLResponse,
                             problem: TVStreamProblem?) -> Int? {
        if let header = response.value(forHTTPHeaderField: "Retry-After"),
           let seconds = SabrRetryAfter.seconds(header) { return seconds }
        if let ms = problem?.retryAfterMs, ms > 0 {
            return max(1, min(3600, (ms + 999) / 1000))
        }
        return nil
    }

    static func apiError(data: Data, response: HTTPURLResponse,
                         route: String) -> TypeTypeError {
        let problem = decoded(data)
        let status = response.statusCode
        // A non-YouTube extractor's terminal 422/no_playable_streams is
        // permanent for this video. The same code during SABR setup may
        // recover with another session or codec and must remain retryable.
        let extractorUnavailable = status == 422 &&
            problem?.code == "no_playable_streams" && !route.contains("sabr")
        if [404, 410, 422].contains(status),
           problem?.isPermanentlyUnavailable == true || extractorUnavailable {
            return .videoUnavailable
        }
        if [429, 503, 504].contains(status),
           let wait = retrySeconds(response, problem: problem) {
            return .retryAfter(status, route, wait)
        }
        if problem?.code == nil,
           safeRequestID(response.value(forHTTPHeaderField: "X-Request-ID")) == nil,
           safeRequestID(problem?.requestId) == nil {
            return .http(status, route)
        }
        return .serverDetails(status, route, displayedMessage(
            status: status, route: route, problem: problem,
            headerRequestID: response.value(forHTTPHeaderField: "X-Request-ID")
        ))
    }

    static func sabrError(data: Data, response: HTTPURLResponse,
                          route: String) -> SabrFailure {
        let problem = decoded(data)
        let status = response.statusCode
        if [404, 410, 422].contains(status),
           problem?.isPermanentlyUnavailable == true {
            return .unavailable
        }
        if [429, 503, 504].contains(status),
           let wait = retrySeconds(response, problem: problem) {
            return .throttled(status, route, wait)
        }
        return .server(status, displayedMessage(
            status: status, route: route, problem: problem,
            headerRequestID: response.value(forHTTPHeaderField: "X-Request-ID")
        ))
    }

    static func httpStatus(_ error: Error) -> Int? {
        if case TypeTypeError.http(let status, _) = error { return status }
        if case TypeTypeError.serverDetails(let status, _, _) = error { return status }
        return nil
    }
}
