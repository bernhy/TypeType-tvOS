import SwiftUI
import UIKit

@MainActor
private final class TVThumbnailMemory {
    static let shared = TVThumbnailMemory()
    let cache: NSCache<NSString, UIImage>
    private init() {
        cache = NSCache<NSString, UIImage>()
        cache.countLimit = 100
        cache.totalCostLimit = 128 * 1_048_576
    }

    func configuredCache() -> NSCache<NSString, UIImage> {
        let selected = UserDefaults.standard.integer(forKey: "typetype.thumbnailCacheMiB")
        let bounded = [32, 64, 128, 256].contains(selected) ? selected : 128
        cache.totalCostLimit = bounded * 1_048_576
        return cache
    }
}

/// Downloads thumbnails through the same verified/pinned session as the API
/// when they originate from the current TypeType instance. CDN images keep
/// Apple's normal system TLS trust; no tokens are forwarded to third parties.
struct TVThumbnail: View {
    let url: URL?
    let origin: URL
    @State private var bitmap: UIImage?

    var body: some View {
        ZStack {
            if let bitmap {
                Image(uiImage: bitmap)
                    .resizable()
                    .scaledToFill()
            } else {
                LinearGradient(
                    colors: [TTTheme.surface, TTTheme.accent.opacity(0.19)],
                    startPoint: .topLeading, endPoint: .bottomTrailing
                )
                Image(systemName: "play.rectangle.fill")
                    .font(.system(size: 55))
                    .foregroundStyle(TTTheme.accent.opacity(0.5))
            }
        }
        .clipped()
        .task(id: url?.absoluteString) {
            await load()
        }
    }

    @MainActor
    private func load() async {
        guard let url else {
            bitmap = nil
            return
        }
        let key = url.absoluteString as NSString
        if let cached = TVThumbnailMemory.shared.configuredCache().object(forKey: key) {
            bitmap = cached
            return
        }
        let firstParty = url.host?.lowercased() == origin.host?.lowercased() &&
            url.scheme == origin.scheme && url.port == origin.port
        guard url.scheme == "https" || (firstParty && url.scheme == "http") else {
            bitmap = nil
            return
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        request.setValue("image/avif,image/webp,image/png,image/jpeg,*/*", forHTTPHeaderField: "Accept")
        if firstParty, let token = TypeTypeCredentials.shared.token(for: origin) {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        do {
            let session = firstParty ? TVNetwork.session(for: origin) : URLSession.shared
            let (data, response) = try await session.data(for: request)
            guard !Task.isCancelled, let http = response as? HTTPURLResponse,
                  http.statusCode == 200, data.count <= 8_000_000,
                  let decoded = UIImage(data: data) else { return }
            let size = Int(decoded.size.width * decoded.size.height * 4)
            TVThumbnailMemory.shared.configuredCache().setObject(decoded, forKey: key, cost: size)
            bitmap = decoded
        } catch {
            // Images may be unavailable before authentication; text stays usable.
        }
    }
}
