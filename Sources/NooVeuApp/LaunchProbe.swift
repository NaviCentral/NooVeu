import AppKit
import Darwin

/// Measures launch to first image on screen (the 300 ms target) and memory at rest (the 80 MB
/// target).
///
/// Set `NOOVEU_LAUNCH_PROBE=1` and pass an image path. When the first image frame reaches the
/// screen, NooVeu prints `launch_to_first_frame_ms=<n>`, waits for the app to settle, prints
/// `footprint_mb=<n>`, and quits. The wait defaults to 3 seconds; `NOOVEU_PROBE_SETTLE_SECONDS`
/// changes it. A shorter wait reads high: right after the first frame, graphics memory the
/// system will reclaim is still counted. `scripts/measure-launch.sh` runs this several times
/// and reports medians.
@MainActor
enum LaunchProbe {
    /// On when `NOOVEU_LAUNCH_PROBE` is set to anything but empty or `0`.
    static let isEnabled: Bool = {
        let value = ProcessInfo.processInfo.environment["NOOVEU_LAUNCH_PROBE"] ?? ""
        return !value.isEmpty && value != "0"
    }()

    private static var settleSeconds: Double {
        ProcessInfo.processInfo.environment["NOOVEU_PROBE_SETTLE_SECONDS"].flatMap(Double.init) ?? 3
    }

    private static var timeout: DispatchWorkItem?

    static func reportAndExit() {
        // The image arrived: the timeout must not cut the settle wait short.
        timeout?.cancel()
        let elapsed = processStart.map { Date().timeIntervalSince($0) * 1_000 } ?? -1
        print(String(format: "launch_to_first_frame_ms=%.1f", elapsed))
        fflush(stdout)
        DispatchQueue.main.asyncAfter(deadline: .now() + settleSeconds) {
            print(String(format: "footprint_mb=%.1f", footprintMegabytes()))
            fflush(stdout)
            exit(0)
        }
    }

    /// Quits with an error if no image appears within 10 seconds, so scripts never hang.
    static func armTimeout() {
        let item = DispatchWorkItem {
            print("launch_to_first_frame_ms=timeout")
            fflush(stdout)
            exit(1)
        }
        timeout = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 10, execute: item)
    }

    /// Memory the system charges to this process (the figure Activity Monitor calls "Memory"),
    /// which includes GPU textures that live in unified memory.
    private static func footprintMegabytes() -> Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? Double(info.phys_footprint) / 1_048_576 : -1
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
