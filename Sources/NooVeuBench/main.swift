import Foundation

/// nooveu-bench: builds the test corpus and checks the performance targets.
///
///     nooveu-bench corpus <dir> [--quick]
///     nooveu-bench run <dir> [--iterations N] [--screen N] [--json FILE] [--enforce]
///
/// Build in release mode (`swift run -c release nooveu-bench …`); debug timings mean nothing.

func usage() -> Never {
    let text = """
    usage:
      nooveu-bench corpus <dir> [--quick]    generate the test corpus (--quick skips the slowest files)
      nooveu-bench run <dir> [options]       time every corpus file against the targets
        --iterations N   runs per measurement, median reported (default 5)
        --screen N       longest side of the display, in pixels, that first views are sized for
                         (default 3456, a 16-inch MacBook Pro; larger displays decode larger, so
                         try 6016 for a 6K one)
        --json FILE      also write the full report as JSON
        --enforce        exit 1 if a target fails, cannot be measured, or a decoded size is wrong
    """
    FileHandle.standardError.write(Data((text + "\n").utf8))
    exit(64)
}

func value(after flag: String, in arguments: [String]) -> String? {
    guard let index = arguments.firstIndex(of: flag), arguments.indices.contains(index + 1) else { return nil }
    return arguments[index + 1]
}

/// A whole number given after `flag`, or `default` when the flag is absent. A value that is
/// missing, not a number, or below `minimum` is an error: silently falling back would let a typo
/// produce flattering results (`--screen 100` makes every first view trivially fast).
func positiveInt(after flag: String, default fallback: Int, minimum: Int = 1, in arguments: [String]) -> Int {
    guard arguments.contains(flag) else { return fallback }
    guard let text = value(after: flag, in: arguments), let number = Int(text), number >= minimum else {
        FileHandle.standardError.write(Data("error: \(flag) needs a whole number of at least \(minimum)\n".utf8))
        exit(64)
    }
    return number
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
        let iterations = positiveInt(after: "--iterations", default: 5, in: arguments)
        log("Benchmarking \(folder.path)")
        let screenSide = positiveInt(after: "--screen", default: 3456, minimum: 512, in: arguments)
        let report = try await Benchmark.run(corpus: folder, iterations: iterations, screenSide: screenSide, log: log)
        report.printSummary()
        if arguments.contains("--json") {
            guard let path = value(after: "--json", in: arguments), !path.hasPrefix("--") else {
                FileHandle.standardError.write(Data("error: --json needs a file name\n".utf8))
                exit(64)
            }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(report).write(to: URL(fileURLWithPath: path))
        }
        if arguments.contains("--enforce") && !report.passesEnforcement {
            log("\nA target failed or could not be measured, or a decoded size was wrong.")
            exit(1)
        }

    default:
        usage()
    }
} catch {
    FileHandle.standardError.write(Data("error: \(error)\n".utf8))
    exit(1)
}
