import Combine
import SwiftUI

/// One shared presentation flag for actual player screens, not video details.
/// The browser's navigation rail must not remain alongside playback or its
/// recovery/error overlays. The counter also handles playlist item changes.
@MainActor
final class TVPlaybackVisibility: ObservableObject {
    static let shared = TVPlaybackVisibility()
    @Published private(set) var isVisible = false
    private var presentationCount = 0

    func enter() {
        presentationCount += 1
        isVisible = true
    }

    func leave() {
        presentationCount = max(0, presentationCount - 1)
        isVisible = presentationCount > 0
    }
}
