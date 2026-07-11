import Foundation
import LavaSecKit

/// Carries a prepared filter snapshot and optional catalog/guardrail context for a warm switch.
///
/// Values returned by ``WarmFilterSnapshotLoader`` loading APIs have passed their warm-reuse
/// gates. The public initializer performs no validation, so direct callers are responsible for
/// supplying a coherent combination.
///
/// `snapshot.nonAllowableThreatRules` is only the allowlist-overlap SUBSET, so applying it as
/// `threatGuardrail` would let `AllowlistValidator` allow a threat domain that isn't currently
/// allowed; the full set is applied instead when present. `nil` ⇒ fall back to the snapshot subset
/// (the warm-startup path, whose launch catalog sync repopulates it).
///
/// Promoted from a private `AppViewModel` struct (LAV-100 Phase 4) so the foreground switch and the
/// headless Focus engine share ONE warm-reuse value type and validation core.
public struct ReusablePreparedFilterSnapshot: Sendable {
    /// Prepared snapshot carried for reuse; loader-returned instances have passed warm-reuse validation.
    public let preparedSnapshot: PreparedFilterSnapshot
    /// Catalog context associated with the snapshot, when supplied.
    public let cachedCatalog: BlocklistCatalog?
    /// Full cached threat guardrail associated with the snapshot, when supplied.
    public let fullThreatGuardrail: DomainRuleSet?

    /// Creates a carrier from caller-supplied values without performing warm-reuse validation.
    public init(
        preparedSnapshot: PreparedFilterSnapshot,
        cachedCatalog: BlocklistCatalog?,
        fullThreatGuardrail: DomainRuleSet?
    ) {
        self.preparedSnapshot = preparedSnapshot
        self.cachedCatalog = cachedCatalog
        self.fullThreatGuardrail = fullThreatGuardrail
    }
}

/// Pure, off-actor warm-snapshot loading + validation, shared by the FOREGROUND switch
/// (`AppViewModel.switchToFilter` / `warmReusableSnapshotForSwitch`) and the HEADLESS Focus engine
/// (`HeadlessFocusFilterSwitchEngine`) so the two execution contexts can never drift on warm-reuse
/// safety. This is the verbatim relocation of `AppViewModel.loadReusableWarmSnapshotForSwitch` /
/// `warmReusableSnapshotForSwitch` / `warmSnapshotStillReusableAgainstCachedCatalog`; the app-side
/// methods now delegate here, supplying the App Group URLs they already derived.
public enum WarmFilterSnapshotLoader {
    /// Resolve a reusable warm snapshot for `target` by trying TWO candidate tokens in order —
    /// the target's `lastCompiledToken` (library), then the sidecar warm-index token (background
    /// warmed, not yet promoted) when it differs. `nil` ⇒ no warm artifact is reusable; the caller
    /// cold-compiles.
    package static func reusableSnapshotForSwitch(
        target: Filter,
        configuration: AppConfiguration,
        containerURL: URL,
        cacheURL: URL?,
        freshnessMaxAge: TimeInterval,
        backgroundWarmIndex: BackgroundWarmIndex
    ) async -> ReusablePreparedFilterSnapshot? {
        var candidateTokens: [String] = []
        if let libraryToken = target.lastCompiledToken { candidateTokens.append(libraryToken) }
        if let sidecarToken = backgroundWarmIndex.token(forFilterID: target.id),
           sidecarToken != target.lastCompiledToken {
            candidateTokens.append(sidecarToken)
        }
        for token in candidateTokens {
            if let reusable = await loadReusable(
                token: token,
                configuration: configuration,
                containerURL: containerURL,
                cacheURL: cacheURL,
                freshnessMaxAge: freshnessMaxAge
            ) {
                return reusable
            }
        }
        return nil
    }

