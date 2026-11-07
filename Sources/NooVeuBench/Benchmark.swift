import CoreGraphics
import Foundation
import Metal
import NooVeuCore
import NooVeuRender
import Synchronization

struct FileResult: Codable {
    var file: String
    var category: String
    var megapixels: Double
    /// Median milliseconds for each step.
    var fullDecode: Double
    /// Decode at the size the app asks for on first view (`--screen`).
    var firstViewDecode: Double
    var firstViewUpload: Double?
    /// Decode plus upload of one fresh image, as the app does it: the median of the per-run sums.
    var firstViewTotal: Double?
    /// Whether the first-view decode came out at about the size asked for. A bad decode strategy
    /// could return a tiny bitmap and make every first-view row trivially fast.
    var firstViewSizeOk: Bool
    var thumbnail: Double
    /// Whether the decoded size matched the size the corpus wrote.
    var sizeMatches: Bool
    var decodedSize: String
}

struct MalformedResult: Codable {
    var file: String
    var outcome: String
}

struct TargetResult: Codable {
    var name: String
    var budget: Double
    var unit: String
    var measured: Double?
    var basis: String
    /// Set when the target is knowingly missed and tracked: the reason is shown. `--enforce`
    /// tolerates the miss only up to `knownMissCeiling`, so it cannot get worse unnoticed.
    var knownMiss: String?
    var knownMissCeiling: Double?

    var passed: Bool? { measured.map { $0 <= budget } }

    /// What `--enforce` treats as a failure: a target that could not be measured, a miss that is
    /// not a known one, or a known miss that has grown past its ceiling.
    var failsEnforcement: Bool {
        guard let measured, measured.isFinite, let passed else { return true }
        if passed { return false }
        // A known miss is tolerated only up to an explicit ceiling.
        guard knownMiss != nil, let ceiling = knownMissCeiling else { return true }
        return measured > ceiling
    }
}

struct BenchReport: Codable {
    var machine: String
    var macOS: String
    var date: String
    var iterations: Int
    /// Longest side of the display the first view is sized for, in pixels.
    var screenSide: Int
    var files: [FileResult]
    var malformed: [MalformedResult]
    var targets: [TargetResult]
}

private enum BenchError: Error, CustomStringConvertible {
    case noMetal
    case missing(String)
    case failedDecodes(Int)
    case noGPUTimestamps

    var description: String {
        switch self {
        case .noMetal: "Metal is unavailable"
        case .missing(let file): "corpus lacks \(file)"
        case .failedDecodes(let count): "\(count) thumbnail decodes failed"
        case .noGPUTimestamps: "the GPU reported no frame times"
        }
    }
}

/// Times decode, upload and drawing for the corpus along the same path the app takes, then
/// checks the results against the proposal's performance targets.
///
/// What "first view" means here matches `ViewerWindowController`: decode at the display's size
/// (`DecodeOptions.fitting`), then upload to the GPU. A target that cannot be measured (a file
/// missing from the corpus, no Metal) is reported as not measured, never skipped or passed.
/// Launch time and memory at rest need the running app: `scripts/measure-launch.sh`.
@MainActor
enum Benchmark {
    /// A grid cell's size in pixels. (An embedded camera preview is about 160 px: bigger cells
    /// would make `ImageDecoder.thumbnail` decode the image instead of using it.)
    static let thumbnailSide = 128
    /// Thumbnails in the first screen of a grid.
    static let gridThumbnails = 60
    /// 120 Hz, the fastest display a Mac has.
    static let frameBudgetMs = 1_000.0 / 120

