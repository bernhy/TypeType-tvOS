import SwiftUI
import UIKit
import ImageIO

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

/// Public TypeType/YouTube artwork is independent of account membership.
/// Reuse identical images across accounts, keyed by the complete source URL
/// (including query parameters) and the requested decode size.
enum TVThumbnailRequestPolicy {
    static func pixelLimit(_ requested: Int) -> Int {
        min(TVThumbnailDecoder.maximumPixelDimension, max(64, requested))
    }

    static func cacheKey(url: URL, pixels: Int) -> String {
        "\(url.absoluteString)\n#pixels=\(pixelLimit(pixels))"
    }
}

/// Resolve thumbnail sources once: prefer the exact TypeType-provided image
/// (which may be a DeArrow replacement), but recover from missing/stale
/// stored artwork in older history, playlist or watch-later rows. Only a
/// validated YouTube video URL qualifies for the canonical fallback.
enum TVThumbnailImageQuality: String {
    case standard, hero
}

enum TVThumbnailSources {
    static func urls(primary: URL?, videoURL: String?,
                     quality: TVThumbnailImageQuality = .standard) -> [URL] {
        guard let id = videoURL.flatMap(VideoAddress.youtubeID),
              let fallback = URL(string: "https://i.ytimg.com/vi/\(id)/hqdefault.jpg") else {
            return primary.map { [$0] } ?? []
        }
        if quality == .standard {
            if let primary, primary != fallback { return [primary, fallback] }
            return [fallback]
        }

        // High-resolution variants are reserved for the detail hero and
        // playback startup poster; normal grid cards remain inexpensive.
        // Prefer custom DeArrow/server art over standard YouTube artwork.
        let host = primary?.host?.lowercased() ?? ""
        let youtubeArtwork = host == "img.youtube.com" ||
            host == "ytimg.com" || host.hasSuffix(".ytimg.com")
        let maxres = URL(string: "https://i.ytimg.com/vi/\(id)/maxresdefault.jpg")!
        let sd = URL(string: "https://i.ytimg.com/vi/\(id)/sddefault.jpg")!
        var candidates: [URL] = []
        if let primary, !youtubeArtwork { candidates.append(primary) }
        candidates.append(contentsOf: [maxres, sd])
        if let primary { candidates.append(primary) }
        candidates.append(fallback)
        var ordered: [URL] = []
        for candidate in candidates where !ordered.contains(candidate) {
            ordered.append(candidate)
        }
        return ordered
    }

    static func accepts(_ image: UIImage, from url: URL,
                        quality: TVThumbnailImageQuality) -> Bool {
        guard quality == .hero,
              ["maxresdefault.jpg", "sddefault.jpg"]
                .contains(url.lastPathComponent.lowercased()) else { return true }
        // Some unavailable maxres variants respond with a tiny image instead
        // of a 404. Do not upscale their placeholder into a fullscreen hero.
        guard let bitmap = image.cgImage else { return false }
        return bitmap.width >= 640 && bitmap.height >= 360
    }
}

