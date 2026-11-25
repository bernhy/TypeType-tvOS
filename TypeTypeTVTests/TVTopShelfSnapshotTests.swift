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

    func testServerDeArrowPrecedesProxyAndDirectYouTube() throws {
        let origin = try XCTUnwrap(URL(string: "https://instance.example/"))
        let primary = try XCTUnwrap(URL(
            string: "https://instance.example/dearrow/thumbnail?videoId=abc123def45&time=15.5"
        ))
        let urls = TVTopShelfPosterPolicy.candidates(
            primary: primary, videoURL: "https://youtu.be/abc123def45",
            origin: origin
        )
        XCTAssertEqual(urls.count, 5)
        XCTAssertEqual(urls[0].path, "/api/dearrow/thumbnail")
        XCTAssertEqual(
            URLComponents(url: urls[0], resolvingAgainstBaseURL: false)?
                .queryItems?.first(where: { $0.name == "time" })?.value,
            "15.5"
        )
        XCTAssertEqual(urls[1].path, "/api/proxy")
        XCTAssertEqual(urls[2].path, "/api/proxy")
        let proxiedHQ = URLComponents(url: urls[1], resolvingAgainstBaseURL: false)?
            .queryItems?.first(where: { $0.name == "url" })?.value
        let proxiedMQ = URLComponents(url: urls[2], resolvingAgainstBaseURL: false)?
            .queryItems?.first(where: { $0.name == "url" })?.value
        XCTAssertEqual(proxiedHQ,
                       "https://i.ytimg.com/vi/abc123def45/hqdefault.jpg")
        XCTAssertEqual(proxiedMQ,
                       "https://i.ytimg.com/vi/abc123def45/mqdefault.jpg")
        XCTAssertEqual(urls[3].absoluteString,
                       "https://i.ytimg.com/vi/abc123def45/hqdefault.jpg")
        XCTAssertEqual(urls[4].absoluteString,
                       "https://i.ytimg.com/vi/abc123def45/mqdefault.jpg")
    }

    func testServerProvidedRemoteArtworkIsProxiedBeforeCanonicals() throws {
        let origin = try XCTUnwrap(URL(string: "https://instance.example/"))
        let primary = try XCTUnwrap(URL(
            string: "https://i.ytimg.com/vi/abc123def45/sddefault.jpg"
        ))
        let urls = TVTopShelfPosterPolicy.candidates(
            primary: primary, videoURL: "https://youtu.be/abc123def45",
            origin: origin
        )
        XCTAssertEqual(urls[0].path, "/api/proxy")
        XCTAssertEqual(
            URLComponents(url: urls[0], resolvingAgainstBaseURL: false)?
                .queryItems?.first(where: { $0.name == "url" })?.value,
            primary.absoluteString
        )
        XCTAssertEqual(urls.count, 5)
    }

    func testPrivateServerPathsAndUnapprovedExternalHostsNeverLeaveApp() throws {
        let origin = try XCTUnwrap(URL(string: "https://instance.example/"))
        for value in [
            "https://instance.example/api/private/thumbnail?token=secret",
            "https://instance.example/api/dearrow/thumbnail?videoId=x&token=secret",
            "https://untrusted.example/secret.jpg"
        ] {
            let urls = TVTopShelfPosterPolicy.candidates(
                primary: URL(string: value),
                videoURL: "https://youtu.be/abc123def45",
                origin: origin
            )
            XCTAssertEqual(urls.count, 4)
            XCTAssertTrue(urls.allSatisfy {
                !$0.absoluteString.contains("secret") &&
                !$0.absoluteString.contains("untrusted")
            })
            XCTAssertTrue(urls[0].absoluteString.hasPrefix(
                "https://instance.example/api/proxy?"
            ))
        }
    }

    func testRemoteSignedImageURLNeverGetsIntoSharedSnapshot() throws {
        let origin = try XCTUnwrap(URL(string: "https://instance.example/"))
        let primary = URL(
            string: "https://i.ytimg.com/vi/abc123def45/sddefault.jpg?token=private"
        )
        let urls = TVTopShelfPosterPolicy.candidates(
            primary: primary, videoURL: "https://youtu.be/abc123def45",
            origin: origin
        )
        XCTAssertEqual(urls.count, 4)
        XCTAssertTrue(urls.allSatisfy {
            !$0.absoluteString.contains("token") &&
                !$0.absoluteString.contains("private")
        })
    }

    func testDuplicateCanonicalYouTubePrimaryIsOnlyProxiedOnce() throws {
        let origin = try XCTUnwrap(URL(string: "https://instance.example/"))
        let primary = try XCTUnwrap(URL(
            string: "https://i.ytimg.com/vi/abc123def45/hqdefault.jpg"
        ))
        let urls = TVTopShelfPosterPolicy.candidates(
            primary: primary, videoURL: "https://youtu.be/abc123def45",
            origin: origin
        )
        XCTAssertEqual(urls.count, 4)
        XCTAssertEqual(Set(urls).count, urls.count)
    }

    func testUnrelatedProvidersUseTheirPublicTypeTypeProxy() throws {
        let origin = try XCTUnwrap(URL(string: "https://instance.example/"))
        let remote = try XCTUnwrap(URL(string: "https://i0.hdslb.com/bfs/archive/test.jpg"))
        let urls = TVTopShelfPosterPolicy.candidates(
            primary: remote, videoURL: "https://www.bilibili.com/video/BV123",
            origin: origin
        )
        XCTAssertEqual(urls.count, 1)
        XCTAssertEqual(urls.first?.path, "/api/proxy")
    }

    func testImageFallbackMovesToNextSourceOnlyWhenPreviousFails() async {
        let origin = URL(string: "https://instance.example/")!
        let urls = TVTopShelfPosterPolicy.candidates(
            primary: nil, videoURL: "https://youtu.be/abc123def45",
            origin: origin
        )
        XCTAssertEqual(urls.count, 4)
        // Both server-proxy images failed; the direct high-quality image
        // succeeded. No network requests are made by this deterministic test.
        let chosen = await TVTopShelfPosterPolicy.firstReachable(
            candidates: urls
        ) { $0 == urls[2] }
        XCTAssertEqual(chosen, urls[2])
        let failed = await TVTopShelfPosterPolicy.firstReachable(
            candidates: urls
        ) { _ in false }
        XCTAssertNil(failed)
    }

    func testNormalAppAlsoFallsBackToMQWhenNeeded() {
        let origin = URL(string: "https://instance.example/")!
        let urls = TVThumbnailSources.urls(
            primary: URL(string: "https://instance.example/dearrow/thumbnail"),
            videoURL: "https://youtu.be/abc123def45", origin: origin
        )
        XCTAssertEqual(urls.map(\.path),
                       ["/api/dearrow/thumbnail", "/api/proxy", "/api/proxy",
                        "/vi/abc123def45/hqdefault.jpg",
                        "/vi/abc123def45/mqdefault.jpg"])
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