    /// Load + validate the prepared snapshot in a SPECIFIC warm token directory for an instant switch.
    /// `nil` ⇒ the directory is missing/undecodable, or the artifact no longer matches `configuration`
    /// + the cached catalog (coverage, source hashes, catalog version, resolver transport), or fails
    /// the tier rule-limit gate. The decoded snapshot's content-addressed token must equal the
    /// directory name, so the subsequent publish flips the pointer to THIS validated dir.
    public static func loadReusable(
        token: String,
        configuration: AppConfiguration,
        containerURL: URL,
        cacheURL: URL?,
        freshnessMaxAge: TimeInterval
    ) async -> ReusablePreparedFilterSnapshot? {
        // Reject warm reuse ONLY when the cold path would actually network-refresh custom lists — i.e.
        // custom lists are allowed to refresh (Plus active) AND the target has an ENABLED custom source.
        // Rationale: when custom lists CAN refresh, reusing a cache-only warm artifact for an enabled custom
        // source could serve STALE bytes (the artifact's fingerprint records the LAST-ACCEPTED hash, and an
        // INACTIVE filter's custom sources are never network-refreshed), so we force the cold network-first
        // path instead. But the guard is scoped tightly:
        //   • ENABLED custom IDs only — a merely-stored DISABLED custom source contributes no bytes to the
        //     artifact (snapshot inputs / custom sync consider only `enabledBlocklistIDs`, cf.
        //     `enabledCustomBlocklists`), so it must not block warm reuse.
        //   • allowsCustomBlocklists only — for a LAPSED Plus user the cold path uses `.cacheOnly` (frozen
        //     lists are never re-downloaded), so forcing cold gains NO freshness and would only discard a
        //     valid retained artifact (or fail when the payload cache is gone); warm-reuse the frozen bytes.
        // Gated HERE in the shared load primitive (not in reusableSnapshotForSwitch) so it covers BOTH the
        // headless Focus path (reusableSnapshotForSwitch → loadReusable) AND the foreground manual switch
        // (AppViewModel.warmReusableSnapshotForSwitch → loadReusable, which bypasses reusableSnapshotForSwitch).
        // (Codex review, lavasec-ios#29.)
        if configuration.limits.allowsCustomBlocklists,
           configuration.customBlocklists.contains(where: { configuration.enabledBlocklistIDs.contains($0.id) }) {
            return nil
        }

        let tokenDirectoryURL = FilterArtifactStore(directoryURL: containerURL).versionedDirectoryURL(token: token)

        return await Task.detached(priority: .userInitiated) {
            // Reuse requires a FRESH cached catalog, mirroring warmFilterArtifact's own precondition
            // (warm only from a fresh cache → reuse only while still fresh). The identity check below
            // validates the artifact against whatever is cached even when that cache is older than
            // the freshness window, so without this a token warmed while fresh could pointer-flip to a
            // stale-catalog artifact long after — instead of the cold path, which network-first
            // refreshes whenever the cache is stale. A stale cache here therefore returns nil so the
            // switch cold-compiles fresh upstream rules (Codex r8).
            guard let cacheURL,
                  BlocklistCatalogSynchronizer.hasFreshCachedCatalog(in: cacheURL, maxAge: freshnessMaxAge) else {
                return nil
            }

            let cachedCatalog = try? BlocklistCatalogSynchronizer(cacheDirectoryURL: cacheURL)
                .loadCachedCatalogMetadata()

            // Manifest-first gate from the small manifest alone (no full prepared decode on a miss).
            let tokenStore = FilterArtifactStore(directoryURL: tokenDirectoryURL)
            guard let manifest = try? tokenStore.loadManifest(),
                  manifest.reuseRejectionReason(configuration: configuration, cachedCatalog: cachedCatalog) == nil,
                  let data = try? Data(contentsOf: tokenStore.preparedSnapshotURL),
                  let preparedSnapshot = try? JSONDecoder().decode(PreparedFilterSnapshot.self, from: data),
                  preparedSnapshot.canReuseForProtectionStartup(
                      configuration: configuration,
                      cachedCatalog: cachedCatalog
                  )
            else {
                return nil
            }

            // The decoded snapshot must hash to the directory it came from, or the publish (which
            // derives the publish token from the snapshot) would flip the pointer to a different dir
            // than the one validated here. Guards a corrupt/mismatched directory.
            guard FilterArtifactStore.versionedToken(for: preparedSnapshot) == token else {
                return nil
            }

            // INV-TIER-1: enforce the SAME tier rule-limit gate the cold compile path applies: the
            // reuse identity check ignores the tier cap, so without this a Plus user who lapsed could
            // switch back to an oversized filter (compiled while Plus) via a pointer flip, bypassing
            // the free-tier limit. A legacy artifact without the field, or one over the limit ⇒ fall
            // back to the cold compile, which surfaces the paywall.
            guard FilterRuleBudget.fitsTierBudget(
                recordedTotal: preparedSnapshot.summary.tierBudgetRuleCount,
                maxFilterRules: configuration.limits.maxFilterRules
            ) else {
                return nil
            }

            // Hydrate the FULL guardrail. The reused snapshot's nonAllowableThreatRules is only the
            // allowlist-overlap SUBSET, so applying it as threatGuardrail would let AllowlistValidator
            // allow a threat domain not already on the allowlist. loadCached with NO enabled sources
            // compiles only the small guardrail lists from cache — cheap, and it preserves the warm win.
            // REQUIRE it: if the full guardrail can't be established, fall back to the cold compile.
            guard let fullThreatGuardrail = try? await BlocklistCatalogSynchronizer(cacheDirectoryURL: cacheURL)
                .loadCached(enabledSourceIDs: [], includesGuardrails: true).guardrailRuleSet
            else {
                return nil
            }

            return ReusablePreparedFilterSnapshot(
                preparedSnapshot: preparedSnapshot,
                cachedCatalog: cachedCatalog,
                fullThreatGuardrail: fullThreatGuardrail
            )
        }.value
    }

    /// Final pre-commit re-validation of a warm snapshot against the CURRENT cached catalog. Re-run
    /// just before the flip so a background catalog refresh that moved `latest.json` since the warm
    /// load causes a clean defer rather than a transient latest.json-ahead-of-pointer wedge.
    /// Read-only, off the main actor.
    package static func stillReusableAgainstCachedCatalog(
        _ snapshot: PreparedFilterSnapshot,
        configuration: AppConfiguration,
        cacheURL: URL?,
        freshnessMaxAge: TimeInterval
    ) async -> Bool {
        guard let cacheURL else { return false }
        let maxAge = freshnessMaxAge
        return await Task.detached(priority: .userInitiated) {
            guard BlocklistCatalogSynchronizer.hasFreshCachedCatalog(in: cacheURL, maxAge: maxAge),
                  let cachedCatalog = try? BlocklistCatalogSynchronizer(cacheDirectoryURL: cacheURL).loadCachedCatalogMetadata()
            else {
                return false
            }
            return snapshot.canReuseForProtectionStartup(configuration: configuration, cachedCatalog: cachedCatalog)
        }.value
    }
}
