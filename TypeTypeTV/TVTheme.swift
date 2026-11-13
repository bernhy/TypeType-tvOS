import Foundation
import SwiftUI

enum TTTheme {
    static let ink = Color(red: 0.035, green: 0.035, blue: 0.043)
    static let surface = Color(red: 0.094, green: 0.094, blue: 0.106)
    static let accent = Color(red: 0.937, green: 0.267, blue: 0.267)
    static let muted = Color(red: 0.631, green: 0.631, blue: 0.667)

    static func time(_ seconds: Int) -> String {
        let total = max(0, seconds)
        if total >= 3_600 {
            return String(format: "%d:%02d:%02d", total / 3_600,
                          (total / 60) % 60, total % 60)
        }
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    static func accessibilityText(for video: VideoItem) -> String {
        let origin = video.uploaderName ?? ""
        let duration = video.isLive == true ? "Live" :
            video.duration.map { time($0) } ?? ""
        return [video.title, origin, duration].filter { !$0.isEmpty }.joined(separator: ", ")
    }
}

struct TVContentMessage: View {
    let symbol: String
    let title: String
    let detail: String
    var action: (() -> Void)? = nil
    var actionTitle = "Erneut versuchen"

    var body: some View {
        VStack(alignment: .leading, spacing: 19) {
            Image(systemName: symbol)
                .font(.system(size: 62, weight: .regular))
                .foregroundStyle(TTTheme.muted)
            Text(title).font(.title.bold())
            Text(detail).font(.body)
                .foregroundStyle(TTTheme.muted)
                .frame(maxWidth: 800, alignment: .leading)
            if let action {
                Button(actionTitle, action: action)
                    .buttonStyle(.borderedProminent)
                    .tint(TTTheme.accent)
            }
        }
        .padding(50)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(TTTheme.surface, in: RoundedRectangle(cornerRadius: 24))
    }
}
