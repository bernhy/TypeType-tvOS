import Foundation

enum TVRecentQueries {
    static let limit = 8

    static func decode(_ value: String) -> [String] {
        guard let data = value.data(using: .utf8),
              let entries = try? JSONDecoder().decode([String].self, from: data)
        else { return [] }
        var result: [String] = []
        for term in entries {
            let trimmed = term.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty || trimmed.count > 96 { continue }
            if !result.contains(where: { $0.localizedCaseInsensitiveCompare(trimmed) == .orderedSame }) {
                result.append(trimmed)
            }
            if result.count == limit { break }
        }
        return result
    }

    static func add(_ term: String, to current: [String]) -> [String] {
        let trimmed = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 96 else { return current }
        let remainder = current.filter {
            $0.localizedCaseInsensitiveCompare(trimmed) != .orderedSame
        }
        return Array(([trimmed] + remainder).prefix(limit))
    }

    static func encode(_ values: [String]) -> String {
        guard let data = try? JSONEncoder().encode(Array(values.prefix(limit))),
              let text = String(data: data, encoding: .utf8) else { return "[]" }
        return text
    }
}
