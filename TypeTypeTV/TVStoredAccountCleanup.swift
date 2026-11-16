import Foundation
import Security

/// Credentials from a *different* TypeType origin. A former server is not
/// necessarily unreachable or invalid, so do not call these "expired".
struct TVInactiveLogin: Identifiable, Hashable {
    let origin: URL
    let userID: String?
    let label: String

    var id: String {
        origin.absoluteString + (userID.map { "|profile:" + $0 } ?? "|legacy-active")
    }
}

struct TVInactiveServer: Identifiable, Hashable {
    let origin: URL
    let logins: [TVInactiveLogin]
    var id: String { origin.absoluteString }
}

/// Lists only TypeType's known generic-password services. Keychain values
/// (access/refresh tokens) are NEVER read while rendering the overview.
enum TVStoredAccountCleanup {
    private static let profileService = "org.typetype.tvOS.account-profiles"
    private static let profileRefreshService = "org.typetype.tvOS.account-profile-refresh"
    private static let activeServices = [
        "org.typetype.tvOS.auth",
        "org.typetype.tvOS.auth-refresh",
        "org.typetype.tvOS.account-identifier"
    ]
    private static let services = [profileService, profileRefreshService] + activeServices

    private struct Key: Hashable {
        let service: String
        let account: String
        let label: String?
    }

    enum Failure: Error {
        case keychain(OSStatus)
    }

    private static func storedKeys() throws -> [Key] {
        var found: [Key] = []
        for service in services {
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecReturnAttributes as String: true,
                kSecMatchLimit as String: kSecMatchLimitAll
            ]
            var result: CFTypeRef?
            let status = SecItemCopyMatching(query as CFDictionary, &result)
            if status == errSecItemNotFound { continue }
            guard status == errSecSuccess,
                  let rows = result as? [[String: Any]] else {
                throw Failure.keychain(status)
            }
            for row in rows {
                guard let account = row[kSecAttrAccount as String] as? String else {
                    continue
                }
                found.append(Key(
                    service: service, account: account,
                    label: row[kSecAttrLabel as String] as? String
                ))
            }
        }
        return found
    }

    /// Extract an exact origin from our profile key without using prefix
    /// comparisons (https://one.example must never match one.example.evil).
    private static func originAndProfile(_ item: Key) -> (URL, String?)? {
        let profiled = item.service == profileService ||
            item.service == profileRefreshService
        let rawOrigin: String
        var userID: String?
        if profiled {
            guard let marker = item.account.range(of: "|user:", options: .backwards)
            else { return nil }
            rawOrigin = String(item.account[..<marker.lowerBound])
            let suffix = String(item.account[marker.upperBound...])
            guard !suffix.isEmpty else { return nil }
            userID = suffix
        } else {
            rawOrigin = item.account
        }
        guard let scheme = URLComponents(string: rawOrigin)?.scheme,
              let mode = TVConnectionMode(rawValue: scheme),
              let origin = try? TVServerAddress.make(
                hostInput: rawOrigin, mode: mode
              ),
              origin.absoluteString == rawOrigin else { return nil }
        return (origin, userID)
    }

    static func inactiveServers(excluding currentOrigin: URL) throws -> [TVInactiveServer] {
        let credentials = TypeTypeCredentials.shared
        var profiles: [String: [String: String]] = [:]
        var origins: [String: URL] = [:]
        var activeOrigins = Set<String>()
        for item in try storedKeys() {
            guard let (origin, userID) = originAndProfile(item),
                  origin != currentOrigin else { continue }
            let key = origin.absoluteString
            origins[key] = origin
            if let userID {
                var rows = profiles[key] ?? [:]
                if item.service == profileService {
                    rows[userID] = item.label.flatMap {
                        $0.isEmpty ? nil : $0
                    } ?? userID
                } else if rows[userID] == nil {
                    // Even a refresh-only orphan must remain visible/deletable.
                    rows[userID] = userID
                }
                profiles[key] = rows
            } else {
                activeOrigins.insert(key)
            }
        }
        return origins.values.map { origin in
            let users = profiles[origin.absoluteString] ?? [:]
            var logins = users.map {
                TVInactiveLogin(origin: origin, userID: $0.key, label: $0.value)
            }
            if activeOrigins.contains(origin.absoluteString), users.isEmpty {
                // Older installations can have an active single-user slot
                // without a household profile. Do not read access tokens
                // merely to build a list of inactive server credentials.
                logins.append(TVInactiveLogin(
                    origin: origin, userID: nil,
                    label: credentials.displayIdentifier(for: origin) ??
                        TVL10n.value("accounts.inactiveLegacy")
                ))
            }
            logins.sort { $0.label.localizedStandardCompare($1.label) == .orderedAscending }
            return TVInactiveServer(origin: origin, logins: logins)
        }.sorted { $0.origin.absoluteString < $1.origin.absoluteString }
    }

    /// Local-only cleanup. The current origin is rejected even if called
    /// outside the UI, and certificate trust is a separate explicit setting.
    @discardableResult
    static func delete(_ origin: URL, excluding currentOrigin: URL) -> Bool {
        guard origin != currentOrigin, let keys = try? storedKeys() else { return false }
        var allSucceeded = true
        for key in keys {
            guard originAndProfile(key)?.0 == origin else { continue }
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: key.service,
                kSecAttrAccount as String: key.account
            ]
            let status = SecItemDelete(query as CFDictionary)
            if status != errSecSuccess && status != errSecItemNotFound {
                allSucceeded = false
            }
        }
        return allSucceeded
    }
}

