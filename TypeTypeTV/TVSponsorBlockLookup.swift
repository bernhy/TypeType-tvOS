import CryptoKit
import Foundation

/// TypeType's YouTube SABR bootstrap currently returns an empty segment list.
/// Fallback to the SponsorBlock read-only hash-prefix API without sending the
/// full video ID. The 4-character SHA256 prefix provides k-anonymity.
/// Never contact this third party while SponsorBlock is disabled.
actor TVSponsorBlockLookup {
    static let shared = TVSponsorBlockLookup()
    private struct Cached {
        let segments: [TVSponsorBlockSegment]
        let until: Date
    }
    private var cache: [String: Cached] = [:]
    private var tasks: [String: Task<[TVSponsorBlockSegment], Never>] = [:]

    private struct Segment: Decodable {
        let segment: [Double]
        let category: String
        let actionType: String?
        var mapped: TVSponsorBlockSegment? {
            guard segment.count == 2 else { return nil }
            return TVSponsorBlockSegment(
                startTime: segment[0], endTime: segment[1],
                category: category, action: actionType ?? "skip"
            )
        }
    }
    private struct Response: Decodable {
        let videoID: String
        let segments: [Segment]
    }

    func segments(for videoID: String) async -> [TVSponsorBlockSegment] {
        if let cached = cache[videoID], cached.until > Date() {
            return cached.segments
        }
        if let running = tasks[videoID] { return await running.value }
        let running = Task { await fetch(videoID) }
        tasks[videoID] = running
        let answer = await running.value
        tasks[videoID] = nil
        if cache.count >= 64, let first = cache.keys.first {
            cache.removeValue(forKey: first)
        }
        // Negative results expire quickly after temporary network failures;
        // successful segment results are cached longer to limit API traffic.
        cache[videoID] = Cached(
            segments: answer,
            until: Date().addingTimeInterval(answer.isEmpty ? 300 : 14_400)
        )
        return answer
    }

    private func fetch(_ videoID: String) async -> [TVSponsorBlockSegment] {
        guard !videoID.isEmpty, videoID.count <= 32 else { return [] }
        let digest = SHA256.hash(data: Data(videoID.utf8))
        let prefix = digest.prefix(2).map { String(format: "%02x", $0) }.joined()
        var components = URLComponents(
            string: "https://sponsor.ajay.app/api/skipSegments/" + prefix
        )
        let categories = TVSponsorBlock.categories
        guard let categoriesData = try? JSONSerialization.data(withJSONObject: categories),
              let categoriesJSON = String(data: categoriesData, encoding: .utf8) else { return [] }
        components?.queryItems = [
            URLQueryItem(name: "categories", value: categoriesJSON),
            URLQueryItem(name: "actionTypes", value: #"["skip","mute","full","poi","chapter"]"#)
        ]
        guard let url = components?.url else { return [] }
        var request = URLRequest(url: url)
        request.timeoutInterval = 9
        request.setValue("TypeType-tvOS/1.0", forHTTPHeaderField: "User-Agent")
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard !Task.isCancelled, let http = response as? HTTPURLResponse,
                  http.statusCode == 200, data.count < 2_000_000 else { return [] }
            let answers = try JSONDecoder().decode([Response].self, from: data)
            return answers.first { $0.videoID == videoID }?.segments.compactMap(\.mapped) ?? []
        } catch {
            // SponsorBlock availability never blocks video playback.
            return []
        }
    }
}