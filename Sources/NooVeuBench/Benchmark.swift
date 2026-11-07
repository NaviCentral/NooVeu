import CoreGraphics
import Foundation
import NooVeuCore
import NooVeuRender

struct FileResult: Codable {
    var file: String
    var category: String
    var megapixels: Double
    /// Median milliseconds.
    var fullDecode: Double
    var screenDecode: Double
    var thumbnail: Double
    var uploadFull: Double?
    var uploadScreen: Double?
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
    var budgetMs: Double
    var measuredMs: Double?
    var basis: String
    var passed: Bool? { measuredMs.map { $0 <= budgetMs } }
}

struct BenchReport: Codable {
    var machine: String
    var macOS: String
    var date: String
    var iterations: Int
    var files: [FileResult]
    var malformed: [MalformedResult]
    var targets: [TargetResult]
}

/// Times decode, thumbnail and GPU upload for every corpus file, then checks the results
/// against the proposal's performance targets.
@MainActor
enum Benchmark {
    /// Long side of a "screen-sized" first decode: covers a 4K display or a 16-inch MacBook Pro.
    static let screenSide = 3840
    static let thumbnailSide = 256

    static func run(corpus root: URL, iterations: Int, log: (String) -> Void) throws -> BenchReport {
        let manifest = try JSONDecoder().decode(
            CorpusManifest.self,
            from: Data(contentsOf: root.appendingPathComponent("manifest.json"))
        )
        let factory = TextureFactory()
        if factory == nil { log("Metal is unavailable: GPU upload times are skipped") }

        var files: [FileResult] = []
        var malformed: [MalformedResult] = []

        for entry in manifest.entries {
            let url = root.appendingPathComponent(entry.file)
            if entry.malformed {
                // Printed first so a crash shows which file caused it.
                log("  \(entry.file)")
                malformed.append(MalformedResult(file: entry.file, outcome: tryDecode(url)))
                continue
            }
            log("  \(entry.file)")
            let full = try timed(iterations) { try ImageDecoder.decode(url) }
            let screen = try timed(iterations) { try ImageDecoder.decode(url, options: .fitting(screenSide)) }
            let thumb = try timed(iterations) { try ImageDecoder.thumbnail(url, maxPixelSize: thumbnailSide) }
            var uploadFull: Double?
            var uploadScreen: Double?
            if let factory {
                uploadFull = try timed(iterations) { try factory.makeTexture(from: full.value.cgImage) }.median
                uploadScreen = try timed(iterations) { try factory.makeTexture(from: screen.value.cgImage) }.median
            }

            let expected = PixelSize(width: entry.pixelWidth, height: entry.pixelHeight)
            let decoded = full.value.pixelSize
            files.append(FileResult(
                file: entry.file,
                category: entry.category,
                megapixels: (expected.megapixels * 10).rounded() / 10,
                fullDecode: full.median,
                screenDecode: screen.median,
                thumbnail: thumb.median,
                uploadFull: uploadFull,
                uploadScreen: uploadScreen,
                sizeMatches: decoded == expected
                    || (expected.longestSide > ImageDecoder.maxTextureDimension
                        && decoded.longestSide == ImageDecoder.maxTextureDimension),
                decodedSize: decoded.description
            ))
        }

        return BenchReport(
            machine: machineDescription(),
            macOS: ProcessInfo.processInfo.operatingSystemVersionString,
            date: ISO8601DateFormatter().string(from: Date()),
            iterations: iterations,
            files: files,
            malformed: malformed,
            targets: targets(from: files)
        )
    }

    // MARK: Targets

    private static func targets(from files: [FileResult]) -> [TargetResult] {
        func file(_ category: String) -> FileResult? { files.first { $0.category == category } }
        func firstView(_ category: String) -> Double? {
            guard let result = file(category) else { return nil }
            return result.screenDecode + (result.uploadScreen ?? 0)
        }
        return [
            TargetResult(name: "Next image, preloaded", budgetMs: 30,
                         measuredMs: file("jpeg-24mp")?.uploadFull,
                         basis: "GPU upload of an already decoded 24 MP JPEG"),
            TargetResult(name: "Next image, 24 MP JPEG not preloaded", budgetMs: 120,
                         measuredMs: firstView("jpeg-24mp"),
                         basis: "screen-sized decode plus upload"),
            TargetResult(name: "Next image, 24 MP HEIC not preloaded", budgetMs: 120,
                         measuredMs: firstView("heic-24mp"),
                         basis: "screen-sized decode plus upload"),
            TargetResult(name: "First view, 100 MP JPEG", budgetMs: 400,
                         measuredMs: firstView("jpeg-100mp"),
                         basis: "screen-sized decode plus upload"),
            TargetResult(name: "First view, 100 MP HEIC", budgetMs: 400,
                         measuredMs: firstView("heic-100mp"),
                         basis: "screen-sized decode plus upload"),
            TargetResult(name: "Thumbnail, 24 MP JPEG", budgetMs: 30,
                         measuredMs: file("jpeg-24mp")?.thumbnail,
                         basis: "derived: ~60 thumbnails in 500 ms with 4 decodes in parallel"),
        ]
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
        times.sort()
        return (times[times.count / 2], last!)
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
        func ms(_ value: Double?) -> String { value.map { String(format: "%.1f", $0) } ?? "–" }
        func pad(_ text: String, _ width: Int) -> String {
            text.count >= width ? text : text + String(repeating: " ", count: width - text.count)
        }

        print("\n\(machine) · \(macOS) · median of \(iterations)\n")
        print(pad("File", 40) + pad("MP", 7) + pad("Full", 9) + pad("Screen", 9) + pad("Thumb", 9)
              + pad("Up full", 9) + pad("Up scr", 9) + "Size")
        for file in files {
            print(pad(file.file, 40) + pad(String(format: "%.1f", file.megapixels), 7)
                  + pad(ms(file.fullDecode), 9) + pad(ms(file.screenDecode), 9) + pad(ms(file.thumbnail), 9)
                  + pad(ms(file.uploadFull), 9) + pad(ms(file.uploadScreen), 9)
                  + (file.sizeMatches ? "ok" : "MISMATCH \(file.decodedSize)"))
        }

        print("\nMalformed files (none may crash):")
        for result in malformed {
            print("  " + pad(result.file, 44) + result.outcome)
        }

        print("\nTargets (milliseconds):")
        for target in targets {
            let verdict = target.passed.map { $0 ? "pass" : "FAIL" } ?? "not measured"
            print("  " + pad(target.name, 40) + pad("≤ \(Int(target.budgetMs))", 8)
                  + pad(ms(target.measuredMs), 9) + pad(verdict, 14) + target.basis)
        }
    }

    var allMeasuredTargetsPass: Bool {
        targets.allSatisfy { $0.passed ?? true } && files.allSatisfy(\.sizeMatches)
    }
}
