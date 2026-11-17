import CoreGraphics
import Foundation
import SwiftUI

/// Metadata provided by TypeType Server's stream response. Coordinates are
/// fractions of the *video picture*, not of the Apple TV's screen.
struct TVEndScreenElement: Decodable, Equatable, Identifiable {
    enum Kind: String {
        case video, playlist, channel, website
    }

    let id: String
    let type: String
    let title: String
    let url: String
    let thumbnailUrl: String
    let startMs: Int64
    let endMs: Int64
    let left: Double
    let top: Double
    let width: Double
    let aspectRatio: Double

    var kind: Kind? { Kind(rawValue: type) }

    var isUsable: Bool {
        guard kind != nil, !id.isEmpty, endMs > startMs,
              startMs >= 0, left.isFinite, top.isFinite,
              width.isFinite, aspectRatio.isFinite,
              (0..<1).contains(left), (0..<1).contains(top),
              width > 0.03, width <= 1, aspectRatio >= 0.25,
              aspectRatio <= 5, let link = URLComponents(string: url),
              link.scheme?.lowercased() == "https",
              let host = link.host?.lowercased(),
              (host == "youtube.com" || host.hasSuffix(".youtube.com") ||
               host == "youtu.be") else { return false }
        // Apple TV does not provide a web browser for arbitrary website cards.
        if kind == .website { return false }
        if kind == .video { return VideoAddress.youtubeID(url) != nil }
        return true
    }

    func visible(at positionMs: Int64) -> Bool {
        isUsable && positionMs >= startMs && positionMs < endMs
    }
}

enum TVEndScreenGeometry {
    static func picture(in size: CGSize, aspectRatio: CGFloat) -> CGRect {
        guard size.width > 0, size.height > 0 else { return .zero }
        let ratio = aspectRatio.isFinite && aspectRatio > 0 ? aspectRatio : 16.0 / 9.0
        let fittedWidth = min(size.width, size.height * ratio)
        let fittedHeight = fittedWidth / ratio
        return CGRect(x: (size.width - fittedWidth) / 2,
                      y: (size.height - fittedHeight) / 2,
                      width: fittedWidth, height: fittedHeight)
    }

    static func card(_ element: TVEndScreenElement, in picture: CGRect) -> CGRect {
        guard picture.width > 0, picture.height > 0 else { return .zero }
        let x = picture.minX + CGFloat(element.left) * picture.width
        let y = picture.minY + CGFloat(element.top) * picture.height
        let w = min(CGFloat(element.width) * picture.width, picture.maxX - x)
        let h = min(w / CGFloat(element.aspectRatio), picture.maxY - y)
        return CGRect(x: x, y: y, width: max(0, w), height: max(0, h))
    }
}

/// tvOS focusable creator cards over the original video coordinates.
/// This is entirely independent of seeking and decoder/renderer queues.
struct TVEndScreenOverlay: View {
    let api: TypeTypeAPI
    let elements: [TVEndScreenElement]
    let videoAspectRatio: CGFloat
    let onSelect: (TVEndScreenElement) -> Void
    let onDismiss: () -> Void
    @FocusState private var focusedID: String?

    var body: some View {
        GeometryReader { viewport in
            let videoRect = TVEndScreenGeometry.picture(
                in: viewport.size, aspectRatio: videoAspectRatio
            )
            ZStack(alignment: .topLeading) {
                Color.clear
                ForEach(Array(elements.prefix(8))) { element in
                    let frame = TVEndScreenGeometry.card(element, in: videoRect)
                    if frame.width > 0, frame.height > 0 {
                        Button { onSelect(element) } label: {
                            ZStack(alignment: .bottomLeading) {
                                TVThumbnail(
                                    url: api.relativeMediaURL(element.thumbnailUrl),
                                    origin: api.origin, contentMode: .fill
                                )
                                LinearGradient(
                                    colors: [.clear, .black.opacity(0.9)],
                                    startPoint: .center, endPoint: .bottom
                                )
                                Text(element.title.isEmpty ? element.type.capitalized : element.title)
                                    .font(.system(size: 18, weight: .semibold))
                                    .foregroundStyle(.white)
                                    .lineLimit(2)
                                    .padding(11)
                            }
                            .frame(width: frame.width, height: frame.height)
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                            .overlay {
                                RoundedRectangle(cornerRadius: 10)
                                    .strokeBorder(focusedID == element.id ? .white : .clear,
                                                  lineWidth: 4)
                            }
                            .scaleEffect(focusedID == element.id ? 1.05 : 1)
                        }
                        .buttonStyle(.plain)
                        .focused($focusedID, equals: element.id)
                        .position(x: frame.midX, y: frame.midY)
                        .accessibilityLabel(element.title)
                    }
                }
                Button(action: onDismiss) {
                    Label("common.close", systemImage: "xmark")
                }
                .buttonStyle(.bordered)
                .position(x: max(85, videoRect.maxX - 85),
                          y: max(45, videoRect.minY + 36))
            }
            .frame(width: viewport.size.width, height: viewport.size.height)
            .focusSection()
            .onAppear { focusedID = elements.first?.id }
            .onChange(of: elements) { _, next in
                if !next.contains(where: { $0.id == focusedID }) {
                    focusedID = next.first?.id
                }
            }
        }
    }
}

/// End-screen navigation is explicit. Video entries start playback; channel
/// and playlist entries open their respective screens with native tvOS Back.
struct TVEndScreenDestination: View {
    let api: TypeTypeAPI
    let element: TVEndScreenElement

    var body: some View {
        NavigationStack {
            switch element.kind {
            case .video:
                PlaybackView(
                    api: api,
                    video: VideoItem(
                        id: VideoAddress.youtubeID(element.url) ?? element.id,
                        title: element.title, url: element.url,
                        thumbnailUrl: element.thumbnailUrl,
                        uploaderName: nil, duration: nil, isLive: false
                    )
                )
            case .playlist:
                TVPublicPlaylistView(api: api, playlistURL: element.url,
                                     startingTitle: element.title)
            case .channel:
                TVSubscriptionsView(api: api, directChannelURL: element.url,
                                    directChannelName: element.title)
            default:
                EmptyView()
            }
        }
    }
}
