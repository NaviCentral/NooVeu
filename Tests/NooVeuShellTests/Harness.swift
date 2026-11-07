import CoreGraphics
import Foundation
import NooVeuCore
import Synchronization
import Testing
@testable import NooVeuShell

struct FakePrepared: Sendable {
    let name: String
    let textureSize: PixelSize
}

/// Holds named operations (a decode, an upload) until a test releases them, so a test decides the
/// order in which asynchronous work finishes.
actor Gates {
    private var held: Set<String> = []
    private var waiting: [String: [CheckedContinuation<Void, Never>]] = [:]

    func hold(_ key: String) { held.insert(key) }

    func wait(_ key: String) async {
        guard held.contains(key) else { return }
        await withCheckedContinuation { waiting[key, default: []].append($0) }
    }

    /// Lets everything held go. Used when a test is stuck, so it fails instead of hanging.
    func releaseAll() {
        held.removeAll()
        for continuations in waiting.values { for continuation in continuations { continuation.resume() } }
        waiting.removeAll()
    }

    func release(_ key: String) {
        held.remove(key)
        for continuation in waiting.removeValue(forKey: key) ?? [] { continuation.resume() }
    }
}

/// A thread-safe record of what the fake environment was asked to do, in order.
final class Log: Sendable {
    private let lines = Mutex<[String]>([])
    func add(_ line: String) { lines.withLock { $0.append(line) } }
    var all: [String] { lines.withLock { $0 } }
    func count(_ line: String) -> Int { all.filter { $0 == line }.count }
    func count(prefix: String) -> Int { all.filter { $0.hasPrefix(prefix) }.count }
}

/// State shared between the fake environment's closures and the test.
final class Store: Sendable {
    /// Operations that throw, by key ("decode:b.jpg", "full:b.jpg", "prepare:b.jpg").
    let failing = Mutex<Set<String>>([])
    /// A different source size for a file's full-resolution decode (a file saved over).
    let fullSourceOverride = Mutex<[String: PixelSize]>([:])
    let listings = Mutex<[String: FolderListing]>([:])
}

/// One shown image, as the fake surface saw it.
struct Shown: Equatable {
    let name: String
    let textureSize: PixelSize
    let resetView: Bool
}

/// A viewer model wired to fakes. Images are 400×300 at full size and 100×75 at first view, so
/// a first view stays sharp up to a zoom of 0.25.
@MainActor
final class Harness {
    nonisolated static let sourceSize = PixelSize(width: 400, height: 300)
    nonisolated static let firstViewSize = PixelSize(width: 100, height: 75)

    let gates = Gates()
    let log = Log()
    let store = Store()

    private(set) var shows: [Shown] = []
    private(set) var clears = 0
    private(set) var titles: [String] = []
    private(set) var subtitles: [String] = []
    /// The status line as it stood right after each show, from inside the surface's own callback.
    private(set) var subtitlesDuringShow: [String] = []
    var view = ViewerModel<FakePrepared>.ViewState(zoom: 0.2, isFitMode: true)
    /// Like the real canvas, showing an image tells the model the view changed.
    var reenter = true
    var model: ViewerModel<FakePrepared>!

    var shownNames: [String] { shows.map(\.name) }
    var lastSubtitle: String { subtitles.last ?? "" }

