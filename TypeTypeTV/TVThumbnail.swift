import SwiftUI
import UIKit
import ImageIO
import CryptoKit

/// Decode only a bounded thumbnail instead of eagerly expanding potentially
/// huge third-party images. This limits memory spikes from highly compressed
/// CDN artwork without changing the original aspect ratio.
enum TVThumbnailDecoder {
    static let maximumPixelDimension = 2_048

    static func decode(_ data: Data, maximumDimension: Int = maximumPixelDimension) -> UIImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
            return nil
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: TVThumbnailRequestPolicy.pixelLimit(maximumDimension),
            kCGImageSourceShouldCacheImmediately: true
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(
            source, 0, options as CFDictionary
        ) else { return nil }
        return UIImage(cgImage: image)
    }
}

/// A decoded UIImage is immutable after its CGImage-backed creation and can
/// safely cross from a worker task to the MainActor for display.
private struct TVThumbnailDecoded: @unchecked Sendable {
    let image: UIImage
}

/// Opaque, size- and account-scoped cache keys: never retain a bearer token
/// directly in NSCache keys. Different signed-in users cannot share images.
enum TVThumbnailRequestPolicy {
    static func pixelLimit(_ requested: Int) -> Int {
        min(TVThumbnailDecoder.maximumPixelDimension, max(64, requested))
    }

    static func cacheKey(url: URL, origin: URL, token: String?,
                         firstParty: Bool, pixels: Int) -> String {
        let scope = firstParty ? (token ?? "guest") : "public"
        let input = "\(origin.absoluteString)\n\(url.absoluteString)\n\(scope)\n\(pixelLimit(pixels))"
        return SHA256.hash(data: Data(input.utf8))
            .map { String(format: "%02x", $0) }.joined()
    }
}

/// A single in-flight HTTP fetch/thumbnail decode per URL, account and size.
/// Limit work across the whole TV, not once per lazily materialized card.
/// The URLSession download is asynchronous; ImageIO runs on a detached
/// utility worker, never in SwiftUI's MainActor image-loading task.
private actor TVThumbnailWorkPool {
    static let shared = TVThumbnailWorkPool()
    private struct Entry {
        let task: Task<TVThumbnailDecoded?, Never>
        var subscribers: Set<UUID>
    }
    private var pending: [String: Entry] = [:]
    private var active = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private let maximumConcurrent = 4

    func image(key: String, request: URLRequest, origin: URL,
               firstParty: Bool, pixels: Int) async -> TVThumbnailDecoded? {
        let subscriber = UUID()
        let task: Task<TVThumbnailDecoded?, Never>
        if var existing = pending[key] {
            existing.subscribers.insert(subscriber)
            pending[key] = existing
            task = existing.task
        } else {
            task = Task.detached(priority: .utility) { () -> TVThumbnailDecoded? in
                await TVThumbnailWorkPool.shared.acquire()
                let result: TVThumbnailDecoded?
                if Task.isCancelled {
                    result = nil
                } else {
                    result = await Self.download(
                        request: request, origin: origin, firstParty: firstParty,
                        pixels: pixels
                    )
                }
                await TVThumbnailWorkPool.shared.release()
                return result
            }
            pending[key] = Entry(task: task, subscribers: [subscriber])
        }
        // SwiftUI cancels .task when a card scrolls out or a view disappears.
        // Drop that subscriber immediately; only cancel the shared network
        // request once its *last* interested view has gone away.
        return await withTaskCancellationHandler {
            let result = await task.value
            releaseSubscriber(key: key, subscriber: subscriber)
            return Task.isCancelled ? nil : result
        } onCancel: {
            Task { await self.releaseSubscriber(key: key, subscriber: subscriber) }
        }
    }

    private func releaseSubscriber(key: String, subscriber: UUID) {
        guard var entry = pending[key],
              entry.subscribers.remove(subscriber) != nil else { return }
        if entry.subscribers.isEmpty {
            entry.task.cancel()
            pending[key] = nil
        } else {
            pending[key] = entry
        }
    }

    private func acquire() async {
        if active < maximumConcurrent {
            active += 1
        } else {
            await withCheckedContinuation { waiter in waiters.append(waiter) }
        }
    }

    private func release() {
        if waiters.isEmpty {
            active -= 1
        } else {
            waiters.removeFirst().resume()
        }
    }

    private nonisolated static func download(
        request: URLRequest, origin: URL, firstParty: Bool, pixels: Int
    ) async -> TVThumbnailDecoded? {
        do {
            let session = firstParty ? TVNetwork.session(for: origin) : URLSession.shared
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse,
                  http.statusCode == 200, data.count <= 8_000_000,
                  let image = TVThumbnailDecoder.decode(
                    data, maximumDimension: pixels
                  ) else { return nil }
            return TVThumbnailDecoded(image: image)
        } catch {
            // A failed thumbnail must never block browsing or video playback.
            return nil
        }
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
    // Cards are displayed well below 1024px; larger hero artwork can opt
    // into 2048px without forcing every grid cell to decode a full image.
    var maximumPixelDimension = 1_024
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
        .task(id: "\(origin.absoluteString)|\(url?.absoluteString ?? "")|\(maximumPixelDimension)") {
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
        let accountToken = firstParty ? TypeTypeCredentials.shared.token(for: origin) : nil
        let pixels = TVThumbnailRequestPolicy.pixelLimit(maximumPixelDimension)
        let key = TVThumbnailRequestPolicy.cacheKey(
            url: url, origin: origin, token: accountToken,
            firstParty: firstParty, pixels: pixels
        ) as NSString
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
        guard let decoded = await TVThumbnailWorkPool.shared.image(
            key: key as String, request: request, origin: origin,
            firstParty: firstParty, pixels: pixels
        ), !Task.isCancelled else { return }
        if let image = decoded.image.cgImage {
            let size = image.bytesPerRow * image.height
            TVThumbnailMemory.shared.configuredCache().setObject(
                decoded.image, forKey: key, cost: size
            )
        }
        bitmap = decoded.image
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
        let key = TVThumbnailRequestPolicy.cacheKey(
            url: url, origin: origin, token: token,
            firstParty: firstParty, pixels: TVThumbnailDecoder.maximumPixelDimension
        )
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
            guard let decoded = await TVThumbnailWorkPool.shared.image(
                key: key, request: request, origin: origin,
                firstParty: firstParty, pixels: TVThumbnailDecoder.maximumPixelDimension
            ), !Task.isCancelled,
                  coordinator?.requestKey == key else { return }
            // No insertion into NSCache: this image is owned by the poster
            // and released after its fade. Share only concurrent downloads.
            view?.image = decoded.image
        }
    }

    static func dismantleUIView(_ view: UIImageView, coordinator: Coordinator) {
        coordinator.release(view, evictCachedImage: false)
    }
}
