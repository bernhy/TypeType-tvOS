import SwiftUI
import UIKit

/// A genuine focusable tvOS text view. A SwiftUI ScrollView containing just
/// one Text has no native focusable content to follow during remote swipes.
/// UITextView must be selectable AND accept indirect Siri Remote touches.
/// Apple describes this specific pattern in "Mastering UIKit on tvOS".
struct TVRemoteDescriptionScrollView: UIViewRepresentable {
    let text: String
    var scrollCommand: Int = 0

    final class Coordinator {
        var lastCommand = 0
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> TVDescriptionTextView {
        let view = TVDescriptionTextView()
        view.backgroundColor = .clear
        view.isSelectable = true
        view.isScrollEnabled = true
        view.bounces = false
        view.alwaysBounceVertical = false
        view.showsVerticalScrollIndicator = true
        view.showsHorizontalScrollIndicator = false
        view.textContainerInset = UIEdgeInsets(top: 18, left: 18, bottom: 18, right: 18)
        view.textContainer.lineFragmentPadding = 0
        view.font = .preferredFont(forTextStyle: .body)
        view.textColor = UIColor(TTTheme.muted)
        view.adjustsFontForContentSizeCategory = true
        view.text = text
        // Without indirect touches, swipes on the Siri Remote cannot pan
        // the text even when the UITextView has focus.
        view.panGestureRecognizer.allowedTouchTypes = [
            NSNumber(value: UITouch.TouchType.direct.rawValue),
            NSNumber(value: UITouch.TouchType.indirect.rawValue)
        ]
        view.accessibilityIdentifier = "video-description-scroll"
        view.accessibilityLabel = TVL10n.value("video.descriptionHeading")
        return view
    }

    func updateUIView(_ view: TVDescriptionTextView, context: Context) {
        if view.text != text {
            view.text = text
            view.setContentOffset(
                CGPoint(x: 0, y: -view.adjustedContentInset.top), animated: false
            )
        }
        let delta = scrollCommand - context.coordinator.lastCommand
        guard delta != 0 else { return }
        context.coordinator.lastCommand = scrollCommand
        let insetTop = view.adjustedContentInset.top
        if let next = TVDescriptionScrollPolicy.targetY(
            current: view.contentOffset.y + insetTop,
            delta: CGFloat(delta) * 125,
            contentHeight: view.contentSize.height + view.adjustedContentInset.bottom,
            viewportHeight: view.bounds.height
        ) {
            view.setContentOffset(
                CGPoint(x: view.contentOffset.x, y: next - insetTop),
                animated: true
            )
        }
    }
}

enum TVDescriptionScrollPolicy {
    /// Physical remote arrow keys scroll by a readable chunk while a focused
    /// description is still inside its viewport. At either edge, yield the
    /// press to tvOS's ordinary focus/navigation behavior.
    static func targetY(current: CGFloat, delta: CGFloat,
                        contentHeight: CGFloat, viewportHeight: CGFloat) -> CGFloat? {
        guard current.isFinite, delta.isFinite,
              contentHeight.isFinite, viewportHeight.isFinite,
              viewportHeight > 0 else { return nil }
        let maximum = max(0, contentHeight - viewportHeight)
        let next = min(maximum, max(0, current + delta))
        return abs(next - current) > 0.5 ? next : nil
    }
}

final class TVDescriptionTextView: UITextView {
    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        var unhandled = Set<UIPress>()
        for item in presses {
            let step: CGFloat
            switch item.type {
            case .upArrow: step = -125
            case .downArrow: step = 125
            default:
                unhandled.insert(item)
                continue
            }
            let insetTop = adjustedContentInset.top
            if let target = TVDescriptionScrollPolicy.targetY(
                current: contentOffset.y + insetTop, delta: step,
                contentHeight: contentSize.height + adjustedContentInset.bottom,
                viewportHeight: bounds.height
            ) {
                setContentOffset(CGPoint(x: contentOffset.x, y: target - insetTop),
                                 animated: true)
            } else {
                unhandled.insert(item)
            }
        }
        if !unhandled.isEmpty {
            super.pressesBegan(unhandled, with: event)
        }
    }
}
