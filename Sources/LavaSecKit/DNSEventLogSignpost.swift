import os

/// Instruments signpost log (QA-gated behavior, always-present symbol), born for
/// `DNSEventLog`'s write-path instrumentation
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
    #if DEBUG || LAVA_QA_TOOLS
    private static let log = OSLog(subsystem: "app.lavasecurity.nrg", category: .pointsOfInterest) // mobsf-ignore: ios_log
    #endif

    /// Emits a named point-of-interest event on the Instruments timeline. `name` must be a
    /// static, non-sensitive label — never anything derived from a queried domain.
    ///
    /// The SYMBOL is always compiled; only the body is QA-gated. App/extension targets and
    /// this SwiftPM target receive compilation conditions through different mechanisms
    /// (xcconfig vs command-line `OTHER_SWIFT_FLAGS` injection), so a flag-gated symbol
    /// would turn every skewed QA build — app defines `LAVA_QA_TOOLS`, package doesn't —
    /// into a link error at the `Shared/EnergySignpost.swift` delegation site. A skewed
    /// build now compiles and the signpost quietly no-ops until the package receives the
    /// matching flag.
    public static func event(_ name: StaticString) {
        #if DEBUG || LAVA_QA_TOOLS
        os_signpost(.event, log: log, name: name)
        #endif
    }
}
