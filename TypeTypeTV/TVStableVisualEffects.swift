import SwiftUI

/// Highlight artwork, not the timestamp or progress badges. Unlike tvOS's
/// automatic card focus treatment, this remains visible with our custom
/// NavigationLink focus style and retains the full uncropped 16:9 image.
struct TVFocusedArtworkGlint: ViewModifier {
    let focused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content.overlay {
            LinearGradient(stops: [
                .init(color: .clear, location: 0.03),
                .init(color: .white.opacity(0.03), location: 0.28),
                .init(color: .white.opacity(0.31), location: 0.44),
                .init(color: .white.opacity(0.08), location: 0.59),
                .init(color: .clear, location: 0.85)
            ], startPoint: .topLeading, endPoint: .bottomTrailing)
            .opacity(focused ? 1 : 0)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.20), value: focused)
            .allowsHitTesting(false)
        }
    }
}

/// Stable tvOS transition choices, separate from the remaining experiments.
enum TVStableMotion {
    static func noticeTransition(reduceMotion: Bool) -> AnyTransition {
        reduceMotion ? .opacity : .move(edge: .top).combined(with: .opacity)
    }

    static func noticeAnimation(reduceMotion: Bool) -> Animation {
        .easeOut(duration: reduceMotion ? 0.14 : 0.28)
    }
}
