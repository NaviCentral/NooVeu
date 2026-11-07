import Foundation

/// Which image of a folder is current, which way the user is travelling, and what to preload.
///
/// Pure value logic with no UI, so the rules for flipping (wrapping, direction, what to warm
/// up next) can be tested on their own. The viewer owns one per window.
public struct FlipState: Sendable {
    public private(set) var listing: FolderListing?
    public private(set) var index: Int?
    /// +1 after moving forward, -1 after moving back. Preloading favours this direction.
    public private(set) var direction = 1

    /// How many images to preload in the direction of travel, and in the opposite one.
    public let preloadAhead: Int
    public let preloadBehind: Int

    public init(preloadAhead: Int = 3, preloadBehind: Int = 1) {
        self.preloadAhead = preloadAhead
        self.preloadBehind = preloadBehind
    }

    public var currentURL: URL? {
        guard let listing, let index, listing.items.indices.contains(index) else { return nil }
        return listing.items[index]
    }

    /// "3 / 120" style position, counted from 1.
    public var position: (number: Int, count: Int)? {
        guard let listing, let index else { return nil }
        return (index + 1, listing.count)
    }

    /// Adopts a folder listing. `current` is the file already on screen, if any; when it is not
    /// in the listing (it was deleted, say) there is no current position.
    public mutating func setListing(_ listing: FolderListing, current: URL?) {
        self.listing = listing
        index = current.flatMap { listing.index(of: $0) }
    }

    /// Moves `delta` images (wrapping at either end) and returns the image to show.
    /// Returns `nil`, changing nothing, when there is no listing or no current image, or when the
    /// move would land on the image already shown (a one-image folder): reloading it would only
    /// throw away the viewer's zoom.
    public mutating func step(_ delta: Int) -> URL? {
        guard let listing, let index,
              let next = listing.index(index, offsetBy: delta, wrapping: true),
              next != index else { return nil }
        direction = delta >= 0 ? 1 : -1
        self.index = next
        return listing.items[next]
    }

    /// Jumps to `target` and returns its image, or `nil` for an index outside the listing, or the
    /// image already shown (reloading it would only throw away the viewer's zoom).
    /// Preloading then favours the way the jump went.
    public mutating func jump(to target: Int) -> URL? {
        guard let listing, listing.items.indices.contains(target), target != index else { return nil }
        if let index { direction = target >= index ? 1 : -1 }
        index = target
        return listing.items[target]
    }

    /// Jumps to the first image. The way on from there is forward.
    public mutating func jumpToFirst() -> URL? {
        let url = jump(to: 0)
        if url != nil { direction = 1 }
        return url
    }

    /// Jumps to the last image. The way on from there is backward (forward would wrap to the
    /// start of the folder).
    public mutating func jumpToLast() -> URL? {
        guard let listing else { return nil }
        let url = jump(to: listing.count - 1)
        if url != nil { direction = -1 }
        return url
    }

    /// The images to warm up now, nearest first, favouring the direction of travel.
    public var preloadURLs: [URL] {
        guard let listing, let index else { return [] }
        let forward = direction > 0
        return listing.preloadOrder(
            around: index,
            ahead: forward ? preloadAhead : preloadBehind,
            behind: forward ? preloadBehind : preloadAhead,
            wrapping: true,
            favouringForward: forward
        ).map { listing.items[$0] }
    }
}
