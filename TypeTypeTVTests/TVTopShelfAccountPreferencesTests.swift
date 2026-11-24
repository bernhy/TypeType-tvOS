import Foundation
import XCTest
@testable import TypeTypeTV

final class TVTopShelfAccountPreferencesTests: XCTestCase {
    func testOptInIsOffByDefaultAndScopedToEachAccountAndServer() throws {
        let suite = "typetype-topshelf-tests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let prefs = TVTopShelfAccountPreferences(defaults: defaults)
        let home = try XCTUnwrap(URL(string: "https://one.example.invalid"))
        let other = try XCTUnwrap(URL(string: "https://two.example.invalid"))

        XCTAssertFalse(prefs.isAllowed(accountID: "alice", origin: home))
        XCTAssertFalse(prefs.isAllowed(accountID: "bob", origin: home))
        prefs.setAllowed(true, accountID: "alice", origin: home)
        XCTAssertTrue(prefs.isAllowed(accountID: "alice", origin: home))
        XCTAssertFalse(prefs.isAllowed(accountID: "bob", origin: home))
        XCTAssertFalse(prefs.isAllowed(accountID: "alice", origin: other))
        // A fresh store (app relaunch) reads the same persisted decision.
        XCTAssertTrue(TVTopShelfAccountPreferences(defaults: defaults)
            .isAllowed(accountID: "alice", origin: home))

        prefs.setAllowed(true, accountID: "bob", origin: home)
        prefs.setAllowed(false, accountID: "alice", origin: home)
        XCTAssertFalse(prefs.isAllowed(accountID: "alice", origin: home))
        XCTAssertTrue(prefs.isAllowed(accountID: "bob", origin: home))

        prefs.remove(accountID: "bob", origin: home)
        XCTAssertFalse(prefs.isAllowed(accountID: "bob", origin: home))
    }

    func testEmptyAccountCannotOptInAndUserDefaultsKeyDoesNotExposeIdentity() throws {
        let suite = "typetype-topshelf-tests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let prefs = TVTopShelfAccountPreferences(defaults: defaults)
        let origin = try XCTUnwrap(URL(string: "https://private-server.example.invalid"))
        prefs.setAllowed(true, accountID: "", origin: origin)
        XCTAssertFalse(prefs.isAllowed(accountID: "", origin: origin))
        prefs.setAllowed(true, accountID: "sensitive-account-name", origin: origin)
        let keys = defaults.dictionaryRepresentation().keys.filter {
            $0.hasPrefix("typetype.topShelf.account.")
        }
        XCTAssertEqual(keys.count, 1)
        XCTAssertFalse(keys[0].contains("sensitive-account-name"))
        XCTAssertFalse(keys[0].contains("private-server"))
    }
}
