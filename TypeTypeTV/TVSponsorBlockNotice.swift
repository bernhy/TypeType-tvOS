import SwiftUI

/// TypeType web's restrained SponsorBlock bar: category, small caption below,
/// Info/SkipForward equivalents and a directly focused Skip button.
struct TVSponsorBlockNotice: View {
    let category: String
    let onSkip: () -> Void
    let onDismiss: () -> Void

    @FocusState private var skipFocused: Bool
    @AppStorage("typetype.exp.glass") private var glassEnabled = false

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "info.circle")
                .font(.system(size: 17))
                .foregroundStyle(.white.opacity(0.8))
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 3) {
                Text(TVL10n.value(TVSponsorBlock.titleKey(category)))
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Text("SponsorBlock")
                    .font(.system(size: 11))
                    .tracking(0.8)
                    .textCase(.uppercase)
                    .foregroundStyle(.white.opacity(0.56))
            }

            Button(action: onSkip) {
                Label(TVL10n.value("sponsor.skip"), systemImage: "forward.end.fill")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.black)
                    .padding(.horizontal, 13)
                    .padding(.vertical, 8)
                    .background(.white, in: Capsule())
                    // Keep focus feedback inside the button's real bounds.
                    .overlay {
                        Capsule().strokeBorder(.black.opacity(skipFocused ? 0.24 : 0),
                                               lineWidth: 1)
                    }
                    .contentShape(Capsule())
            }
            // tvOS still adds a large glowing pill to .plain buttons even
            // when focusEffectDisabled is set. The rail's custom style and
            // explicit environment opt-out keep this capsule at fixed size.
            .buttonStyle(TVRailButtonStyle())
            .focusEffectDisabled(true)
            .focused($skipFocused)
            .accessibilityIdentifier("sponsorblock-skip")
            .onExitCommand(perform: onDismiss)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(glassEnabled ? Color.black.opacity(0.16) : Color.black.opacity(0.78),
                    in: Capsule())
        .overlay(Capsule().strokeBorder(.white.opacity(0.15), lineWidth: 1))
        .background {
            if glassEnabled {
                Capsule().fill(.clear).glassEffect(.regular, in: Capsule())
            }
        }
        .fixedSize(horizontal: true, vertical: true)
        .environment(\.isFocusEffectEnabled, false)
        .onExitCommand(perform: onDismiss)
        .task {
            // No remote navigation needed: one confirmation triggers Skip.
            await Task.yield()
            skipFocused = true
        }
    }
}
