import SwiftUI

/// The native tvOS highlight responds to touchpad gimbal motion with a
/// *moving* specular reflection, unlike a static gradient. Scope it to the
/// artwork viewport: the parent card retains its exact 1.065 zoom and its
/// counter-scaled timestamp badge. Other focus affordances stay custom.
struct TVFocusedArtworkGlint: ViewModifier {
    var enabled = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .contentShape(.hoverEffect, RoundedRectangle(cornerRadius: 10))
            .hoverEffect(.highlight, isEnabled: enabled && !reduceMotion)
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