    static func run(corpus root: URL, iterations: Int, screenSide: Int, log: (String) -> Void) async throws -> BenchReport {
        let manifest = try JSONDecoder().decode(
            CorpusManifest.self,
            from: Data(contentsOf: root.appendingPathComponent("manifest.json"))
        )
        let manifestFiles = Set(manifest.entries.map(\.file))
        let device = MTLCreateSystemDefaultDevice()
        let factory = device.flatMap { TextureFactory(device: $0) }
        let renderer = device.flatMap { ImageRenderer(device: $0) }
        if factory == nil || renderer == nil { log("Metal is unavailable: upload and frame targets are not measured") }

        let firstView = DecodeOptions.fitting(screenSide)
        let clock = ContinuousClock()
        var files: [FileResult] = []
        var malformed: [MalformedResult] = []

        for entry in manifest.entries {
            let url = root.appendingPathComponent(entry.file)
            log("  \(entry.file)")
            if entry.malformed {
                malformed.append(MalformedResult(file: entry.file, outcome: tryDecode(url)))
                continue
            }

            let full = try timed(iterations) { try ImageDecoder.decode(url) }
            let thumb = try timed(iterations) { try ImageDecoder.thumbnail(url, maxPixelSize: thumbnailSide) }

            // First view: decode a fresh image, then upload that same image, every run. Timing
            // them together on a fresh image is what makes a decode that hides inside the
            // upload count against the total.
            var decodes: [Double] = [], uploads: [Double] = [], totals: [Double] = []
            var sizeOk = true
            for _ in 0..<max(1, iterations) {
                let start = clock.now
                let image = try autoreleasepool { try ImageDecoder.decode(url, options: firstView) }
                let decodeMs = (clock.now - start).milliseconds
                // At least 3/4 of the size asked for (or of the source, when that is smaller).
                let wanted = min(screenSide, image.sourcePixelSize.longestSide)
                if image.pixelSize.longestSide * 4 < wanted * 3 { sizeOk = false }
                decodes.append(decodeMs)
                if let factory {
                    let uploadStart = clock.now
                    _ = try await factory.makeTexture(from: image.cgImage)
                    let uploadMs = (clock.now - uploadStart).milliseconds
                    uploads.append(uploadMs)
                    totals.append(decodeMs + uploadMs)
                }
            }

            let expected = PixelSize(width: entry.pixelWidth, height: entry.pixelHeight)
            let decoded = full.value.pixelSize
            files.append(FileResult(
                file: entry.file,
                category: entry.category,
                megapixels: (expected.megapixels * 10).rounded() / 10,
                fullDecode: full.median,
                firstViewDecode: median(decodes) ?? 0,
                firstViewUpload: median(uploads),
                firstViewTotal: median(totals),
                firstViewSizeOk: sizeOk,
                thumbnail: thumb.median,
                sizeMatches: decoded == expected
                    || (expected.longestSide > ImageDecoder.maxTextureDimension
                        && decoded.longestSide == ImageDecoder.maxTextureDimension),
                decodedSize: decoded.description
            ))
        }

        log("Frames, uploads and thumbnails")
        var targets = firstViewTargets(from: files)
        targets += await gpuTargets(root: root, manifestFiles: manifestFiles, factory: factory, renderer: renderer,
                                    iterations: iterations, screenSide: screenSide)
        targets += await thumbnailTargets(root: root, manifestFiles: manifestFiles, iterations: max(iterations, 5))

        return BenchReport(
            machine: machineDescription(),
            macOS: ProcessInfo.processInfo.operatingSystemVersionString,
            date: ISO8601DateFormatter().string(from: Date()),
            iterations: iterations,
            screenSide: screenSide,
            files: files,
            malformed: malformed,
            targets: targets
        )
    }

    // MARK: Targets from the per-file table

    private static func firstViewTargets(from files: [FileResult]) -> [TargetResult] {
        func row(_ name: String, category: String, budget: Double,
                 knownMiss: String? = nil, ceiling: Double? = nil) -> TargetResult {
            // Decode plus upload on one fresh image; without Metal there is no upload time, and
            // a decode alone would understate the cost, so it stays unmeasured.
            TargetResult(name: name, budget: budget, unit: "ms",
                         measured: files.first { $0.category == category }?.firstViewTotal,
                         basis: "screen-sized decode + GPU upload of one fresh image",
                         knownMiss: knownMiss, knownMissCeiling: ceiling)
        }
        return [
            row("First view, 24 MP JPEG", category: "jpeg-24mp", budget: 120),
            row("First view, 24 MP HEIC", category: "heic-24mp", budget: 120),
            row("First view, 100 MP JPEG", category: "jpeg-100mp", budget: 400),
            row("First view, 100 MP HEIC", category: "heic-100mp", budget: 400),
            row("First view, 24 MP PNG", category: "png-24mp", budget: 120,
                knownMiss: "PNG has no fast decode path; revisit in phase 3", ceiling: 300),
        ]
    }

    // MARK: GPU targets

    /// Measures one target. Anything that goes wrong (a missing corpus file, no Metal) leaves it
    /// not measured, with the reason in its basis, instead of ending the run.
    private static func attempt(
        _ name: String, budget: Double, unit: String = "ms", basis: String,
        _ body: () async throws -> Double?
    ) async -> TargetResult {
        do {
            return TargetResult(name: name, budget: budget, unit: unit, measured: try await body(), basis: basis)
        } catch {
            return TargetResult(name: name, budget: budget, unit: unit, measured: nil,
                                basis: "could not measure: \(error)")
        }
    }

