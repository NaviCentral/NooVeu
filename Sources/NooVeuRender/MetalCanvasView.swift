import AppKit
import MetalKit
import NooVeuCore

/// The image canvas: one textured quad drawn with Metal, redrawn only when something changes.
///
/// Gestures: pinch or mouse wheel zooms about the pointer, a two-finger trackpad scroll or a
/// drag pans, and a smart-zoom tap toggles between fit and actual pixels.
@MainActor
public final class MetalCanvasView: MTKView {
    public private(set) var transform = ViewTransform()

    /// Offered every key press first; return `true` if it was handled.
    public var keyHandler: ((NSEvent) -> Bool)?
    /// Called after zoom, pan or a new image changes what is on screen.
    public var onTransformChange: ((ViewTransform) -> Void)?
    /// Called once, when the display has handled a frame showing an image: later than the GPU
    /// finishing it, and for an occluded window still reached.
    public var onImageFramePresented: (@MainActor @Sendable () -> Void)?

    private let renderer: ImageRenderer
    private let factory: TextureFactory
    private var texture: MTLTexture?

    /// Fails only when Metal is unavailable, which no Apple Silicon Mac lacks.
    public init?(contentFrame frame: CGRect) {
        guard let device = MTLCreateSystemDefaultDevice(),
              let factory = TextureFactory(device: device),
              let renderer = ImageRenderer(device: device)
        else { return nil }

        self.renderer = renderer
        self.factory = factory
        super.init(frame: frame, device: device)

        colorPixelFormat = renderer.pixelFormat
        clearColor = MTLClearColor(red: 0.11, green: 0.11, blue: 0.12, alpha: 1)
        framebufferOnly = true
        // Draw on demand, not at 120 frames a second.
        isPaused = true
        enableSetNeedsDisplay = true
    }

    @available(*, unavailable)
    required init(coder: NSCoder) {
        fatalError("MetalCanvasView is created in code")
    }

    // MARK: Showing images

    /// Uploads `image` to the GPU without blocking the main thread. Pass the result to
    /// `show(_:of:resetView:)` once it is still the image the user wants.
    public func prepare(_ image: DecodedImage) async throws -> PreparedTexture {
        try await factory.makeTexture(from: image.cgImage)
    }

    /// Shows an already uploaded image.
    ///
    /// The view works in the source's pixel size, so a downsampled `image` is drawn stretched
    /// to the source's footprint. Passing `resetView: false` swaps in a sharper version of the
    /// image already on screen without disturbing zoom or pan.
    public func show(_ prepared: PreparedTexture, of image: DecodedImage, resetView: Bool = true) {
        texture = prepared.texture
        (layer as? CAMetalLayer)?.colorspace = prepared.colorSpace
        if resetView {
            transform.setImageSize(CGSize(width: image.sourcePixelSize.width,
                                          height: image.sourcePixelSize.height))
        }
        changed()
    }

    public func clear() {
        texture = nil
        changed()
    }

    public var hasImage: Bool { texture != nil }

    // MARK: Zoom commands

    public func zoom(by factor: CGFloat, anchor: CGPoint? = nil) {
        guard hasImage else { return }
        transform.zoom(by: factor, anchor: anchor)
        changed()
    }

    public func zoomToFit() {
        transform.fit()
        changed()
    }

    public func zoomToActualPixels(anchor: CGPoint? = nil) {
        guard hasImage else { return }
        transform.setZoom(1, anchor: anchor)
        changed()
    }

    // MARK: Drawing

    public override func draw(_ dirtyRect: NSRect) {
        guard let pass = currentRenderPassDescriptor,
              let drawable = currentDrawable,
              let buffer = renderer.commandQueue.makeCommandBuffer(),
              let encoder = buffer.makeRenderCommandEncoder(descriptor: pass)
        else { return }

        if let texture {
            renderer.encode(into: encoder, texture: texture, transform: transform)
        }
        encoder.endEncoding()

        // Take the callback now, so a second draw before this frame is presented cannot attach it
        // again. It fires once, when the display has handled the frame. It must not wait for
        // `presentedTime` to be non-zero: that is 0 whenever the window is occluded or off screen
        // (measured), and retrying until it is would redraw an invisible window forever.
        if texture != nil, let callback = onImageFramePresented {
            onImageFramePresented = nil
            drawable.addPresentedHandler { _ in
                Task { @MainActor in callback() }
            }
        }
        buffer.present(drawable)
        buffer.commit()
    }

    // MARK: Layout

    public override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        syncViewSize()
    }

    public override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        syncViewSize()
    }

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        syncViewSize()
    }

    private func syncViewSize() {
        transform.setViewSize(bounds.size, backingScale: window?.backingScaleFactor ?? 2)
        changed()
    }

    private func changed() {
        needsDisplay = true
        onTransformChange?(transform)
    }

    // MARK: Input

    public override var acceptsFirstResponder: Bool { true }

    public override func keyDown(with event: NSEvent) {
        if keyHandler?(event) == true { return }
        super.keyDown(with: event)
    }

    public override func scrollWheel(with event: NSEvent) {
        guard hasImage else { return }
        if event.hasPreciseScrollingDeltas && !event.modifierFlags.contains(.command) {
            // Trackpad scroll pans; the deltas already follow the user's scroll direction.
            transform.pan(by: CGSize(width: event.scrollingDeltaX, height: -event.scrollingDeltaY))
            changed()
        } else {
            // A mouse wheel (or ⌘ with a trackpad) zooms about the pointer.
            let steps = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY / 40 : event.scrollingDeltaY
            zoom(by: pow(1.15, steps), anchor: convert(event.locationInWindow, from: nil))
        }
    }

    public override func magnify(with event: NSEvent) {
        zoom(by: 1 + event.magnification, anchor: convert(event.locationInWindow, from: nil))
    }

    public override func smartMagnify(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if transform.mode == .fit {
            // An image no larger than the view is already at 1:1; magnify it instead.
            if transform.fitZoom >= 1 {
                guard hasImage else { return }
                transform.setZoom(2, anchor: point)
                changed()
            } else {
                zoomToActualPixels(anchor: point)
            }
        } else {
            zoomToFit()
        }
    }

    public override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 {
            window?.toggleFullScreen(nil)
        }
    }

    public override func mouseDragged(with event: NSEvent) {
        guard hasImage else { return }
        transform.pan(by: CGSize(width: event.deltaX, height: -event.deltaY))
        changed()
    }
}
