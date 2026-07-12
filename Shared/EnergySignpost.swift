#if DEBUG || LAVA_QA_TOOLS
import LavaSecKit

// QA-only Points-of-Interest signposts (NRG Phase 2) so an Instruments Energy Log run
// can correlate battery cost to each lever firing. Emitted ONLY at low-frequency
// sites — never per debug-log append (that would be the observer effect); the
// debug-log lever is represented by the once-per-window `nrg-window` mark emitted by
// the NRG counter flush in `AppGroup.swift`. The counters give per-lever RATES; these
// signposts give the per-event timeline brackets Instruments attributes energy to.
//
// Deliberately holds NO `OSLog`/`os_signpost` of its own: it delegates to
// `DNSEventLogSignpost` (`Sources/LavaSecKit/DNSEventLogSignpost.swift`), the single
// reviewed emitter carrying the codebase's one mobsfscan `ios_log` suppression —
// mobsfscan honors only a single suppressed file per rule, and the shared emitter is
// what keeps that rule live for every other file in the app and tunnel processes.
enum EnergySignpost {
    static func event(_ name: StaticString) {
        DNSEventLogSignpost.event(name)
    }
}
#endif
