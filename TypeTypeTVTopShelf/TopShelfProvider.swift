import Foundation
import TVServices

/// tvOS runs this in an independent, tightly limited extension process.
/// All artwork and metadata are prepared by the app, so Top Shelf needs
/// neither an authentication token nor server/network access.
final class TopShelfProvider: TVTopShelfContentProvider {
    override func loadTopShelfContent(
        completionHandler: @escaping (TVTopShelfContent?) -> Void
    ) {
        guard let snapshot = TVTopShelfSnapshotStore.read() else {
            completionHandler(nil)
            return
        }

        let sections: [TVTopShelfItemCollection<TVTopShelfSectionedItem>] =
            snapshot.items.compactMap { saved in
            let poster = TVTopShelfSectionedItem(identifier: saved.key)
            poster.title = saved.title
            poster.imageShape = .hdtv
            poster.playbackProgress = saved.playbackFraction
            guard let raw = saved.thumbnailURL,
                  let url = URL(string: raw), url.scheme == "https",
                  url.user == nil, url.password == nil else { return nil }
            // Poster metadata contains only public HTTPS thumbnail URLs.
            // The extension has no bearer token and never runs our API.
            // Both output modes use the same URL. TVServices chooses by
            // device scale (e.g. a 1080p Apple TV can require 1x); these
            // variants are not a network-failure fallback.
            poster.setImageURL(url, for: .screenScale1x)
            poster.setImageURL(url, for: .screenScale2x)
            poster.displayAction = TVTopShelfSnapshotStore.actionURL(for: saved.key)
                .map { TVTopShelfAction(url: $0) }
            // Sectioned content is one horizontal row across collections.
            // A single video per collection lets the label above the row
            // follow the focused video's channel without conflating it
            // with the individual video's title.
            let section = TVTopShelfItemCollection<TVTopShelfSectionedItem>(
                items: [poster]
            )
            section.title = saved.sectionTitle
            return section
        }
        guard !sections.isEmpty else {
            completionHandler(nil)
            return
        }
        completionHandler(TVTopShelfSectionedContent(sections: sections))
    }
}
