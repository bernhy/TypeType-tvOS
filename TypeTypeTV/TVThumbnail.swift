import SwiftUI
import UIKit
import ImageIO

/// Decode only a bounded thumbnail instead of eagerly expanding potentially
/// huge third-party images. This limits memory spikes from highly compressed
/// CDN artwork without changing the original aspect ratio.
enum TVThumbnailDecoder {
    static let maximumPixelDimension = 2_048

    static func decode(_ data: Data) -> UIImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
            return nil
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maximumPixelDimension,
            kCGImageSourceShouldCacheImmediately: true
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(
            source, 0, options as CFDictionary
        ) else { return nil }
        return UIImage(cgImage: image)
    }
}

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
    // Default to cover for hero artwork. Card artwork instead uses .fit so
    // focusing it never cuts off faces/text along the edges.
    var contentMode: ContentMode = .fill
    var placeholderSymbol = "play.rectangle.fill"
    @State private var bitmap: UIImage?

    var body: some View {
        // Both axes stay bounded to the thumbnail viewport. For video
        // cards we use .fit to preserve the whole picture when a focused
        // card grows; hero artwork may still use the default .fill.
        GeometryReader { geometry in
            ZStack {
                if let bitmap {
                    Image(uiImage: bitmap)
                        .resizable()
                        .aspectRatio(contentMode: contentMode)
                        .frame(width: geometry.size.width, height: geometry.size.height)
                } else {
                    LinearGradient(
                        colors: [TTTheme.surface, TTTheme.accent.opacity(0.19)],
                        startPoint: .topLeading, endPoint: .bottomTrailing
                    )
                    Image(systemName: placeholderSymbol)
                        .font(.system(size: 55))
                        .foregroundStyle(TTTheme.accent.opacity(0.5))
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .clipped()
        }
        .clipped()
        .task(id: url?.absoluteString) {
            // SwiftUI may reuse a card for a different URL. Do not keep the
            // previous video's artwork visible while the new image loads.
            bitmap = nil
            await load()
        }
    }

    @MainActor
    private func load() async {
        guard let url else {
            bitmap = nil
            return
        }
        let firstParty = url.host?.lowercased() == origin.host?.lowercased() &&
            url.scheme == origin.scheme && url.port == origin.port
        // A first-party media route can be account-specific. Keep the image
        // cache scoped to its bearer token, even on a shared household Apple TV.
        let accountToken = firstParty ? TypeTypeCredentials.shared.token(for: origin) : nil
        let key = (url.absoluteString +
            (firstParty ? "|account:" + (accountToken ?? "guest") : "")) as NSString
        if let cached = TVThumbnailMemory.shared.configuredCache().object(forKey: key) {
            bitmap = cached
            return
        }
        guard url.scheme == "https" || (firstParty && url.scheme == "http") else {
            bitmap = nil
            return
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        request.setValue("image/avif,image/webp,image/png,image/jpeg,*/*", forHTTPHeaderField: "Accept")
        if firstParty, let accountToken {
            request.setValue("Bearer \(accountToken)", forHTTPHeaderField: "Authorization")
        }
        do {
            let session = firstParty ? TVNetwork.session(for: origin) : URLSession.shared
            let (data, response) = try await session.data(for: request)
            guard !Task.isCancelled, let http = response as? HTTPURLResponse,
                  http.statusCode == 200, data.count <= 8_000_000,
                  let decoded = TVThumbnailDecoder.decode(data),
                  let image = decoded.cgImage else { return }
            let size = image.bytesPerRow * image.height
            TVThumbnailMemory.shared.configuredCache().setObject(decoded, forKey: key, cost: size)
            bitmap = decoded
        } catch {
            // Images may be unavailable before authentication; text stays usable.
        }
    }
}


/// A stable UIKit thumbnail surface reserved for the SABR startup poster.
/// Unlike regular video-card thumbnails, its decoded image is never added to
/// the shared cache. Once the fade completes we clear UIImageView.image,
/// cancel any unfinished fetch, and release the entry if already cached.
/// makeUIView is never conditional on playback/seek state.
struct TVTransientStartupImage: UIViewRepresentable {
    let url: URL?
    let origin: URL
    let retainsImage: Bool

    @MainActor
    final class Coordinator: NSObject {
        var requestKey: String?
        var task: Task<Void, Never>?

        func release(_ view: UIImageView, evictCachedImage: Bool = true) {
            task?.cancel()
            task = nil
            let key = requestKey
            requestKey = nil
            view.image = nil
            if evictCachedImage, let key {
                // Evict only this poster image, not the entire shared
                // thumbnail cache used by rails and recommendations.
                TVThumbnailMemory.shared.configuredCache()
                    .removeObject(forKey: key as NSString)
            }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> UIImageView {
        let view = UIImageView()
        view.backgroundColor = .clear
        view.contentMode = .scaleAspectFill
        view.clipsToBounds = true
        return view
    }

    func updateUIView(_ view: UIImageView, context: Context) {
        let coordinator = context.coordinator
        guard retainsImage, let url else {
            if coordinator.requestKey != nil || view.image != nil {
                coordinator.release(view)
            }
            return
        }

        let firstParty = url.host?.lowercased() == origin.host?.lowercased() &&
            url.scheme == origin.scheme && url.port == origin.port
        let token = firstParty ? TypeTypeCredentials.shared.token(for: origin) : nil
        let key = url.absoluteString +
            (firstParty ? "|account:" + (token ?? "guest") : "")
        guard coordinator.requestKey != key else { return }

        coordinator.release(view, evictCachedImage: false)
        coordinator.requestKey = key
        if let cached = TVThumbnailMemory.shared.configuredCache()
            .object(forKey: key as NSString) {
            view.image = cached
            return
        }
        guard url.scheme == "https" || (firstParty && url.scheme == "http") else {
            coordinator.requestKey = nil
            return
        }

        coordinator.task = Task { @MainActor [weak view, weak coordinator] in
            var request = URLRequest(url: url)
            request.timeoutInterval = 20
            request.setValue("image/avif,image/webp,image/png,image/jpeg,*/*",
                             forHTTPHeaderField: "Accept")
            if firstParty, let token {
                request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            }
            do {
                let session = firstParty ? TVNetwork.session(for: origin) : URLSession.shared
                let (bytes, response) = try await session.data(for: request)
                guard !Task.isCancelled,
                      let http = response as? HTTPURLResponse,
                      http.statusCode == 200, bytes.count <= 8_000_000,
                      let bitmap = TVThumbnailDecoder.decode(bytes),
                      !Task.isCancelled,
                      coordinator?.requestKey == key else { return }
                // No insertion into NSCache: this UIImage is owned by the
                // poster surface and discarded after its fade completes.
                view?.image = bitmap
            } catch {
                // The existing black backdrop still works without artwork.
            }
        }
    }

    static func dismantleUIView(_ view: UIImageView, coordinator: Coordinator) {
        coordinator.release(view, evictCachedImage: false)
    }
}