    init(firstViewSide: Int = 1000, folders: [String: [String]] = [:]) {
        for (folder, names) in folders { setFolder(folder, names) }

        let gates = self.gates, log = self.log, store = self.store
        let environment = ViewerModel<FakePrepared>.Environment(
            isFolder: { $0.pathExtension.isEmpty },
            listing: { url, isFolder in
                let key = isFolder ? url.path : url.deletingLastPathComponent().path
                log.add("listing:\(key)")
                await gates.wait("listing:\(key)")
                return store.listings.withLock { $0[key] }
            },
            image: { url, options, priority in
                let name = url.lastPathComponent
                let full = options.maxPixelSize == nil
                let kind = full ? "full" : "decode"
                log.add("\(kind):\(name)" + (options.maxPixelSize.map { ":\($0)" } ?? ""))
                log.add("priority:\(kind):\(name)=\(priority)")
                await gates.wait("\(kind):\(name)")
                // A decode that fails reports its error even if the request was cancelled meanwhile
                // (a race the real scheduler allows); otherwise a cancelled request throws.
                if store.failing.withLock({ $0.contains("\(kind):\(name)") }) { throw DecodeError.decodeFailed(url) }
                try Task.checkCancellation()
                let size = full ? (store.fullSourceOverride.withLock { $0[name] } ?? Harness.sourceSize) : Harness.firstViewSize
                let source = full ? size : Harness.sourceSize
                return Harness.makeImage(name: name + (full ? "#full" : ""), source: source, texture: size)
            },
            preload: { urls, options in
                let first = urls.first?.lastPathComponent ?? ""
                log.add("preload:" + urls.map(\.lastPathComponent).joined(separator: ","))
                log.add("preload@\(options.maxPixelSize ?? 0)")
                await gates.wait("preload:\(first)")
            },
            prepare: { image in
                let name = image.typeIdentifier ?? "?"
                let base = name.replacingOccurrences(of: "#full", with: "")
                log.add("prepare:\(name)")
                await gates.wait("prepare:\(name)")
                try Task.checkCancellation()
                if store.failing.withLock({ $0.contains("prepare:\(name)") || $0.contains("prepare:\(base)") }) {
                    throw DecodeError.decodeFailed(URL(fileURLWithPath: "/x"))
                }
                return FakePrepared(name: name, textureSize: image.pixelSize)
            },
            // A bigger texture takes longer to upload, so the status line says which image it describes.
            uploadDuration: { .milliseconds($0.textureSize.width / 10) },
            show: { _, _, _ in },
            clear: {},
            setTitle: { _, _ in },
            setSubtitle: { _ in },
            viewState: { ViewerModel<FakePrepared>.ViewState(zoom: 0, isFitMode: true) },
            imageWillShow: {}
        )
        // The main-actor pieces need `self`, so the model is built with them in place.
        var wired = environment
        wired.show = { [unowned self] prepared, image, resetView in
            self.log.add("show:\(prepared.name)")
            self.shows.append(Shown(name: prepared.name, textureSize: prepared.textureSize, resetView: resetView))
            if self.reenter { self.model.transformChanged() }
            self.subtitlesDuringShow.append(self.subtitles.last ?? "")
        }
        wired.clear = { [unowned self] in
            self.log.add("clear")
            self.clears += 1
            // Like the real canvas, clearing reports a change.
            if self.reenter { self.model.transformChanged() }
        }
        wired.setTitle = { [unowned self] title, _ in self.titles.append(title) }
        wired.setSubtitle = { [unowned self] in self.subtitles.append($0) }
        wired.viewState = { [unowned self] in self.view }
        wired.imageWillShow = { [unowned self] in self.log.add("willShow") }
        model = ViewerModel(environment: wired, firstViewSide: firstViewSide)
    }

    func setFolder(_ folder: String, _ names: [String]) {
        let items = names.map { URL(fileURLWithPath: folder).appendingPathComponent($0) }
        store.listings.withLock { $0[folder] = FolderListing(folder: URL(fileURLWithPath: folder), items: items) }
    }

    func fail(_ key: String) { store.failing.withLock { _ = $0.insert(key) } }

    /// A file's full-resolution decode comes out at a different size (it was saved over).
    func overrideFullSource(_ name: String, _ size: PixelSize) {
        store.fullSourceOverride.withLock { $0[name] = size }
    }

    func url(_ folder: String, _ name: String) -> URL {
        URL(fileURLWithPath: folder).appendingPathComponent(name)
    }

    /// Lets work that was released run, then checks nothing more happens. For negative assertions.
    func letPendingWorkRun() async throws {
        try await Task.sleep(for: .milliseconds(60))
    }

    nonisolated static func makeImage(name: String, source: PixelSize, texture: PixelSize) -> DecodedImage {
        let context = CGContext(data: nil, width: texture.width, height: texture.height, bitsPerComponent: 8,
                                bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
        return DecodedImage(cgImage: context.makeImage()!, sourcePixelSize: source, typeIdentifier: name,
                            decodeDuration: .milliseconds(10))
    }
}

extension Harness {
    /// Polls until `condition` holds (2 s at most), recording a failure otherwise.
    func waitFor(_ description: String, _ condition: @MainActor () -> Bool) async throws {
        for _ in 0..<400 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        Issue.record("timed out waiting for: \(description)")
    }
}

extension Harness {
    /// Waits for all work in flight, giving up after 5 seconds. A test whose work is stuck (a gate
    /// nobody released, a regression that deadlocks) fails with a message instead of hanging.
    func settle() async {
        await withDeadline("work in flight to finish") { await self.model.settle() }
    }

    /// Waits for the folder listing to be taken in, with the same deadline.
    func settleListing() async {
        await withDeadline("the folder listing to arrive") { await self.model.settleListing() }
    }

    private func withDeadline(_ what: String, _ work: () async -> Void) async {
        let timedOut = Flag()
        let gates = self.gates
        // If the work is stuck, free whatever it is waiting on so it can end, and remember why.
        let watchdog = Task {
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled else { return }
            timedOut.raise()
            await gates.releaseAll()
        }
        await work()
        watchdog.cancel()
        if timedOut.isRaised { Issue.record("timed out after 5 s waiting for \(what): something is stuck") }
    }
}

final class Flag: Sendable {
    private let raised = Mutex(false)
    func raise() { raised.withLock { $0 = true } }
    var isRaised: Bool { raised.withLock { $0 } }
}
