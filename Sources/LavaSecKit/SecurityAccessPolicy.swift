import Foundation

public enum SecurityProtectedSurface: String, CaseIterable, Codable, Sendable {
    case appUnlock
    case protectionControl
    case protectionPause
    case filterEditing
    case activityViewing
    case appSettings
}

/// App-confirmed credential availability; extensions cannot read the app-only keychain.
public enum SecurityAuthenticationAvailability: String, Codable, Sendable {
    case available
    case absent
    case unavailable
}

/// Shared gate storage. Only the app writes; production readers use the atomic projection.
public enum SecurityProtectedSurfaceStorage {
    /// The UserDefaults key persisting the set of surfaces gated behind app authentication.
    public static let defaultsKeyName = "securityProtectedSurfaces"
    /// Compatibility alias for existing consumers of the public package product.
    public static let defaultsKey = defaultsKeyName
    private static let availabilityKey = "securityAuthenticationAvailability"
    private static let migrationKey = "securitySurfacesMigratedVersion"
    private static let noticeKey = "securitySurfaceDefaultsNoticePending"
    private static let optInMigrationVersion = 2
    private static let appUnlockCoverChoiceKey = "securityAppUnlockCoverChoice"
    /// Security choices are explicitly opt-in; credential setup never selects a surface.
    public static let defaultSurfaces: Set<SecurityProtectedSurface> = []

    /// Compatibility defaults reader. Production entry points use the projection-URL overload.
    public static func loadProtectedSurfaces(from defaults: UserDefaults) -> Set<SecurityProtectedSurface> {
        storedSurfaces(from: defaults)
    }

    /// Saves an informed choice, including an empty set, without reseeding on subsequent launches.
    public static func saveProtectedSurfaces(
        _ surfaces: Set<SecurityProtectedSurface>,
        to defaults: UserDefaults
    ) {
        defaults.set(surfaces.map(\.rawValue).sorted(), forKey: defaultsKeyName)
        defaults.set(optInMigrationVersion, forKey: migrationKey)
        defaults.removeObject(forKey: noticeKey)
    }

    /// Publishes a classified app-only keychain read without adding protection choices.
    /// Unreadable credentials retain preferences; only confirmed absence clears them.
    public static func reconcileAuthentication(
        _ availability: SecurityAuthenticationAvailability,
        in defaults: UserDefaults
    ) {
        defaults.set(availability.rawValue, forKey: availabilityKey)
        switch availability {
        case .available:
            // Legacy explicit saves left the defaults notice pending. Neither that
            // notice nor version 1 proves which choices were automatically seeded.
            // Retire the metadata without removing potentially explicit protections.
            // pinned: SecurityProtectedSurfaceStorageTests.testLegacyExplicitChoicesSurvivePendingNoticeAndRepeatedReconciliation
            saveProtectedSurfaces(storedSurfaces(from: defaults), to: defaults)
        case .absent:
            defaults.set([String](), forKey: defaultsKeyName)
            defaults.set(optInMigrationVersion, forKey: migrationKey)
            defaults.removeObject(forKey: noticeKey)
        case .unavailable:
            break
        }
    }

    /// Compatibility API: the retired default-seeding notice is never presented.
    public static func hasPendingDefaultsNotice(in defaults: UserDefaults) -> Bool {
        false
    }

    /// Called only by the foreground notice's acknowledgement action.
    public static func acknowledgeDefaultsNotice(in defaults: UserDefaults) {
        defaults.removeObject(forKey: noticeKey)
    }

    /// The common gate used by app, intent, widget and background switch entry points.
    public static func isProtected(
        _ surface: SecurityProtectedSurface,
        defaults: UserDefaults
    ) -> Bool {
        loadProtectedSurfaces(from: defaults).contains(surface)
    }

    /// Shared control-plane file containing gates and migration state, never credential material.
    public static func projectionURL(containerURL: URL) -> URL {
        containerURL.appendingPathComponent("security-gates.json")
    }

    /// Reads fresh cross-process gates; missing or unreadable state cannot authorize an action.
    public static func loadProtectedSurfaces(from defaults: UserDefaults, projectionURL: URL?) -> Set<SecurityProtectedSurface> {
        guard let projectionURL, let state = try? readProjection(at: projectionURL) else {
            return Set(SecurityProtectedSurface.allCases)
        }
        return state.effectiveSurfaces
    }

    /// Reads the saved Open Lava choice, never a synthetic gate from repair.
    /// Reading consent cannot grant or refresh authorization.
    public static func appUnlockCoverChoice(projectionURL: URL?, defaults: UserDefaults? = nil) -> Bool? {
        guard let projectionURL, let state = try? readProjection(at: projectionURL) else {
            return defaults.flatMap(storedAppUnlockCoverChoice)
        }
        if let consent = state.coverConsent { return consent.choice }
        return legacyAppUnlockCoverChoice(state, defaults: defaults)
    }

