import Foundation
import XCTest
@testable import TypeTypeTV

final class TVLibraryPagingAndMembershipTests: XCTestCase {
    private func video(_ id: String, url: String) -> VideoItem {
        VideoItem(id: id, title: "Video \(id)", url: url, thumbnailUrl: nil,
                  uploaderName: "Channel", duration: 95, isLive: false)
    }

    func testHistoryDeduplicationWorksAcrossMultipleServerPages() {
        let first = [video("a", url: "https://www.youtube.com/watch?v=dQw4w9WgXcQ"),
                     video("b", url: "https://youtu.be/9bZkp7q19f0")]
        let second = [video("a-again", url: "https://youtu.be/dQw4w9WgXcQ"),
                      video("c", url: "https://www.youtube.com/shorts/jfKfPfyJRdk")]
        let existing = TVHistoryDeduplicator.unique(first)
        let additional = TVHistoryDeduplicator.appendUnique(second, to: existing)
        XCTAssertEqual(existing.count, 2)
        XCTAssertEqual(additional.count, 1)
        XCTAssertEqual(additional[0].id, "c")
        // HTTP offset uses the *raw page size*, including duplicates.
        XCTAssertEqual(first.count + second.count, 4)
        XCTAssertEqual(existing.count + additional.count, 3)
    }

    func testHistoryCanGrowBeyondThePreviousFirstPage() {
        let first = (0..<60).map {
            video("\($0)", url: "https://other.example/video/\($0)")
        }
        let second = (60..<170).map {
            video("\($0)", url: "https://other.example/video/\($0)")
        }
        let all = TVHistoryDeduplicator.unique(first) +
            TVHistoryDeduplicator.appendUnique(second, to: first)
        XCTAssertEqual(all.count, 170)
    }

    @MainActor
    func testPlaylistMembershipRecognizesYouTubeURLVariants() {
        XCTAssertEqual(
            TVPlaylistMembership.videoKey(
                "https://www.youtube.com/watch?v=dQw4w9WgXcQ"),
            TVPlaylistMembership.videoKey("https://youtu.be/dQw4w9WgXcQ")
        )
        XCTAssertNotEqual(
            TVPlaylistMembership.videoKey("https://site.example/videos/1"),
            TVPlaylistMembership.videoKey("https://site.example/videos/2")
        )
    }
    
    @MainActor
    func testFavoriteMarkersMatchEquivalentYouTubeURLs() {
        XCTAssertEqual(
            TVFavoriteMembership.videoKey(
                "https://www.youtube.com/watch?v=dQw4w9WgXcQ"
            ),
            TVFavoriteMembership.videoKey("https://youtu.be/dQw4w9WgXcQ")
        )
        XCTAssertEqual(
            TVFavoriteMembership.videoKey("https://www.youtube.com/shorts/dQw4w9WgXcQ"),
            TVPlaylistMembership.videoKey("https://youtu.be/dQw4w9WgXcQ")
        )
        XCTAssertNotEqual(
            TVFavoriteMembership.videoKey("https://site.example/a"),
            TVFavoriteMembership.videoKey("https://site.example/b")
        )
    }

    @MainActor
    func testPlaylistPopupSavesAndRestoresFocusOrCancels() throws {
        let api = try TypeTypeAPI(address: "https://preview.invalid")
        let target = video("test", url: "https://youtu.be/dQw4w9WgXcQ")
        let popup = TVPlaylistPopupPresenter.shared
        popup.finish()
        var events: [String] = []

        popup.present(api: api, video: target,
                      onSaved: { events.append("saved:" + $0) },
                      onDismiss: { events.append("dismissed") })
        XCTAssertEqual(popup.request?.video.url, target.url)
        popup.finish(result: "added")
        XCTAssertNil(popup.request)
        XCTAssertEqual(events, ["saved:added", "dismissed"])

        events.removeAll()
        popup.present(api: api, video: target,
                      onSaved: { events.append("saved:" + $0) },
                      onDismiss: { events.append("dismissed") })
        popup.finish()
        XCTAssertEqual(events, ["dismissed"])
        XCTAssertNil(popup.request)
    }
}
