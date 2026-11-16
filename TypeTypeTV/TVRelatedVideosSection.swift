import SwiftUI

/// Video detail recommendations are separate from in-player overlays.
struct TVRelatedVideosSection: View {
    let api: TypeTypeAPI
    let videos: [VideoItem]
    private let columns = Array(repeating: GridItem(.flexible(), spacing: 28), count: 4)

    var body: some View {
        if !videos.isEmpty {
            VStack(alignment: .leading, spacing: 22) {
                Divider()
                Text("video.relatedVideos")
                    .font(.title2.bold())
                LazyVGrid(columns: columns, spacing: 34) {
                    ForEach(Array(videos.prefix(24))) { video in
                        NavigationLink {
                            VideoDetailView(api: api, video: video)
                        } label: {
                            VideoCard(api: api, video: video)
                        }
                        .buttonStyle(TVRailButtonStyle())
                        .focusEffectDisabled(true)
                        .videoActions(api: api, video: video)
                    }
                }
                .focusSection()
            }
        }
    }
}
