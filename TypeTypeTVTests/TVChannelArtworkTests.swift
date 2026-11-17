import XCTest
@testable import TypeTypeTV

final class TVChannelArtworkTests: XCTestCase {
    func testBannerPreferredWhenProvided() {
        let page = TVChannelPage(
            name: "Example", description: nil,
            avatarUrl: "/avatar.webp", bannerUrl: "/banner.webp",
            subscriberCount: nil, isVerified: nil, videos: [],
            nextpage: nil, hasCourses: nil
        )
        let artwork = TVChannelArtwork(page: page)
        XCTAssertEqual(artwork.avatarURL, "/avatar.webp")
        XCTAssertEqual(artwork.heroURL, "/banner.webp")
    }

    func testAvatarFallbackAndBlankValues() {
        let page = TVChannelPage(
            name: "Example", description: nil,
            avatarUrl: " /avatar.webp ", bannerUrl: " ",
            subscriberCount: nil, isVerified: nil, videos: [],
            nextpage: nil, hasCourses: nil
        )
        let artwork = TVChannelArtwork(page: page)
        XCTAssertEqual(artwork.avatarURL, "/avatar.webp")
        XCTAssertEqual(artwork.heroURL, "/avatar.webp")
    }
}
