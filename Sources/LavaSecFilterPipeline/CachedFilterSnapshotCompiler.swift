import Foundation
import LavaSecKit

// The in-extension compile facade, extracted from FilterSnapshot.swift so the
// FilterSnapshot MODEL can live in LavaSecKit while this compiler wrapper stays
// with the snapshot pipeline in LavaSecCore.

public struct CachedFilterSnapshotCompiler: Sendable {
    public let cacheDirectoryURL: URL
    public let includesGuardrails: Bool

    public init(cacheDirectoryURL: URL, includesGuardrails: Bool = true) {
        self.cacheDirectoryURL = cacheDirectoryURL
        self.includesGuardrails = includesGuardrails
    }

    /// Compiles the in-extension runtime snapshot. Delegates to
    /// `StreamingCompactSnapshotCompiler`, which NEVER holds the dirty `DomainRuleSet`
    /// union of all enabled sources in memory — it streams each source's domains into an
    /// on-disk blob, keeps only the compact entry table (~8 B/rule) resident, and
    /// memory-maps the resulting artifact. So the packet-tunnel ~50 MiB jetsam budget is
    /// respected even for a large multi-list configuration, and the result is the same
    /// 9 B/rule mapped-compact shape the foreground app produces. Over the streaming
    /// aggregate budget (`FilterSnapshotMemoryBudget.maxStreamingCompileRuleCount`) it
    /// throws `StreamingCompileBudgetExceeded`; the caller falls back fail-CLOSED and the
    /// app re-prepares the full snapshot.
    ///
    /// `stampIdentity` lets the tunnel stamp the snapshot with the identity it computed
    /// from the cached catalog (preserving the prior resident-identity behavior); when nil
    /// the identity is derived from the resolved catalog.
    ///
    /// `retainedArtifactURL` optionally keeps the compiled compact artifact on disk at the
    /// given path (atomic same-volume promotion out of scratch) so a later cold start can
    /// fast-resume from this compile instead of repeating it. Best-effort: retention
    /// failure never fails the compile. Readers must identity-gate the retained file the
    /// same way they gate every artifact-store read — the path may hold an older compile.
    public func compile(
        baseSnapshot: FilterSnapshot,
        configuration: AppConfiguration,
        stampIdentity: PreparedFilterSnapshotIdentity? = nil,
        retainedArtifactURL: URL? = nil
    ) async throws -> CompactFilterSnapshot {
        try await StreamingCompactSnapshotCompiler(
            cacheDirectoryURL: cacheDirectoryURL,
            includesGuardrails: includesGuardrails
        ).compile(
            baseSnapshot: baseSnapshot,
            configuration: configuration,
            stampIdentity: stampIdentity,
            retainedArtifactURL: retainedArtifactURL
        )
    }

    /// Removes any scratch directories a jetsam-killed in-extension compile may have left
    /// behind. Safe to call at tunnel start / before a compile (a live mapped artifact is
    /// never rooted in scratch). See `StreamingCompactSnapshotCompiler.sweepStaleScratch`.
    public static func sweepStaleScratch(cacheDirectoryURL: URL) {
        StreamingCompactSnapshotCompiler.sweepStaleScratch(cacheDirectoryURL: cacheDirectoryURL)
    }
}
