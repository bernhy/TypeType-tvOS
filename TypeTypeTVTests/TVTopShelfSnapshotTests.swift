import XCTest
@testable import TypeTypeTV

final class TVTopShelfSnapshotTests: XCTestCase {
    private func entry(_ identifier: String, positionMs: Int64 = 60_000) ->
        TVTopShelfSnapshotStore.Item {
        TVTopShelfSnapshotStore.Item(
            key: TVTopShelfSnapshotStore.key(for: "https://youtu.be/" + identifier),
            videoID: identifier, title: "Video " + identifier,
            videoURL: "https://youtu.be/" + identifier,
            thumbnailURL: "https://i.ytimg.com/vi/" + identifier + "/hqdefault.jpg",
            imageName: nil, duration: 300, positionMs: positionMs
        )
    }

    func testNoLoginAndGuestAccountsUseStaticTopShelfArtwork() {
        XCTAssertFalse(TVTopShelfVisibilityPolicy.permits(nil))
        XCTAssertFalse(TVTopShelfVisibilityPolicy.permits(
            TVAccountIdentity(id: "guest:session", role: nil, publicUsername: nil)
        ))
        XCTAssertFalse(TVTopShelfVisibilityPolicy.permits(
            TVAccountIdentity(id: "", role: nil, publicUsername: nil)
        ))
        XCTAssertTrue(TVTopShelfVisibilityPolicy.permits(
            TVAccountIdentity(id: "account-123", role: nil, publicUsername: "Example")
        ))
    }

    func testSnapshotCapsContentsAtFiveAndKeepsOrder() {
        let entries = (0..<12).map { entry(String(format: "%011d", $0)) }
        let result = TVTopShelfSnapshotStore.make(
            origin: "https://example.invalid", scopeFingerprint: "account",
            items: entries
        )
        XCTAssertEqual(result.items.count, 5)
        XCTAssertEqual(result.items.map(\.key), Array(entries.prefix(5)).map(\.key))
    }

    func testDisplayActionUsesOpaqueKeyAndRequiresMatchingAccount() throws {
        let video = entry("abc123def45")
        let result = TVTopShelfSnapshotStore.make(
            origin: "https://example.invalid",
            scopeFingerprint: TVTopShelfSnapshotStore.fingerprint("secret-scope"),
            items: [video]
        )
        let action = try XCTUnwrap(TVTopShelfSnapshotStore.actionURL(for: video.key))
        XCTAssertFalse(action.absoluteString.contains("youtu.be"))
        XCTAssertEqual(TVTopShelfSnapshotStore.item(
            for: action, in: result, origin: result.origin,
            scopeFingerprint: result.scopeFingerprint
        ), video)
        XCTAssertNil(TVTopShelfSnapshotStore.item(
            for: action, in: result, origin: result.origin,
            scopeFingerprint: "other-household-profile"
        ))
        XCTAssertNil(TVTopShelfSnapshotStore.item(
            for: action, in: result, origin: "https://other.invalid",
            scopeFingerprint: result.scopeFingerprint
        ))
    }

    func testProgressIsClampedAndNoCredentialsStoredInSnapshot() throws {
        let video = entry("abc123def45", positionMs: 150_000)
        XCTAssertEqual(video.playbackFraction, 0.5, accuracy: 0.001)
        XCTAssertEqual(entry("abc123def45", positionMs: 999_000).playbackFraction, 1)
        let scope = TVTopShelfSnapshotStore.fingerprint("bearer-not-for-disk")
        let snapshot = TVTopShelfSnapshotStore.make(
            origin: "https://example.invalid", scopeFingerprint: scope,
            items: [video]
        )
        let json = try JSONEncoder().encode(snapshot)
        XCTAssertFalse(String(decoding: json, as: UTF8.self).contains("bearer-not-for-disk"))
    }

    func testSnapshotRejectsMalformedURLsAndEscapingImageNames() {
        let key = TVTopShelfSnapshotStore.key(for: "sample")
        XCTAssertNil(TVTopShelfSnapshotStore.actionURL(for: "invalid-key"))
        XCTAssertNil(TVTopShelfSnapshotStore.imageURL(
            named: "../secrets.jpg", in: URL(fileURLWithPath: "/tmp")
        ))
        XCTAssertNotNil(TVTopShelfSnapshotStore.actionURL(for: key))
        XCTAssertNotNil(TVTopShelfSnapshotStore.imageURL(
            named: key + ".jpg", in: URL(fileURLWithPath: "/tmp")
        ))
    }

    func testActionRejectsExtraParametersFragmentsAndInvalidKeys() throws {
        let video = entry("abc123def45")
        let snapshot = TVTopShelfSnapshotStore.make(
            origin: "https://example.invalid", scopeFingerprint: "one",
            items: [video]
        )
        let valid = try XCTUnwrap(TVTopShelfSnapshotStore.actionURL(for: video.key))
        func resolve(_ raw: String) -> TVTopShelfSnapshotStore.Item? {
            guard let url = URL(string: raw) else { return nil }
            return TVTopShelfSnapshotStore.item(
                for: url, in: snapshot, origin: snapshot.origin,
                scopeFingerprint: snapshot.scopeFingerprint
            )
        }
        XCTAssertEqual(resolve(valid.absoluteString), video)
        XCTAssertNil(resolve(valid.absoluteString + "&key=" + video.key))
        XCTAssertNil(resolve(valid.absoluteString + "&unexpected=true"))
        XCTAssertNil(resolve(valid.absoluteString + "#fragment"))
        XCTAssertNil(resolve("typetype-tv://resume/?key=" + video.key))
        XCTAssertNil(resolve("typetype-tv://resume?key=malformed"))
        XCTAssertNil(resolve("typetype-tv://other?key=" + video.key))
    }

    func testActionRejectsSnapshotKeyNotMatchingVideoURL() throws {
        let video = entry("abc123def45")
        let tampered = TVTopShelfSnapshotStore.Item(
            key: video.key, videoID: video.videoID, title: video.title,
            videoURL: "https://youtu.be/not-the-same", thumbnailURL: video.thumbnailURL,
            imageName: nil, duration: video.duration, positionMs: video.positionMs
        )
        let snapshot = TVTopShelfSnapshotStore.make(
            origin: "https://example.invalid", scopeFingerprint: "one",
            items: [tampered]
        )
        let action = try XCTUnwrap(TVTopShelfSnapshotStore.actionURL(for: video.key))
        XCTAssertNil(TVTopShelfSnapshotStore.item(
            for: action, in: snapshot, origin: snapshot.origin,
            scopeFingerprint: snapshot.scopeFingerprint
        ))
    }

    func testAtomicSnapshotWriteAndRead() {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let snapshot = TVTopShelfSnapshotStore.make(
            origin: "https://example.invalid", scopeFingerprint: "one",
            items: [entry("abc123def45")]
        )
        XCTAssertTrue(TVTopShelfSnapshotStore.write(snapshot, to: directory))
        XCTAssertEqual(TVTopShelfSnapshotStore.read(from: directory), snapshot)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: directory.appendingPathComponent("resume.json.tmp").path
        ))
    }
}
