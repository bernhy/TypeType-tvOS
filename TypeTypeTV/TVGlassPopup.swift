import SwiftUI

/// Shared Liquid Glass surface for custom navigation sheets, matching the
/// playback option panel. Native confirmation dialogs and alerts keep the
/// system-provided tvOS appearance and focus behavior.
extension View {
    func tvGlassPopup() -> some View {
        self
            .background {
                RoundedRectangle(cornerRadius: 24)
                    .fill(Color.black.opacity(0.18))
            }
            .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 24))
            .presentationBackground(.clear)
    }
}
