import AppKit
import NooVeuCore
import NooVeuRender

/// One viewer window: shows an image and flips through the rest of its folder.
@MainActor
final class ViewerWindowController: NSWindowController, NSWindowDelegate {
    var onClose: (() -> Void)?
    /// Called once, when the first image has been presented on screen.
    var onFirstImageFrame: (() -> Void)?

    /// What the window needs to remember about the image on screen. Sizes and timings only: the
    /// bitmap itself belongs to the scheduler's cache and must not be pinned here (after an
    /// upgrade it can be 400 MB).
    private struct ShownImage {
        let sourceSize: PixelSize
        let textureSize: PixelSize
        let decodeDuration: Duration
        let uploadDuration: Duration
    }

    private let canvas: MetalCanvasView
    private let scheduler: DecodeScheduler
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
    private var loadTask: Task<Void, Never>?
    private var upgradeTask: Task<Void, Never>?
    private var preloadTask: Task<Void, Never>?
    private var shown: ShownImage?
    private var errorMessage: String?

    /// Longest side, in pixels, of the display the window is on. First views are decoded to about
    /// this size, which is much faster than full resolution for big photos; a full decode follows
    /// when the user zooms in. Follows the window when it moves to a larger display.
    private var firstViewSide: Int

    init(scheduler: DecodeScheduler) {
        guard let canvas = MetalCanvasView(contentFrame: NSRect(x: 0, y: 0, width: 1200, height: 800)) else {
            fatalError("Metal is unavailable on this Mac")
        }
        self.canvas = canvas
        self.scheduler = scheduler
        self.firstViewSide = Self.longestSide(of: NSScreen.main)

        let window = NSWindow(
            contentRect: canvas.frame,
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.contentView = canvas
        window.minSize = NSSize(width: 320, height: 240)
        window.collectionBehavior.insert(.fullScreenPrimary)
        window.isReleasedWhenClosed = false
        window.center()
        super.init(window: window)

        window.delegate = self
        window.makeFirstResponder(canvas)
        canvas.keyHandler = { [weak self] event in self?.handleKey(event) ?? false }
        canvas.onTransformChange = { [weak self] _ in self?.transformChanged() }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("ViewerWindowController is created in code")
    }

    /// The longest side of `screen` in pixels (3840 when there is no screen to ask).
    private static func longestSide(of screen: NSScreen?) -> Int {
        guard let screen else { return 3840 }
        return Int((max(screen.frame.width, screen.frame.height) * screen.backingScaleFactor).rounded())
    }

    private var firstViewOptions: DecodeOptions { .fitting(firstViewSide) }

    // MARK: Opening

    /// Opens a file (and lists its folder for flipping) or a folder (starting at its first image).
    func open(_ requested: URL) {
        let isFolder = (try? requested.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
        // One spelling of the path, so the first image and the folder listing share cache entries.
        let url = isFolder ? requested : FolderNavigator.canonical(requested)
        if !isFolder {
            // Show the file at once; the folder listing arrives in the background.
            display(url)
        }
        Task { [weak self] in
            let listing = await Task.detached(priority: .userInitiated) {
                try? isFolder ? FolderNavigator.listing(of: url) : FolderNavigator.listing(containing: url)
            }.value
            guard let self else { return }
            guard let listing else {
                // An unreadable folder: say so, rather than leave a blank window.
                if isFolder {
                    self.window?.title = url.lastPathComponent
                    self.window?.subtitle = "Can't read this folder"
                }
                return
            }
            self.flip.setListing(listing, current: isFolder ? nil : url)
            if isFolder {
                guard let first = self.flip.jumpToFirst() else {
                    self.window?.title = url.lastPathComponent
                    self.window?.subtitle = "No images in this folder"
                    return
                }
                self.display(first)
            }
            self.preloadNeighbours()
            self.updateSubtitle()
        }
    }

    private func go(to url: URL?) {
        guard let url else { return }
        display(url)
        preloadNeighbours()
    }

    private func display(_ url: URL) {
        currentURL = url
        generation += 1
        loadTask?.cancel()
        upgradeTask?.cancel()
        upgradeTask = nil
        // Cancelling removes this window's queued request. A decode already running finishes
        // and is cached, so flipping back is instant.
        loadTask = Task { [weak self, scheduler, options = firstViewOptions] in
            do {
                let image = try await scheduler.image(for: url, options: options, priority: .visible)
                guard let self, !Task.isCancelled else { return }
                // The upload runs off the main thread; the user may move on while it does.
                let prepared = try await self.canvas.prepare(image)
                guard !Task.isCancelled else { return }

                self.armFirstFrameCallback()
                self.errorMessage = nil
                self.window?.title = url.lastPathComponent
                self.window?.representedURL = url
                // Set before showing: showing triggers `transformChanged`, which reads it.
                self.shown = ShownImage(sourceSize: image.sourcePixelSize, textureSize: image.pixelSize,
                                        decodeDuration: image.decodeDuration, uploadDuration: prepared.uploadDuration)
                self.shownURL = url
                self.canvas.show(prepared, of: image)
                self.updateSubtitle()
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled, let self else { return }
                self.shown = nil
                self.shownURL = nil
                self.canvas.clear()
                self.window?.title = url.lastPathComponent
                self.window?.representedURL = url
                self.errorMessage = "Can't open this file"
                self.updateSubtitle()
            }
        }
    }

    private func preloadNeighbours() {
        let urls = flip.preloadURLs
        // Each call waits for the one before it, so under fast flipping an older list can never
        // reach the scheduler after a newer one and drop what the newer one wants.
        let previous = preloadTask
        preloadTask = Task { [scheduler, options = firstViewOptions] in
            await previous?.value
            await scheduler.preload(urls, options: options)
        }
    }

    /// Replaces a downsampled first view with the full-resolution decode once the user zooms in
    /// past what the smaller texture can show sharply. The view (zoom and pan) is untouched,
    /// because it works in source pixels.
    private func considerUpgrade() {
        guard upgradeTask == nil, upgradeAttemptedFor != generation, let shown, let url = currentURL, shownURL == url,
              UpgradePolicy.shouldUpgrade(
                textureLongestSide: shown.textureSize.longestSide,
                sourceLongestSide: shown.sourceSize.longestSide,
                zoom: canvas.transform.zoom,
                isCustomZoom: canvas.transform.mode == .custom) else { return }

        let generation = self.generation
        upgradeAttemptedFor = generation
        upgradeTask = Task { [weak self, scheduler] in
            let full = try? await scheduler.image(for: url, options: .fullResolution, priority: .visible)
            var prepared: PreparedTexture?
            if let full, let self, self.generation == generation {
                prepared = try? await self.canvas.prepare(full)
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
            self.shown = ShownImage(sourceSize: full.sourcePixelSize, textureSize: full.pixelSize,
                                    decodeDuration: full.decodeDuration, uploadDuration: prepared.uploadDuration)
            self.canvas.show(prepared, of: full, resetView: !sameShape)
            self.updateSubtitle()
        }
    }

    private func armFirstFrameCallback() {
        guard let callback = onFirstImageFrame else { return }
        onFirstImageFrame = nil
        // The canvas takes the callback when it draws and fires it once, when the frame is presented.
        canvas.onImageFramePresented = { callback() }
    }

    private func transformChanged() {
        updateSubtitle()
        considerUpgrade()
    }

    // MARK: Status line

    private func updateSubtitle() {
        var parts: [String] = []
        // The position of the image on screen, not of the one that is loading.
        if let shownURL, let listing = flip.listing, let index = listing.index(of: shownURL) {
            parts.append("\(index + 1) / \(listing.count)")
        }
        if let shown {
            parts.append(shown.sourceSize.description)
            parts.append("\(Int((canvas.transform.zoom * 100).rounded()))%")
            parts.append(String(format: "decode %.0f ms, upload %.0f ms",
                                shown.decodeDuration.milliseconds, shown.uploadDuration.milliseconds))
        } else if let errorMessage {
            parts.append(errorMessage)
        }
        window?.subtitle = parts.joined(separator: "  ·  ")
    }

    // MARK: Keyboard

    private func handleKey(_ event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            .subtracting([.numericPad, .function, .capsLock])
        // ⌘, ⌃ and ⌥ shortcuts belong to the menus.
        guard modifiers.isDisjoint(with: [.command, .control, .option]),
              let characters = event.charactersIgnoringModifiers,
              let scalar = characters.unicodeScalars.first else { return false }

        switch Int(scalar.value) {
        case NSRightArrowFunctionKey, NSDownArrowFunctionKey, NSPageDownFunctionKey, 0x20:
            go(to: flip.step(+1))
        case NSLeftArrowFunctionKey, NSUpArrowFunctionKey, NSPageUpFunctionKey, 0x7F:
            go(to: flip.step(-1))
        case NSHomeFunctionKey:
            go(to: flip.jumpToFirst())
        case NSEndFunctionKey:
            go(to: flip.jumpToLast())
        case 0x1B where window?.styleMask.contains(.fullScreen) == true:
            window?.toggleFullScreen(nil)
        default:
            switch characters.lowercased() {
            case "+", "=": canvas.zoom(by: 1.25)
            case "-", "_": canvas.zoom(by: 0.8)
            // As in the View menu: ⌘0 and 0 are actual pixels, ⌘9 and 9 fit. "1" is a second
            // way to reach actual pixels.
            case "0", "1": canvas.zoomToActualPixels()
            case "9": canvas.zoomToFit()
            case "f", "\r":
                // Holding the key must not flicker in and out of full screen.
                if !event.isARepeat { window?.toggleFullScreen(nil) }
            default: return false
            }
        }
        return true
    }

    // MARK: Menu actions (reached through the responder chain)

    @objc func nextImage(_ sender: Any?) { go(to: flip.step(+1)) }
    @objc func previousImage(_ sender: Any?) { go(to: flip.step(-1)) }
    @objc func firstImage(_ sender: Any?) { go(to: flip.jumpToFirst()) }
    @objc func lastImage(_ sender: Any?) { go(to: flip.jumpToLast()) }
    @objc func zoomIn(_ sender: Any?) { canvas.zoom(by: 1.25) }
    @objc func zoomOut(_ sender: Any?) { canvas.zoom(by: 0.8) }
    @objc func actualPixels(_ sender: Any?) { canvas.zoomToActualPixels() }
    @objc func zoomToFit(_ sender: Any?) { canvas.zoomToFit() }

    // MARK: NSWindowDelegate

    /// Moved to a larger display: a first view sized for the old one would be stretched, and a
    /// fitted view never upgrades. Decode again at the new size, keeping zoom if the user set one.
    func windowDidChangeScreen(_ notification: Notification) {
        let side = Self.longestSide(of: window?.screen)
        guard side > firstViewSide else { return }
        firstViewSide = side
        if canvas.transform.mode == .fit, let url = currentURL {
            display(url)
            preloadNeighbours()
        }
    }

    func windowWillClose(_ notification: Notification) {
        loadTask?.cancel()
        upgradeTask?.cancel()
        preloadTask?.cancel()
        onClose?()
    }
}
