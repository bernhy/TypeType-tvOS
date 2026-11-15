import SwiftUI

/// TypeType web's restrained SponsorBlock bar: category, small caption below,
/// Info/SkipForward equivalents and a directly focused Skip button.
struct TVSponsorBlockNotice: View {
    let category: String
    let onSkip: () -> Void
    let onDismiss: () -> Void

    @FocusState private var skipFocused: Bool

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
            }
            .buttonStyle(.plain)
            .focusEffectDisabled(true)
            .focused($skipFocused)
            .scaleEffect(skipFocused ? 1.035 : 1)
            .shadow(color: .white.opacity(skipFocused ? 0.22 : 0), radius: 5)
            .accessibilityIdentifier("sponsorblock-skip")
            .onExitCommand(perform: onDismiss)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.black.opacity(0.78), in: Capsule())
        .overlay(Capsule().strokeBorder(.white.opacity(0.15), lineWidth: 1))
        .fixedSize(horizontal: true, vertical: true)
        .onExitCommand(perform: onDismiss)
        .task {
            // No remote navigation needed: one confirmation triggers Skip.
            await Task.yield()
            skipFocused = true
        }
    }
}
