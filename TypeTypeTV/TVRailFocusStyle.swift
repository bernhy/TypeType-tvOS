import SwiftUI

/// Stable-size focus behavior for our two navigation rails.
/// SwiftUI's tvOS .plain ButtonStyle can still supply its own focused/pressed
/// decoration. Using a custom style and disabling the native focus effect on
/// the rail lets each row draw exactly one rounded focus pill.
struct TVRailButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.83 : 1)
            .scaleEffect(1)
    }
}

/// A native tvOS horizontal move may focus a vertically closer *wrong* rail
/// element for one frame before the explicit FocusState restoration wins.
/// Never use that unverified focus value directly to draw our white focus pill.
/// On entry, the logical selected destination owns the visual highlight.
/// Only a confirmed movement *within* the rail can follow native focus.
enum TVRailVisualFocus {
    static func highlights<Item: Equatable>(
        _ item: Item, focused: Item?, selected: Item,
        browsingWithinRail: Bool = false
    ) -> Bool {
        guard let focused else { return false }
        return browsingWithinRail ? focused == item : selected == item
    }
}

/// One consistent appearance for the main rail and Settings subnavigation.
/// The selected section stays TypeType red, including while it has focus.
struct TVRailRowHighlight: ViewModifier {
    let focused: Bool
    let selected: Bool

    func body(content: Content) -> some View {
        content
            .foregroundStyle(selected ? TTTheme.accent :
                             (focused ? TTTheme.ink : TTTheme.muted))
            .background {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(focused ? Color.white : .clear)
            }
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

/// Cards in pushed pages need a visible focus halo. The rail button style
/// deliberately draws none, and we avoid scaling the text or cropping thumbs.
struct TVCardFocusHalo: ViewModifier {
    let focused: Bool
    func body(content: Content) -> some View {
        content
            .scaleEffect(focused ? 1.045 : 1)
            .overlay {
                RoundedRectangle(cornerRadius: 15)
                    .strokeBorder(.white.opacity(focused ? 0.94 : 0), lineWidth: 4)
            }
            .shadow(color: .black.opacity(focused ? 0.40 : 0),
                    radius: focused ? 16 : 0, y: 7)
            .animation(.easeOut(duration: 0.18), value: focused)
    }
}
