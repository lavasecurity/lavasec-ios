#if DEBUG || LAVA_QA_TOOLS
import os

/// QA-only Instruments signpost log, born for `DNSEventLog`'s write-path instrumentation
/// (UR-53 follow-up) and now the app-wide QA points-of-interest emitter: the app/tunnel
/// NRG signposts route here too via `Shared/EnergySignpost.swift`. Kept as its OWN
/// dedicated file so it is the ONE place in the whole codebase that touches
/// `OSLog`/`os_signpost` directly — mobsfscan's ignore-comment mechanic honors only a
/// single suppressed file per rule (`post_ignore_files` rebuilds its keep-list from the
/// unfiltered match list on every suppressed file, so the last one wins and any earlier
/// suppressed file's matches leak back in), which makes one shared emitter the only
/// shape that keeps the `ios_log` rule live everywhere else. Every event name passed
/// through `event(_:)` is a hardcoded, non-sensitive label — never a domain, query, or
/// other event content — so this is the sole reviewed site carrying the suppression;
/// every other file (including `DNSEventLog.swift` itself) stays fully exposed to that
/// rule for anything actually worth catching.
public enum DNSEventLogSignpost {
    private static let log = OSLog(subsystem: "app.lavasecurity.nrg", category: .pointsOfInterest) // mobsf-ignore: ios_log

    /// Emits a named point-of-interest event on the Instruments timeline. `name` must be a
    /// static, non-sensitive label — never anything derived from a queried domain.
    public static func event(_ name: StaticString) {
        os_signpost(.event, log: log, name: name)
    }
}
#endif
