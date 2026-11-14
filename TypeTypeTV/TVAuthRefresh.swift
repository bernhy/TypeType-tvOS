import Foundation
import Security

/// Refresh credentials are separate from the one-hour access JWT and never
/// written to UserDefaults or diagnostics. The server returns them as an
/// HttpOnly Set-Cookie on password/device login and every refresh.
enum TVAuthCookie {
    static let name = "refresh_token"

    static func token(from response: HTTPURLResponse, for origin: URL) -> String? {
        var fields: [String: String] = [:]
        for (key, value) in response.allHeaderFields {
            guard let key = key as? String, let value = value as? String else { continue }
            fields[key] = value
        }
        let url = response.url ?? origin
        return HTTPCookie.cookies(withResponseHeaderFields: fields, for: url)
            .first(where: { $0.name == name && !$0.value.isEmpty })?.value
    }
}

extension TypeTypeCredentials {
    private static let activeRefreshService = "org.typetype.tvOS.auth-refresh"
    private static let profileRefreshService = "org.typetype.tvOS.account-profile-refresh"

    private func refreshKey(origin: URL, userID: String? = nil) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: userID == nil
                ? Self.activeRefreshService : Self.profileRefreshService,
            kSecAttrAccount as String: userID.map {
                Self.profileKey(origin: origin, userID: $0)
            } ?? origin.absoluteString
        ]
    }

    private func readRefresh(origin: URL, userID: String? = nil) -> String? {
        var query = refreshKey(origin: origin, userID: userID)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var value: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &value) == errSecSuccess,
              let data = value as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func refreshToken(for origin: URL) -> String? {
        readRefresh(origin: origin)
    }

    func profileRefreshToken(_ userID: String, for origin: URL) -> String? {
        readRefresh(origin: origin, userID: userID)
    }

    @discardableResult
    func saveRefreshToken(_ token: String, for origin: URL, userID: String? = nil) -> Bool {
        guard !token.isEmpty else { return false }
        let key = refreshKey(origin: origin, userID: userID)
        let data = Data(token.utf8)
        let updated = SecItemUpdate(key as CFDictionary,
                                   [kSecValueData as String: data] as CFDictionary)
        let result: OSStatus
        if updated == errSecItemNotFound {
            var item = key
            item[kSecValueData as String] = data
            item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            result = SecItemAdd(item as CFDictionary, nil)
        } else {
            result = updated
        }
        if result != errSecSuccess {
            NSLog("TypeType Keychain refresh write failed OSStatus=%d", result)
        }
        return result == errSecSuccess
    }

    func clearRefreshToken(for origin: URL, userID: String? = nil) {
        SecItemDelete(refreshKey(origin: origin, userID: userID) as CFDictionary)
    }
}

private struct TVRefreshRequest: Encodable {
    let token: String
}

private struct TVRefreshReply: Decodable {
    let accessToken: String
}

/// Reads an unsigned JWT claim for cache-key bookkeeping only. This never
/// confers trust or authenticates the user; the server verifies signatures.
enum TVJWTClaims {
    static func userID(from token: String) -> String? {
        let parts = token.split(separator: ".")
        guard parts.count == 3 else { return nil }
        var value = String(parts[1]).replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        value += String(repeating: "=", count: (4 - value.count % 4) % 4)
        guard let data = Data(base64Encoded: value),
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return nil
        }
        return json["sub"] as? String
    }
}

/// A shared single-flight refresh prevents simultaneous /auth/me, history,
/// thumbnails and SABR requests from rotating one refresh credential several
/// times. A stale in-flight result never overwrites a manually switched user.
actor TVAuthRefreshCoordinator {
    static let shared = TVAuthRefreshCoordinator()
    private var pending: [String: Task<String?, Error>] = [:]

    func refresh(origin: URL, session: URLSession, failedAccessToken: String) async throws -> String? {
        let credentials = TypeTypeCredentials.shared
        guard let current = credentials.token(for: origin), !current.isEmpty else { return nil }
        if current != failedAccessToken { return current }

        let scope = origin.absoluteString
        if let existing = pending[scope] { return try await existing.value }
        let task = Task<String?, Error> {
            guard let refreshToken = credentials.refreshToken(for: origin) else {
                return nil
            }
            var request = URLRequest(url: origin.appendingPathComponent("api/auth/refresh"))
            request.httpMethod = "POST"
            request.httpShouldHandleCookies = false // explicit body wins over session cookies
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            request.setValue("TypeTypeTV-tvOS/0.1", forHTTPHeaderField: "User-Agent")
            request.httpBody = try JSONEncoder().encode(TVRefreshRequest(token: refreshToken))
            let (data, result) = try await session.data(for: request)
            guard let response = result as? HTTPURLResponse else {
                throw TypeTypeError.unexpectedResponse
            }
            guard response.statusCode == 200 else {
                NSLog("TypeType AUTH refresh returned HTTP %d", response.statusCode)
                return nil
            }
            let reply = try JSONDecoder().decode(TVRefreshReply.self, from: data)
            guard !reply.accessToken.isEmpty,
                  let rotated = TVAuthCookie.token(from: response, for: origin) else {
                // Never keep a new access token without its rotated refresh
                // credential: doing so breaks the next one-hour renewal.
                return nil
            }
            // A user might have switched profile while the request was in flight.
            guard credentials.token(for: origin) == failedAccessToken,
                  credentials.refreshToken(for: origin) == refreshToken else {
                return credentials.token(for: origin)
            }
            let previousLabel = credentials.displayIdentifier(for: origin)
            guard credentials.saveRefreshToken(rotated, for: origin),
                  credentials.save(reply.accessToken, for: origin) else {
                return nil
            }
            if let previousLabel {
                credentials.saveDisplayIdentifier(previousLabel, for: origin)
            }
            // A renewed credential must also update the saved household
            // profile; otherwise switching back restores an expired JWT.
            if let identity = TVJWTClaims.userID(from: reply.accessToken),
               !identity.hasPrefix("guest:") {
                _ = credentials.saveRefreshToken(rotated, for: origin, userID: identity)
                _ = credentials.updateSavedProfileAccessToken(
                    reply.accessToken, for: origin, userID: identity
                )
            }
            return reply.accessToken
        }
        pending[scope] = task
        defer { pending[scope] = nil }
        return try await task.value
    }
}
