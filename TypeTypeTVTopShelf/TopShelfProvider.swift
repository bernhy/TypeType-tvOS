import Foundation
import TVServices

/// tvOS runs this in an independent, tightly limited extension process.
/// All artwork and metadata are prepared by the app, so Top Shelf needs
/// neither an authentication token nor server/network access.
final class TopShelfProvider: TVTopShelfContentProvider {
    override func loadTopShelfContent(
        completionHandler: @escaping (TVTopShelfContent?) -> Void
    ) {
        guard let container = TVTopShelfSnapshotStore.container(),
              let snapshot = TVTopShelfSnapshotStore.read(from: container) else {
            #if DEBUG
            NSLog("TypeType TOPSHELF provider: no readable snapshot")
            #endif
            completionHandler(nil
            return
        }

        let items: [TVTopShelfSectionedItem] = snapshot.items.compactMap { saved in
            let poster = TVTopShelfSectionedItem(identifier: saved.key)
            poster.title = saved.title
            poster.imageShape = .hdtv
            poster.playbackProgress = saved.playbackFraction
            if let imageName = saved.imageName,
               let image = TVTopShelfSnapshotStore.imageURL(
                   named: imageName, in: container
               ), FileManager.default.fileExists(atPath: image.path) {
                poster.setImageURL(image, for: .screenScale2x)
            } else if let raw = saved.thumbnailURL,
                      let url = URL(string: raw), url.scheme == "https" {
                // Public CDN fallback only; private TypeType URLs require
                // the app's authenticated, pinned thumbnail fetch.
                poster.setImageURL(url, for: .screenScale2x)
            } else {
                return nil
            }
            poster.displayAction = TVTopShelfSnapshotStore.actionURL(for: saved.key)
                .map { TVTopShelfAction(url: $0) }
            return poster
        }
        guard !items.isEmpty else {
            completionHandler(nil)
            return
        }
        let section = TVTopShelfItemCollection<TVTopShelfSectionedItem>(items: items)
        section.title = "Ansehen fortsetzen"
        completionHandler(TVTopShelfSectionedContent(sections: [section]))
    }
}
