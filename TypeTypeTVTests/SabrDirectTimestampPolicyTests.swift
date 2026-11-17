import XCTest
@testable import TypeTypeTV

final class SabrDirectTimestampPolicyTests: XCTestCase {
    func testPreservesSmallOriginalAACOffsetInsteadOfInventingGap() {
        XCTAssertTrue(SabrDirectTimestampPolicy.preserveNative(
            nativeStartMs: 10_046, expectedStartMs: 10_000,
            previousActualEndMs: 10_000,
            previousSequence: 3, sequence: 4
        ))
    }

    func testPreservesNativeContinuityWhenSabrMetadataIsWrong() {
        XCTAssertTrue(SabrDirectTimestampPolicy.preserveNative(
            nativeStartMs: 176_643, expectedStartMs: 183_683,
            previousActualEndMs: 176_643,
            previousSequence: 31, sequence: 32
        ))
    }

    func testStandaloneAssetReaderTimebaseStillGetsReanchored() {
        XCTAssertFalse(SabrDirectTimestampPolicy.preserveNative(
            nativeStartMs: 0, expectedStartMs: 125_000,
            previousActualEndMs: 125_000,
            previousSequence: nil, sequence: 22
        ))
    }

    func testNonadjacentSegmentCannotClaimContinuity() {
        XCTAssertFalse(SabrDirectTimestampPolicy.preserveNative(
            nativeStartMs: 176_643, expectedStartMs: 183_683,
            previousActualEndMs: 176_643,
            previousSequence: 30, sequence: 32
        ))
    }

    func testRejectsInvalidNativeTime() {
        XCTAssertFalse(SabrDirectTimestampPolicy.preserveNative(
            nativeStartMs: nil, expectedStartMs: 10_000,
            previousActualEndMs: nil,
            previousSequence: nil, sequence: nil
        ))
    }
    func testSeekTrimmedAACMustNotRebaseFirstRetainedPacketToOldFragment() {
        XCTAssertTrue(SabrDirectTimestampPolicy.preserveNative(
            nativeStartMs: 120_016, expectedStartMs: 111_000,
            previousActualEndMs: nil, previousSequence: nil, sequence: 22,
            seekTargetMs: 120_000
        ))
        XCTAssertFalse(SabrDirectTimestampPolicy.preserveNative(
            nativeStartMs: 0, expectedStartMs: 111_000,
            previousActualEndMs: nil, previousSequence: nil, sequence: 22,
            seekTargetMs: 120_000
        ))
    }
}
