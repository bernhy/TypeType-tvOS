import SwiftUI

/// A single immutable collection snapshot for all four-column video grids.
/// Focus is intentionally NOT part of equality: one Siri Remote move must
/// never rebuild every tile, its context menu or its thumbnail requests.
struct TVSharedVideoGridSnapshot: Equatable {
    let videos: [VideoItem]
    let scope: String
    let destination: String
    let focusPrefix: String
    let accessibilityPrefix: String
    let columns: Int
    let columnSpacing: CGFloat
    let rowSpacing: CGFloat
    let canLoadMore: Bool
    let loadAhead: Int
    let lookupMissingMetadata: Bool
    let isWatchLaterEntry: Bool
    let playbackQueue: [VideoItem]?
}

private struct TVSharedVideoGridEntry: Identifiable {
    let index: Int
    let video: VideoItem
    var id: String { video.url }
}

/// The card keeps the same native NavigationLink and focus binding for its
/// entire lifetime. Menus observe shared status ONLY when opened; there are
/// no per-card timers, presentation states or mutation of parent focus state.
private struct TVSharedVideoGridTile: View {
    let entry: TVSharedVideoGridEntry
    let api: TypeTypeAPI
    let focus: FocusState<String?>.Binding
    let menu: TVHomeMenuCoordinator
    let focusID: String
    let columns: Int
    let accessibilityPrefix: String
    let lookupMissingMetadata: Bool
    let isWatchLaterEntry: Bool
    let playbackQueue: [VideoItem]?
    let onReturnToList: (String) -> Void
    let onReturnedVideo: ((VideoItem) -> Void)?
    let onLeftEdge: (String) -> Void
    let onNavigation: () -> Void
    let onTopEdge: (String) -> Void
    let onRemoveFromPlaylist: (() async throws -> Void)?
    @Environment(\.tvDirectPlayback) private var directPlayback

    var body: some View {
        let video = entry.video
        // Reading the focus binding in the *tile* avoids invalidating the
        // whole four-column factory for a remote focus move.
        let active = focus.wrappedValue
        NavigationLink {
            VideoDetailView(
                api: api, video: video, playbackQueue: playbackQueue,
                onReturnToList: { onReturnToList(focusID) },
                onReturnedVideo: onReturnedVideo
            )
        } label: {
            VideoCard(
                api: api, video: video,
                lookupMissingMetadata: lookupMissingMetadata
            )
        }
        .buttonStyle(TVRailButtonStyle())
        .focusEffectDisabled(true)
        .zIndex(active == focusID ? 5 : 0)
        .id(focusID)
        .modifier(TVHomeLightweightVideoActions(
            api: api, video: video, model: menu,
            focus: focus, focusID: focusID,
            isWatchLaterEntry: isWatchLaterEntry,
            onRemoveFromPlaylist: onRemoveFromPlaylist
        ))
        .onMoveCommand { direction in
            onNavigation()
            if direction == .left && entry.index % columns == 0 {
                onLeftEdge(focusID)
            } else if direction == .up && entry.index < columns {
                onTopEdge(focusID)
            }
        }
        .onPlayPauseCommand {
            // Only the actually focused video card may consume the command.
            // Select/OK still opens details via the original NavigationLink.
            guard focus.wrappedValue == focusID else { return }
            directPlayback(
                video, playbackQueue: playbackQueue,
                onReturnedVideo: onReturnedVideo
            )
        }
        .accessibilityLabel(TTTheme.accessibilityText(for: video))
        .accessibilityIdentifier(accessibilityPrefix + String(entry.index))
    }
}

/// Equatable lazy grid shared by Home recommendations, subscription feed,
/// search videos and the library. The caller owns network, filters, paging,
/// nested rails and focus requests; the reusable layer owns only stable tile
/// identity, visual style, menu and local directional focus behavior.
struct TVSharedVideoGrid: View, Equatable {
    let snapshot: TVSharedVideoGridSnapshot
    let api: TypeTypeAPI
    let focus: FocusState<String?>.Binding
    let menu: TVHomeMenuCoordinator
    let onReturnToList: (String) -> Void
    var onReturnedVideo: ((VideoItem) -> Void)? = nil
    let onLeftEdge: (String) -> Void
    let onApproachEnd: () -> Void
    var onNavigation: () -> Void = {}
    var onTopEdge: (String) -> Void = { _ in }
    var onRemoveFromPlaylist: ((VideoItem) -> (() async throws -> Void)?)? = nil

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.snapshot == rhs.snapshot && lhs.menu === rhs.menu
    }

    var body: some View {
        LazyVGrid(
            columns: Array(repeating: GridItem(
                .flexible(), spacing: snapshot.columnSpacing
            ), count: snapshot.columns),
            spacing: snapshot.rowSpacing
        ) {
            ForEach(snapshot.videos.enumerated().map {
                TVSharedVideoGridEntry(index: $0.offset, video: $0.element)
            }) { entry in
                TVSharedVideoGridTile(
                    entry: entry, api: api, focus: focus, menu: menu,
                    focusID: snapshot.focusPrefix + entry.video.url,
                    columns: snapshot.columns,
                    accessibilityPrefix: snapshot.accessibilityPrefix,
                    lookupMissingMetadata: snapshot.lookupMissingMetadata,
                    isWatchLaterEntry: snapshot.isWatchLaterEntry,
                    playbackQueue: snapshot.playbackQueue,
                    onReturnToList: onReturnToList,
                    onReturnedVideo: onReturnedVideo,
                    onLeftEdge: onLeftEdge,
                    onNavigation: onNavigation,
                    onTopEdge: onTopEdge,
                    onRemoveFromPlaylist: onRemoveFromPlaylist?(entry.video)
                )
                .onAppear {
                    guard snapshot.canLoadMore,
                          entry.index >= snapshot.videos.count -
                              snapshot.loadAhead else { return }
                    onApproachEnd()
                }
            }
        }
        .focusSection()
    }
}

/// Pure Back policy for every native video-tile grid. Work only on remote
/// Back presses, never while focus moves or the lazy grid is rendering.
enum TVVideoGridBackPolicy {
    static func firstTarget(focused: String?, first: String?) -> String? {
        guard let focused, let first, focused != first else { return nil }
        return first
    }
}
