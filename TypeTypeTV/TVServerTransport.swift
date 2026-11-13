import Foundation
import Security
import CryptoKit

enum TVConnectionMode: String, CaseIterable, Identifiable {
    case https, http
    var id: String { rawValue }
    var title: String { self == .https ? "HTTPS (verschlüsselt)" : "HTTP (lokales Netz)" }
}

/// A strict origin builder. HTTP is only offered for literal private/local
/// names and addresses, never arbitrary Internet hosts.
enum TVServerAddress {
    static func isLocalHost(_ raw: String) -> Bool {
        let host = raw.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        if host == "localhost" || host.hasSuffix(".localhost") || host.hasSuffix(".local") {
            return true
        }
        if !host.contains(".") && !host.contains(":") && !host.isEmpty { return true }
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        if parts.count == 4 {
            let values = parts.compactMap { UInt8($0) }
            if values.count != 4 { return false }
            let a = Int(values[0]), b = Int(values[1])
            return a == 10 || a == 127 || (a == 172 && (16...31).contains(b)) ||
                   (a == 192 && b == 168) || (a == 169 && b == 254)
        }
        if host == "::1" || host.hasPrefix("fe80:") ||
            host.hasPrefix("fc") || host.hasPrefix("fd") { return true }
        return false
    }

    static func make(hostInput: String, mode: TVConnectionMode) throws -> URL {
        let entry = hostInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !entry.isEmpty else { throw TypeTypeError.invalidServerAddress }
        let candidate = entry.contains("://") ? entry : mode.rawValue + "://" + entry
        guard let parts = URLComponents(string: candidate),
              let host = parts.host, !host.isEmpty,
              parts.scheme?.lowercased() == mode.rawValue,
              parts.user == nil, parts.password == nil,
              parts.fragment == nil, parts.query == nil,
              ["", "/", "/api", "/api/"].contains(parts.path)
        else { throw TypeTypeError.invalidServerAddress }
        if mode == .http && !isLocalHost(host) {
            throw TypeTypeError.insecureHTTP
        }
        var canonical = URLComponents()
        canonical.scheme = mode.rawValue
        canonical.host = host
        canonical.port = parts.port
        canonical.path = "/"
        guard let url = canonical.url else { throw TypeTypeError.invalidServerAddress }
        return url
    }

    static func hostInput(from stored: String) -> String {
        guard let url = URLComponents(string: stored), let host = url.host else {
            return stored.replacingOccurrences(of: "https://", with: "")
                         .replacingOccurrences(of: "http://", with: "")
        }
        let bracketedHost = host.contains(":") ? "[\(host)]" : host
        return bracketedHost + url.port.map { ":\($0)" }.orEmpty
    }
}

private extension Optional where Wrapped == String {
    var orEmpty: String { self ?? "" }
}

struct TVCertificateReport: Equatable, Identifiable {
    let origin: URL
    let fingerprint: String
    let subject: String
    let chain: [String]
    let problem: String
    var id: String { origin.absoluteString }
    var formattedFingerprint: String {
        stride(from: 0, to: fingerprint.count, by: 2).map {
            let start = fingerprint.index(fingerprint.startIndex, offsetBy: $0)
            let end = fingerprint.index(start, offsetBy: min(2, fingerprint.count - $0))
            return String(fingerprint[start..<end])
        }.joined(separator: ":")
    }
}

/// This store never authorizes a certificate without an explicit UI action.
/// A changed certificate is rejected, even if the new leaf happens to be
/// system-trusted, until the user reviews it again.
final class TVServerTrust: @unchecked Sendable {
    static let shared = TVServerTrust()
    private let lock = NSLock()
    private var unapproved: [String: TVCertificateReport] = [:]
    private let service = "org.typetype.tvOS.server-certificate-sha256"
    private init() {}

    func report(for origin: URL) -> TVCertificateReport? {
        lock.lock()
        defer { lock.unlock() }
        return unapproved[origin.absoluteString]
    }

