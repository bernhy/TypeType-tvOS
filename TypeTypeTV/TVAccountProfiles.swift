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
        // Replace credentials for the same user ID only, never a family
        // member's saved account. Restore any existing record on write error.
        var previousQuery = key
        previousQuery[kSecReturnAttributes as String] = true
        previousQuery[kSecReturnData as String] = true
        var previousResult: CFTypeRef?
        let previous = SecItemCopyMatching(previousQuery as CFDictionary, &previousResult)
            == errSecSuccess ? previousResult as? [String: Any] : nil
        SecItemDelete(key as CFDictionary)
        if SecItemAdd(item as CFDictionary, nil) == errSecSuccess { return true }
        if let previous,
           let oldData = previous[kSecValueData as String] as? Data {
            var restore = key
            restore[kSecValueData as String] = oldData
            restore[kSecAttrLabel as String] = previous[kSecAttrLabel as String] ?? identity.id
            restore[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            SecItemAdd(restore as CFDictionary, nil)
        }
        return false
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
        save(selectedToken, for: origin)
        if token(for: origin) != selectedToken {
            if let previousToken {
                save(previousToken, for: origin)
                saveDisplayIdentifier(previousLabel, for: origin)
            }
            return false
        }
        saveDisplayIdentifier(account.label, for: origin)
        return true
    }

    /// Forget one signed-in user locally. Other household profiles survive.
    func forget(_ userID: String, for origin: URL) {
        let key: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.profileService,
            kSecAttrAccount as String: Self.profileKey(origin: origin, userID: userID)
        ]
        SecItemDelete(key as CFDictionary)
    }
}
