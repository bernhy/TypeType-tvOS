import Foundation
import Security

/// A TypeType Server account saved on this specific Apple TV. Account IDs are
/// server-scoped; no passwords or refresh cookies are stored.
struct TVSavedAccount: Identifiable, Hashable {
    let id: String
    let label: String
}

extension TypeTypeCredentials {
    private static var profileService: String { "org.typetype.tvOS.account-profiles" }

    /// The server URL is part of each Keychain account key so two TypeType
    /// instances may use identical user IDs without sharing credentials.
    static func profileKey(origin: URL, userID: String) -> String {
        origin.absoluteString + "|user:" + userID
    }

    func savedAccounts(for origin: URL) -> [TVSavedAccount] {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.profileService,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let rows = result as? [[String: Any]] else { return [] }
        let prefix = Self.profileKey(origin: origin, userID: "")
        return rows.compactMap { row -> TVSavedAccount? in
            guard let key = row[kSecAttrAccount as String] as? String,
                  key.hasPrefix(prefix) else { return nil }
            let userID = String(key.dropFirst(prefix.count))
            guard !userID.isEmpty else { return nil }
            let label = (row[kSecAttrLabel as String] as? String)
                .flatMap { $0.isEmpty ? nil : $0 } ?? userID
            return TVSavedAccount(id: userID, label: label)
        }.sorted {
            $0.label.localizedStandardCompare($1.label) == .orderedAscending
        }
    }

    /// Save a separately switchable account without disturbing the other users.
    /// Called only after the server has verified the bearer token via /auth/me.
    @discardableResult
    func remember(_ identity: TVAccountIdentity, token value: String,
                  displayIdentifier: String?, for origin: URL) -> Bool {
        guard !identity.isGuest, !identity.id.isEmpty, !value.isEmpty else {
            return false
        }
        let label = identity.visibleName
            ?? displayIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines)
            ?? identity.id
        let account = Self.profileKey(origin: origin, userID: identity.id)
        let key: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.profileService,
            kSecAttrAccount as String: account
        ]
        var item = key
        item[kSecValueData as String] = Data(value.utf8)
        item[kSecAttrLabel as String] = label
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        // In-place updates preserve the old credential if the keychain write
        // fails. Delete-before-insert could discard a working household login.
        let updated = SecItemUpdate(key as CFDictionary,
            [kSecValueData as String: Data(value.utf8),
             kSecAttrLabel as String: label] as CFDictionary)
        let result = updated == errSecItemNotFound
            ? SecItemAdd(item as CFDictionary, nil) : updated
        if result != errSecSuccess {
            NSLog("TypeType Keychain profile write failed OSStatus=%d", result)
            return false
        }
        // Household profile switching must carry its own rotating refresh
        // credential, not merely the one-hour access JWT.
        if let refresh = refreshToken(for: origin) {
            return saveRefreshToken(refresh, for: origin, userID: identity.id)
        }
        return true
    }

    /// Migrate a legacy single-user login into the multi-account Keychain the
    /// first time an up-to-date client successfully resolves /auth/me.
    @discardableResult
    func rememberActive(_ identity: TVAccountIdentity, for origin: URL) -> Bool {
        guard let current = token(for: origin), !identity.isGuest else { return false }
        return remember(identity, token: current,
                        displayIdentifier: displayIdentifier(for: origin),
                        for: origin)
    }

    /// Keep a previously saved household profile synchronized with the
    /// rotated access token. Never implicitly create profiles from JWT claims.
    @discardableResult
    func updateSavedProfileAccessToken(_ token: String, for origin: URL,
                                       userID: String) -> Bool {
        guard !token.isEmpty, !userID.isEmpty else { return false }
        let key: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.profileService,
            kSecAttrAccount as String: Self.profileKey(origin: origin, userID: userID)
        ]
        return SecItemUpdate(key as CFDictionary, [
            kSecValueData as String: Data(token.utf8)
        ] as CFDictionary) == errSecSuccess
    }

    /// Make one saved user active using the legacy active-token slot, so all
    /// existing TypeType requests continue to use the chosen user.
    func activate(_ account: TVSavedAccount, for origin: URL) -> Bool {
        let key: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.profileService,
            kSecAttrAccount as String:
                Self.profileKey(origin: origin, userID: account.id),
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(key as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data,
              let selectedToken = String(data: data, encoding: .utf8),
              !selectedToken.isEmpty else { return false }
        let previousToken = token(for: origin)
        let previousLabel = displayIdentifier(for: origin)
        let previousRefresh = refreshToken(for: origin)
        let selectedRefresh = profileRefreshToken(account.id, for: origin)

        func rollback() {
            if let previousToken {
                save(previousToken, for: origin)
                saveDisplayIdentifier(previousLabel, for: origin)
            } else {
                clear(for: origin)
            }
            if let previousRefresh {
                saveRefreshToken(previousRefresh, for: origin)
            } else {
                clearRefreshToken(for: origin)
            }
        }

        guard save(selectedToken, for: origin) else { return false }
        if let selectedRefresh {
            guard saveRefreshToken(selectedRefresh, for: origin) else {
                rollback()
                return false
            }
        } else {
            // Never let the previous household user's refresh secret renew
            // the newly selected account's access token.
            clearRefreshToken(for: origin)
        }
        saveDisplayIdentifier(account.label, for: origin)
        return true
    }

    /// Forget one signed-in user locally. Other household profiles survive.
    @discardableResult
    func forget(_ userID: String, for origin: URL) -> Bool {
        let key: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.profileService,
            kSecAttrAccount as String: Self.profileKey(origin: origin, userID: userID)
        ]
        let status = SecItemDelete(key as CFDictionary)
        if status == errSecSuccess || status == errSecItemNotFound {
            clearRefreshToken(for: origin, userID: userID)
            return true
        }
        return false
    }
}
