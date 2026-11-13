import SwiftUI
import UIKit

private final class TVRemoteCaptureView: UIView {
    var onTouch: (() -> Void)?
    var onDirection: ((Int) -> Void)?
    var onTogglePlayback: (() -> Void)?

    override var canBecomeFocused: Bool { true }

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        var unhandled = Set<UIPress>()
        for item in presses {
            switch item.type {
            case .leftArrow: onDirection?(-1)
            case .rightArrow: onDirection?(1)
            case .playPause: onTogglePlayback?()
            case .select: onTouch?()
            default: unhandled.insert(item)
            }
        }
        if !unhandled.isEmpty { super.pressesBegan(unhandled, with: event) }
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        onTouch?()
        super.touchesBegan(touches, with: event)
    }
}

/// Touch and click support for the custom SABR media surface.
/// Apple TV hardware testing is needed to confirm touch *contact* events.
struct SiriRemotePlayerInput: UIViewRepresentable {
    let onTouch: () -> Void
    let onDirection: (Int) -> Void
    let onTogglePlayback: () -> Void

    final class Coordinator: NSObject {
        var onTouch: () -> Void
        init(_ onTouch: @escaping () -> Void) { self.onTouch = onTouch }
        @objc func moved(_ gesture: UIPanGestureRecognizer) {
            if gesture.state == .began || gesture.state == .changed { onTouch() }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(onTouch) }

    func makeUIView(context: Context) -> UIView {
        let view = TVRemoteCaptureView()
        view.onTouch = onTouch
        view.onDirection = onDirection
        view.onTogglePlayback = onTogglePlayback
        let pan = UIPanGestureRecognizer(
            target: context.coordinator, action: #selector(Coordinator.moved(_:))
        )
        pan.cancelsTouchesInView = false
        view.addGestureRecognizer(pan)
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        guard let view = uiView as? TVRemoteCaptureView else { return }
        view.onTouch = onTouch
        view.onDirection = onDirection
        view.onTogglePlayback = onTogglePlayback
        context.coordinator.onTouch = onTouch
    }
}
