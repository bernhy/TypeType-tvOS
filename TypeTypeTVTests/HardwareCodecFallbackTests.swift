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

    func testQualityMenuDoesNotHideAVCAndVP9AfterEightAV1Formats() {
        // The source may have many 4K AV1 representations. A hard cap on
        // the first eight hid valid lower-resolution alternatives from UI.
        let manyAV1 = (0..<12).map {
            video(100 + $0, codec: "av01.0.08M.08", height: 2160, fps: 30)
        }
        let bootstrap = SabrBootstrap(
            id: nil, hlsUrl: nil, isLive: nil,
            videoOnlyStreams: manyAV1 + [
                video(137, codec: "avc1.640028", height: 1080, fps: 30),
                video(248, codec: "vp09.00.51.08", height: 1080, fps: 30),
                video(900, codec: "hvc1.2.4.L153.B0", height: 1080, fps: 30)
            ],
            audioStreams: [SabrBootstrap.Audio(
                itag: 140, codec: "mp4a.40.2", mimeType: "audio/mp4",
                audioTrackId: nil, audioTrackName: nil, audioLocale: nil,
                isOriginal: true, deliveryMethod: "sabr"
            )]
        )
        // Software allowance here makes the test independent of the Xcode
        // simulator's dynamically reported hardware decoder capabilities.
        let options = HardwareCodec.candidates(from: bootstrap, allowSoftware: true)
        XCTAssertEqual(options.count, 15)
        XCTAssertTrue(options.contains { $0.video.itag == 137 })
        XCTAssertTrue(options.contains { $0.video.itag == 248 })
        XCTAssertTrue(options.contains { $0.video.itag == 900 })
    }

    func testTwoLevelQualityMenuGroupsCodecBeforeResolutionAndFrameRate() {
        let tracks = [
            video(1, codec: "av01.0.08M.08", height: 2160, fps: 30),
            video(2, codec: "av01.0.08M.08", height: 2160, fps: 30),
            video(3, codec: "av01.0.08M.08", height: 1080, fps: 60),
            video(4, codec: "avc1.640028", height: 1080, fps: 30),
            video(5, codec: "vp09.00.51.08", height: 720, fps: 30),
            video(6, codec: "hvc1.2.4.L153.B0", height: 1080, fps: 30)
        ]
        XCTAssertEqual(SabrVideoQualityGroups.codecs(from: tracks),
                       [.av1, .hevc, .vp9, .h264])
        let choices = SabrVideoQualityGroups.variants(
            codec: .av1, from: tracks, selectedItag: nil
        )
        XCTAssertEqual(choices.map(\.itag), [1, 3],
                       "Duplicate AV1 representations should not clutter resolution list")
        let retained = SabrVideoQualityGroups.variants(
            codec: .av1, from: tracks, selectedItag: 2
        )
        XCTAssertEqual(retained.map(\.itag), [2, 3],
                       "An already selected representation should remain checked")
        XCTAssertEqual(
            SabrVideoQualityGroups.variants(codec: .h264, from: tracks,
                                            selectedItag: nil).map(\.itag),
            [4]
        )
    }

    func testAutoPlaybackPrefersHardwareOverHigherResolutionSoftwareCodec() {
        let audio = SabrBootstrap.Audio(
            itag: 140, codec: "mp4a.40.2", mimeType: "audio/mp4",
            audioTrackId: nil, audioTrackName: nil, audioLocale: nil,
            isOriginal: true, deliveryMethod: "sabr"
        )
        let videos = [
            video(400, codec: "av01.0.08M.08", height: 2160, fps: 30),
            video(137, codec: "avc1.640028", height: 1080, fps: 30),
            video(248, codec: "vp09.00.51.08", height: 720, fps: 30),
            video(401, codec: "av01.0.08M.08", height: 1080, fps: 30)
        ]
        let candidates = videos.map { SabrSelection(video: $0, audio: audio) }
        let hardware: (String) -> Bool = { $0.hasPrefix("avc1") || $0.hasPrefix("vp09") }
        let auto = SabrPlaybackPreferences.orderedAutomaticVideos(
            candidates, defaultQuality: nil, deviceMax: 2160,
            hardwareSupported: hardware
        )
        XCTAssertEqual(auto.map(\.video.itag), [137, 248, 400, 401],
                       "A 4K software AV1 stream must not outrank 1080p hardware AVC")
        let capped = SabrPlaybackPreferences.orderedAutomaticVideos(
            candidates, defaultQuality: "1080p", deviceMax: 2160,
            hardwareSupported: hardware
        )
        XCTAssertEqual(capped.map(\.video.itag), [137, 248, 401, 400])
    }

    func testAutomaticSelectionStillWorksWhenNoHardwareCodecIsOffered() {
        let audio = SabrBootstrap.Audio(
            itag: 140, codec: "mp4a.40.2", mimeType: "audio/mp4",
            audioTrackId: nil, audioTrackName: nil, audioLocale: nil,
            isOriginal: true, deliveryMethod: "sabr"
        )
        let av1 = SabrSelection(video: video(
            401, codec: "av01.0.08M.08", height: 1080, fps: 30
        ), audio: audio)
        let auto = SabrPlaybackPreferences.orderedAutomaticVideos(
            [av1], defaultQuality: nil, deviceMax: 2160,
            hardwareSupported: { _ in false }
        )
        XCTAssertEqual(auto.map(\.video.itag), [401],
                       "A manually permitted software-only set remains playable")
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
