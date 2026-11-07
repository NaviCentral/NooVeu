import AppKit
import Darwin

/// Measures launch to first image on screen (the 300 ms target).
///
/// Set `NOOVEU_LAUNCH_PROBE=1` and pass an image path: once the first image frame finishes
/// on the GPU, NooVeu prints `launch_to_first_frame_ms=<n>` to standard output and quits.
/// `scripts/measure-launch.sh` runs this several times and reports the median.
@MainActor
enum LaunchProbe {
    static let isEnabled = ProcessInfo.processInfo.environment["NOOVEU_LAUNCH_PROBE"] != nil

    static func reportAndExit() {
        let elapsed = processStart.map { Date().timeIntervalSince($0) * 1_000 } ?? -1
        print(String(format: "launch_to_first_frame_ms=%.1f", elapsed))
        fflush(stdout)
        exit(0)
    }

    /// Quits with an error if no image appears within 10 seconds, so scripts never hang.
    static func armTimeout() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) {
            print("launch_to_first_frame_ms=timeout")
            fflush(stdout)
            exit(1)
        }
    }

    /// When the kernel started this process.
    private static var processStart: Date? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        guard sysctl(&mib, UInt32(mib.count), &info, &size, nil, 0) == 0 else { return nil }
        let start = info.kp_proc.p_starttime
        return Date(timeIntervalSince1970: Double(start.tv_sec) + Double(start.tv_usec) / 1_000_000)
    }
}
