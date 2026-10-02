import Foundation

/// A concrete remedy unavailable to automatic filter recovery under the current settings.
public enum FilterArtifactIntervention: String, Codable, Equatable, Sendable {
    /// The selected rules still exceed the budget after refresh.
    case reviewFilterSelection
    /// Background refresh cannot replace a custom source's accepted identity.
    case refreshCustomSources
}

/// The app's most recent repair attempt, scoped to the user's configuration.
public struct FilterArtifactRepairStatus: Codable, Equatable, Sendable {
    /// Recorded outcomes; waiting and publication never imply that the user must act.
    public enum Outcome: String, Codable, Sendable {
        case repairing, waitingForRetry, published, selectionOverBudget, customSourceUnavailable
    }

    /// Configuration fingerprint excluding catalog freshness.
    public let configurationIdentity: String
    /// Last app-owned repair outcome.
    public let outcome: Outcome
    /// Time at which the app recorded the outcome.
    public let recordedAt: Date

    /// Creates evidence for one configuration and repair outcome.
    public init(configurationIdentity: String, outcome: Outcome, recordedAt: Date) {
        self.configurationIdentity = configurationIdentity
        self.outcome = outcome
        self.recordedAt = recordedAt
    }

    /// Binds evidence to persisted intent and current limits without including catalog freshness.
    public static func identity(for configuration: AppConfiguration, snapshotFingerprint: String) -> String {
        "\(snapshotFingerprint):\(configuration.configurationGeneration):\(configuration.limits.maxFilterRules):\(configuration.limits.allowsCustomBlocklists)"
    }
}

/// Shared artifact triage, independent of DNS-only or chained routing.
public enum FilterArtifactRecoveryAssessment: Equatable, Sendable {
    case serving, repairing, waitingForAutomaticRepair
    case requiresUserAction(FilterArtifactIntervention)

    /// Assesses current service and app repair evidence; unknown or stale evidence cannot escalate.
    public static func assess(isServing: Bool, reloadInFlight: Bool, configurationIdentity: String,
                              repair: FilterArtifactRepairStatus?, failureStartedAt: Date? = nil,
                              now: Date = Date()) -> Self {
        if isServing { return .serving }
        if reloadInFlight { return .repairing }
        guard let repair, let failureStartedAt, repair.recordedAt >= failureStartedAt,
              repair.configurationIdentity == configurationIdentity,
              (0...600).contains(now.timeIntervalSince(repair.recordedAt)) else {
            return .waitingForAutomaticRepair
        }
        switch repair.outcome {
        case .repairing: return .repairing
        case .published, .waitingForRetry: return .waitingForAutomaticRepair
        case .selectionOverBudget: return .requiresUserAction(.reviewFilterSelection)
        case .customSourceUnavailable: return .requiresUserAction(.refreshCustomSources)
        }
    }

    /// The user action justified by this assessment, if any.
    public var intervention: FilterArtifactIntervention? {
        if case .requiresUserAction(let action) = self { return action }
        return nil
    }
}

/// App-owned repair evidence. The tunnel only reads; the incident ledger remains observational.
@MainActor
public enum FilterArtifactRepairStatusStore {
    private struct Attempt {
        let url: URL
        let configurationIdentity: String
    }
    private static var attempts: [UUID: Attempt] = [:]

    /// Stable location in the shared application container.
    public nonisolated static func url(in containerURL: URL) -> URL {
        containerURL.appendingPathComponent("filter-artifact-repair.json")
    }

    /// Reads bounded, complete evidence without creating or repairing files.
    public nonisolated static func load(at url: URL?) -> FilterArtifactRepairStatus? {
        guard let url, let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 4097), data.count <= 4096 else { return nil }
        return try? JSONDecoder().decode(FilterArtifactRepairStatus.self, from: data)
    }

    /// Records productive app work before it starts; overlapping work keeps intervention suppressed.
    public static func begin(at url: URL?, configurationIdentity: String, now: Date = Date()) -> UUID? {
        guard let url else { return nil }
        let token = UUID()
        attempts[token] = Attempt(url: url, configurationIdentity: configurationIdentity)
        write(.init(configurationIdentity: configurationIdentity, outcome: .repairing, recordedAt: now), at: url)
        return token
    }

    /// Completes this attempt against its evaluated configuration, including its own persisted refresh.
    public static func finish(_ token: UUID?, outcome: FilterArtifactRepairStatus.Outcome,
                              completedConfigurationIdentity: String? = nil, now: Date = Date()) {
        guard let token, let attempt = attempts.removeValue(forKey: token),
              load(at: attempt.url)?.configurationIdentity == attempt.configurationIdentity else { return }
        let completedIdentity = completedConfigurationIdentity ?? attempt.configurationIdentity
        let stillRunning = attempts.values.contains {
            $0.url == attempt.url && $0.configurationIdentity == completedIdentity
        }
        write(.init(configurationIdentity: completedIdentity,
                    outcome: stillRunning ? .repairing : outcome, recordedAt: now), at: attempt.url)
    }

    private static func write(_ status: FilterArtifactRepairStatus, at url: URL) {
        guard let data = try? JSONEncoder().encode(status) else { return }
        try? data.write(to: url, options: SharedStateFileProtection.atomicControlPlaneWritingOptions)
    }
}
