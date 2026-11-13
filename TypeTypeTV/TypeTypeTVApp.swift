import SwiftUI

@main
struct TypeTypeTVApp: App {
    var body: some Scene {
        WindowGroup {
            RootView()
        }
    }
}

struct RootView: View {
    @AppStorage("typetype.instanceOrigin") private var instanceOrigin = ""

    var body: some View {
        #if DEBUG
        if let preview = Self.previewMode,
           let api = try? TypeTypeAPI(address: "https://preview.invalid") {
            NavigationStack {
                if preview == "home" {
                    HomeView(api: api, previewVideos: TVShowcaseFixtures.videos)
                } else if preview == "search" {
                    SearchView(api: api)
                } else {
                    VideoDetailView(api: api, video: TVShowcaseFixtures.videos[0])
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
/// Network-free screenshot fixtures for automated simulator UI reviews.
/// These are never shown in Release builds or to ordinary users.
enum TVShowcaseFixtures {
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
            let item = VideoItem(
                id: "ui-preview-\(number)", title: title,
                url: "https://youtu.be/dQw4w9WgXcQ", thumbnailUrl: nil,
                uploaderName: uploader, duration: duration, isLive: live
            )
            samples.append(item)
        }
        return samples
    }()
}
#endif

