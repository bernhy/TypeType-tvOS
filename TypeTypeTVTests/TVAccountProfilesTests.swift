import Foundation
import XCTest
@testable import TypeTypeTV

final class TVAccountProfilesTests: XCTestCase {
    func testProfileKeysAreServerScoped() {
        let one = URL(string: "https://server-a.example")!
        let two = URL(string: "https://server-b.example")!
        XCTAssertNotEqual(
            TypeTypeCredentials.profileKey(origin: one, userID: "user-42"),
            TypeTypeCredentials.profileKey(origin: two, userID: "user-42")
        )
        XCTAssertNotEqual(
            TypeTypeCredentials.profileKey(origin: one, userID: "user-42"),
            TypeTypeCredentials.profileKey(origin: one, userID: "user-43")
        )
    }

    func testFamilyAccountsStaySeparateAndCanBeSwitched() throws {
        let origin = URL(string: "https://profiles-test-\(UUID().uuidString).invalid")!
        let store = TypeTypeCredentials.shared
        defer {
            store.forget("family-alice", for: origin)
            store.forget("family-bob", for: origin)
            store.clear(for: origin)
        }
        let alice = TVAccountIdentity(id: "family-alice", role: "user", publicUsername: "Alice")
        let bob = TVAccountIdentity(id: "family-bob", role: "user", publicUsername: "Bob")

        // A simulator with no functional Keychain cannot run this integration
        // test; production app operations use the same Keychain APIs.
        guard store.remember(alice, token: "token-alice",
                             displayIdentifier: nil, for: origin) else {
            throw XCTSkip("Simulator Keychain not available")
        }
        XCTAssertTrue(store.remember(bob, token: "token-bob",
                                     displayIdentifier: nil, for: origin))
        let saved = store.savedAccounts(for: origin)
        XCTAssertEqual(Set(saved.map(\.id)), ["family-alice", "family-bob"])
        XCTAssertEqual(saved.map(\.label), ["Alice", "Bob"])

        XCTAssertTrue(store.activate(try XCTUnwrap(saved.first { $0.id == "family-alice" }),
                                     for: origin))
        XCTAssertEqual(store.token(for: origin), "token-alice")
        XCTAssertTrue(store.activate(try XCTUnwrap(saved.first { $0.id == "family-bob" }),
                                     for: origin))
        XCTAssertEqual(store.token(for: origin), "token-bob")

        // Logging out of one user never removes the other family member.
        store.forget("family-bob", for: origin)
        store.clear(for: origin)
        XCTAssertEqual(store.savedAccounts(for: origin).map(\.id), ["family-alice"])
    }

    func testEachHouseholdProfileRetainsItsOwnRotatingRefreshToken() throws {
        let origin = URL(string: "https://refresh-profiles-\(UUID().uuidString).invalid")!
        let credentials = TypeTypeCredentials.shared
        defer {
            credentials.forget("member-a", for: origin)
            credentials.forget("member-b", for: origin)
            credentials.clear(for: origin)
        }
        guard credentials.save("access-a", for: origin),
              credentials.saveRefreshToken("refresh-a", for: origin) else {
            throw XCTSkip("Simulator Keychain unavailable")
        }
        let a = TVAccountIdentity(id: "member-a", role: "user", publicUsername: "A")
        let b = TVAccountIdentity(id: "member-b", role: "user", publicUsername: "B")
        XCTAssertTrue(credentials.remember(a, token: "access-a", displayIdentifier: nil, for: origin))
        XCTAssertTrue(credentials.save("access-b", for: origin))
        XCTAssertTrue(credentials.saveRefreshToken("refresh-b", for: origin))
        XCTAssertTrue(credentials.remember(b, token: "access-b", displayIdentifier: nil, for: origin))
        XCTAssertTrue(credentials.activate(TVSavedAccount(id: "member-a", label: "A"), for: origin))
        XCTAssertEqual(credentials.refreshToken(for: origin), "refresh-a")
        XCTAssertTrue(credentials.activate(TVSavedAccount(id: "member-b", label: "B"), for: origin))
        XCTAssertEqual(credentials.refreshToken(for: origin), "refresh-b")
        credentials.forget("member-a", for: origin)
        XCTAssertNil(credentials.profileRefreshToken("member-a", for: origin))
        XCTAssertEqual(credentials.profileRefreshToken("member-b", for: origin), "refresh-b")
    }

    func testInactiveServersAreListedWithoutTouchingCurrentCredentials() throws {
        let suffix = UUID().uuidString.lowercased()
        let current = try XCTUnwrap(URL(string: "https://current-\(suffix).invalid/"))
        let old = try XCTUnwrap(URL(string: "https://former-\(suffix).invalid/"))
        let other = try XCTUnwrap(URL(string: "https://another-\(suffix).invalid/"))
        let credentials = TypeTypeCredentials.shared
        defer {
            _ = TVStoredAccountCleanup.delete(old, excluding: current)
            _ = TVStoredAccountCleanup.delete(other, excluding: current)
            credentials.forget("member", for: current)
            credentials.clear(for: current)
        }

        guard credentials.save("current-access", for: current),
              credentials.save("old-access", for: old),
              credentials.saveRefreshToken("old-refresh", for: old),
              credentials.saveRefreshToken("refresh-only", for: old,
                                           userID: "refresh-only-user"),
              credentials.save("other-access", for: other) else {
            throw XCTSkip("Simulator Keychain unavailable")
        }
        let identity = TVAccountIdentity(
            id: "member", role: "user", publicUsername: "Member"
        )
        XCTAssertTrue(credentials.remember(
            identity, token: "old-access", displayIdentifier: nil, for: old
        ))

        let listed = try TVStoredAccountCleanup.inactiveServers(excluding: current)
        let former = try XCTUnwrap(listed.first { $0.origin == old })
        XCTAssertTrue(former.logins.contains { $0.userID == "member" })
        XCTAssertTrue(former.logins.contains { $0.userID == "refresh-only-user" })
        XCTAssertTrue(listed.contains { $0.origin == other })
        XCTAssertFalse(listed.contains { $0.origin == current })

        XCTAssertFalse(TVStoredAccountCleanup.delete(current, excluding: current))
        XCTAssertEqual(credentials.token(for: current), "current-access")

        XCTAssertTrue(TVStoredAccountCleanup.delete(old, excluding: current))
        XCTAssertNil(credentials.token(for: old))
        XCTAssertNil(credentials.refreshToken(for: old))
        XCTAssertNil(credentials.profileRefreshToken("member", for: old))
        XCTAssertNil(credentials.profileRefreshToken("refresh-only-user", for: old))
        XCTAssertNil(credentials.profileAccessToken("member", for: old))
        XCTAssertEqual(credentials.token(for: current), "current-access")
        let remaining = try TVStoredAccountCleanup.inactiveServers(excluding: current)
        XCTAssertFalse(remaining.contains { $0.origin == old })
        XCTAssertTrue(remaining.contains { $0.origin == other })
    }

    func testGuestCannotBecomeSavedFamilyProfile() {
        let origin = URL(string: "https://guest-profiles.invalid")!
        let guest = TVAccountIdentity(id: "guest:opaque", role: "guest", publicUsername: nil)
        XCTAssertFalse(TypeTypeCredentials.shared.remember(
            guest, token: "guest-token", displayIdentifier: nil, for: origin
        ))
    }
}