/// A single in-flight HTTP fetch/thumbnail decode per public URL and size.
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
    var videoURL: String? = nil
    var quality: TVThumbnailImageQuality = .standard
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
        .task(id: "\(origin.absoluteString)|\(url?.absoluteString ?? "")|\(maximumPixelDimension)|\(videoURL ?? "")|\(quality.rawValue)") {
            // SwiftUI may reuse a card for a different URL. Do not keep the
            // previous video's artwork visible while the new image loads.
            bitmap = nil
            await load()
        }
        .onDisappear {
            // Lazy grid cells may survive offscreen in SwiftUI's view graph.
            // Release their bitmap; the bounded shared cache can repopulate it.
            bitmap = nil
        }
    }

    @MainActor
    private func load() async {
        let candidates = TVThumbnailSources.urls(
            primary: url, videoURL: videoURL, quality: quality
        )
        guard !candidates.isEmpty else {
            bitmap = nil
            return
        }
        let pixels = TVThumbnailRequestPolicy.pixelLimit(maximumPixelDimension)
        for (index, candidate) in candidates.enumerated() {
            guard !Task.isCancelled else { return }
            let firstParty = candidate.host?.lowercased() == origin.host?.lowercased() &&
                candidate.scheme == origin.scheme && candidate.port == origin.port
            guard candidate.scheme == "https" ||
                  (firstParty && candidate.scheme == "http") else { continue }

            let key = TVThumbnailRequestPolicy.cacheKey(
                url: candidate, pixels: pixels
            ) as NSString
            if let cached = TVThumbnailMemory.shared.configuredCache().object(forKey: key) {
                if TVThumbnailSources.accepts(cached, from: candidate, quality: quality) {
                    bitmap = cached
                    return
                }
                TVThumbnailMemory.shared.configuredCache().removeObject(forKey: key)
            }
            var request = URLRequest(url: candidate)
            request.timeoutInterval = 20
            request.setValue("image/avif,image/webp,image/png,image/jpeg,*/*",
                             forHTTPHeaderField: "Accept")
            if firstParty, let token = TypeTypeCredentials.shared.token(for: origin) {
                request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            }
            guard let decoded = await TVThumbnailWorkPool.shared.image(
                key: key as String, request: request, origin: origin,
                firstParty: firstParty, pixels: pixels
            ), !Task.isCancelled,
               TVThumbnailSources.accepts(decoded.image, from: candidate,
                                          quality: quality) else { continue }
            if let image = decoded.image.cgImage {
                let size = image.bytesPerRow * image.height
                TVThumbnailMemory.shared.configuredCache().setObject(
                    decoded.image, forKey: key, cost: size
                )
            }
            bitmap = decoded.image
            #if DEBUG
            if index > 0 || url == nil {
                NSLog("TypeType thumbnail recovered via YouTube fallback reason=%@",
                      index > 0 ? "primary-unavailable" : "missing-primary")
            }
            #endif
            return
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
    var videoURL: String? = nil

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
        let urls = TVThumbnailSources.urls(
            primary: url, videoURL: videoURL, quality: .hero
        )
        guard retainsImage, !urls.isEmpty else {
            if coordinator.requestKey != nil || view.image != nil {
                coordinator.release(view)
            }
            return
        }
        // Track the whole ordered source list so a changed thumbnail URL
        // invalidates the poster even when both videos share a fallback.
        let requestKey = urls.map(\.absoluteString).joined(separator: "\n") +
            "\n#pixels=\(TVThumbnailDecoder.maximumPixelDimension)"
        guard coordinator.requestKey != requestKey else { return }

        coordinator.release(view, evictCachedImage: false)
        coordinator.requestKey = requestKey
        for source in urls {
            let key = TVThumbnailRequestPolicy.cacheKey(
                url: source, pixels: TVThumbnailDecoder.maximumPixelDimension
            ) as NSString
            if let cached = TVThumbnailMemory.shared.configuredCache()
                .object(forKey: key),
               TVThumbnailSources.accepts(cached, from: source, quality: .hero) {
                view.image = cached
                return
            }
        }

        coordinator.task = Task { @MainActor [weak view, weak coordinator] in
            for source in urls {
                guard !Task.isCancelled,
                      coordinator?.requestKey == requestKey else { return }
                let firstParty = source.host?.lowercased() == origin.host?.lowercased() &&
                    source.scheme == origin.scheme && source.port == origin.port
                guard source.scheme == "https" ||
                      (firstParty && source.scheme == "http") else { continue }

                var request = URLRequest(url: source)
                request.timeoutInterval = 20
                request.setValue("image/avif,image/webp,image/png,image/jpeg,*/*",
                                 forHTTPHeaderField: "Accept")
                if firstParty, let token = TypeTypeCredentials.shared.token(for: origin) {
                    request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
                }
                let key = TVThumbnailRequestPolicy.cacheKey(
                    url: source, pixels: TVThumbnailDecoder.maximumPixelDimension
                )
                guard let decoded = await TVThumbnailWorkPool.shared.image(
                    key: key, request: request, origin: origin, firstParty: firstParty,
                    pixels: TVThumbnailDecoder.maximumPixelDimension
                ), !Task.isCancelled,
                      coordinator?.requestKey == requestKey,
                      TVThumbnailSources.accepts(decoded.image, from: source,
                                                 quality: .hero) else { continue }
                // Startup images remain transient; no shared-cache insertion.
                view?.image = decoded.image
                return
            }
        }
    }

    static func dismantleUIView(_ view: UIImageView, coordinator: Coordinator) {
        coordinator.release(view, evictCachedImage: false)
    }
}
