/// A video context menu must finish the focus shrink/grow animation
/// before the success toast can fade in. This delays *only* the UI.
enum TVActionFeedbackPolicy {
    static let delayMilliseconds = 480
}
