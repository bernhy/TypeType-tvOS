import SwiftUI

/// Shared Liquid Glass surface for custom navigation sheets, matching the
/// playback option panel. Native confirmation dialogs and alerts keep the
/// system-provided tvOS appearance and focus behavior.
extension View {
    func tvGlassPopup(transparent: Bool = false) -> some View {
        self
            .background {
                RoundedRectangle(cornerRadius: 24)
                    .fill(Color.black.opacity(transparent ? 0.08 : 0.18))
            }
            .glassEffect(transparent ? .clear : .regular,
                         in: RoundedRectangle(cornerRadius: 24))
            .presentationBackground(.clear)
    }
}
