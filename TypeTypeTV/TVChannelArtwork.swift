import SwiftUI

/// Channel artwork comes from TypeType's channel API, never from guessed URLs.
struct TVChannelArtwork: Equatable {
    let avatarURL: String?
    let bannerURL: String?

    init(page: TVChannelPage) {
        avatarURL = Self.clean(page.avatarUrl)
        bannerURL = Self.clean(page.bannerUrl)
    }

    var heroURL: String? { bannerURL ?? avatarURL }

    private static func clean(_ string: String?) -> String? {
        guard let trimmed = string?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else { return nil }
        return trimmed
    }
}

/// Share one asynchronous channel lookup between video details and the OSD.
/// Scope entries to the TypeType origin/account, like stream metadata.
actor TVChannelArtworkCache {
    static let shared = TVChannelArtworkCache()
    private var completed: [String: TVChannelArtwork] = [:]
    private var pending: [String: Task<TVChannelArtwork?, Never>] = [:]

    private func key(_ channelURL: String, api: TypeTypeAPI) -> String {
        api.metadataCacheScope + "|" + channelURL
    }

    func remember(_ page: TVChannelPage, for channelURL: String, api: TypeTypeAPI) {
        completed[key(channelURL, api: api)] = TVChannelArtwork(page: page)
    }

    func artwork(for channelURL: String, api: TypeTypeAPI) async -> TVChannelArtwork? {
        let lookup = key(channelURL, api: api)
        if let cached = completed[lookup] { return cached }
        if let task = pending[lookup] { return await task.value }
        let task = Task<TVChannelArtwork?, Never> {
            guard let page = try? await api.channel(channelURL) else { return nil }
            return TVChannelArtwork(page: page)
        }
        pending[lookup] = task
        let image = await task.value
        pending[lookup] = nil
        if let image { completed[lookup] = image }
        return image
    }
}

/// Decorative artwork only, outside the tvOS focus graph.
struct TVChannelAvatar: View {
    let api: TypeTypeAPI
    let imageURL: String?
    let size: CGFloat

    var body: some View {
        ZStack {
            Circle().fill(TTTheme.surface)
            if let url = api.relativeMediaURL(imageURL) {
                TVThumbnail(url: url, origin: api.origin,
                            placeholderSymbol: "person.crop.circle.fill")
                    .frame(width: size, height: size)
                    .clipShape(Circle())
            } else {
                Image(systemName: "person.crop.circle.fill")
                    .resizable()
                    .scaledToFit()
                    .foregroundStyle(.white.opacity(0.6))
                    .padding(size * 0.18)
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .overlay(Circle().strokeBorder(.white.opacity(0.25), lineWidth: 1))
        .accessibilityHidden(true)
        .allowsHitTesting(false)
    }
}

struct TVChannelHeroBackdrop: View {
    let api: TypeTypeAPI
    let avatarURL: String?
    let bannerURL: String?

    var body: some View {
        ZStack {
            TTTheme.surface
            if let raw = (bannerURL?.isEmpty == false ? bannerURL : avatarURL),
               let url = api.relativeMediaURL(raw) {
                TVThumbnail(url: url, origin: api.origin,
                            placeholderSymbol: "person.crop.circle.fill")
                    .blur(radius: bannerURL?.isEmpty == false ? 0 : 18)
                    .scaleEffect(bannerURL?.isEmpty == false ? 1 : 1.14)
            }
            LinearGradient(
                colors: [.black.opacity(0.54), .black.opacity(0.72),
                         .black.opacity(0.86)],
                startPoint: .topLeading, endPoint: .bottomTrailing
            )
        }
        .clipped()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
