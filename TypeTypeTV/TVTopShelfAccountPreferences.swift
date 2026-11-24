import Foundation

/// A privacy opt-in kept locally on this Apple TV and scoped by server plus
/// verified household account ID. Never store account names, credentials or
/// raw server addresses in UserDefaults keys. No observable object or network.
struct TVTopShelfAccountPreferences {
    private static let keyPrefix = "typetype.topShelf.account."

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    private func key(accountID: String, origin: URL) -> String {
        Self.keyPrefix + TVTopShelfSnapshotStore.fingerprint(
            origin.absoluteString + "|account:" + accountID
        )
    }

    func isAllowed(accountID: String, origin: URL) -> Bool {
        guard !accountID.isEmpty else { return false }
        // Deliberately opt-in: absence of a saved choice means OFF.
        return defaults.bool(forKey: key(accountID: accountID, origin: origin))
    }

    func setAllowed(_ allowed: Bool, accountID: String, origin: URL) {
        guard !accountID.isEmpty else { return }
        defaults.set(allowed, forKey: key(accountID: accountID, origin: origin))
    }

    func remove(accountID: String, origin: URL) {
        guard !accountID.isEmpty else { return }
        defaults.removeObject(forKey: key(accountID: accountID, origin: origin))
    }
}
