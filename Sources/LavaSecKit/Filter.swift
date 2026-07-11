import Foundation

/// A single named filter: the security configuration a user can switch between.
///
/// A "filter" is exactly the clean, filter-scoped subset of `AppConfiguration`
/// (`enabledBlocklistIDs`, `customBlocklists`, `blockedDomains`, `allowedDomains`).
/// Everything else on `AppConfiguration` — protection on/off, DNS resolver,
/// retention prefs, `isPaid`, Guard unlocks — is device-global and is NOT part of
/// a filter; it stays on `AppConfiguration`.
///
/// The app hosts MANY filters (a `FilterLibrary`) but loads exactly one at a time.
/// "Loading" reuses the existing config → snapshot → compact → artifact-store →
/// pointer-flip pipeline; `lastCompiledToken` lets the versioned-artifact GC retain
/// a recently-loaded filter's compiled directory so switching back is an instant
/// pointer flip rather than a cold compile.
public struct Filter: Identifiable, Codable, Equatable, Sendable {
    /// The stable id of the filter the legacy single-filter configuration migrates
    /// into. Kept human-stable (not a UUID) so the migration is deterministic and
    /// idempotent.
    public static let defaultFilterID = "default"
    /// The display name given to the migrated legacy filter (and the name a decoded
    /// filter with a missing/blank name falls back to).
    public static let defaultFilterName = "Default"

    public let id: String
    public var name: String

    // The four filter-scoped fields. These mirror `AppConfiguration`'s filter subset.
    public var enabledBlocklistIDs: Set<String>
    public var customBlocklists: [CustomBlocklistSource]
    public var blockedDomains: Set<String>
    public var allowedDomains: Set<String>

    public private(set) var createdAt: Date
    /// The versioned-artifact token this filter last compiled to, if any. Used both
    /// for GC retention (keep this filter's compiled dir warm) and the instant-switch
    /// cache (a still-present token dir ⇒ a switch is a pointer flip, not a compile).
    /// Cleared when the filter's contents change so the next use recompiles.
    public var lastCompiledToken: String?
    /// Per-filter freshness timestamp (Phase 3). `nil` ⇒ fall back to the global
    /// catalog freshness signal.
    public private(set) var lastSyncedAt: Date?

    public init(
        id: String = defaultFilterID,
        name: String = defaultFilterName,
        enabledBlocklistIDs: Set<String> = [],
        customBlocklists: [CustomBlocklistSource] = [],
        blockedDomains: Set<String> = [],
        allowedDomains: Set<String> = [],
        createdAt: Date = Date(),
        lastCompiledToken: String? = nil,
        lastSyncedAt: Date? = nil
    ) {
        self.id = id
        self.name = Filter.sanitizedName(name)
        self.enabledBlocklistIDs = enabledBlocklistIDs
        self.customBlocklists = customBlocklists
        self.blockedDomains = blockedDomains
        self.allowedDomains = allowedDomains
        self.createdAt = createdAt
        self.lastCompiledToken = lastCompiledToken
        self.lastSyncedAt = lastSyncedAt
    }