enum TVInactiveLoginCheck: Equatable {
    case valid
    case renewed
    case signInRequired
    case serverUnavailable
    case storageFailure

    var titleKey: String {
        switch self {
        case .valid: return "accounts.inactiveValid"
        case .renewed: return "accounts.inactiveRenewed"
        case .signInRequired: return "accounts.inactiveSignInRequired"
        case .serverUnavailable: return "accounts.inactiveUnavailable"
        case .storageFailure: return "accounts.inactiveStorageFailure"
        }
    }
}

/// Only run after an explicit remote click. A refresh rotates the server
/// token, so the rotated pair MUST be stored in this same inactive profile.
/// Never activate an account or modify the currently connected server.
@MainActor
enum TVInactiveAccountChecker {
    private struct RefreshBody: Encodable { let token: String }
    private struct RefreshResponse: Decodable { let accessToken: String }

    private static func checkAccess(_ token: String, origin: URL,
                                    session: URLSession) async throws -> (Int, TVAccountIdentity?) {
        var request = URLRequest(url: origin.appendingPathComponent("api/auth/me"))
        request.timeoutInterval = 12
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.httpShouldHandleCookies = false
        let (bytes, result) = try await session.data(for: request)
        guard let http = result as? HTTPURLResponse else {
            return (0, nil)
        }
        if http.statusCode == 200 {
            return (200, try JSONDecoder().decode(TVAccountIdentity.self, from: bytes))
        }
        return (http.statusCode, nil)
    }

    static func check(_ login: TVInactiveLogin, currentOrigin: URL,
                      session suppliedSession: URLSession? = nil) async -> TVInactiveLoginCheck {
        guard login.origin != currentOrigin else { return .storageFailure }
        let origin = login.origin
        let store = TypeTypeCredentials.shared
        let token = login.userID.map { store.profileAccessToken($0, for: origin) }
            ?? store.token(for: origin)
        let refresh = login.userID.map { store.profileRefreshToken($0, for: origin) }
            ?? store.refreshToken(for: origin)
        let session = suppliedSession ?? TVNetwork.session(for: origin)

        do {
            if let token, !token.isEmpty {
                let (code, identity) = try await checkAccess(
                    token, origin: origin, session: session
                )
                if code == 200 {
                    if login.userID == nil || identity?.id == login.userID {
                        return .valid
                    }
                    return .signInRequired
                }
                guard code == 401 else { return .serverUnavailable }
            }
            guard let refresh, !refresh.isEmpty else { return .signInRequired }
            var request = URLRequest(url: origin.appendingPathComponent("api/auth/refresh"))
            request.httpMethod = "POST"
            request.timeoutInterval = 12
            request.httpShouldHandleCookies = false
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            request.httpBody = try JSONEncoder().encode(RefreshBody(token: refresh))
            let (data, result) = try await session.data(for: request)
            guard let response = result as? HTTPURLResponse else {
                return .serverUnavailable
            }
            if response.statusCode == 401 { return .signInRequired }
            guard response.statusCode == 200,
                  let renewed = try? JSONDecoder().decode(RefreshResponse.self, from: data),
                  !renewed.accessToken.isEmpty,
                  let rotated = TVAuthCookie.token(from: response, for: origin)
            else { return .serverUnavailable }
            if let userID = login.userID,
               TVJWTClaims.userID(from: renewed.accessToken) != userID {
                return .signInRequired
            }

            // Ensure the local selected account has not changed during I/O.
            let currentRefresh = login.userID.map {
                store.profileRefreshToken($0, for: origin)
            } ?? store.refreshToken(for: origin)
            guard currentRefresh == refresh else { return .storageFailure }

            // /auth/refresh ROTATES the server credential before this client
            // receives the reply. Persist the new refresh secret immediately:
            // if the following /auth/me verification times out, the prior
            // refresh secret would otherwise be irreversibly invalidated.
            let wasSelectedOnOldServer = login.userID != nil &&
                store.token(for: origin) == token &&
                store.refreshToken(for: origin) == refresh
            let previousDisplayName = store.displayIdentifier(for: origin)
            if let userID = login.userID {
                guard store.saveRefreshToken(rotated, for: origin, userID: userID)
                else { return .storageFailure }
                if wasSelectedOnOldServer {
                    guard store.saveRefreshToken(rotated, for: origin)
                    else { return .storageFailure }
                }
            } else {
                guard store.saveRefreshToken(rotated, for: origin)
                else { return .storageFailure }
            }

            let (checkedCode, identity) = try await checkAccess(
                renewed.accessToken, origin: origin, session: session
            )
            guard checkedCode == 200,
                  login.userID == nil || identity?.id == login.userID else {
                return .signInRequired
            }

            if let userID = login.userID {
                guard store.setProfileAccessToken(
                    renewed.accessToken, for: origin,
                    userID: userID, label: login.label
                ) else { return .storageFailure }
                if wasSelectedOnOldServer {
                    guard store.save(renewed.accessToken, for: origin)
                    else { return .storageFailure }
                    store.saveDisplayIdentifier(previousDisplayName, for: origin)
                }
            } else {
                guard store.save(renewed.accessToken, for: origin)
                else { return .storageFailure }
                store.saveDisplayIdentifier(previousDisplayName, for: origin)
            }
            return .renewed
        } catch {
            // DNS, timeout, TLS trust, redirects and HTTP parsing cannot be
            // interpreted as evidence of an expired account.
            return .serverUnavailable
        }
    }
}