    private static func gpuTargets(
        root: URL, manifestFiles: Set<String>, factory: TextureFactory?, renderer: ImageRenderer?,
        iterations: Int, screenSide: Int
    ) async -> [TargetResult] {
        let large = root.appendingPathComponent("large")
        var results: [TargetResult] = []
        func need() throws -> (TextureFactory, ImageRenderer) {
            guard let factory, let renderer else { throw BenchError.noMetal }
            return (factory, renderer)
        }
        // Only files the manifest lists: a corpus regenerated with `--quick` over an older full one
        // must not be measured through stale files left on disk.
        func existing(_ name: String) throws -> URL {
            guard manifestFiles.contains("large/\(name)") else { throw BenchError.missing("large/\(name)") }
            return large.appendingPathComponent(name)
        }
        let panel = viewTransform(imageSize: PixelSize(width: 0, height: 0), screenSide: screenSide).viewSize

        // The image is already decoded at display size (preloaded). What is left before the user
        // sees it: upload, then one drawn frame. The wait for the display's next refresh (up to
        // 8 ms at 120 Hz) is not included.
        results.append(await attempt("Next image, preloaded (upload + one frame)", budget: 30,
                                     basis: "GPU upload + one drawn frame, 24 MP JPEG, excluding display refresh") {
            let (factory, renderer) = try need()
            let preloaded = try ImageDecoder.decode(try existing("jpeg-24mp.jpg"), options: .fitting(screenSide))
            let transform = viewTransform(imageSize: preloaded.sourcePixelSize, screenSide: screenSide)
            return try await timedAsync(iterations) {
                let prepared = try await factory.makeTexture(from: preloaded.cgImage)
                _ = try renderer.renderOffscreen(texture: prepared.texture, transform: transform)
            }.median
        })

        // Frame time: median GPU time of one fitted (zoomed-out) frame. Zoomed frames, the
        // pixel-grid sampler and CPU time are not measured; the margin here is 20 to 40 times.
        for (name, file, options) in [
            ("Frame time, fit view, 100 MP JPEG at display size", "jpeg-100mp.jpg", DecodeOptions.fitting(screenSide)),
            ("Frame time, fit view, full-size 100 MP JPEG", "jpeg-100mp.jpg", DecodeOptions.fullResolution),
            ("Frame time, fit view, full-size 24 MP JPEG", "jpeg-24mp.jpg", DecodeOptions.fullResolution),
        ] {
            results.append(await attempt(name, budget: frameBudgetMs,
                                         basis: "median GPU time of 30 frames at \(Int(panel.width * 2))×\(Int(panel.height * 2))") {
                let (factory, renderer) = try need()
                let image = try ImageDecoder.decode(try existing(file), options: options)
                let prepared = try await factory.makeTexture(from: image.cgImage)
                let transform = viewTransform(imageSize: image.sourcePixelSize, screenSide: screenSide)
                for _ in 0..<5 { _ = try renderer.renderOffscreen(texture: prepared.texture, transform: transform) }
                var frames: [Double] = []
                for _ in 0..<30 {
                    frames.append(try renderer.renderOffscreen(texture: prepared.texture, transform: transform).gpuSeconds * 1_000)
                }
                guard let middle = median(frames), middle > 0 else { throw BenchError.noGPUTimestamps }
                return middle
            })
        }

        // A freshly decoded image must upload as fast as a plain bitmap of the same size. If it
        // costs much more, decoding is still pending and lands on whoever uploads first (a real
        // bug once: 60 ms against 16 ms for a 24 MP JPEG). The plain bitmap is the reference, so
        // this also catches a format that would decode again on every upload.
        for (label, file) in [("JPEG", "jpeg-24mp.jpg"), ("HEIC", "heic-24mp.heic"), ("PNG", "png-24mp.png")] {
            results.append(await attempt("Upload cost, decoded 24 MP \(label), vs a plain bitmap", budget: 1.6, unit: "×",
                                         basis: "decoded ÷ plain-bitmap upload; worst of display size and full size") {
                let (factory, _) = try need()
                let url = try existing(file)
                var worst = 0.0
                for options in [DecodeOptions.fitting(screenSide), .fullResolution] {
                    var ratios: [Double] = []
                    for _ in 0..<max(iterations, 3) {
                        let image = try ImageDecoder.decode(url, options: options)
                        let first = try await factory.makeTexture(from: image.cgImage).uploadDuration.milliseconds
                        // The reference copy forces any pending decode, after the timed upload.
                        guard let plain = plainBitmap(of: image.cgImage) else { throw TextureError.conversionFailed }
                        let reference = try await factory.makeTexture(from: plain).uploadDuration.milliseconds
                        ratios.append(first / max(reference, 0.1))
                    }
                    worst = max(worst, median(ratios) ?? 0)
                }
                return worst
            })
        }
        return results
    }

