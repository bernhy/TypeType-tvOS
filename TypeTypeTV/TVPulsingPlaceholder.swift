import SwiftUI

/// Lightweight, decorative loading placeholders; the real data fetch is
/// unchanged. Displayed only while a thumbnail grid is empty and loading.
struct TVPulsingPlaceholder: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pulse = false

    var body: some View {
        HStack(alignment: .top, spacing: 22) {
            ForEach(0..<3, id: \.self) { _ in
                VStack(alignment: .leading, spacing: 10) {
                    RoundedRectangle(cornerRadius: 10)
                        .fill(TTTheme.surface)
                        .aspectRatio(16.0 / 9.0, contentMode: .fit)
                    RoundedRectangle(cornerRadius: 5)
                        .fill(TTTheme.surface)
                        .frame(height: 19)
                    RoundedRectangle(cornerRadius: 5)
                        .fill(TTTheme.surface)
                        .frame(width: 110, height: 12)
                }
                .frame(maxWidth: .infinity)
            }
        }
        .frame(maxWidth: .infinity)
        .opacity(pulse && !reduceMotion ? 0.48 : 1)
        .animation(reduceMotion ? nil :
                   .easeInOut(duration: 0.85).repeatForever(autoreverses: true),
                   value: pulse)
        .onAppear { pulse = true }
        .onDisappear { pulse = false }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(TVL10n.value("settings.remoteLoading"))
    }
}
