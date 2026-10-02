import Foundation
import LavaSecKit

/// Whether an artifact the app is about to publish is one the TUNNEL can actually adopt.
///
/// ## The gap this closes
///
/// The two processes derive the snapshot identity from DIFFERENT catalogs, and nothing compared
/// them:
///
/// - The app stamps `PreparedFilterSnapshot.identity` from the catalog its prepare RESOLVED —
///   `BlocklistCatalogSynchronizer.compile` returns a `resolvedCatalog` whose enabled sources
///   carry the versionID and hash of the payload it actually used.
/// - The tunnel computes the identity it WANTS from the catalog on disk —
///   `loadCachedCatalogMetadata()`, which is `loadLatestCatalog()`, the persisted `latest.json`.
///
/// `sync` keeps those in step: it persists the resolved catalog whenever the resolve moved
/// (`saveLatestCatalog(encode(result.catalog))`, "records rotated versionIDs and hashes"). The
/// CACHE-ONLY prepare resolves the same way and persists nothing, so a resolve that diverges from
/// the persisted catalog produces an artifact the tunnel rejects on
/// `selectedSourceVersionIDs`/`selectedSourceHashes` — and rejects again on every reload, because
/// nothing on either side moves. The divergence survives at one `catalogVersion`, which is why the
/// miss reason names those two fields and not `catalogVersion`.
///
/// ## Why the app could not see it
///
/// Every app-side gate passes in this state: the prepare succeeded, `coversEnabledBlocklists` is
/// true, the tier budget fits, the pointer flip committed, and `snapshot-publish-outcome` records
/// `published`. The failure is only visible as the tunnel's `loadSnapshot-store-miss`, one process
/// away, and PR #640 added that diagnostic on the tunnel side alone. This is the other half: the
/// publisher checking, before it claims success, that what it wrote is a thing the reader can take.
///
/// Field evidence (2026-09-02, `lavasec-infra` plans/2026-09-03-artifact-adoptability-plan.md): a
/// Focus-driven switch published token `f2b34db3…`, the tunnel wanted `33f8c592…`, and 17
/// consecutive reloads logged `loadSnapshot-reload-failed-keeping-resident` over five hours. The
/// resident stayed CORRECT throughout — `serveLastKnownGoodOrFailClosed` had adopted a
/// selection-exact last-known-good — so nothing user-visible said the content had stopped
/// refreshing.
///
/// ## What this type is not
///
/// It answers one question — does this identity equal the one the tunnel will compute — and it
/// answers it by calling the SAME `PreparedFilterSnapshotIdentity.make` the tunnel calls, on the
/// SAME persisted catalog. It deliberately does not re-derive, re-order, or normalise anything: a
/// second implementation of identity construction beside the real one would drift, and a
/// confidently-wrong "adoptable" is worse than no check at all.
public enum PublishedArtifactAdoptability {
    /// Whether the tunnel can adopt this artifact, and — when it cannot — which fields decided it.
    public enum Verdict: Equatable, Sendable {
        /// The identity matches what the tunnel computes; the artifact is adoptable on sight.
        case adoptable
        /// The tunnel will reject this artifact. `reason` is `reuseMismatchReason`'s output —
        /// field NAMES only (`freshness:selectedSourceHashes`, `inputs:enabledBlocklistIDs`), never
        /// a domain, rule, or list name, so it is safe to log and to put in a bug report.
        case rejectedByTunnel(reason: String)
        /// No catalog is persisted yet, so the tunnel's expectation cannot be computed here.
        ///
        /// NOT a rejection: on a first run the tunnel takes its own no-cached-catalog warm-start
        /// branch, which compares against configuration inputs rather than a catalog. Reporting
        /// this as unadoptable would fire on every clean install.
        case noPersistedCatalog
    }

    /// The verdict for an artifact identity, against the catalog the tunnel will read.
    ///
    /// - Parameters:
    ///   - artifactIdentity: the identity STAMPED on the artifact being published — read off the
    ///     prepared snapshot, never recomputed here, so this compares what was actually written.
    ///   - configuration: the configuration the tunnel will hold when it reloads.
    ///   - persistedCatalog: `BlocklistCatalogSynchronizer.loadCachedCatalogMetadata()`. The
    ///     PERSISTED catalog, not the resolve's — passing the resolved one compares the identity
    ///     with itself and always answers `adoptable`, which is precisely the blind spot.
    public static func verdict(
        artifactIdentity: PreparedFilterSnapshotIdentity,
        configuration: AppConfiguration,
        persistedCatalog: BlocklistCatalog?
    ) -> Verdict {
        guard let persistedCatalog else { return .noPersistedCatalog }
        let tunnelExpectation = PreparedFilterSnapshotIdentity.make(
            configuration: configuration,
            catalog: persistedCatalog
        )
        guard let reason = tunnelExpectation.reuseMismatchReason(against: artifactIdentity) else {
            return .adoptable
        }
        return .rejectedByTunnel(reason: reason)
    }
}

extension PublishedArtifactAdoptability.Verdict {
    /// A short, privacy-safe value for `snapshot-publish-outcome`.
    ///
    /// One key rather than a flag plus an optional reason: an absent reason and a reason that
    /// happens to be empty read identically in a capture, and this event is read from bug reports
    /// where the difference decides whether the publish side is implicated at all.
    public var diagnosticValue: String {
        switch self {
        case .adoptable: return "adoptable"
        case .noPersistedCatalog: return "no-persisted-catalog"
        case .rejectedByTunnel(let reason): return "rejected:\(reason)"
        }
    }

    /// Whether the publish produced an artifact the tunnel is going to refuse.
    ///
    /// `noPersistedCatalog` is deliberately NOT this: an unknown is not a failure, and treating it
    /// as one would report every first run as broken.
    public var isRejectedByTunnel: Bool {
        if case .rejectedByTunnel = self { return true }
        return false
    }
}
