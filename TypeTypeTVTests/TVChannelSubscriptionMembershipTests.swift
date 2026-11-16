import XCTest
@testable import TypeTypeTV

final class TVChannelSubscriptionMembershipTests: XCTestCase {
    private func subscription(_ channelURL: String, name: String = "Channel") -> TVSubscription {
        TVSubscription(channelUrl: channelURL, name: name,
                       avatarUrl: "https://example.invalid/avatar.png",
                       subscribedAt: 1_732_000_000)
    }

    func testNormalizesChannelURLsLikeTypeTypeServer() {
        XCTAssertEqual(
            TVChannelSubscriptionMembership.canonicalURL(
                "http://WWW.YouTube.com:80/channel/UC123/?utm_source=x#fragment"),
            "https://www.youtube.com/channel/UC123"
        )
        XCTAssertEqual(
            TVChannelSubscriptionMembership.canonicalURL(
                "https://example.com:443/"),
            "https://example.com"
        )
        XCTAssertEqual(
            TVChannelSubscriptionMembership.canonicalURL(
                "https://www.youtube.com/@CaseSensitive"),
            "https://www.youtube.com/@CaseSensitive"
        )
    }

    func testDetectsExistingSubscriptionByURLNotChannelName() {
        let first = subscription("https://www.youtube.com/channel/UC123", name: "Same")
        let second = subscription("https://www.youtube.com/channel/UC456", name: "Same")
        XCTAssertEqual(
            TVChannelSubscriptionMembership.entry(
                for: "http://WWW.YouTube.com/channel/UC123/?feature=share",
                in: [first, second])?.channelUrl,
            first.channelUrl
        )
        XCTAssertNil(TVChannelSubscriptionMembership.entry(
            for: "https://www.youtube.com/channel/UC789",
            in: [first, second]))
    }

    func testSubscribeDoesNotCreateDuplicateRows() {
        let old = subscription("http://youtube.com/@Example/")
        let new = subscription("https://youtube.com/@Example", name: "Updated")
        let all = TVChannelSubscriptionMembership.adding(new, to: [old])
        XCTAssertEqual(all.count, 1)
        XCTAssertEqual(all.first?.name, "Updated")
    }

    func testUnsubscribeOnlyRemovesTheSelectedChannel() {
        let a = subscription("https://www.youtube.com/channel/A")
        let b = subscription("https://www.youtube.com/channel/B")
        let remaining = TVChannelSubscriptionMembership.removing(
            channelURL: "http://WWW.YOUTUBE.COM/channel/A/",
            from: [a, b]
        )
        XCTAssertEqual(remaining.map(\.channelUrl), [b.channelUrl])
    }

    func testSubscriptionReplyFromServerDecodesAndRetainsCanonicalURL() throws {
        let result = try JSONDecoder().decode(TVSubscription.self, from: Data(#"""
        {"channelUrl":"https://youtube.com/@Creator",
         "name":"Creator","avatarUrl":"","subscribedAt":1763300000}
        """#.utf8))
        XCTAssertEqual(result.channelUrl, "https://youtube.com/@Creator")
        XCTAssertEqual(result.subscribedAt, 1_763_300_000)
    }
}
