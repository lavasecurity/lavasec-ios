import AppIntents
import Foundation
import LavaSecKit

// MARK: - Filter AppEntity + enumerable query (populates the Settings › Focus picker + Shortcuts filter param)
//
// Lives in `Shared/` so BOTH the App Intents extension (LavaSecIntents — the Focus `SetFocusFilterIntent`)
// and the app target (LavaSecApp — the discoverable `SwitchFilterIntent`/`LavaShortcuts`) compile the SAME
// entity + query. The query reads the App Group filter library headlessly (no `AppViewModel`), so it is
// shared-safe in either process, exactly like `Shared/FocusSwitchEnvironment.swift`. Extracted verbatim from
// FocusFilterIntent.swift when the App Shortcuts provider moved to the app target (App Shortcuts register
// from the app bundle, not an extension).

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