    /// Wrap a legacy single-filter `AppConfiguration` into a `Filter`. The migration
    /// is a pure array-wrap of the four filter-scoped fields — no parsing, no compile —
    /// so it is cheap enough to run synchronously at launch.
    public init(
        legacyConfiguration configuration: AppConfiguration,
        id: String = defaultFilterID,
        name: String = defaultFilterName,
        createdAt: Date = Date()
    ) {
        self.init(
            id: id,
            name: name,
            enabledBlocklistIDs: configuration.enabledBlocklistIDs,
            customBlocklists: configuration.customBlocklists,
            blockedDomains: configuration.blockedDomains,
            allowedDomains: configuration.allowedDomains,
            createdAt: createdAt
        )
    }

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case enabledBlocklistIDs
        case customBlocklists
        case blockedDomains
        case allowedDomains
        case createdAt
        case lastCompiledToken
        case lastSyncedAt
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(String.self, forKey: .id) ?? Filter.defaultFilterID
        name = Filter.sanitizedName(try container.decodeIfPresent(String.self, forKey: .name) ?? "")
        enabledBlocklistIDs = try container.decodeIfPresent(Set<String>.self, forKey: .enabledBlocklistIDs) ?? []
        customBlocklists = try container.decodeIfPresent([CustomBlocklistSource].self, forKey: .customBlocklists) ?? []
        blockedDomains = try container.decodeIfPresent(Set<String>.self, forKey: .blockedDomains) ?? []
        allowedDomains = try container.decodeIfPresent(Set<String>.self, forKey: .allowedDomains) ?? []
        createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        lastCompiledToken = try container.decodeIfPresent(String.self, forKey: .lastCompiledToken)
        lastSyncedAt = try container.decodeIfPresent(Date.self, forKey: .lastSyncedAt)
    }

    /// The filter-scoped selection (no custom lists) used for diffing.
    public var selection: FilterConfigurationSelection {
        FilterConfigurationSelection(
            enabledBlocklistIDs: enabledBlocklistIDs,
            blockedDomains: blockedDomains,
            allowedDomains: allowedDomains
        )
    }

    /// `true` when this filter would compile to zero rules — no ENABLED blocklists
    /// (curated or custom) and no manually-blocked domains. Snapshot preparation only
    /// merges sources whose id is in `enabledBlocklistIDs` (an enabled custom list has
    /// its id there); a saved-but-disabled custom source contributes nothing, so it must
    /// NOT count as protection. A loaded-but-empty filter is zero protection, not benign
    /// silence — the UI must treat it as an unprotected/alarm state.
    public var isEmpty: Bool {
        enabledBlocklistIDs.isEmpty && blockedDomains.isEmpty
    }

    /// Apply the four filter-scoped fields from an `AppConfiguration` onto this filter
    /// (the active-filter write-through used at the persistence boundary). Returns
    /// whether anything changed so callers can avoid clearing `lastCompiledToken` on a
    /// no-op write.
    @discardableResult
    public mutating func applyFilterFields(from configuration: AppConfiguration) -> Bool {
        let changed = enabledBlocklistIDs != configuration.enabledBlocklistIDs
            || customBlocklists != configuration.customBlocklists
            || blockedDomains != configuration.blockedDomains
            || allowedDomains != configuration.allowedDomains
        guard changed else { return false }
        enabledBlocklistIDs = configuration.enabledBlocklistIDs
        customBlocklists = configuration.customBlocklists
        blockedDomains = configuration.blockedDomains
        allowedDomains = configuration.allowedDomains
        return true
    }

    static func sanitizedName(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? defaultFilterName : trimmed
    }

    /// A copy with the device-LOCAL cache fields cleared (`lastCompiledToken`,
    /// `lastSyncedAt`). Those describe this device's compiled-artifact directories and
    /// freshness signal — they are meaningless on any other device and must never be part
    /// of a portable encrypted backup. Stripping them also keeps the backup's no-op
    /// re-seal guard honest: a maintenance persist that only restamps a compile token
    /// would otherwise look like a content change and churn the upload marker.
    public func strippingLocalCacheState() -> Filter {
        var copy = self
        copy.lastCompiledToken = nil
        copy.lastSyncedAt = nil
        return copy
    }
}

/// The user's library of filters: the app hosts many, loads exactly one. The library
/// is the source of truth for the set of filters and which one is active; the active
/// filter's four fields are mirrored write-through into the live `AppConfiguration`
/// so the ~25 existing readers of `configuration.enabledBlocklistIDs` et al. are
/// untouched.
///
/// Invariants (enforced by `normalized()`): at least one filter, and `activeFilterID`
/// references an existing filter.
public struct FilterLibrary: Codable, Equatable, Sendable {
    /// v2: the library holds the three seeded default filters (Core / Balanced / Extra) on the
    /// free tier. A persisted library stamped < 2 predates that model and is reseeded to the
    /// three defaults on load (the on-upgrade migration; the app is not yet public, so existing
    /// single/custom libraries are intentionally replaced — see `loadOrMigrateFilterLibrary`).
    public static let currentSchemaVersion = 2

    public var schemaVersion: Int
    public private(set) var filters: [Filter]
    public private(set) var activeFilterID: String
    /// The `AppConfiguration.configurationGeneration` this library was last written alongside.
    /// The library and config are two separate files written non-atomically; stamping the library
    /// with the generation of the config it was paired with lets the load path detect a library
    /// that lost a write race (its stamp is OLDER than the config now on disk — e.g. a restore wrote
    /// a newer config but this library write never landed) and reject it in the config's favour,
    /// regardless of which file was written first. Device-LOCAL persistence metadata: it is stripped
    /// for backups (see ``strippingLocalCacheState()``) and re-stamped on the next local write.
    public var configurationGeneration: Int

    public init(
        filters: [Filter],
        activeFilterID: String,
        schemaVersion: Int = FilterLibrary.currentSchemaVersion,
        configurationGeneration: Int = 0
    ) {
        self.schemaVersion = schemaVersion
        self.filters = filters
        self.activeFilterID = activeFilterID
        self.configurationGeneration = configurationGeneration
    }

