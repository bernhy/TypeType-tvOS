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
