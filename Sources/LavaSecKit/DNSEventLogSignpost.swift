#if DEBUG || LAVA_QA_TOOLS
import os

/// QA-only Instruments signpost log for `DNSEventLog`'s write-path instrumentation (UR-53
/// follow-up). Kept as its OWN dedicated file so it is the ONE place in the package layer
/// that touches `OSLog`/`os_signpost` directly. Every event name passed through `event(_:)`
/// is a hardcoded, non-sensitive label — never a domain, query, or other event content — so
/// this is the sole reviewed site that needs a mobsfscan `ios_log` suppression; every other
/// file in the package (including `DNSEventLog.swift` itself) stays fully exposed to that
/// rule for anything actually worth catching.
enum DNSEventLogSignpost {
    private static let log = OSLog(subsystem: "app.lavasecurity.nrg", category: .pointsOfInterest) // mobsf-ignore: ios_log

    /// Emits a named point-of-interest event on the Instruments timeline. `name` must be a
    /// static, non-sensitive label — never anything derived from a queried domain.
    static func event(_ name: StaticString) {
        os_signpost(.event, log: log, name: name)
    }
}
#endif
