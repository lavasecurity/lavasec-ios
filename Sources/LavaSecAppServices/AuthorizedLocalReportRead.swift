import Foundation

/// The app-facing local report pipeline. It deliberately accepts only a local
/// diagnostics reader: tunnel/provider health sampling remains a separate task.
/// Both initial reads and explicit refresh use this pipeline. Authorization is
/// checked after every suspension and once more immediately before publication.
@MainActor
public enum AuthorizedLocalReportRead {
    /// Runs a local report read in the current native authorization turn. `Grant`
    /// is native-owned (for example the security controller's revision), never a
    /// JavaScript boolean. `validate` must throw if the lifecycle, owner or policy
    /// changed, including while `readDiagnostics` was suspended.
    public static func run<Grant, Diagnostics, Result>(
        authorize: () async throws -> Grant,
        readDiagnostics: () async throws -> Diagnostics,
        compose: (Diagnostics) throws -> Result,
        validate: (Grant) throws -> Void
    ) async throws -> Result {
        let grant = try await authorize()
        try Task.checkCancellation()
        try validate(grant)
        let diagnostics = try await readDiagnostics()
        try Task.checkCancellation()
        try validate(grant)
        let result = try compose(diagnostics)
        try validate(grant)
        return result
    }
}
