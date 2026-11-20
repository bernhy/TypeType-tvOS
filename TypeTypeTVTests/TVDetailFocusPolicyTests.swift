import XCTest
import SwiftUI
@testable import TypeTypeTV

final class TVDetailFocusPolicyTests: XCTestCase {
    private func next(_ from: VideoDetailView.DetailFocus,
                      _ move: MoveCommandDirection,
                      hasChannel: Bool = true,
                      canMarkWatched: Bool = true,
                      libraryActionsAvailable: Bool = true,
                      hasDescription: Bool = true,
                      hasComments: Bool = true) -> VideoDetailView.DetailFocus? {
        TVDetailFocusPolicy.next(
            from: from, direction: move,
            hasChannel: hasChannel, canMarkWatched: canMarkWatched,
            libraryActionsAvailable: libraryActionsAvailable,
            hasDescription: hasDescription, hasComments: hasComments
        )
    }

    func testHeroActionsFollowRowsRatherThanJumpingToMarkWatched() {
        XCTAssertEqual(next(.play, .right), .back)
        XCTAssertEqual(next(.back, .right), .favorite)
        XCTAssertEqual(next(.favorite, .right), .watchLater)
        XCTAssertEqual(next(.watchLater, .left), .favorite)
        XCTAssertEqual(next(.favorite, .left), .back)
        XCTAssertEqual(next(.back, .left), .play)
        XCTAssertEqual(next(.back, .down), .playlist)
        XCTAssertEqual(next(.playlist, .up), .back,
                       "Up from playlist must not land on Mark Watched")
        XCTAssertEqual(next(.playlist, .left), .markWatched)
        XCTAssertEqual(next(.markWatched, .up), .play)
    }

    func testDetailTabsRestoreTheirOwnFocusWithoutUnexpectedWatchedJump() {
        XCTAssertEqual(next(.markWatched, .down), .descriptionEntry)
        XCTAssertEqual(next(.descriptionEntry, .down), .descriptionBody)
        XCTAssertEqual(next(.descriptionBody, .up), .descriptionEntry)
        XCTAssertEqual(next(.descriptionEntry, .right), .commentsTab)
        XCTAssertEqual(next(.commentsTab, .up), .playlist)
        XCTAssertEqual(next(.commentsTab, .left), .descriptionEntry)
        XCTAssertEqual(next(.descriptionEntry, .up), .markWatched)
    }

    func testLiveOrUnloadedActionRowsDoNotRequestMissingFocusTargets() {
        XCTAssertEqual(next(.play, .down, canMarkWatched: false), .playlist)
        XCTAssertEqual(next(.descriptionEntry, .up,
                            canMarkWatched: false), .playlist)
        XCTAssertNil(next(.playlist, .left, canMarkWatched: false))
        XCTAssertNil(next(.back, .right, libraryActionsAvailable: false))
        XCTAssertNil(next(.play, .up, hasChannel: false))
        XCTAssertEqual(next(.playlist, .down, hasDescription: false), .commentsTab)
        XCTAssertNil(next(.playlist, .down, hasDescription: false,
                          hasComments: false))
        XCTAssertNil(next(.commentsTab, .left, hasDescription: false))
    }
}
