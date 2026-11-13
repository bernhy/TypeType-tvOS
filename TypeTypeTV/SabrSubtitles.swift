import Foundation

struct SabrCaptionCue: Equatable {
    let startMs: Int64
    let endMs: Int64
    let text: String

    static func showing(_ cues: [SabrCaptionCue], at timeMs: Int64) -> String? {
        cues.first { $0.startMs <= timeMs && timeMs < $0.endMs }?.text
    }
}

/// Parses only the caption payloads actually supported on tvOS: WebVTT and
/// common TTML timed <p> elements. Bad/unknown formats are not shown as if
/// subtitles had loaded successfully.
enum SabrCaptionParser {
    static func decode(_ data: Data, mime: String?) throws -> [SabrCaptionCue] {
        guard data.count <= 3_000_000 else {
            throw SabrFailure.unsupported("subtitle file exceeds size limit")
        }
        let text = String(decoding: data, as: UTF8.self)
        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let kind = mime?.lowercased() ?? ""
        if kind.contains("vtt") || normalized.hasPrefix("WEBVTT") {
            return webVTT(text)
        }
        if kind.contains("ttml") || kind.contains("xml") ||
           normalized.hasPrefix("<?xml") || normalized.hasPrefix("<tt") {
            let parser = XMLParser(data: data)
            let collector = SabrTTMLCollector()
            parser.delegate = collector
            parser.shouldResolveExternalEntities = false
            guard parser.parse() else {
                throw SabrFailure.unsupported("malformed TTML subtitles")
            }
            return collector.cues.sorted { $0.startMs < $1.startMs }
        }
        throw SabrFailure.unsupported("unsupported subtitle format")
    }

    static func timestamp(_ value: String) -> Int64? {
        let cleaned = value.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: ",", with: ".")
        if cleaned.hasSuffix("ms"),
           let ms = Double(cleaned.dropLast(2)), ms.isFinite && ms >= 0 {
            return Int64(ms)
        }
        if cleaned.hasSuffix("s"),
           let seconds = Double(cleaned.dropLast()), seconds.isFinite && seconds >= 0 {
            return Int64(seconds * 1_000)
        }
        let components = cleaned.split(separator: ":")
        guard components.count == 2 || components.count == 3 else { return nil }
        let numbers = components.compactMap { Double($0) }
        guard numbers.count == components.count, numbers.allSatisfy({
            $0.isFinite && $0 >= 0
        }) else { return nil }
        let seconds = components.count == 3
            ? numbers[0] * 3_600 + numbers[1] * 60 + numbers[2]
            : numbers[0] * 60 + numbers[1]
        guard seconds < Double(Int64.max) / 1_000 else { return nil }
        return Int64(seconds * 1_000)
    }

    private static func webVTT(_ text: String) -> [SabrCaptionCue] {
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let blocks = normalized.components(separatedBy: "\n\n")
        var cues: [SabrCaptionCue] = []
        for block in blocks {
            let rows = block.components(separatedBy: "\n")
            guard let index = rows.firstIndex(where: { $0.contains("-->") }) else {
                continue
            }
            let boundaries = rows[index].components(separatedBy: "-->")
            guard boundaries.count == 2,
                  let start = timestamp(boundaries[0]),
                  let end = timestamp(
                    boundaries[1].trimmingCharacters(in: .whitespaces)
                        .components(separatedBy: " ").first ?? ""
                  ), end > start else { continue }
            let caption = cleanText(rows.dropFirst(index + 1).joined(separator: "\n"))
            guard !caption.isEmpty else { continue }
            cues.append(SabrCaptionCue(startMs: start, endMs: end, text: caption))
        }
        return cues.sorted { $0.startMs < $1.startMs }
    }

    static func cleanText(_ value: String) -> String {
        let noTags = value.replacingOccurrences(
            of: "<[^>]+>", with: "", options: .regularExpression
        )
        return noTags
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private final class SabrTTMLCollector: NSObject, XMLParserDelegate {
    private(set) var cues: [SabrCaptionCue] = []
    private var currentStart: Int64?
    private var currentEnd: Int64?
    private var contents = ""

    func parser(_ parser: XMLParser, didStartElement elementName: String,
                namespaceURI: String?, qualifiedName qName: String?,
                attributes attributeDict: [String : String] = [:]) {
        switch elementName.components(separatedBy: ":").last ?? elementName {
        case "p":
            currentStart = attributeDict["begin"].flatMap(SabrCaptionParser.timestamp)
            currentEnd = attributeDict["end"].flatMap(SabrCaptionParser.timestamp)
            if currentEnd == nil, let start = currentStart,
               let dur = attributeDict["dur"].flatMap(SabrCaptionParser.timestamp) {
                currentEnd = start + dur
            }
            contents = ""
        case "br":
            if currentStart != nil { contents += "\n" }
        default: break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if currentStart != nil { contents += string }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String,
                namespaceURI: String?, qualifiedName qName: String?) {
        guard (elementName.components(separatedBy: ":").last ?? elementName) == "p"
        else { return }
        defer { currentStart = nil; currentEnd = nil; contents = "" }
        guard let start = currentStart, let end = currentEnd, end > start else { return }
        let text = SabrCaptionParser.cleanText(contents)
        if !text.isEmpty {
            cues.append(SabrCaptionCue(startMs: start, endMs: end, text: text))
        }
    }
}

private final class SabrCaptionNoRedirect: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

enum SabrCaptionLoader {
    static func load(_ track: SabrBootstrap.Subtitle, origin: URL) async throws -> [SabrCaptionCue] {
        guard let url = URL(string: track.url, relativeTo: origin)?.absoluteURL,
              let scheme = url.scheme?.lowercased(),
              url.user == nil, url.password == nil else {
            throw SabrFailure.invalidResponse("invalid caption URL")
        }
        let sameOrigin = scheme == origin.scheme &&
            url.host?.lowercased() == origin.host?.lowercased() &&
            url.port == origin.port
        guard scheme == "https" || (scheme == "http" && sameOrigin) else {
            throw SabrFailure.invalidResponse("insecure external caption URL")
        }

        let session: URLSession
        if sameOrigin {
            session = TVNetwork.session(for: origin)
        } else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.httpShouldSetCookies = false
            configuration.httpCookieAcceptPolicy = .never
            configuration.timeoutIntervalForRequest = 25
            session = URLSession(
                configuration: configuration,
                delegate: SabrCaptionNoRedirect(), delegateQueue: nil
            )
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 25
        request.setValue("text/vtt, application/ttml+xml, application/xml",
                         forHTTPHeaderField: "Accept")
        // Never forward the TypeType account bearer token to a caption CDN.
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode) else {
            throw SabrFailure.unsupported("caption download failed")
        }
        return try SabrCaptionParser.decode(data, mime: track.mimeType)
    }
}
