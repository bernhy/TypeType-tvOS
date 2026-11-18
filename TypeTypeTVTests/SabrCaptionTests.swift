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

    func testMalformedGiganticCaptionTimestampsNeverOverflow() throws {
        XCTAssertNil(SabrCaptionParser.timestamp("9223372036854775808ms"))
        XCTAssertNil(SabrCaptionParser.timestamp("1e50ms"))
        XCTAssertNil(SabrCaptionParser.timestamp("1e20s"))
        XCTAssertNil(SabrCaptionParser.timestamp("1e20:00:00"))
        XCTAssertNil(SabrCaptionParser.timestamp("-12ms"))
        XCTAssertEqual(SabrCaptionParser.timestamp("1750ms"), 1_750)
        XCTAssertEqual(SabrCaptionParser.timestamp("1.75s"), 1_750)
        XCTAssertEqual(SabrCaptionParser.timestamp("00:00:01.750"), 1_750)

        let data = Data("""
        WEBVTT

        1e50s --> 1e51s
        Bad cue

        00:00:01.000 --> 00:00:02.000
        Good cue
        """.utf8)
        let cues = try SabrCaptionParser.decode(data, mime: "text/vtt")
        XCTAssertEqual(cues.map(\.text), ["Good cue"])
    }

    func testTTMLDurationPlusStartOverflowDropsOnlyInvalidCue() throws {
        let input = Data("""
        <?xml version="1.0" encoding="utf-8"?>
        <tt xmlns="http://www.w3.org/ns/ttml">
          <body><div>
            <p begin="9000000000000000000ms" dur="500000000000000000ms">Invalid</p>
            <p begin="1s" dur="2s">Valid</p>
          </div></body>
        </tt>
        """.utf8)
        let cues = try SabrCaptionParser.decode(input, mime: "application/ttml+xml")
        XCTAssertEqual(cues.count, 1)
        XCTAssertEqual(cues.first?.text, "Valid")
        XCTAssertEqual(cues.first?.startMs, 1_000)
        XCTAssertEqual(cues.first?.endMs, 3_000)
    }

    func testRejectsUnknownCaptionFormat() {
        XCTAssertThrowsError(try SabrCaptionParser.decode(
            Data("random".utf8), mime: "application/octet-stream"
        ))
    }
}