    /// Build a single-filter library by wrapping a legacy `AppConfiguration` into the
    /// migrated "Default" filter. This is the on-upgrade migration entry point.
    public init(migratingLegacy configuration: AppConfiguration) {
        let filter = Filter(legacyConfiguration: configuration)
        self.init(filters: [filter], activeFilterID: filter.id)
    }

    enum CodingKeys: String, CodingKey {
        case schemaVersion
        case filters
        case activeFilterID
        case configurationGeneration
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion)
            ?? FilterLibrary.currentSchemaVersion
        filters = try container.decodeIfPresent([Filter].self, forKey: .filters) ?? []
        activeFilterID = try container.decodeIfPresent(String.self, forKey: .activeFilterID)
            ?? filters.first?.id
            ?? Filter.defaultFilterID
        configurationGeneration = try container.decodeIfPresent(Int.self, forKey: .configurationGeneration) ?? 0
    }

    /// Whether this on-disk library lost a two-file write race against the config and must be
    /// rejected in the config's favour on load: it is stamped with an OLDER config generation than
    /// the config now on disk (e.g. a restore wrote a newer config but this library write never
    /// landed, so the old library is stale). A library stamped equal-or-newer is authoritative.
    /// Generation 0 — a library written before stamping existed — is trusted (no positive evidence
    /// it is stale; rejecting it would needlessly collapse an existing multi-filter library).
    public func lostWriteRace(againstConfigurationGeneration configGeneration: Int) -> Bool {
        configurationGeneration > 0 && configurationGeneration < configGeneration
    }

    // MARK: - Reads

    public func filter(id: String) -> Filter? {
        filters.first { $0.id == id }
    }

    public func index(of id: String) -> Int? {
        filters.firstIndex { $0.id == id }
    }

    public func contains(id: String) -> Bool {
        filters.contains { $0.id == id }
    }

    /// The currently-loaded filter. Falls back to the first filter if `activeFilterID`
    /// ever dangles (a decode of a corrupt file), so callers always get a value.
    public var activeFilter: Filter {
        filter(id: activeFilterID) ?? filters.first ?? Filter()
    }

    public var isValid: Bool {
        !filters.isEmpty && contains(id: activeFilterID)
    }

    // MARK: - Mutations (preserve invariants)

    /// Re-point the active filter. No-ops if the id is unknown (keeps the invariant).
    public mutating func setActiveFilter(id: String) {
        guard contains(id: id) else { return }
        activeFilterID = id
    }

    /// Replace a filter wholesale (matched by id). No-ops if the id is unknown.
    public mutating func update(_ filter: Filter) {
        guard let idx = index(of: filter.id) else { return }
        filters[idx] = filter
    }

    /// Mutate a filter in place by id.
    public mutating func mutateFilter(id: String, _ body: (inout Filter) -> Void) {
        guard let idx = index(of: id) else { return }
        body(&filters[idx])
    }

    public mutating func append(_ filter: Filter) {
        guard !contains(id: filter.id) else { return }
        filters.append(filter)
    }

    /// Remove a filter by id. Refuses to remove the active filter or the last
    /// remaining filter (the ≥1 invariant). Returns whether a removal happened.
    @discardableResult
    public mutating func remove(id: String) -> Bool {
        guard filters.count > 1, id != activeFilterID, let idx = index(of: id) else {
            return false
        }
        filters.remove(at: idx)
        return true
    }

    /// Repair the invariants: drop the active id onto the first filter if it dangles.
    /// (An empty `filters` is unrepairable here — the caller treats that as "migrate".)
    public func normalized() -> FilterLibrary {
        guard !filters.isEmpty else { return self }
        guard !contains(id: activeFilterID), let first = filters.first else { return self }
        var copy = self
        copy.activeFilterID = first.id
        return copy
    }

    /// A copy with every hosted filter's device-LOCAL cache fields cleared (see
    /// ``Filter/strippingLocalCacheState()``) AND the device-local `configurationGeneration`
    /// reset to 0 (it is not passed to the init). Applied when building an encrypted-backup payload
    /// so the carried library is portable — its compile tokens and write-race generation are
    /// meaningless on a restore target — and the no-op re-seal guard ignores their churn.
    public func strippingLocalCacheState() -> FilterLibrary {
        FilterLibrary(
            filters: filters.map { $0.strippingLocalCacheState() },
            activeFilterID: activeFilterID,
            schemaVersion: schemaVersion
        )
    }
}