    /// Gate used by production app, intent, widget and background entry points.
    public static func isProtected(_ surface: SecurityProtectedSurface, defaults: UserDefaults, projectionURL: URL?) -> Bool {
        loadProtectedSurfaces(from: defaults, projectionURL: projectionURL).contains(surface)
    }

    /// Publishes conservative gates before the app makes a new credential usable.
    /// Failure must prevent the keychain write; a failed write leaves these gates until app reconciliation.
    @discardableResult
    public static func prepareCredentialChange(in defaults: UserDefaults, projectionURL: URL?) -> Bool {
        updateProjection(in: defaults, at: projectionURL) { $0.availability = .unavailable }
    }

    /// Atomically reconciles credentials while preserving explicit, opt-in choices.
    @discardableResult
    public static func reconcileAuthentication(_ availability: SecurityAuthenticationAvailability,
                                               in defaults: UserDefaults, projectionURL: URL?,
                                               protectedDataIsAvailable: Bool = true) -> Bool {
        updateProjection(in: defaults, at: projectionURL,
                         allowsLegacySeeding: protectedDataIsAvailable && availability != .unavailable,
                         repairsMalformedRecord: protectedDataIsAvailable) { state in
            state.availability = availability
            // Legacy projection saves also retained noticePending after explicit edits.
            // Preserve every stored choice; this marker retires only the old notice.
            // Unreadable startup defers migration until a classified credential read.
            // pinned: SecurityGateProjectionTests.testLegacyExplicitChoicesSurvivePendingNoticeAndRepeatedReconciliation
            if protectedDataIsAvailable && availability != .unavailable && state.optInMigration == nil {
                state.optInMigration = optInMigrationVersion
                state.noticePending = false
            }
            switch availability {
            case .available:
                state.migrated = true
            case .absent:
                state.surfaces = []
                state.coverConsent = .off
                state.migrated = true
                state.noticePending = false
            case .unavailable: break
            }
        }
    }

    /// Persists an informed choice in the same atomic record as migration and credential availability.
    @discardableResult
    public static func saveProtectedSurfaces(_ surfaces: Set<SecurityProtectedSurface>, to defaults: UserDefaults,
                                             projectionURL: URL?) -> Bool {
        saveProtectedSurfaces(surfaces, to: defaults, projectionURL: projectionURL,
                              appUnlockCoverChoice: surfaces.contains(.appUnlock))
    }

    /// The app supplies Open Lava's actual choice separately from conservative
    /// access gates when editing a different protected action after recovery.
    @discardableResult
    public static func saveProtectedSurfaces(_ surfaces: Set<SecurityProtectedSurface>, to defaults: UserDefaults,
                                             projectionURL: URL?, appUnlockCoverChoice: Bool?) -> Bool {
        updateProjection(in: defaults, at: projectionURL) { state in
            state.coverConsent = CoverConsent(appUnlockCoverChoice)
            state.surfaces = surfaces
            state.migrated = true
            state.optInMigration = optInMigrationVersion
            state.noticePending = false
        }
    }

    /// Reads the notice from the authoritative record, independently of defaults propagation.
    public static func hasPendingDefaultsNotice(in defaults: UserDefaults, projectionURL: URL?) -> Bool {
        false
    }

    /// Records foreground acknowledgement without changing the effective gates.
    @discardableResult
    public static func acknowledgeDefaultsNotice(in defaults: UserDefaults, projectionURL: URL?) -> Bool {
        updateProjection(in: defaults, at: projectionURL) { $0.noticePending = false }
    }

    private enum CoverConsent: String, Codable {
        case off, on, unknown
        init(_ choice: Bool?) { self = choice.map { $0 ? .on : .off } ?? .unknown }
        var choice: Bool? { self == .unknown ? nil : self == .on }
    }

    private struct Projection: Codable {
        var version = 1
        var availability: SecurityAuthenticationAvailability
        var surfaces: Set<SecurityProtectedSurface>
        var migrated: Bool
        var noticePending: Bool
        var optInMigration: Int?
        var coverConsent: CoverConsent? = nil // Absent only in a legacy, valid record.

        var effectiveSurfaces: Set<SecurityProtectedSurface> {
            // Unreadable credentials are not consent to clear preferences. Temporary
            // fail-closed gates never persist as a user's selected protection choices.
            guard availability != .unavailable else { return Set(SecurityProtectedSurface.allCases) }
            // A known OFF global choice is not an unknown access gate. Keeping
            // a synthetic appUnlock here would strand entry with no unlock UI.
            return coverConsent == .off ? surfaces.subtracting([.appUnlock]) : surfaces
        }
    }

