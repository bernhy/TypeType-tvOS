import XCTest
@testable import TypeTypeTV

final class TVSabrMediaTransportTests: XCTestCase {
    func testExplicitPlayPauseAreIdempotentEvenWhileBuffering() {
        XCTAssertFalse(TVMediaTransportCommand.play.wantsPause(currentlyPaused: false))
        XCTAssertFalse(TVMediaTransportCommand.play.wantsPause(currentlyPaused: true))
        XCTAssertTrue(TVMediaTransportCommand.pause.wantsPause(currentlyPaused: false))
        XCTAssertTrue(TVMediaTransportCommand.pause.wantsPause(currentlyPaused: true))
    }

    func testToggleUsesUserIntentNotActualRendererRate() {
        XCTAssertTrue(TVMediaTransportCommand.toggle.wantsPause(currentlyPaused: false))
        XCTAssertFalse(TVMediaTransportCommand.toggle.wantsPause(currentlyPaused: true))
    }

    func testOnlyCrossSourceDuplicateWithinOnePressIsSuppressed() {
        var dedupe = TVMediaCommandDeduplicator()
        XCTAssertTrue(dedupe.shouldHandle(source: .siriRemote, at: 100))
        XCTAssertFalse(dedupe.shouldHandle(source: .system, at: 100.08))
        XCTAssertTrue(dedupe.shouldHandle(source: .system, at: 100.35))
        XCTAssertTrue(dedupe.shouldHandle(source: .system, at: 100.41),
                      "Two independent AirPods events must both be handled")
        XCTAssertTrue(dedupe.shouldHandle(source: .siriRemote, at: 101))
    }
}
