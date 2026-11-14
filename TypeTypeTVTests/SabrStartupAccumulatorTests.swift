import XCTest
@testable import TypeTypeTV

final class SabrStartupAccumulatorTests: XCTestCase {
    func testAudioAndVideoMayStartAtDifferentSegmentIndices() throws {
        var pending = SabrStartupAccumulator<Int>()
        XCTAssertNil(try pending.append(audio: [1, 2], video: []))
        let ready = try XCTUnwrap(pending.append(audio: [3], video: [10, 11]))
        XCTAssertEqual(ready.audio, [1, 2, 3])
        XCTAssertEqual(ready.video, [10, 11])
        XCTAssertTrue(pending.audio.isEmpty)
        XCTAssertTrue(pending.video.isEmpty)
    }

    func testVideoMayArriveBeforeAudioInLaterWindow() throws {
        var pending = SabrStartupAccumulator<Int>()
        XCTAssertNil(try pending.append(audio: [], video: [50, 60]))
        XCTAssertNil(try pending.append(audio: [], video: [70]))
        let ready = try XCTUnwrap(pending.append(audio: [1], video: []))
        XCTAssertEqual(ready.audio, [1])
        XCTAssertEqual(ready.video, [50, 60, 70])
    }

    func testStartupBufferHasFiniteBound() throws {
        var pending = SabrStartupAccumulator<Int>(maxSamplesPerTrack: 2)
        XCTAssertNil(try pending.append(audio: [1, 2], video: []))
        XCTAssertThrowsError(try pending.append(audio: [3], video: []))
    }
}
