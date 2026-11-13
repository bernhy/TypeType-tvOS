import XCTest
@testable import TypeTypeTV

final class HardwareCodecFallbackTests: XCTestCase {
    private func video(_ id: Int, codec: String, height: Int, fps: Int) -> SabrBootstrap.Video {
        SabrBootstrap.Video(itag: id, codec: codec, mimeType: "video/mp4",
                            width: height * 16 / 9, height: height, fps: fps,
                            bitrate: 3_000_000, deliveryMethod: "sabr")
    }

    func testFallbacksRemainWithinResolutionAndFrameRateLimits() {
        let bootstrap = SabrBootstrap(
            id: nil, hlsUrl: nil, isLive: nil,
            videoOnlyStreams: [
                video(1, codec: "av01.0.08M.08", height: 2160, fps: 30),
                video(2, codec: "hvc1.2.4.L153.B0", height: 1080, fps: 60),
                video(3, codec: "avc1.640028", height: 1080, fps: 30),
                video(4, codec: "avc1.640028", height: 720, fps: 30),
                video(5, codec: "avc1.640028", height: 1080, fps: 120)
            ],
            audioStreams: [SabrBootstrap.Audio(
                itag: 140, codec: "mp4a.40.2", mimeType: "audio/mp4",
                audioTrackId: nil, audioTrackName: nil, audioLocale: nil,
                isOriginal: true, deliveryMethod: "sabr"
            )]
        )
        let ordered = HardwareCodec.candidates(
            from: bootstrap, maxHeight: 1080, allowSoftware: true
        )
        XCTAssertEqual(ordered.map { $0.video.itag }, [2, 3, 4])
        XCTAssertEqual(HardwareCodec.choose(
            from: bootstrap, maxHeight: 1080, allowSoftware: true
        )?.video.itag, 2)
        XCTAssertNil(HardwareCodec.choose(
            from: bootstrap, maxHeight: 480, allowSoftware: true
        ))
    }

    func testMissingCompatibleAudioDisablesPlaybackSelection() {
        let bootstrap = SabrBootstrap(id: nil, hlsUrl: nil, isLive: nil,
            videoOnlyStreams: [video(137, codec: "avc1.640028", height: 1080, fps: 30)],
            audioStreams: []
        )
        XCTAssertTrue(HardwareCodec.candidates(
            from: bootstrap, allowSoftware: true
        ).isEmpty)
    }
}
