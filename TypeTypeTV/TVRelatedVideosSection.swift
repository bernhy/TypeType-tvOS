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
    @State private var mutationCursor = TVVideoMutationCursor()
    @State private var hiddenVideoIDs = Set<String>()

    private var visibleVideos: [VideoItem] {
        Array(videos.filter {
            !hiddenVideoIDs.contains(TVPlaylistMembership.videoKey($0.url))
        }.prefix(24))
    }

    var body: some View {
        if !visibleVideos.isEmpty {
            VStack(alignment: .leading, spacing: 22) {
                Divider()
                Text("video.relatedVideos")
                    .font(.title2.bold())
                TVSharedVideoGrid(
                    snapshot: TVSharedVideoGridSnapshot(
                        videos: visibleVideos,
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
            .onReceive(TVVideoMutationCenter.shared.$events) { reconcileMutations($0) }
            .onAppear { reconcileMutations(TVVideoMutationCenter.shared.events) }
            .onChange(of: videoMenu.focusRestoreRequest) { _, _ in
                if let id = videoMenu.focusRestoreTarget,
                   visibleVideos.contains(where: { $0.url == id }) {
                    focusedRelatedID = id
                }
            }
            .task {
                await TVWatchLaterMembership.shared.ensureLoaded(api: api)
            }
            .task {
                async let playlists: Void = TVPlaylistMembership.shared.ensureLoaded(api: api)
                async let favorites: Void = TVFavoriteMembership.shared.ensureLoaded(api: api)
                _ = await (playlists, favorites)
            }
        }
    }

    @MainActor
    private func reconcileMutations(_ events: [TVVideoMutationCenter.Event]) {
        let pending = events.filter {
            $0.id > mutationCursor.lastID && $0.accountScope == api.metadataCacheScope
        }
        mutationCursor.lastID = max(mutationCursor.lastID, events.last?.id ?? 0)
        guard !pending.isEmpty else { return }
        for item in videos where pending.contains(where: { $0.removes(item) }) {
            hiddenVideoIDs.insert(TVPlaylistMembership.videoKey(item.url))
        }
    }
}
