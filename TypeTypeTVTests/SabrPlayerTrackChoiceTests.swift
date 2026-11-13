import XCTest
import Foundation
@testable import TypeTypeTV

final class SabrPlayerTrackChoiceTests: XCTestCase {
    func testAudioLanguageChoicesRemainDistinct() throws {
        let input = try JSONDecoder().decode(SabrBootstrap.self, from: Data(
            #"""
            {"audioStreams":[
                {"itag":140,"codec":"mp4a.40.2","deliveryMethod":"sabr",
                  "audioTrackId":"en","audioTrackName":"English","isOriginal":true},
                {"itag":140,"codec":"mp4a.40.2","deliveryMethod":"sabr",
                  "audioTrackId":"fr","audioTrackName":"Français"},
                {"itag":251,"codec":"opus","deliveryMethod":"sabr",
                  "audioTrackId":"de"}
            ]}
            """#.utf8
        ))
        XCTAssertEqual(
            HardwareCodec.audioCandidates(from: input).map { $0.audioTrackId ?? "" },
            ["en", "fr"]
        )
    }
}
