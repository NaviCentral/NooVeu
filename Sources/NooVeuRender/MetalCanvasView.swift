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
    /// Called once the GPU has finished a frame that shows an image.
    public var onImageFrameCompleted: (@MainActor @Sendable () -> Void)?

    private let factory: TextureFactory
    private let commandQueue: MTLCommandQueue
    private let pipeline: MTLRenderPipelineState
    private let smoothSampler: MTLSamplerState
    private let pixelSampler: MTLSamplerState
    private var texture: MTLTexture?

    /// Fails only when Metal is unavailable, which no Apple Silicon Mac lacks.
    public init?(contentFrame frame: CGRect) {
        guard let device = MTLCreateSystemDefaultDevice(),
              let factory = TextureFactory(device: device),
              let commandQueue = device.makeCommandQueue(),
              let pipeline = try? Shaders.makePipeline(device: device, pixelFormat: .bgra8Unorm),
              let smoothSampler = Shaders.makeSampler(device: device, pixelGrid: false),
              let pixelSampler = Shaders.makeSampler(device: device, pixelGrid: true)
        else { return nil }

        self.factory = factory
        self.commandQueue = commandQueue
        self.pipeline = pipeline
        self.smoothSampler = smoothSampler
        self.pixelSampler = pixelSampler
        super.init(frame: frame, device: device)

        colorPixelFormat = .bgra8Unorm
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

    /// Uploads `image` and shows it.
    ///
    /// The view works in the source's pixel size, so a downsampled `image` is drawn stretched
    /// to the source's footprint. Passing `resetView: false` swaps in a sharper version of the
    /// image already on screen without disturbing zoom or pan.
    /// - Returns: The time spent converting and uploading it to the GPU.
    @discardableResult
    public func show(_ image: DecodedImage, resetView: Bool = true) throws -> Duration {
        let prepared = try factory.makeTexture(from: image.cgImage)
        texture = prepared.texture
        (layer as? CAMetalLayer)?.colorspace = prepared.colorSpace
        if resetView {
            transform.setImageSize(CGSize(width: image.sourcePixelSize.width,
                                          height: image.sourcePixelSize.height))
        }
        changed()
        return prepared.uploadDuration
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
              let buffer = commandQueue.makeCommandBuffer(),
              let encoder = buffer.makeRenderCommandEncoder(descriptor: pass)
        else { return }

        if let texture {
            var rect = transform.clipRect
            encoder.setRenderPipelineState(pipeline)
            encoder.setVertexBytes(&rect, length: MemoryLayout<SIMD4<Float>>.stride, index: 0)
            encoder.setFragmentTexture(texture, index: 0)
            encoder.setFragmentSamplerState(transform.showsPixelGrid ? pixelSampler : smoothSampler, index: 0)
            encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        }
        encoder.endEncoding()

        if texture != nil, let callback = onImageFrameCompleted {
            buffer.addCompletedHandler { _ in
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
            zoomToActualPixels(anchor: point)
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
