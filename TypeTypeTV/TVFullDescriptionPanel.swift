import SwiftUI

/// Long descriptions live in their own focus scope, so moving down cannot
/// escape to the related-video cards halfway through scrolling.
struct TVFullDescriptionPanel: View {
    let description: String
    @Environment(\.dismiss) private var dismiss
    @FocusState private var descriptionFocused: Bool
    @State private var scrollCommand = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            HStack {
                Text("video.descriptionHeading").font(.title2.bold())
                Spacer()
                Button("common.close") { dismiss() }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("video-full-description-close")
            }
            TVRemoteDescriptionScrollView(
                text: description, scrollCommand: scrollCommand
            )
            .frame(height: 510)
            .background(.black.opacity(0.14),
                        in: RoundedRectangle(cornerRadius: 16))
            .accessibilityElement(children: .contain)
            .focusable(true)
            .focused($descriptionFocused)
            .onMoveCommand { direction in
                if direction == .down { scrollCommand += 1 }
                if direction == .up { scrollCommand -= 1 }
            }
            .accessibilityIdentifier("video-full-description-scroll")
            .focusSection()
        }
        .padding(34)
        .frame(width: 1060)
        .tvGlassPopup(transparent: true)
        .onAppear { descriptionFocused = true }
        .onExitCommand { dismiss() }
    }
}
