import AppKit
import NooVeuCore
import NooVeuRender
import NooVeuShell

/// One viewer window: the AppKit side of a viewer. It owns the window and the Metal canvas,
/// translates events into commands, and supplies the real decoder, uploader and screen to
/// `ViewerModel`, which holds the logic (and is tested without any of this).
@MainActor
final class ViewerWindowController: NSWindowController, NSWindowDelegate {
    var onClose: (() -> Void)?
    /// Called once, when the first image has been presented on screen.
    var onFirstImageFrame: (() -> Void)?

    private let canvas: MetalCanvasView
    private var model: ViewerModel<PreparedTexture>!

    init(scheduler: DecodeScheduler) {
        guard let canvas = MetalCanvasView(contentFrame: NSRect(x: 0, y: 0, width: 1200, height: 800)) else {
            fatalError("Metal is unavailable on this Mac")
        }
        self.canvas = canvas

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
        canvas.onTransformChange = { [weak self] _ in self?.model.transformChanged() }

        model = ViewerModel(
            environment: makeEnvironment(scheduler: scheduler, canvas: canvas, window: window),
            firstViewSide: Self.longestSide(of: NSScreen.main)
        )
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("ViewerWindowController is created in code")
    }

    /// The real decoder, uploader and window, as `ViewerModel` sees them.
    private func makeEnvironment(
        scheduler: DecodeScheduler, canvas: MetalCanvasView, window: NSWindow
    ) -> ViewerModel<PreparedTexture>.Environment {
        .init(
            isFolder: { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false },
            listing: { url, isFolder in
                await Task.detached(priority: .userInitiated) {
                    try? isFolder ? FolderNavigator.listing(of: url) : FolderNavigator.listing(containing: url)
                }.value
            },
            image: { url, options, priority in try await scheduler.image(for: url, options: options, priority: priority) },
            preload: { urls, options in await scheduler.preload(urls, options: options) },
            prepare: { image in try await canvas.prepare(image) },
            uploadDuration: { $0.uploadDuration },
            show: { prepared, image, resetView in canvas.show(prepared, of: image, resetView: resetView) },
            clear: { canvas.clear() },
            setTitle: { [weak window] title, url in
                window?.title = title
                window?.representedURL = url
            },
            setSubtitle: { [weak window] in window?.subtitle = $0 },
            viewState: { ViewerModel<PreparedTexture>.ViewState(zoom: canvas.transform.zoom,
                                                                isFitMode: canvas.transform.mode == .fit) },
            imageWillShow: { [weak self] in self?.armFirstFrameCallback() }
        )
    }

    private static func longestSide(of screen: NSScreen?) -> Int {
        ScreenMath.longestSide(of: screen?.frame.size, scale: screen?.backingScaleFactor ?? 2)
    }

    /// Opens a file (and lists its folder for flipping) or a folder (starting at its first image).
    func open(_ requested: URL) {
        model.open(requested)
    }

    private func armFirstFrameCallback() {
        guard let callback = onFirstImageFrame else { return }
        onFirstImageFrame = nil
        // The canvas takes the callback when it draws and fires it once, when the frame is presented.
        canvas.onImageFramePresented = { callback() }
    }

    // MARK: Commands

    private func run(_ command: ViewerCommand) {
        if model.perform(command) { return }
        switch command {
        case .zoomIn: canvas.zoom(by: 1.25)
        case .zoomOut: canvas.zoom(by: 0.8)
        case .actualPixels: canvas.zoomToActualPixels()
        case .zoomToFit: canvas.zoomToFit()
        case .toggleFullScreen, .exitFullScreen: window?.toggleFullScreen(nil)
        case .nextImage, .previousImage, .firstImage, .lastImage: break  // handled by the model
        }
    }

    // MARK: Keyboard

    private func handleKey(_ event: NSEvent) -> Bool {
        guard let input = Self.keyInput(for: event) else { return false }
        let isFullScreen = window?.styleMask.contains(.fullScreen) == true
        switch KeyBindings.action(for: input, isFullScreen: isFullScreen) {
        case .passThrough: return false
        case .swallow: return true
        case .run(let command):
            run(command)
            return true
        }
    }

    /// An AppKit key event, reduced to what `KeyBindings` looks at.
    private static func keyInput(for event: NSEvent) -> KeyInput? {
        guard let characters = event.charactersIgnoringModifiers,
              let scalar = characters.unicodeScalars.first else { return nil }
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let key: KeyInput.Key
        switch Int(scalar.value) {
        case NSRightArrowFunctionKey: key = .rightArrow
        case NSLeftArrowFunctionKey: key = .leftArrow
        case NSUpArrowFunctionKey: key = .upArrow
        case NSDownArrowFunctionKey: key = .downArrow
        case NSPageUpFunctionKey: key = .pageUp
        case NSPageDownFunctionKey: key = .pageDown
        case NSHomeFunctionKey: key = .home
        case NSEndFunctionKey: key = .end
        case 0x20: key = .space
        case 0x7F: key = .delete
        case 0x1B: key = .escape
        case 0x0D: key = .returnKey
        default: key = .character(characters.lowercased())
        }
        return KeyInput(key,
                        hasMenuModifier: !modifiers.isDisjoint(with: [.command, .control, .option]),
                        isRepeat: event.isARepeat)
    }

    // MARK: Menu actions (reached through the responder chain)

    @objc func nextImage(_ sender: Any?) { run(.nextImage) }
    @objc func previousImage(_ sender: Any?) { run(.previousImage) }
    @objc func firstImage(_ sender: Any?) { run(.firstImage) }
    @objc func lastImage(_ sender: Any?) { run(.lastImage) }
    @objc func zoomIn(_ sender: Any?) { run(.zoomIn) }
    @objc func zoomOut(_ sender: Any?) { run(.zoomOut) }
    @objc func actualPixels(_ sender: Any?) { run(.actualPixels) }
    @objc func zoomToFit(_ sender: Any?) { run(.zoomToFit) }

    // MARK: NSWindowDelegate

    func windowDidChangeScreen(_ notification: Notification) {
        model.screenChanged(longestSide: Self.longestSide(of: window?.screen))
    }

    func windowWillClose(_ notification: Notification) {
        model.close()
        onClose?()
    }
}
