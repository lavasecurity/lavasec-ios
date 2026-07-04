import AppIntents
import Foundation
import LavaSecCore

// MARK: - Focus filter App Intent (LAV-100 Phase 4)
//
// `SetFocusFilterIntent` is the system mechanism that lets a Focus switch the active Lava filter
// hands-free. The user adds "Lava Filter" under a Focus in Settings › Focus › Focus Filters and picks
// which saved filter to apply; when that Focus turns on, the system runs `perform()`. This intent lives
// in the App Intents EXTENSION (LavaSecIntents), so `perform()` runs even when Lava is fully closed —
// the system background-launches the extension (an app-target intent only runs in the foreground app,
// WWDC22 §10121). perform() drives the shared headless switch engine via
// `FocusSwitchEnvironment.performSwitch` → `HeadlessFocusFilterSwitchEngine` (LavaSecCore).
//
// perform() runs for BOTH activation and deactivation — the system re-runs it whenever the configured
// parameters change, and there is no explicit on/off signal. We infer the edge from whether the
// (deliberately OPTIONAL) `filter` parameter is set: on activation it carries the chosen filter →
// switch to it; on deactivation it is nil → we intentionally do nothing. A filter is a sticky choice
// (another Focus, or a manual tap, is what changes it next), so there is no "revert on Focus-off".
// Making the parameter optional is REQUIRED: a non-optional parameter is only delivered on activation,
// so the deactivation edge would silently reuse the last value.
//
// The security gate (OFF whenever "require auth to edit filters" is on — Focus auto-switch is available
// to all tiers, no Plus paywall) and every switch semantic live in the engine, reached through
// `FocusSwitchEnvironment.performSwitch`. perform() runs unattended in the background and cannot prompt
// for authentication, so a gated-out switch is a silent no-op — never a partial or unauthenticated change.

struct LavaFocusFilterIntent: SetFocusFilterIntent {
    nonisolated(unsafe) static var title: LocalizedStringResource = "Lava Filter"
    nonisolated(unsafe) static var description = IntentDescription(
        "Switch your active Lava filter automatically when a Focus turns on."
    )
    // Configured in Settings › Focus, not the Shortcuts app. Focus eligibility comes from
    // `SetFocusFilterIntent` conformance, not from discoverability; keeping it out of Shortcuts avoids a
    // stray "run once" action that has no Focus context.
    nonisolated(unsafe) static var isDiscoverable = false

    // OPTIONAL on purpose — see the file header. A nil value is the Focus turning OFF (or no filter
    // chosen yet); we leave the active filter untouched in that case.
    @Parameter(title: "Filter")
    var filter: LavaFilterEntity?

    init() {}

    var displayRepresentation: DisplayRepresentation {
        filter?.displayRepresentation ?? DisplayRepresentation(title: "No filter")
    }

    static var parameterSummary: some ParameterSummary {
        Summary("Switch to \(\.$filter)")
    }

    func perform() async throws -> some IntentResult {
        // Focus turning OFF (or nothing configured): a pure no-op. A filter is a sticky choice (another Focus
        // or a manual tap is what changes it next), so there is no "revert on Focus-off". We also must NOT
        // cancel a still-deferred marker here: perform(nil) carries NO Focus identity, so the off-edge cannot
        // tell WHICH Focus turned off and would risk clearing a DIFFERENT, still-active Focus's just-recorded
        // switch (a lost update). The foreground reconcile's supersession + already-active/target-gone guards
        // drop genuinely-stale markers, and a deferred switch re-applying is the tolerated, self-healing
        // direction (LAV-100 Phase 4 round-5 panel P1).
        guard let filter else {
            return .result()
        }
        await FocusSwitchEnvironment.performSwitch(toFilterID: filter.id)
        return .result()
    }
}

// MARK: - Filter AppEntity + enumerable query (populates the Settings › Focus picker)

struct LavaFilterEntity: AppEntity {
    let id: String
    let name: String

    // Both `static let` (not `var`): the AppIntents metadata processor emits the AppEntity record —
    // and from it the parameter→query type link — only from CONST bindings. A mutable `static var`
    // here produces "no record of the query can be found" at export. Both initializer values are
    // Sendable, so the `let`s are concurrency-safe under Swift 6.
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Filter")
    static let defaultQuery = LavaFilterEntityQuery()

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)")
    }
}

struct LavaFilterEntityQuery: EntityQuery {
    // Reads the on-disk filter library directly (no `AppViewModel`): the query runs in whatever process
    // the system picks for the Settings picker / background switch, so it must not depend on the app's
    // foreground object graph. Every hosted filter is listed; the auth-to-edit gate is enforced at switch
    // time inside the engine, the single security boundary — not here, so an auth-locked user's configured
    // choice is preserved (and silently no-ops) rather than vanishing from Settings.
    //
    // Plain `EntityQuery` with an explicit `suggestedEntities()` (not `EnumerableEntityQuery`): the
    // latter's default `entities(for:)`/`results()` don't synthesize a query record the AppIntents
    // metadata processor can find ("no record of the query can be found" at export).

    /// Populates the filter picker shown in Settings › Focus › Focus Filters.
    func suggestedEntities() async throws -> [LavaFilterEntity] {
        LavaFilterEntityQuery.loadHostedFilters().map {
            LavaFilterEntity(id: $0.id, name: $0.name)
        }
    }

    /// Resolves a previously-chosen filter id back to an entity (the Focus stores the id).
    func entities(for identifiers: [String]) async throws -> [LavaFilterEntity] {
        let wanted = Set(identifiers)
        return try await suggestedEntities().filter { wanted.contains($0.id) }
    }

    static func loadHostedFilters() -> [Filter] {
        // Fence-free read BY DESIGN (Kilo review, lavasec-ios#29): this only populates the DISPLAY list for
        // the Settings › Focus › Focus Filters picker. The writer persists filter-library.json with `.atomic`
        // (temp-then-rename), so this read never sees a torn/partial file — at worst it returns the previous
        // COMPLETE library for a few ms if it races a concurrent write, which self-corrects on the next picker
        // open. Taking the cross-process write flock here would add lock machinery to a cosmetic read path for
        // a window a single user can't realistically hit (the picker lives in iOS Settings; filter edits happen
        // in the app — not concurrently). The actual SWITCH is fully fenced: the engine commits under the
        // generation CAS + flock at switch time. This query never drives a commit.
        guard let url = LavaSecAppGroup.containerURL?
            .appendingPathComponent(LavaSecAppGroup.filterLibraryFilename),
            let data = try? Data(contentsOf: url),
            let library = try? JSONDecoder().decode(FilterLibrary.self, from: data)
        else {
            return []
        }
        return library.normalized().filters
    }
}
