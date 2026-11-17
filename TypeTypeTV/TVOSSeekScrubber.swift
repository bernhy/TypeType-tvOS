import SwiftUI

/// tvOS has no native SwiftUI Slider. This is a Siri-Remote-friendly transport
/// focus target: left/right preview a position, Select commits it, and a touch
/// drag scrubs continuously. The media engine is only asked to seek on commit.
enum TVOSSeekScrubPolicy {
    static func clamp(_ seconds: Double, duration: Double) -> Double {
        guard seconds.isFinite, duration.isFinite, duration > 0 else { return 0 }
        return max(0, min(duration, seconds))
    }

    static func seconds(at x: CGFloat, width: CGFloat, duration: Double) -> Double {
        guard width > 0, duration > 0 else { return 0 }
        return clamp(Double(max(0, min(width, x)) / width) * duration,
                     duration: duration)
    }

    static func stepped(_ current: Double, direction: Int,
                        stepSeconds: Int, duration: Double) -> Double {
        clamp(current + Double(direction * max(1, stepSeconds)), duration: duration)
    }
}

struct TVOSSeekScrubber: View {
    let duration: Double
    let current: Double
    @Binding var preview: Double?
    let sponsorSegments: [TVSponsorBlockSegment]
    let skipSeconds: Int
    let onPreviewChange: (Bool) -> Void
    let onCommit: (Double) -> Void

    @FocusState private var focused: Bool

    private var cursor: Double {
        TVOSSeekScrubPolicy.clamp(preview ?? current, duration: duration)
    }

    var body: some View {
        Button {
            commit()
        } label: {
            GeometryReader { geometry in
                let width = geometry.size.width
                let fraction = duration > 0 ? cursor / duration : 0
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(.white.opacity(0.29))
                        .frame(height: 9)
                    Capsule()
                        .fill(Color.purple.opacity(0.94))
                        .frame(width: max(0, width * fraction), height: 9)
                    if duration > 0 {
                        ForEach(Array(sponsorSegments.enumerated()), id: \.offset) { pair in
                            if let bounds = TVSponsorBlock.bounds(pair.element, duration: duration) {
                                let start = CGFloat(bounds.lowerBound / duration) * width
                                let length = CGFloat((bounds.upperBound - bounds.lowerBound)
                                                     / duration) * width
                                Capsule()
                                    .fill(color(for: pair.element.category))
                                    .frame(width: max(3, length), height: 9)
                                    .offset(x: start)
                                    .accessibilityHidden(true)
                            }
                        }
                    }
                    Circle()
                        .fill(.white)
                        .frame(width: focused ? 29 : 23, height: focused ? 29 : 23)
                        .shadow(color: focused ? .purple.opacity(0.75) : .black.opacity(0.35),
                                radius: focused ? 13 : 5)
                        .offset(x: max(0, min(width - (focused ? 29 : 23),
                                              width * fraction - 12)))
                }
                .frame(height: 48)
                .contentShape(Rectangle())
                .simultaneousGesture(
                    DragGesture(minimumDistance: 6)
                        .onChanged { gesture in
                            preview = TVOSSeekScrubPolicy.seconds(
                                at: gesture.location.x, width: width,
                                duration: duration
                            )
                            onPreviewChange(true)
                        }
                        .onEnded { gesture in
                            preview = TVOSSeekScrubPolicy.seconds(
                                at: gesture.location.x, width: width,
                                duration: duration
                            )
                            commit()
                        }
                )
            }
            .frame(height: 48)
        }
        .buttonStyle(.plain)
        .focused($focused)
        .onMoveCommand { direction in
            let sign: Int
            switch direction {
            case .left: sign = -1
            case .right: sign = 1
            default: return
            }
            preview = TVOSSeekScrubPolicy.stepped(
                cursor, direction: sign, stepSeconds: skipSeconds,
                duration: duration
            )
            onPreviewChange(true)
        }
        .onChange(of: focused) { _, nowFocused in
            if !nowFocused, preview != nil {
                // Leaving the timeline should not leave a stale preview
                // position visible over another popup.
                commit()
            }
        }
        .disabled(duration <= 0)
        .accessibilityLabel("Zeitleiste")
        .accessibilityValue(TTTheme.time(Int(cursor)))
    }

    private func commit() {
        guard duration > 0 else { return }
        let seconds = TVOSSeekScrubPolicy.clamp(preview ?? current, duration: duration)
        onCommit(seconds)
        preview = nil
        onPreviewChange(false)
    }

    private func color(for category: String) -> Color {
        switch category {
        case "sponsor": return .red
        case "intro", "outro": return .orange
        case "selfpromo": return .green
        case "interaction", "poi_highlight": return .blue
        case "chapter": return .purple
        default: return .yellow
        }
    }
}