    private enum ProjectionError: Error { case malformed, unsupportedVersion, oversized }

    private struct ProjectionVersion: Decodable { let version: Int }

    private static func readProjection(at url: URL) throws -> Projection {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: 4097) ?? Data()
        guard data.count <= 4096 else { throw ProjectionError.oversized }
        do {
            let decoder = JSONDecoder()
            // Inspect the version before decoding fields an older app cannot understand.
            guard try decoder.decode(ProjectionVersion.self, from: data).version == 1 else {
                throw ProjectionError.unsupportedVersion
            }
            return try decoder.decode(Projection.self, from: data)
        } catch is DecodingError {
            throw ProjectionError.malformed
        }
    }

    // App-main-actor writers only. Readers never seed, migrate or repair this record.
    private static func updateProjection(in defaults: UserDefaults, at url: URL?,
                                          allowsLegacySeeding: Bool = false,
                                          repairsMalformedRecord: Bool = false,
                                          _ update: (inout Projection) -> Void) -> Bool {
        guard let url else { return false }
        do {
            var state: Projection
            do { state = try readProjection(at: url) }
            catch let error as NSError where error.domain == NSCocoaErrorDomain
                && [NSFileNoSuchFileError, NSFileReadNoSuchFileError].contains(error.code) {
                // Prewarm cannot read protected legacy preferences. Leave the file absent
                // and readers conservative until foreground reconciliation can migrate them.
                guard allowsLegacySeeding else { return false }
                state = Projection(
                    availability: SecurityAuthenticationAvailability(rawValue: defaults.string(forKey: availabilityKey) ?? "") ?? .unavailable,
                    surfaces: storedSurfaces(from: defaults), migrated: defaults.integer(forKey: migrationKey) >= 1,
                    noticePending: defaults.bool(forKey: noticeKey),
                    optInMigration: defaults.integer(forKey: migrationKey) >= optInMigrationVersion ? optInMigrationVersion : nil)
            } catch ProjectionError.malformed where repairsMalformedRecord {
                // Only app credential reconciliation repairs corruption. Lost choices default
                // to conservative gates, while independently saved Open Lava consent survives.
                let coverChoice = storedAppUnlockCoverChoice(defaults)
                state = Projection(availability: .unavailable,
                                   surfaces: Set(SecurityProtectedSurface.allCases),
                                   migrated: true, noticePending: false, optInMigration: optInMigrationVersion,
                                   coverConsent: CoverConsent(coverChoice))
            }
            if state.coverConsent == nil { state.coverConsent = CoverConsent(legacyAppUnlockCoverChoice(state, defaults: defaults)) }
            update(&state)
            if state.coverConsent == .off { state.surfaces.remove(.appUnlock) }
            try JSONEncoder().encode(state).write(to: url, options: SharedStateFileProtection.atomicControlPlaneWritingOptions)
            if let choice = state.coverConsent?.choice { defaults.set(choice, forKey: appUnlockCoverChoiceKey) }
            defaults.set(state.surfaces.map(\.rawValue).sorted(), forKey: defaultsKeyName)
            defaults.set(state.optInMigration ?? (state.migrated ? 1 : 0), forKey: migrationKey)
            defaults.set(state.availability.rawValue, forKey: availabilityKey)
            defaults.set(state.noticePending, forKey: noticeKey)
            return true
        } catch { return false }
    }

    private static func storedSurfaces(from defaults: UserDefaults) -> Set<SecurityProtectedSurface> {
        Set((defaults.stringArray(forKey: defaultsKeyName) ?? []).compactMap(SecurityProtectedSurface.init(rawValue:)))
    }

    private static func legacyAppUnlockCoverChoice(_ state: Projection, defaults: UserDefaults?) -> Bool? {
        guard state.surfaces.contains(.appUnlock) else { return false }
        // Older repair writers persisted synthetic appUnlock gates, including
        // subsets after later action edits. Only independent consent can prove ON.
        return defaults?.object(forKey: appUnlockCoverChoiceKey) as? Bool
    }

    private static func storedAppUnlockCoverChoice(_ defaults: UserDefaults) -> Bool? {
        if let choice = defaults.object(forKey: appUnlockCoverChoiceKey) as? Bool { return choice }
        // A legacy OFF set cannot have come from the old all-gates repair.
        if let saved = defaults.stringArray(forKey: defaultsKeyName), !saved.contains(SecurityProtectedSurface.appUnlock.rawValue) { return false }
        return nil
    }
}

public enum SecurityAccessPolicy: Equatable, Sendable {
    case readOnly
    case requires(SecurityProtectedSurface)

    public var requiredSurface: SecurityProtectedSurface? {
        switch self {
        case .readOnly:
            nil
        case .requires(let surface):
            surface
        }
    }
}