    /// A copy of `image` drawn fresh into an 8-bit bitmap with the SAME pixel layout: a bitmap that
    /// is certainly fully decoded, and that costs the same to upload as the original if the original
    /// has no decode pending. (Comparing against a different layout, BGRA against RGBA, made the
    /// ratio sit near its limit for HEIC.)
    private static func plainBitmap(of image: CGImage) -> CGImage? {
        let space = image.colorSpace?.model == .rgb ? image.colorSpace! : CGColorSpace(name: CGColorSpace.displayP3)!
        let bitmapInfo = image.isMetalUploadable
            ? image.bitmapInfo.rawValue
            : CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        guard let context = CGContext(
            data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
            bitmapInfo: bitmapInfo
        ) else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return context.makeImage()
    }

    private static func viewTransform(imageSize: PixelSize, screenSide: Int) -> ViewTransform {
        // A typical laptop panel: 3456×2234 pixels at 2×.
        let width = CGFloat(screenSide) / 2
        let height = (width * 2234 / 3456).rounded()
        return ViewTransform(imageSize: CGSize(width: imageSize.width, height: imageSize.height),
                             viewSize: CGSize(width: width, height: height), backingScale: 2)
    }

    // MARK: Thumbnail grid

    /// The first screen of a thumbnail grid. Two cases, because they differ tenfold: camera files
    /// carry a small preview inside, which needs no decoding; files without one must be decoded.
    private static func thumbnailTargets(root: URL, manifestFiles: Set<String>, iterations: Int) async -> [TargetResult] {
        let large = root.appendingPathComponent("large")
        func need(_ name: String) throws -> URL {
            guard manifestFiles.contains("large/\(name)") else { throw BenchError.missing("large/\(name)") }
            return large.appendingPathComponent(name)
        }
        return [
            await attempt("Thumbnail grid, first screen (embedded previews)", budget: 500,
                          basis: "decode only, \(gridThumbnails) reads of one warm file; its embedded preview is 160 px, so this shows previews cost almost nothing, not a whole grid") {
                try thumbnailGrid(file: try need("jpeg-24mp-thumb.jpg"), parallelism: 4, iterations: iterations)
            },
            await attempt("Thumbnail grid, first screen (no preview, worst case)", budget: 500,
                          basis: "decode only, \(gridThumbnails) decodes of one warm 24 MP JPEG, 8 at a time (thumbnail concurrency is a phase 2 decision)") {
                try thumbnailGrid(file: try need("jpeg-24mp.jpg"), parallelism: 8, iterations: iterations)
            },
        ]
    }

    /// Median milliseconds to make `gridThumbnails` thumbnails of `file`, `parallelism` at a time.
    /// Any thumbnail that fails to decode fails the measurement: a failure is faster than a
    /// decode, so ignoring it would flatter the result.
    private static func thumbnailGrid(file: URL, parallelism: Int, iterations: Int) throws -> Double {
        guard FileManager.default.fileExists(atPath: file.path) else {
            throw BenchError.missing("large/\(file.lastPathComponent)")
        }
        let side = thumbnailSide
        let count = gridThumbnails
        let clock = ContinuousClock()
        var times: [Double] = []
        for _ in 0..<max(1, iterations) {
            let failures = Mutex(0)
            let start = clock.now
            let queue = DispatchQueue(label: "bench.grid", attributes: .concurrent)
            let slots = DispatchSemaphore(value: parallelism)
            let group = DispatchGroup()
            for _ in 0..<count {
                slots.wait()
                group.enter()
                queue.async {
                    do { _ = try ImageDecoder.thumbnail(file, maxPixelSize: side) } catch { failures.withLock { $0 += 1 } }
                    slots.signal()
                    group.leave()
                }
            }
            group.wait()
            times.append((clock.now - start).milliseconds)
            let failed = failures.withLock { $0 }
            if failed > 0 { throw BenchError.failedDecodes(failed) }
        }
        return median(times) ?? 0
    }

    // MARK: Helpers

