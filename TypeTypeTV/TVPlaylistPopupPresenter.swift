import Foundation
import Combine

/// Present the same picker above the actual browsing/navigation hierarchy.
/// A native tvOS sheet can use an opaque presentation surface even when its
/// child view has glassEffect and .presentationBackground(.clear).
@MainActor
final class TVPlaylistPopupPresenter: ObservableObject {
    static let shared = TVPlaylistPopupPresenter()

    struct Request {
        let api: TypeTypeAPI
        let video: VideoItem
        let onSaved: (String) -> Void
        let onDismiss: () -> Void
    }

    @Published private(set) var request: Request?

    private init() {}

    func present(api: TypeTypeAPI, video: VideoItem,
                 onSaved: @escaping (String) -> Void = { _ in },
                 onDismiss: @escaping () -> Void = {}) {
        guard request == nil else { return }
        request = Request(api: api, video: video,
                          onSaved: onSaved, onDismiss: onDismiss)
    }

    func finish(result: String? = nil) {
        guard let current = request else { return }
        request = nil
        if let result { current.onSaved(result) }
        current.onDismiss()
    }
}
