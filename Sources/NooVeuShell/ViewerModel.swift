import CoreGraphics
import Foundation
import NooVeuCore

/// The logic of one viewer window, without the window: opening a file or folder, flipping through
/// it, showing the image on screen, upgrading it to full resolution when the user zooms in, and
/// following the window to another display.
///
/// Everything it depends on comes in through `Environment`, so tests can drive it with fakes and
/// control when each decode and upload finishes. The AppKit controller supplies the real ones.
///
/// Rules it keeps:
/// - Work started for an earlier image never lands on a later one (`generation`).
/// - The model records the image as shown *before* telling the surface to show it, because showing
///   triggers `transformChanged`, which reads it.
/// - Each image is upgraded to full resolution at most once.
@MainActor
public final class ViewerModel<Prepared: Sendable> {
    /// What the model reads from the view.
    public struct ViewState: Sendable, Equatable {
        /// Device pixels per source pixel.
        public var zoom: CGFloat
        /// The view fits the whole image, rather than a zoom the user chose.
        public var isFitMode: Bool

        public init(zoom: CGFloat, isFitMode: Bool) {
            self.zoom = zoom
            self.isFitMode = isFitMode
        }
    }

    /// Everything the model needs from outside.
    public struct Environment {
        public var isFolder: @Sendable (URL) -> Bool
        public var listing: @Sendable (_ url: URL, _ isFolder: Bool) async -> FolderListing?
        public var image: @Sendable (URL, DecodeOptions, DecodePriority) async throws -> DecodedImage
        public var preload: @Sendable ([URL], DecodeOptions) async -> Void
        public var prepare: @Sendable (DecodedImage) async throws -> Prepared
        public var uploadDuration: @Sendable (Prepared) -> Duration
        public var show: @MainActor (Prepared, DecodedImage, _ resetView: Bool) -> Void
        public var clear: @MainActor () -> Void
        public var setTitle: @MainActor (_ title: String, _ representedURL: URL?) -> Void
        public var setSubtitle: @MainActor (String) -> Void
        public var viewState: @MainActor () -> ViewState
        /// Called just before an image is shown, for the surface to prepare for it.
        public var imageWillShow: @MainActor () -> Void

        public init(
            isFolder: @escaping @Sendable (URL) -> Bool,
            listing: @escaping @Sendable (URL, Bool) async -> FolderListing?,
            image: @escaping @Sendable (URL, DecodeOptions, DecodePriority) async throws -> DecodedImage,
            preload: @escaping @Sendable ([URL], DecodeOptions) async -> Void,
            prepare: @escaping @Sendable (DecodedImage) async throws -> Prepared,
            uploadDuration: @escaping @Sendable (Prepared) -> Duration,
            show: @escaping @MainActor (Prepared, DecodedImage, Bool) -> Void,
            clear: @escaping @MainActor () -> Void,
            setTitle: @escaping @MainActor (String, URL?) -> Void,
            setSubtitle: @escaping @MainActor (String) -> Void,
            viewState: @escaping @MainActor () -> ViewState,
            imageWillShow: @escaping @MainActor () -> Void
        ) {
            self.isFolder = isFolder
            self.listing = listing
            self.image = image
            self.preload = preload
            self.prepare = prepare
            self.uploadDuration = uploadDuration
            self.show = show
            self.clear = clear
            self.setTitle = setTitle
            self.setSubtitle = setSubtitle
            self.viewState = viewState
            self.imageWillShow = imageWillShow
        }
    }

    private let env: Environment
    private var flip = FlipState()
    private var currentURL: URL?
    /// The file `shown` came from. Differs from `currentURL` while the next image loads.
    private var shownURL: URL?
    /// Bumped on every `display`; work started for an earlier image checks it before landing.
    private var generation = 0
    /// The generation whose full-resolution upgrade has been tried. Each image is upgraded at most
    /// once: a failed upgrade is not retried on every pan, and a full-resolution decode that comes
    /// out no larger than the texture on screen (a very wide JPEG is subsampled to stay within the
    /// texture limit) cannot trigger another one.
    private var upgradeAttemptedFor = -1
    private var listingTask: Task<Void, Never>?
    private var loadTask: Task<Void, Never>?
    private var upgradeTask: Task<Void, Never>?
    private var preloadTask: Task<Void, Never>?
    private var shown: ShownImageInfo?
    private var errorMessage: String?
    /// Set by `close()`. A closed model starts no new work, whatever it is told afterwards.
    private var isClosed = false

