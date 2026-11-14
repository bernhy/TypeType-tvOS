import SwiftUI

@main
struct TypeTypeTVApp: App {
    @AppStorage("typetype.uiLanguage") private var language = TVLanguages.followSystem
    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(\.locale, TVLanguages.locale(for: language))
        }
    }
}

struct RootView: View {
    @AppStorage("typetype.instanceOrigin") private var instanceOrigin = ""

    var body: some View {
        #if DEBUG
        if let preview = Self.previewMode,
           let api = try? TypeTypeAPI(address: "https://preview.invalid") {
            if preview == "player-error" {
                SabrPlaybackErrorPreview()
            } else if ["home", "home-expanded", "search", "library", "subscriptions", "account",
                "settings", "settings-content", "settings-performance", "settings-device",
                "settings-language", "settings-account", "settings-instance",
                "settings-about"].contains(preview) {
                BrowseView(
                    instanceOrigin: "https://preview.invalid",
                    onDisconnect: {},
                    initialSection: preview == "search" ? .search :
                        (preview == "library" ? .library :
                        (preview == "subscriptions" ? .subscriptions :
                        (preview == "account" ? .account :
                        (preview.hasPrefix("settings") ? .settings : .home)))),
                    previewVideos: TVShowcaseFixtures.videos,
                    initiallyExpanded: preview == "home-expanded",
                    initialSettingsGroup: {
                        switch preview {
                        case "settings-content": return .content
                        case "settings-performance", "settings-device": return .device
                        case "settings-language": return .language
                        case "settings-account": return .account
                        case "settings-instance": return .instance
                        case "settings-about": return .about
                        default: return .playback
                        }
                    }()
                )
            } else {
                NavigationStack {
                    VideoDetailView(api: api,
                                    video: preview == "detail-long"
                                        ? TVShowcaseFixtures.longTitleVideo
                                        : TVShowcaseFixtures.videos[0])
                }
            }
        } else {
            configuredContent
        }
        #else
        configuredContent
        #endif
    }

    @ViewBuilder
    private var configuredContent: some View {
        if instanceOrigin.isEmpty {
            ServerSetupView { instanceOrigin = $0 }
        } else {
            BrowseView(instanceOrigin: instanceOrigin) { instanceOrigin = "" }
        }
    }

    #if DEBUG
    private static var previewMode: String? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "-TypeTypeTVPreview"),
              arguments.indices.contains(index + 1) else { return nil }
        return arguments[index + 1]
    }
    #endif
}

#if DEBUG
/// Network-free focus regression for the same error dialog displayed
/// during real SABR playback. Real backend errors are not needed for this test.
private struct SabrPlaybackErrorPreview: View {
    @State private var selected = "none"

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VStack(spacing: 28) {
                SabrPlaybackErrorDialog(
                    unavailable: false,
                    failure: "SABR preview failure",
                    onRetry: { selected = "retry" },
                    onBack: { selected = "back" }
                )
                Text(selected)
                    .accessibilityIdentifier("sabrErrorPreviewSelection")
            }
        }
    }
}

/// Network-free screenshot fixtures for automated simulator UI reviews.
/// These are never shown in Release builds or to ordinary users.
enum TVShowcaseFixtures {
    static let longTitleVideo = VideoItem(
        id: "ui-preview-long-title",
        title: "Eine günstige TESLA Alternative? XPENG L03: Das perfekte E-Auto für Alltag und lange Reisen – ein ausführlicher Vergleich mit vielen Details",
        url: "https://youtu.be/dQw4w9WgXcQ",
        thumbnailUrl: nil, uploaderName: "Testkanal",
        duration: 2196, isLive: false
    )

    static let titles = [
        "Neuigkeiten aus der Welt der Technik",
        "So funktioniert die Videowiedergabe in 4K",
        "Die schönsten Landschaften in HDR",
        "Ein spannender Blick hinter die Kulissen",
        "Tipps für dein Heimkino",
        "Unterwegs in Europas Städten",
        "Musik und Dokumentationen entdecken",
        "Ein neues Kapitel für Open Source"
    ]

    static let videos: [VideoItem] = {
        var samples: [VideoItem] = []
        for number in 0..<24 {
            let title: String = titles[number % titles.count]
            let live: Bool = number == 7
            let duration: Int? = live ? nil : 340 + number * 37
            let uploader: String = number % 3 == 0 ? "TypeType Community" : "Beispielkanal"
            var item = VideoItem(
                id: "ui-preview-\(number)", title: title,
                url: "https://youtu.be/dQw4w9WgXcQ", thumbnailUrl: nil,
                uploaderName: uploader, duration: duration, isLive: live
            )
            // Preview both partially viewed and completed cards in Xcode
            // screenshot tests without requiring an account or network.
            if let duration, !live {
                if number % 5 == 1 {
                    item.watchPositionMs = Int64(duration) * 420
                } else if number % 5 == 2 {
                    item.watchPositionMs = Int64(duration) * 950
                }
            }
            samples.append(item)
        }
        return samples
    }()
}
#endif

