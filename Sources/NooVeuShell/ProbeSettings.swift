import Foundation

/// How the launch probe is switched on and tuned from the environment (`NOOVEU_LAUNCH_PROBE`,
/// `NOOVEU_PROBE_SETTLE_SECONDS`).
public enum ProbeSettings {
    /// On for any value except unset, empty or `0`.
    public static func isEnabled(_ value: String?) -> Bool {
        guard let value, !value.isEmpty, value != "0" else { return false }
        return true
    }

    /// Seconds to wait before reading memory. A missing, non-numeric, negative or non-finite value
    /// gives the default.
    public static func settleSeconds(_ value: String?, default fallback: Double = 3) -> Double {
        guard let value, let seconds = Double(value), seconds.isFinite, seconds >= 0 else { return fallback }
        return seconds
    }
}
