import XCTest
import Foundation
@testable import TypeTypeTV

final class SabrPlaybackPreferenceTests: XCTestCase {
    func testDeviceAlwaysCapsAccountDefaultQuality() {
        XCTAssertEqual(SabrPlaybackPreferences.defaultHeight("4K", deviceMax: 1080), 1080)
        XCTAssertEqual(SabrPlaybackPreferences.defaultHeight("720p", deviceMax: 2160), 720)
        XCTAssertEqual(SabrPlaybackPreferences.defaultHeight("auto", deviceMax: 1440), 1440)
        XCTAssertEqual(SabrPlaybackPreferences.defaultHeight("1080p", deviceMax: 2160), 1080)
    }

    func testLanguagePreferencesUseServerCodes() throws {
        let stream = try JSONDecoder().decode(SabrBootstrap.self, from: Data(
            #"""
            {"audioStreams":[
            {"itag":140,"codec":"mp4a.40.2","deliveryMethod":"sabr","audioLocale":"en",
             "isOriginal":true},
            {"itag":140,"codec":"mp4a.40.2","deliveryMethod":"sabr","audioLocale":"de-DE",
             "audioTrackId":"german"}
            ]}
            """#.utf8
        ))
        let tracks = HardwareCodec.audioCandidates(from: stream)
        XCTAssertEqual(SabrPlaybackPreferences.preferredAudio(
            tracks, language: "de", preferOriginal: false
        )?.audioTrackId, "german")
        XCTAssertEqual(SabrPlaybackPreferences.preferredAudio(
            tracks, language: "de", preferOriginal: true
        )?.audioLocale, "en")
    }
}
