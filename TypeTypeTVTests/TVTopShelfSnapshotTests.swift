import XCTest
@testable import TypeTypeTV

final class TVTopShelfSnapshotTests: XCTestCase {
    private func entry(_ identifier: String, positionMs: Int64 = 60_000) ->
        TVTopShelfSnapshotStore.Item {
        TVTopShelfSnapshotStore.Item(
            key: TVTopShelfSnapshotStore.key(for: "https://youtu.be/" + identifier),
            videoID: identifier, title: "Video " + identifier,
            channelName: "Testkanal", videoURL: "https://youtu.be/" + identifier,
            thumbnailURL: "https://i.ytimg.com/vi/" + identifier + "/hqdefault.jpg",
            duration: 300, positionMs: positionMs
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

    func testSnapshotRejectsMalformedActionURLs() {
        let key = TVTopShelfSnapshotStore.key(for: "sample")
        XCTAssertNil(TVTopShelfSnapshotStore.actionURL(for: "invalid-key"))
        XCTAssertNotNil(TVTopShelfSnapshotStore.actionURL(for: key))
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
            channelName: video.channelName, videoURL: "https://youtu.be/not-the-same", thumbnailURL: video.thumbnailURL,
            duration: video.duration, positionMs: video.positionMs
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

    func testPosterPolicyAvoidsPrivateServerArtwork() {
        let publicURL = TVTopShelfPosterPolicy.publicThumbnail(
            primary: URL(string: "https://private.example.invalid/protected?t=secret"),
            videoURL: "https://youtu.be/abc123def45"
        )
        XCTAssertEqual(publicURL, "https://i.ytimg.com/vi/abc123def45/hqdefault.jpg")
        XCTAssertFalse(publicURL?.contains("secret") ?? false)
        XCTAssertNil(TVTopShelfPosterPolicy.publicThumbnail(
            primary: URL(string: "https://private.example.invalid/private"),
            videoURL: "not-a-youtube-video"
        ))
    }

    func testSectionHeaderShowsChannelWithoutChangingVideoTitle() {
        let original = entry("abc123def45")
        XCTAssertEqual(original.title, "Video abc123def45")
        XCTAssertEqual(original.channelName, "Testkanal")
        XCTAssertEqual(original.sectionTitle, "Ansehen fortsetzen · Testkanal")

        let blankChannel = TVTopShelfSnapshotStore.Item(
            key: original.key, videoID: original.videoID,
            title: original.title, channelName: "   ",
            videoURL: original.videoURL, thumbnailURL: original.thumbnailURL,
            duration: original.duration, positionMs: original.positionMs
        )
        XCTAssertEqual(blankChannel.sectionTitle, "Ansehen fortsetzen")

        let missingChannel = TVTopShelfSnapshotStore.Item(
            key: original.key, videoID: original.videoID,
            title: original.title, channelName: nil,
            videoURL: original.videoURL, thumbnailURL: original.thumbnailURL,
            duration: original.duration, positionMs: original.positionMs
        )
        XCTAssertEqual(missingChannel.sectionTitle, "Ansehen fortsetzen")
    }

    func testPreviousSnapshotWithoutChannelNameIsStillReadable() throws {
        let old = entry("abc123def45")
        let snapshot = TVTopShelfSnapshotStore.make(
            origin: "https://example.invalid", scopeFingerprint: "one",
            items: [old]
        )
        var obj = try XCTUnwrap(JSONSerialization.jsonObject(
            with: JSONEncoder().encode(snapshot)
        ) as? [String: Any])
        var items = try XCTUnwrap(obj["items"] as? [[String: Any]])
        items[0].removeValue(forKey: "channelName")
        obj["items"] = items
        let legacyData = try JSONSerialization.data(withJSONObject: obj)
        let decoded = try JSONDecoder().decode(
            TVTopShelfSnapshotStore.Snapshot.self, from: legacyData
        )
        XCTAssertNil(decoded.items.first?.channelName)
        XCTAssertEqual(decoded.items.first?.sectionTitle, "Ansehen fortsetzen")
    }

    func testPosterPolicyKeepsExistingPublicImageBeforeFallback() {
        let original = URL(
            string: "https://i.ytimg.com/vi/abc123def45/sddefault.jpg"
        )
        XCTAssertEqual(TVTopShelfPosterPolicy.publicThumbnail(
            primary: original, videoURL: "https://youtu.be/abc123def45"
        ), original?.absoluteString)
        // Top Shelf can choose a canonical fallback when the source is
        // private, but Apple's image loader cannot retry after a failed GET.
    }

    func testSharedDefaultsStoreWritesReadsAndClearsOneSnapshot() throws {
        let suite = "typetype.test.topshelf." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let snapshot = TVTopShelfSnapshotStore.make(
            origin: "https://example.invalid", scopeFingerprint: "one",
            items: [entry("abc123def45")]
        )
        XCTAssertNil(TVTopShelfSnapshotStore.read(using: defaults))
        XCTAssertTrue(TVTopShelfSnapshotStore.write(snapshot, using: defaults))
        XCTAssertEqual(TVTopShelfSnapshotStore.read(using: defaults), snapshot)
        XCTAssertTrue(TVTopShelfSnapshotStore.clear(using: defaults))
        XCTAssertNil(TVTopShelfSnapshotStore.read(using: defaults))
        XCTAssertFalse(TVTopShelfSnapshotStore.clear(using: defaults))
    }

    func testOversizedSharedSnapshotIsRejectedWithoutOverwritingExisting() throws {
        let suite = "typetype.test.topshelf." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let good = TVTopShelfSnapshotStore.make(
            origin: "https://example.invalid", scopeFingerprint: "account",
            items: [entry("abc123def45")]
        )
        XCTAssertTrue(TVTopShelfSnapshotStore.write(good, using: defaults))
        let longTitle = String(repeating: "L", count: TVTopShelfSnapshotStore.maximumBytes)
        let oversized = TVTopShelfSnapshotStore.make(
            origin: good.origin, scopeFingerprint: good.scopeFingerprint,
            items: [TVTopShelfSnapshotStore.Item(
                key: good.items[0].key, videoID: good.items[0].videoID,
                title: longTitle, channelName: good.items[0].channelName,
                videoURL: good.items[0].videoURL,
                thumbnailURL: good.items[0].thumbnailURL,
                duration: 300, positionMs: 60_000
            )]
        )
        XCTAssertFalse(TVTopShelfSnapshotStore.write(oversized, using: defaults))
        XCTAssertEqual(TVTopShelfSnapshotStore.read(using: defaults), good)
    }

    func testCorruptSharedSnapshotIsNotRead() throws {
        let suite = "typetype.test.topshelf." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        // A malformed object must never yield incomplete or cross-account
        // personal content. A valid snapshot can subsequently replace it.
        let garbage = Data("not a snapshot".utf8)
        defaults.set(garbage, forKey: "typetype.topShelf.resume.v2")
        XCTAssertNil(TVTopShelfSnapshotStore.read(using: defaults))
        XCTAssertTrue(TVTopShelfSnapshotStore.write(
            TVTopShelfSnapshotStore.make(
                origin: "https://example.invalid", scopeFingerprint: "one",
                items: [entry("abc123def45")]
            ), using: defaults
        ))
        XCTAssertNotNil(TVTopShelfSnapshotStore.read(using: defaults))
    }

}