    /// Longest side, in pixels, of the display the window is on. First views are decoded to about
    /// this size, which is much faster than full resolution for big photos.
    public private(set) var firstViewSide: Int

    public init(environment: Environment, firstViewSide: Int) {
        self.env = environment
        self.firstViewSide = firstViewSide
    }

    private var firstViewOptions: DecodeOptions { .fitting(firstViewSide) }

    // MARK: Opening

    /// Opens a file (and lists its folder for flipping) or a folder (starting at its first image).
    public func open(_ requested: URL) {
        guard !isClosed else { return }
        let isFolder = env.isFolder(requested)
        // One spelling of the path, so the first image and the folder listing share cache entries.
        let url = isFolder ? requested : FolderNavigator.canonical(requested)
        if !isFolder {
            // Show the file at once; the folder listing arrives in the background.
            display(url)
        }
        listingTask = Task { [weak self, env] in
            let listing = await env.listing(url, isFolder)
            guard let self, !Task.isCancelled else { return }
            guard let listing else {
                // An unreadable folder: say so, rather than leave a blank window.
                if isFolder {
                    env.setTitle(url.lastPathComponent, nil)
                    env.setSubtitle("Can't read this folder")
                }
                return
            }
            self.flip.setListing(listing, current: isFolder ? nil : url)
            if isFolder {
                guard let first = self.flip.jumpToFirst() else {
                    env.setTitle(url.lastPathComponent, nil)
                    env.setSubtitle("No images in this folder")
                    return
                }
                self.display(first)
            }
            self.preloadNeighbours()
            self.updateSubtitle()
        }
    }

    /// Carries out a navigation command. Returns false for any other command (zoom and full
    /// screen belong to the view).
    @discardableResult
    public func perform(_ command: ViewerCommand) -> Bool {
        switch command {
        case .nextImage: go(to: flip.step(+1))
        case .previousImage: go(to: flip.step(-1))
        case .firstImage: go(to: flip.jumpToFirst())
        case .lastImage: go(to: flip.jumpToLast())
        default: return false
        }
        return true
    }

    private func go(to url: URL?) {
        guard let url else { return }
        display(url)
        preloadNeighbours()
    }

    private func display(_ url: URL) {
        guard !isClosed else { return }
        currentURL = url
        generation += 1
        loadTask?.cancel()
        upgradeTask?.cancel()
        upgradeTask = nil
        // Cancelling removes this window's queued request. A decode already running finishes
        // and is cached, so flipping back is instant.
        loadTask = Task { [weak self, env, options = firstViewOptions] in
            do {
                let image = try await env.image(url, options, .visible)
                guard let self, !Task.isCancelled else { return }
                // The upload runs off the main thread; the user may move on while it does.
                let prepared = try await env.prepare(image)
                guard !Task.isCancelled else { return }

                env.imageWillShow()
                self.errorMessage = nil
                env.setTitle(url.lastPathComponent, url)
                // Set before showing: showing triggers `transformChanged`, which reads it.
                self.shown = ShownImageInfo(sourceSize: image.sourcePixelSize, textureSize: image.pixelSize,
                                            decodeDuration: image.decodeDuration,
                                            uploadDuration: env.uploadDuration(prepared))
                self.shownURL = url
                env.show(prepared, image, true)
                self.updateSubtitle()
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled, let self else { return }
                self.shown = nil
                self.shownURL = nil
                env.clear()
                env.setTitle(url.lastPathComponent, url)
                self.errorMessage = "Can't open this file"
                self.updateSubtitle()
            }
        }
    }

