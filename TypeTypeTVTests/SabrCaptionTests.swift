import Foundation
import XCTest
@testable import TypeTypeTV

final class SabrCaptionTests: XCTestCase {
    func testWebVTTTimingAndCaptionText() throws {
        let input = Data("""
        WEBVTT

        00:00:01.250 --> 00:00:03.000
        <c>Hello &amp; welcome</c>

        00:03.100 --> 00:04.700
        Second line
        """.utf8)
        let cues = try SabrCaptionParser.decode(input, mime: "text/vtt")
        XCTAssertEqual(cues.count, 2)
        XCTAssertEqual(cues[0].startMs, 1_250)
        XCTAssertEqual(cues[0].text, "Hello & welcome")
        XCTAssertEqual(SabrCaptionCue.showing(cues, at: 2_000), "Hello & welcome")
        XCTAssertNil(SabrCaptionCue.showing(cues, at: 3_050))
    }

    func testTTMLAndMilliseconds() throws {
        let data = Data("""
        <?xml version="1.0" encoding="utf-8"?>
        <tt xmlns="http://www.w3.org/ns/ttml">
          <body><div><p begin="1s" dur="1750ms">Hallo<br/>TV</p></div></body>
        </tt>
        """.utf8)
        let cues = try SabrCaptionParser.decode(data, mime: "application/ttml+xml")
        XCTAssertEqual(cues.first?.startMs, 1_000)
        XCTAssertEqual(cues.first?.endMs, 2_750)
        XCTAssertEqual(cues.first?.text, "Hallo\nTV")
    }

    func testRejectsUnknownCaptionFormat() {
        XCTAssertThrowsError(try SabrCaptionParser.decode(
            Data("random".utf8), mime: "application/octet-stream"
        ))
    }
}
