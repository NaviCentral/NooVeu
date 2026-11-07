import AppKit
import NooVeuCore
import NooVeuRender

/// One viewer window: shows an image and flips through the rest of its folder.
@MainActor
final class ViewerWindowController: NSWindowController, NSWindowDelegate {
    var onClose: (() -> Void)?
    /// Called once, when the first image has been presented on screen.
    var onFirstImageFrame: (() -> Void)?

    private let canvas: MetalCanvasView
    private let scheduler: DecodeScheduler
    private var flip = FlipState()
    private var currentURL: URL?
    /// The file `shown` came from. Differs from `currentURL` while the next image loads.
    private var shownURL: URL?
    /// Bumped on every `display`; work started for an earlier image checks it before landing.
    private var generation = 0
    /// The generation whose full-resolution upgrade failed; it is not retried on every pan.
    private var upgradeFailedFor = -1
    private var loadTask: Task<Void, Never>?
    private var upgradeTask: Task<Void, Never>?
    private var preloadTask: Task<Void, Never>?
    private var shown: (image: DecodedImage, upload: Duration)?
    private var errorMessage: String?

    /// Longest side, in pixels, of the largest connected display. First views are decoded to
    /// about this size, which is much faster than full resolution for big photos; a full
    /// decode follows when the user zooms in.
    private let firstViewSide: Int

    init(scheduler: DecodeScheduler) {
        guard let canvas = MetalCanvasView(contentFrame: NSRect(x: 0, y: 0, width: 1200, height: 800)) else {
            fatalError("Metal is unavailable on this Mac")
        }
        self.canvas = canvas
        self.scheduler = scheduler
        self.firstViewSide = Self.largestScreenSide()

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

    private static func largestScreenSide() -> Int {
        let sides = NSScreen.screens.map { max($0.frame.width, $0.frame.height) * $0.backingScaleFactor }
        return Int((sides.max() ?? 3840).rounded())
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
            guard let self, let listing else { return }
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
                self.shown = (image, prepared.uploadDuration)
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
        guard upgradeTask == nil, upgradeFailedFor != generation, let shown, let url = currentURL, shownURL == url,
              UpgradePolicy.shouldUpgrade(
                textureLongestSide: shown.image.pixelSize.longestSide,
                sourceLongestSide: shown.image.sourcePixelSize.longestSide,
                zoom: canvas.transform.zoom,
                isCustomZoom: canvas.transform.mode == .custom) else { return }

        let generation = self.generation
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
            guard let full, let prepared, let previous = self.shown else {
                self.upgradeFailedFor = generation
                return
            }

            // The file may have been saved over with a different size: start the view afresh.
            let sameShape = full.sourcePixelSize == previous.image.sourcePixelSize
            // Set before showing: showing triggers `transformChanged`, which reads it, and must
            // see an image that needs no further upgrade.
            self.shown = (full, prepared.uploadDuration)
            self.canvas.show(prepared, of: full, resetView: !sameShape)
            self.updateSubtitle()
        }
    }

    private func armFirstFrameCallback() {
        guard let callback = onFirstImageFrame else { return }
        onFirstImageFrame = nil
        canvas.onImageFramePresented = { [weak canvas] in
            canvas?.onImageFramePresented = nil
            callback()
        }
    }

    private func transformChanged() {
        updateSubtitle()
        considerUpgrade()
    }

    // MARK: Status line

    private func updateSubtitle() {
        var parts: [String] = []
        if let position = flip.position {
            parts.append("\(position.number) / \(position.count)")
        }
        if let shown {
            parts.append(shown.image.sourcePixelSize.description)
            parts.append("\(Int((canvas.transform.zoom * 100).rounded()))%")
            parts.append(String(format: "decode %.0f ms, upload %.0f ms",
                                shown.image.decodeDuration.milliseconds, shown.upload.milliseconds))
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

    func windowWillClose(_ notification: Notification) {
        loadTask?.cancel()
        upgradeTask?.cancel()
        onClose?()
    }
}