    private func preloadNeighbours() {
        guard !isClosed else { return }
        let urls = flip.preloadURLs
        // Each call waits for the one before it, so under fast flipping an older list can never
        // reach the scheduler after a newer one and drop what the newer one wants.
        let previous = preloadTask
        preloadTask = Task { [env, options = firstViewOptions] in
            await previous?.value
            await env.preload(urls, options)
        }
    }

    // MARK: Upgrade

    /// Tells the model the view changed (zoom, pan, a new image, a resize). Updates the status
    /// line and, if the user has zoomed past what the small first-view texture can show sharply,
    /// replaces it with the full-resolution decode. The view (zoom and pan) is untouched, because
    /// it works in source pixels.
    public func transformChanged() {
        updateSubtitle()
        considerUpgrade()
    }

    private func considerUpgrade() {
        let view = env.viewState()
        guard !isClosed, upgradeTask == nil, upgradeAttemptedFor != generation, let shown, let url = currentURL, shownURL == url,
              UpgradePolicy.shouldUpgrade(
                textureLongestSide: shown.textureSize.longestSide,
                sourceLongestSide: shown.sourceSize.longestSide,
                zoom: view.zoom,
                isCustomZoom: !view.isFitMode) else { return }

        let generation = self.generation
        upgradeAttemptedFor = generation
        upgradeTask = Task { [weak self, env] in
            let full = try? await env.image(url, .fullResolution, .visible)
            var prepared: Prepared?
            if let full, let self, self.generation == generation {
                prepared = try? await env.prepare(full)
            }
            // A newer image was opened meanwhile; this work belongs to the old one. The task
            // stays registered until here, so no second upgrade starts during the upload.
            guard let self, self.generation == generation else { return }
            self.upgradeTask = nil
            guard !Task.isCancelled else { return }
            guard let full, let prepared, let previous = self.shown else { return }

            // The file may have been saved over with a different size: start the view afresh.
            let sameShape = full.sourcePixelSize == previous.sourceSize
            // Set before showing: showing triggers `transformChanged`, which reads it, and must
            // see an image that needs no further upgrade.
            self.shown = ShownImageInfo(sourceSize: full.sourcePixelSize, textureSize: full.pixelSize,
                                        decodeDuration: full.decodeDuration, uploadDuration: env.uploadDuration(prepared))
            env.show(prepared, full, !sameShape)
            self.updateSubtitle()
        }
    }

    // MARK: Display changes and closing

    /// The window moved to a display with the given longest side (pixels). A first view sized for
    /// a smaller display would be stretched, and a fitted view never upgrades: decode again at the
    /// new size, keeping the zoom if the user set one.
    public func screenChanged(longestSide side: Int) {
        guard !isClosed, side > firstViewSide else { return }
        firstViewSide = side
        if env.viewState().isFitMode, let url = currentURL {
            display(url)
            preloadNeighbours()
        }
    }

    /// The window is closing: stop all work for it and start none afterwards. Cancelling makes
    /// anything still in flight drop its result instead of showing it into a closed window.
    public func close() {
        isClosed = true
        listingTask?.cancel()
        loadTask?.cancel()
        upgradeTask?.cancel()
        preloadTask?.cancel()
    }

    // MARK: Status line

    private func updateSubtitle() {
        // The position of the image on screen, not of the one that is loading.
        var position: (number: Int, count: Int)?
        if let shownURL, let listing = flip.listing, let index = listing.index(of: shownURL) {
            position = (index + 1, listing.count)
        }
        env.setSubtitle(SubtitleFormatter.text(position: position, shown: shown,
                                               zoom: env.viewState().zoom, error: errorMessage))
    }

    // MARK: Testing

    /// Waits until the folder listing has been taken in. For tests.
    func settleListing() async {
        await listingTask?.value
    }

    /// Waits until the work in flight has finished. For tests.
    func settle() async {
        // Work can start more work (a listing shows an image, which preloads), so go round again
        // until a full pass finds nothing new.
        for _ in 0..<4 {
            let tasks = [listingTask, loadTask, upgradeTask, preloadTask].compactMap { $0 }
            for task in tasks { await task.value }
        }
    }
}