    func record(_ report: TVCertificateReport) {
        lock.lock()
        defer { lock.unlock() }
        unapproved[report.origin.absoluteString] = report
    }

    func clearPending(for origin: URL) {
        lock.lock()
        defer { lock.unlock() }
        unapproved.removeValue(forKey: origin.absoluteString)
    }

    func fingerprint(for origin: URL) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: origin.absoluteString,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let bytes = result as? Data else { return nil }
        return String(data: bytes, encoding: .utf8)
    }

    @discardableResult
    func approve(_ report: TVCertificateReport) -> Bool {
        lock.lock()
        let same = unapproved[report.origin.absoluteString]?.fingerprint == report.fingerprint
        lock.unlock()
        guard same else { return false }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: report.origin.absoluteString
        ]
        SecItemDelete(query as CFDictionary)
        var item = query
        item[kSecValueData as String] = Data(report.fingerprint.utf8)
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        guard SecItemAdd(item as CFDictionary, nil) == errSecSuccess else { return false }
        clearPending(for: report.origin)
        return true
    }

    func revoke(for origin: URL) {
        SecItemDelete([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: origin.absoluteString
        ] as CFDictionary)
        clearPending(for: origin)
    }
}

private final class TypeTypeNetworkDelegate: NSObject, URLSessionDelegate, URLSessionTaskDelegate, @unchecked Sendable {
    private let origin: URL
    init(origin: URL) { self.origin = origin }

    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust else {
            completionHandler(.performDefaultHandling, nil)
            return
        }
        let expectedPort = origin.port ?? 443
        guard challenge.protectionSpace.host.lowercased() == origin.host?.lowercased(),
              challenge.protectionSpace.port == expectedPort,
              let trust = challenge.protectionSpace.serverTrust,
              let leaf = SecTrustGetCertificateAtIndex(trust, 0)
        else {
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }

        let certificate = SecCertificateCopyData(leaf) as Data
        let fingerprint = SHA256.hash(data: certificate)
            .map { String(format: "%02X", $0) }.joined()
        let approved = TVServerTrust.shared.fingerprint(for: origin)
        var evaluationError: CFError?
        let valid = SecTrustEvaluateWithError(trust, &evaluationError)
        if approved == nil && valid {
            completionHandler(.performDefaultHandling, nil)
            return
        }
        if approved == fingerprint {
            completionHandler(.useCredential, URLCredential(trust: trust))
            return
        }

        let names: [String] = (0..<SecTrustGetCertificateCount(trust)).compactMap { index in
            guard let cert = SecTrustGetCertificateAtIndex(trust, index) else { return nil }
            return SecCertificateCopySubjectSummary(cert) as String?
        }
        let report = TVCertificateReport(
            origin: origin, fingerprint: fingerprint,
            subject: SecCertificateCopySubjectSummary(leaf) as String? ?? "Unbekannt",
            chain: names,
            problem: valid ? TVL10n.value("certificate.changed")
                           : (evaluationError.map { ($0 as Error).localizedDescription } ??
                              TVL10n.value("certificate.untrustedError"))
        )
        TVServerTrust.shared.record(report)
        completionHandler(.cancelAuthenticationChallenge, nil)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        // Never forward bearer credentials or a trusted certificate to another host.
        completionHandler(nil)
    }
}

private final class TVSessionPool: @unchecked Sendable {
    static let shared = TVSessionPool()
    private let lock = NSLock()
    private var sessions: [String: URLSession] = [:]
    private init() {}

    func session(for origin: URL) -> URLSession {
        lock.lock()
        defer { lock.unlock() }
        if let available = sessions[origin.absoluteString] {
            return available
        }
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 45
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        let created = URLSession(configuration: config,
                                 delegate: TypeTypeNetworkDelegate(origin: origin),
                                 delegateQueue: nil)
        sessions[origin.absoluteString] = created
        return created
    }
}

enum TVNetwork {
    static func session(for origin: URL) -> URLSession {
        TVSessionPool.shared.session(for: origin)
    }
}