    private static func tryDecode(_ url: URL) -> String {
        do {
            let image = try ImageDecoder.decode(url)
            return "decoded \(image.pixelSize) (partial data accepted)"
        } catch {
            return "rejected: \(error)"
        }
    }

    private static func median(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        return values.sorted()[(values.count - 1) / 2]
    }

    /// Runs `body` `iterations` times and returns the median time and the last result.
    /// Each run drains its own autorelease pool, so large bitmaps do not pile up.
    private static func timed<T>(_ iterations: Int, _ body: () throws -> T) throws -> (median: Double, value: T) {
        var times: [Double] = []
        var last: T?
        let clock = ContinuousClock()
        for _ in 0..<max(1, iterations) {
            try autoreleasepool {
                let start = clock.now
                let value = try body()
                times.append((clock.now - start).milliseconds)
                last = value
            }
        }
        return (median(times)!, last!)
    }

    private static func timedAsync<T>(_ iterations: Int, _ body: () async throws -> T) async throws -> (median: Double, value: T) {
        var times: [Double] = []
        var last: T?
        let clock = ContinuousClock()
        for _ in 0..<max(1, iterations) {
            let start = clock.now
            let value = try await body()
            times.append((clock.now - start).milliseconds)
            last = value
        }
        return (median(times)!, last!)
    }

    private static func machineDescription() -> String {
        func sysctlString(_ name: String) -> String? {
            var size = 0
            guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
            var buffer = [CChar](repeating: 0, count: size)
            guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
            return String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        }
        let chip = sysctlString("machdep.cpu.brand_string") ?? "unknown chip"
        let memory = ProcessInfo.processInfo.physicalMemory >> 30
        return "\(chip), \(memory) GB, \(ProcessInfo.processInfo.activeProcessorCount) cores"
    }
}

// MARK: Printing

extension BenchReport {
    func printSummary() {
        func ms(_ value: Double?, decimals: Int = 1) -> String { value.map { String(format: "%.\(decimals)f", $0) } ?? "–" }
        func pad(_ text: String, _ width: Int) -> String {
            text.count >= width ? text : text + String(repeating: " ", count: width - text.count)
        }

        print("\n\(machine) · \(macOS) · median of \(iterations) · first view sized for \(screenSide) px\n")
        print(pad("File", 40) + pad("MP", 7) + pad("Full", 9) + pad("View dec", 10) + pad("Upload", 9) + pad("Thumb", 9) + "Size")
        for file in files {
            print(pad(file.file, 40) + pad(String(format: "%.1f", file.megapixels), 7)
                  + pad(ms(file.fullDecode), 9) + pad(ms(file.firstViewDecode), 10) + pad(ms(file.firstViewUpload), 9)
                  + pad(ms(file.thumbnail), 9)
                  + (file.sizeMatches ? (file.firstViewSizeOk ? "ok" : "FIRST VIEW TOO SMALL") : "MISMATCH \(file.decodedSize)"))
        }

        print("\nMalformed files (none may crash):")
        for result in malformed {
            print("  " + pad(result.file, 44) + result.outcome)
        }

        print("\nTargets:")
        for target in targets {
            let verdict: String
            if target.measured == nil {
                verdict = "NOT MEASURED"
            } else if target.passed == true {
                verdict = "pass"
            } else if target.knownMiss != nil {
                verdict = target.failsEnforcement ? "MISS TOO BIG" : "known miss"
            } else {
                verdict = "FAIL"
            }
            let limit = target.budget < 10 ? String(format: "%.1f", target.budget) : String(Int(target.budget))
            print("  " + pad(target.name, 58) + pad("≤ \(limit) \(target.unit)", 11)
                  + pad(ms(target.measured, decimals: target.unit == "×" ? 2 : 1), 8) + pad(verdict, 14) + target.basis)
            if let reason = target.knownMiss, target.passed == false {
                print("      known miss: \(reason)" + (target.knownMissCeiling.map { " (tolerated up to \(Int($0)) \(target.unit))" } ?? ""))
            }
        }
        print("\nNot measured here (needs the running app): launch to first frame and memory at rest, see scripts/measure-launch.sh")
    }

    /// Whether `--enforce` should succeed: every target measured and met (known misses within
    /// their ceiling excepted), and every file decoded at the size the corpus wrote and at about
    /// the size asked for on first view.
    var passesEnforcement: Bool {
        !targets.contains(where: \.failsEnforcement) && files.allSatisfy { $0.sizeMatches && $0.firstViewSizeOk }
    }
}
