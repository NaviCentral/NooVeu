import Foundation

/// nooveu-bench: builds the test corpus and checks the performance targets.
///
///     nooveu-bench corpus <dir> [--quick]
///     nooveu-bench run <dir> [--iterations N] [--json FILE] [--enforce]
///
/// Build in release mode (`swift run -c release nooveu-bench …`); debug timings mean nothing.

func usage() -> Never {
    let text = """
    usage:
      nooveu-bench corpus <dir> [--quick]    generate the test corpus (--quick skips the slowest files)
      nooveu-bench run <dir> [options]       time every corpus file against the targets
        --iterations N   runs per measurement, median reported (default 5)
        --json FILE      also write the full report as JSON
        --enforce        exit 1 if a measured target fails or a decoded size is wrong
    """
    FileHandle.standardError.write(Data((text + "\n").utf8))
    exit(64)
}

func value(after flag: String, in arguments: [String]) -> String? {
    guard let index = arguments.firstIndex(of: flag), arguments.indices.contains(index + 1) else { return nil }
    return arguments[index + 1]
}

func log(_ message: String) {
    print(message)
    fflush(stdout)
}

let arguments = Array(CommandLine.arguments.dropFirst())
guard arguments.count >= 2 else { usage() }
let folder = URL(fileURLWithPath: arguments[1], isDirectory: true)

do {
    switch arguments[0] {
    case "corpus":
        let quick = arguments.contains("--quick")
        log("Writing corpus to \(folder.path)\(quick ? " (quick)" : "")")
        let manifest = try CorpusGenerator.generate(into: folder, quick: quick, log: log)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(manifest).write(to: folder.appendingPathComponent("manifest.json"))
        log("\(manifest.entries.count) files written")
        if !manifest.skipped.isEmpty {
            log("Skipped:")
            manifest.skipped.forEach { log("  \($0)") }
        }

    case "run":
        let iterations = value(after: "--iterations", in: arguments).flatMap(Int.init) ?? 5
        log("Benchmarking \(folder.path)")
        let report = try Benchmark.run(corpus: folder, iterations: iterations, log: log)
        report.printSummary()
        if let path = value(after: "--json", in: arguments) {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(report).write(to: URL(fileURLWithPath: path))
        }
        if arguments.contains("--enforce") && !report.allMeasuredTargetsPass {
            log("\nA target failed or a decoded size was wrong.")
            exit(1)
        }

    default:
        usage()
    }
} catch {
    FileHandle.standardError.write(Data("error: \(error)\n".utf8))
    exit(1)
}
