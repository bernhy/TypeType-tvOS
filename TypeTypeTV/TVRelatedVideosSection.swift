import SwiftUI

/// Related recommendations use the SAME focus-isolated video tiles and one
/// lightweight action/menu host as Home, Search, Library and subscriptions.
/// No separate per-card context-menu states or thumbnail requests.
struct TVRelatedVideosSection: View {
    let api: TypeTypeAPI
    let videos: [VideoItem]

    @StateObject private var videoMenu = TVHomeMenuCoordinator()
    @FocusState private var focusedRelatedID: String?
    @State private var detailReturnID: String?

    var body: some View {
        if !videos.isEmpty {
            VStack(alignment: .leading, spacing: 22) {
                Divider()
                Text("video.relatedVideos")
                    .font(.title2.bold())
                TVSharedVideoGrid(
                    snapshot: TVSharedVideoGridSnapshot(
                        videos: Array(videos.prefix(24)),
                        scope: api.metadataCacheScope,
                        destination: "video-related",
                        focusPrefix: "",
                        accessibilityPrefix: "related-video-",
                        columns: 4, columnSpacing: 28, rowSpacing: 34,
                        canLoadMore: false, loadAhead: 5,
                        lookupMissingMetadata: false,
                        isWatchLaterEntry: false,
                        reloadPlaylistOnRemoval: false,
                        playbackQueue: nil
                    ),
                    api: api, focus: $focusedRelatedID, menu: videoMenu,
                    onReturnToList: { id in
                        // The detail page's own scroll position is intact
                        // after a nested detail pop. Let tvOS target the
                        // original related tile without delayed scrolling.
                        detailReturnID = id
                        focusedRelatedID = id
                    },
                    onLeftEdge: { _ in },
                    onChanged: {},
                    onApproachEnd: {}
                )
                .equatable()
            }
            .defaultFocus(
                $focusedRelatedID, detailReturnID,
                priority: detailReturnID == nil ? .automatic : .userInitiated
            )
            .modifier(TVHomeMenuPresentation(model: videoMenu))
            .task {
                await TVWatchLaterMembership.shared.ensureLoaded(api: api)
            }
        }
    }
}
