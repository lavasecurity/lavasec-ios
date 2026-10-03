import Darwin
import Foundation
import SwiftUI
import UIKit
@preconcurrency import CoreHaptics
@preconcurrency import NetworkExtension
@preconcurrency import UserNotifications
import LavaSecKit
import LavaSecFilterPipeline
import LavaSecAppServices

// One concern of `AppViewModel`, split out of the former single-file view model.
// Stored state (`@Published` and otherwise) lives in LavaSecApp/AppViewModel.swift (extensions
// cannot declare stored properties); every file under AppViewModel/ is one `// MARK:` section.

extension AppViewModel {
    // MARK: - Shareable filters

    /// The security-reviewed, shareable slice of the current setup (blocklists +
    /// blocked/allowed domains, with no resolver or device details).
    var shareableFilterConfiguration: ShareableFilterConfiguration {
        ShareableFilterConfiguration(configuration: configuration)
    }

    /// The tamper-evident text/QR token that encodes ``shareableFilterConfiguration``.
    var shareableFilterConfigurationCode: String {
        shareableFilterConfiguration.encodedConfigurationCode()
    }

    /// Total rules a filter contributes in effect: the active filter's live compiled
    /// count, or a saved filter's projected list count plus its manual blocked domains.
    func filterRuleCount(for filter: Filter) -> Int {
        if filter.id == activeFilterID {
            return protectedRuleCount
        }
        return projectedFilterRuleCount(forEnabledIDs: filter.enabledBlocklistIDs).known
            + filter.blockedDomains.count
    }

    /// The shareable text/QR code for a specific saved filter (for sharing a filter other
    /// than the one in effect).
    func shareableFilterCode(for filter: Filter) -> String {
        ShareableFilterConfiguration(filter: filter).encodedConfigurationCode()
    }

    /// Whether a filter can be shared at all: it has something to share AND its code fits
    /// the shareable capacity (the higher of the QR/code limits). An oversized setup is
    /// "too big to share"; an empty filter has nothing to share.
    func isFilterShareable(_ filter: Filter) -> Bool {
        let shareable = ShareableFilterConfiguration(filter: filter)
        return !shareable.isEmpty && !shareable.containsPrivateSourceParameters && shareable.fitsShareableCodeCapacity()
    }

    /// Reconciles a shared config against this device's catalog/plan for a PREVIEW shown BEFORE the
    /// destination is chosen. Legacy v1 imports reserve the largest recipient allowlist;
    /// v2 carries its own exceptions and replaces the recipient's exceptions.
    func importPlan(for shared: ShareableFilterConfiguration) -> ShareableFilterImportPlan {
        let worstCasePreserved = shared.allowedDomains == nil
            ? library.filters.map { $0.allowedDomains.count }.max() ?? 0 : 0
        return importPlan(for: shared, preservedAllowedDomainCount: worstCasePreserved)
    }

    /// Reconciles a shared config against this device's catalog and tier, with `preservedAllowedDomainCount`
    /// allowlist exceptions counted against the rule budget for legacy v1 imports.
    func importPlan(
        for shared: ShareableFilterConfiguration,
        preservedAllowedDomainCount: Int
    ) -> ShareableFilterImportPlan {
        let curatedIDs = Set(DefaultCatalog.curatedSources.map(\.id))
        let publishedSources = sharedImportCatalogSourcesByID ?? [:]
        let availableCuratedIDs = Set(publishedSources.keys)
        let catalogSourceIDsByCustomURL = Dictionary(
            shared.customBlocklists.compactMap { source in
                knownCatalogSourceIDForSharedImport(source.sourceURL).map { (source.sourceURL, $0) }
            }, uniquingKeysWith: { first, _ in first })
        // An imported custom list may not claim any built-in list ID (curated or
        // guardrail), so a crafted code can't shadow a trusted list.
        let reservedIDs = curatedIDs
            .union(publishedSources.keys)
            .union(catalogSourcesByID.keys)
            .union(DefaultCatalog.guardrailSources.map(\.id))
        // Known per-list rule counts so the plan can trim over-budget selections
        // (e.g. a Plus setup imported on Free) before they fail at compile time.
        var ruleCounts: [String: Int] = [:]
        for (id, source) in publishedSources where source.entryCount > 0 {
            ruleCounts[id] = source.entryCount
        }
        for (id, ruleSet) in cachedBlockRuleSets where ruleCounts[id] == nil {
            ruleCounts[id] = ruleSet.count
        }
        let capabilities = ShareableFilterImportCapabilities(
            availableCuratedBlocklistIDs: availableCuratedIDs,
            reservedBlocklistIDs: reservedIDs,
            catalogSourceIDsByCustomURL: catalogSourceIDsByCustomURL,
            allowsCustomBlocklists: configuration.limits.allowsCustomBlocklists,
            maxBlockedDomains: configuration.limits.maxBlockedDomains,
            maxFilterRules: configuration.limits.maxFilterRules,
            blocklistRuleCounts: ruleCounts,
            preservedRuleCount: shared.allowedDomains == nil ? preservedAllowedDomainCount : 0,
            maxAllowedDomains: configuration.limits.maxAllowedDomains,
            nonAllowableThreatRules: threatGuardrail
        )
        return shared.importPlan(capabilities: capabilities)
    }

    /// Recognize synced sources as well as bundled aliases; current publication wins URL collisions.
    private func knownCatalogSourceIDForSharedImport(_ url: URL) -> String? {
        let cached = catalogSourcesByID.values.sorted { $0.id < $1.id }
        let published = (sharedImportCatalogSourcesByID ?? [:]).values.sorted { $0.id < $1.id }
        let publishedURLs = Dictionary(published.map { ($0.sourceURL, $0.id) },
            uniquingKeysWith: { first, _ in first })
        if let currentID = KnownBlocklistURLMatcher.catalogSourceIDForImport(for: url, additionalSourceIDsByURL: publishedURLs),
           published.contains(where: { $0.id == currentID }) {
            return currentID
        }
        let knownURLs = Dictionary((cached + published).map { ($0.sourceURL, $0.id) },
            uniquingKeysWith: { _, publishedID in publishedID })
        return KnownBlocklistURLMatcher.catalogSourceIDForImport(for: url, additionalSourceIDsByURL: knownURLs)
    }

    /// Refresh import availability only. Never rewrite installed lists, payload caches or protection.
    /// Every import preview checks publication; cached/bundled references cannot restore a removed ID.
    func refreshCatalogForSharedImport(_ shared: ShareableFilterConfiguration) async throws {
        sharedImportCatalogSourcesByID = nil
        let customIDs = Set(shared.customBlocklists.map(\.id))
        let knownCatalogIDs = Set(DefaultCatalog.curatedSources.map(\.id)).union(catalogSourcesByID.keys)
        let needsCatalog = !shared.enabledBlocklistIDs.isDisjoint(with: knownCatalogIDs)
            || !shared.enabledBlocklistIDs.subtracting(customIDs).isEmpty
            || shared.customBlocklists.contains { knownCatalogSourceIDForSharedImport($0.sourceURL) != nil }
        guard needsCatalog else {
            sharedImportCatalogSourcesByID = [:]
            return
        }
        guard let cacheURL = catalogCacheURL else { throw LavaSecAppError.appGroupUnavailable }
        let published = try await BlocklistCatalogSynchronizer(
            cacheDirectoryURL: cacheURL,
            dataFetcher: makeBootstrapAwareCatalogDataFetcher()
        ).fetchPublishedCatalog()
        try Task.checkCancellation()
        sharedImportCatalogSourcesByID = Dictionary(uniqueKeysWithValues: published.sources.map { ($0.id, $0) })
    }

    /// Applies only the reviewed filter fields with generation-fenced persistence.
    /// Pre-write supersession refuses the import; publication errors attempt a fenced rollback.
    /// A saved import remains successful when a newer switch owns artifact publication.
    func applyImportedShareableConfiguration(
        _ applied: ShareableFilterConfiguration
    ) async -> ShareableFilterImportResult {
        // Never let an import that reconciled to nothing wipe the existing setup.
        guard !applied.isEmpty, importPlan(for: applied).applied == applied else {
            return .failure(message: "There's nothing this device can import from that code.")
        }

        let previousConfiguration = configuration
        let previousLibrary = library
        let previousFilter = library.activeFilter
        let previousDraft = activeFilterDraft
        let previousSnapshot = preparedSnapshotForCurrentConfiguration()
        let nextConfiguration = configuration.applyingImportedShareableConfiguration(applied)
        var publicationStarted = false

        let restoreRequest = makeProtectionRestoreRequest()

        // Claim the configuration-replacement token so a switch/restore that completes while this
        // import prepares supersedes it (and vice versa) instead of one silently reverting the other.
        let importToken = configurationReplacementGate.begin()

        do {
            let prepared = try await prepareFilterSnapshot(for: nextConfiguration)
            let importedRuleCount = prepared.snapshot.summary.blockedDomainRuleCount
            // A newer replacement took ownership while we prepared — abort without committing.
            guard configurationReplacementGate.isCurrent(importToken),
                  configuration == previousConfiguration,
                  library.activeFilter.strippingLocalCacheState() == previousFilter.strippingLocalCacheState(),
                  importPlan(for: applied).applied == applied else {
                return .failure(message: "Something else updated your filter while this imported. Try again.")
            }
            publicationStarted = true
            configuration = nextConfiguration
            // The ACTIVE filter's content was just replaced, so its per-filter draft (built from
            // the pre-import config) is stale — drop it. Other filters' drafts are untouched.
            activeFilterDraft = nil
            updateCustomBlocklistHashes(prepared.customResult.sourceHashes)
            let outcome = try await persistSharedState(preparedSnapshot: prepared.snapshot,
                                                       schedulesAutomaticBackup: false,
                                                       expectedConfigurationGeneration: previousConfiguration.configurationGeneration)
            // The pair is durable before the artifact await. A later Focus switch loads and
            // retains the imported contents, even when it wins the pointer flip. Report that
            // completed import without retrying or applying stale active-filter side effects;
            // the pending-switch marker drives adoption of the newer selection (PR #724).
            if case .abortedSuperseded = outcome {
                return .success(ruleCount: importedRuleCount)
            }
            guard outcome == .published else {
                return .failure(message: "Something else updated your filter while this imported. Try again.")
            }
            // Re-check after the persist's artifact-actor await (see switchToFilter): a newer
            // replacement that took ownership during it must not have its caches/config desynced by
            // this import's tail. Derived rule state (applyCatalogSyncResult) is therefore applied
            // only AFTER the persist + this gate — persistSharedState used prepared.snapshot, not the
            // caches, so deferring it is safe.
            guard configurationReplacementGate.isCurrent(importToken) else {
                return .success(ruleCount: importedRuleCount)
            }
            applyCatalogSyncResult(prepared.catalogResult)
            appendAppNetworkActivity(.changeFilters)
            backup.scheduleAutomaticBackupAfterConfigurationChange()

            await notifyTunnelSnapshotUpdated()
            guard configurationReplacementGate.isCurrent(importToken) else {
                return .success(ruleCount: importedRuleCount)
            }
            await restoreProtectionIfNeeded(restoreRequest)
            guard configurationReplacementGate.isCurrent(importToken) else {
                return .success(ruleCount: importedRuleCount)
            }

            catalogStatusMessage = (importedRuleCount == 1 ? "Imported %@ rule for local protection." : "Imported %@ rules for local protection.").lavaLocalizedFormat(importedRuleCount.formatted())
            catalogStatusIsError = false
            return .success(ruleCount: importedRuleCount)
        } catch {
            // Roll back only this import's accepted publication. A later process write
            // wins under the same configuration-generation CAS used at confirmation.
            if publicationStarted, configurationReplacementGate.isCurrent(importToken), library.activeFilterID == previousFilter.id {
                // The writer rejects a stale base before either file changes. Unwind the
                // foreground proposal (including the funnel's library sync), not the newer
                // on-disk selection; no compensating write is authorized here (PR #724).
                if error is SharedFilterStatePersistence.StaleBaseGenerationError {
                    configuration = previousConfiguration
                    library = previousLibrary
                    activeFilterDraft = previousDraft
                    return .failure(message: "Something else updated your filter while this imported. Try again.")
                }
                let failedConfiguration = configuration
                let failedLibrary = library
                let failedGeneration = configuration.configurationGeneration
                configuration = configuration.applyingImportedShareableConfiguration(ShareableFilterConfiguration(filter: previousFilter))
                activeFilterDraft = previousDraft
                do {
                    _ = try await persistSharedState(preparedSnapshot: previousSnapshot,
                                                      schedulesAutomaticBackup: false,
                                                      expectedConfigurationGeneration: failedGeneration)
                } catch {
                    if configuration.configurationGeneration == failedGeneration {
                        configuration = failedConfiguration
                        library = failedLibrary
                    }
                    return .failure(message: "The import could not be saved or restored. Review the current filter before trying again.")
                }
            }
            return .failure(message: Self.filterPreparationFailureMessage(for: error))
        }
    }

    /// The next free localized `Shared filter` name.
    ///
    /// A shared payload deliberately never carries the sender's library name — rendering
    /// sender-chosen text in the recipient's filter list would hand an untrusted party a
    /// UI surface — so every imported filter is named here instead. Localized at this
    /// boundary because ``SharedFilterNamePolicy`` lives in a package that does not localize.
    ///
    /// `excludingFilterID` omits a replacement target's own name so the target can keep the
    /// slot it already occupies rather than being bumped by its own presence.
    private func nextSharedFilterName(excludingFilterID excludedID: String? = nil) -> String {
        uniqueFilterName(basedOn: "Shared filter".lavaLocalized, excludingFilterID: excludedID)
    }

    /// Import an already-reconciled shared setup (`applied` = the previewed plan) as a NEW filter
    /// (additive — leaves every existing filter untouched). Library-only: the new filter isn't
    /// switched to, so nothing compiles or reloads the tunnel and protection is unchanged. Takes
    /// the SAME plan the preview showed (no re-plan) so what was previewed is exactly what's added.
    /// Gated on ``canCreateFilter``. Returns the new filter's id or nil if blocked / nothing to
    /// import.
    ///
    /// The name is derived here rather than supplied by the caller: it is never sender-controlled,
    /// and computing it immediately before the mutation keeps it correct against the library as it
    /// actually stands at write time.
    @discardableResult
    func addImportedShareableConfigurationAsNewFilter(
        _ applied: ShareableFilterConfiguration
    ) -> String? {
        guard canCreateFilter, !applied.isEmpty,
              importPlan(for: applied, preservedAllowedDomainCount: 0).applied == applied else { return nil }
        let newID = "filter-\(UUID().uuidString)"
        let newFilter = Filter(
            id: newID,
            name: nextSharedFilterName(),
            emoji: applied.schemaVersion == 1 ? applied.emoji : nil,
            enabledBlocklistIDs: applied.enabledBlocklistIDs,
            customBlocklists: applied.customBlocklists,
            blockedDomains: applied.blockedDomains,
            allowedDomains: applied.allowedDomains ?? []
        )
        let previousLibrary = library
        library.append(newFilter)
        guard persistLibraryOnlyChange(rollingBackTo: previousLibrary) else { return nil }
        return newID
    }

    /// Replace an existing filter's contents with a shared setup, keeping that filter's id,
    /// library position and display name. Version 2 replaces allowlist exceptions from the
    /// shared code; legacy version 1 preserves the recipient's exceptions.
    /// Replacing the ACTIVE filter goes through the full prepare+publish+reload (it's loaded); a
    /// NON-active filter is replaced library-only (no recompile until it's next switched to — its
    /// compiled token is invalidated). Refuses an empty import, an unknown id, or a frozen
    /// (read-only) filter.
    /// - Parameter confirmedActiveReplacement: whether the caller has explicitly
    ///   confirmed replacing the filter *in effect*. Required — and deliberately not
    ///   defaulted — because whether `id` is the active filter is not a property the
    ///   caller can decide once and rely on: a Focus or shortcut switch commits from
    ///   another process, so a filter that was inactive when the user picked it can
    ///   be live by the time this runs. The check therefore belongs here, against the
    ///   library as it is now, rather than in a UI branch taken before an `await`.
    func replaceFilterWithImportedShareableConfiguration(
        id: String,
        _ applied: ShareableFilterConfiguration,
        confirmedActiveReplacement: Bool
    ) async -> ShareableFilterImportResult {
        guard !applied.isEmpty, importPlan(for: applied).applied == applied else {
            return .failure(message: "There's nothing this device can import from that code.")
        }
        guard let target = library.filter(id: id), !isFilterFrozen(id) else {
            return .failure(message: "That filter is no longer available.")
        }
        // Re-read at the boundary: replacing what is protecting the device needs
        // explicit consent to THAT, and authenticating proves identity, not
        // understanding. Refusing is safe — the caller re-asks and comes back.
        // pinned: SharedFilterImportSourceTests.testActiveReplacementIsRefusedWithoutConfirmationAtTheBoundary
        guard confirmedActiveReplacement || id != library.activeFilterID else {
            return .failure(message: "That filter is now in effect. Confirm replacing it and try again.")
        }
        // The active filter is loaded — reuse the full apply path (prepare + publish + tunnel
        // reload). The target keeps its name; v2 exceptions replace its exceptions, while
        // legacy v1 imports preserve them.
        if id == library.activeFilterID {
            return await applyImportedShareableConfiguration(applied)
        }
        // Non-active: library-only replace. Keep the filter's id and position, apply
        // every field present in the shared schema, and invalidate its compiled token so a later switch
        // recompiles. One transaction, rolled back whole if the write fails.
        let previousLibrary = library
        library.mutateFilter(id: id) { filter in
            filter.enabledBlocklistIDs = applied.enabledBlocklistIDs
            filter.customBlocklists = applied.customBlocklists
            filter.blockedDomains = applied.blockedDomains
            if let allowed = applied.allowedDomains { filter.allowedDomains = allowed }
            filter.lastCompiledToken = nil
        }
        // The in-memory guard above answered "is this the active filter?" from a snapshot that a
        // headless Focus/Shortcut commit can outrun — the foreground adopts such a commit
        // asynchronously off a Darwin notification, so `library` can still name the previous filter
        // while disk names the new one. Re-ask under the write lock, where the answer cannot change
        // between the check and the write: a filter that is live on disk must not be overwritten by
        // the library-only path, which would both skip the destructive confirmation and clobber the
        // newer switch.
        // pinned: SharedFilterImportSourceTests.testLibraryOnlyReplaceRefusesAnOnDiskActiveTarget
        guard persistLibraryOnlyChange(rollingBackTo: previousLibrary, refusesIfOnDiskActiveFilterIs: id) else {
            // Classified after the fact because the persist funnel reports only success/failure.
            // Safety does not depend on this: the write was already refused either way — this only
            // decides which of two true things to say.
            if let filterLibraryURL,
               SharedFilterStatePersistence.onDiskActiveFilterID(at: filterLibraryURL) == id {
                return .failure(message: "That filter is now in effect. Confirm replacing it and try again.")
            }
            return .failure(message: "Couldn't save the imported filter. Please try again.")
        }
        // The replaced filter's contents changed, so its per-filter draft (built from the old
        // contents) is stale — drop it.
        filterDrafts.setDraft(nil, for: id)
        let updated = library.filter(id: id) ?? target
        return .success(ruleCount: filterRuleCount(for: updated))
    }

    /// The Focus diagnostics, or nothing at all — purging a legacy record when consent is off.
    ///
    /// 🔴 STOPPING THE WRITES WAS NOT ENOUGH. The previous release's writer was unconditional, so a
    /// user who ALREADY had Network Activity off carries a record written before the gate existed.
    /// They never toggle the switch again, so the transition-clear never fires, and that legacy
    /// value would ship in the next bug report despite consent having been withdrawn all along
    /// (Codex, PR #625).
    ///
    /// PURGE ON READ, which is the shape `refreshNetworkActivityLog` already uses for exactly this
    /// problem: `guard keepNetworkActivity else { clear; return }`. Reading is the only moment the
    /// app is guaranteed to consult consent and the records together, so doing it here needs no
    /// launch hook and cannot be forgotten by a future reader — there is only one read path.
    /// pinned: ProtectionOnDemandSourceTests.testTheBugReportReadsFocusDiagnosticsUnderConsent
    var focusDiagnosticsUnderConsent:
        (last: FocusSwitchDiagnosticRecord?, failure: FocusSwitchDiagnosticRecord?)
    {
        Self.withFocusDiagnosticsConsent { consented in
            guard consented else {
                FocusSwitchDiagnostics.clear(in: LavaSecAppGroup.sharedDefaults)
                return (nil, nil)
            }
            return (
                FocusSwitchDiagnostics.last(in: LavaSecAppGroup.sharedDefaults),
                FocusSwitchDiagnostics.lastFailure(in: LavaSecAppGroup.sharedDefaults)
            )
        }
    }

    /// Resolves Focus-diagnostic consent from the PERSISTED configuration, holding the settings
    /// path's lock for the duration.
    ///
    /// 🔴 NOT `configuration.keepNetworkActivity`. That in-memory value can be a PLACEHOLDER: when
    /// the real file is locked before first unlock, `loadPersistedConfiguration()` deliberately
    /// leaves a default `AppConfiguration` in memory and raises `sharedStateUnavailableAtLoad` —
    /// and that default says `keepNetworkActivity == true`. Reading it turns "we could not tell"
    /// into "consent granted" (Codex, PR #625). The shared resolver reads disk and fails closed.
    ///
    /// One adapter so all three call sites — the bug-report read, the catch-block write and the
    /// opt-out clear — name the same two URLs exactly once.
    /// pinned: ProtectionOnDemandSourceTests.testTheBugReportReadsFocusDiagnosticsUnderConsent
    /// pinned: FocusSwitchDiagnosticsTests.testConsentFailsClosedWhenTheConfigurationCannotBeRead
    static func withFocusDiagnosticsConsent<T>(_ body: (Bool) -> T) -> T {
        guard let container = LavaSecAppGroup.containerURL else { return body(false) }
        return FocusSwitchDiagnostics.withResolvedConsent(
            configurationURL: container.appendingPathComponent(
                LavaSecAppGroup.configurationFilename),
            lockURL: container.appendingPathComponent(
                LavaSecAppGroup.configurationWriteLockFilename),
            body)
    }

    /// Classifies a failed Focus reconcile apply into a STABLE, PRIVACY-SAFE key.
    ///
    /// Never an interpolated error description. This value lands in
    /// ``FocusSwitchDiagnostics`` and is surfaced in the redacted bug report, and
    /// `String(describing: error)` on these paths can carry a container path, a catalog URL or a
    /// user-chosen filter name. Every branch below yields a compile-time constant, and the
    /// fallback carries the error's TYPE only — enough to group by, incapable of carrying content.
    ///
    /// Stable because it is grouped ON: a reason that changed spelling between builds would split
    /// one recurring failure into several and hide exactly the pattern this exists to reveal.
    /// pinned: ProtectionOnDemandSourceTests.testASilentFocusApplyFailureIsRecordedForRelease
    static func focusReconcileFailureReason(for error: Error) -> String {
        if error is CancellationError { return "cancelled" }
        if let appError = error as? LavaSecAppError {
            switch appError {
            case .appGroupUnavailable: return "app-group-unavailable"
            case .vpnStillStopping: return "vpn-still-stopping"
            case .sharedStateUnavailable: return "shared-state-unavailable"
            }
        }
        // 🔴 THE PREPARATION ERRORS ARE CLASSIFIED BY CASE, because collapsing them defeats the
        // point. `prepareSwitchPublication` is the most likely thrower on this path, and
        // `other:BlocklistCatalogSyncError` would name ELEVEN different actionable failures with
        // one string — a checksum mismatch, a rule-limit overflow and a missing source are
        // different bugs with different fixes (Codex, PR #625).
        //
        // CASE ONLY, NEVER THE PAYLOAD. EIGHT of the eleven carry associated values — only
        // `invalidCatalog`, `noCachedCatalog` and `noRulesAvailable` are bare. FIVE carry a catalog
        // `sourceID`, and `customBlocklistUnavailable(displayName:)` carries a name the USER typed.
        // None of it is needed to say what went wrong, and this record ships in the redacted bug
        // report. (An earlier version of this comment said "three" and "two"; both were wrong —
        // Kilo, PR #625.)
        //
        // Exhaustive with no `default`, so a twelfth case has to be classified deliberately
        // rather than silently rejoining the `other:` bucket this exists to empty.
        if let sync = error as? BlocklistCatalogSyncError {
            switch sync {
            case .invalidHTTPStatus: return "catalog-http-status"
            case .invalidCatalog: return "catalog-invalid"
            case .invalidBlocklistEncoding: return "blocklist-encoding"
            case .blocklistTooLarge: return "blocklist-too-large"
            case .blocklistExceedsRuleLimit: return "blocklist-rule-limit"
            case .checksumMismatch: return "blocklist-checksum-mismatch"
            case .noAcceptedSourceHashes: return "blocklist-no-accepted-hashes"
            case .missingEnabledBlocklistSource: return "blocklist-source-missing"
            case .noCachedCatalog: return "catalog-not-cached"
            case .noRulesAvailable: return "no-rules-available"
            case .customBlocklistUnavailable: return "custom-blocklist-unavailable"
            }
        }
        // THE BUDGET FAILURES ARE TWO DIFFERENT ANSWERS TO THE USER, so they get two keys. The
        // preparation service throws them deliberately apart: one says this device cannot hold the
        // compiled rules, the other says the subscription tier caps them. "Your phone can't" and
        // "your plan won't" have different remedies, and one bucket would hide which (Codex,
        // PR #625). Payloads dropped for the reason above — they carry per-source rule counts.
        if let budget = error as? FilterSnapshotPreparationError {
            switch budget {
            case .exceedsDeviceMemoryBudget: return "prepare-device-memory-budget"
            case .exceedsTierFilterRuleLimit: return "prepare-tier-rule-limit"
            }
        }
        // TYPE ONLY. A `URLError` says "the catalog fetch failed" without saying which URL; the
        // same holds for every other error that reaches here.
        return "other:\(String(describing: type(of: error)))"
    }

    /// The *reason* a preparation failed, as user copy. The failure view frames it
    /// (title = "We couldn't update your filter", plus a separate "Your previous filter
    /// is still active." reassurance) — so this returns only the reason, no prefix.
    static func filterPreparationFailureMessage(for error: Error) -> String {
        if let syncError = error as? BlocklistCatalogSyncError {
            switch syncError {
            case .checksumMismatch, .noAcceptedSourceHashes:
                return "Lava is still preparing an update for this blocklist source. Try again shortly."
            case .noCachedCatalog:
                return "Lava could not reach the source catalog. Check your connection and try again."
            case .invalidHTTPStatus, .invalidCatalog:
                return "Lava could not refresh the source catalog. Try again shortly."
            case .invalidBlocklistEncoding, .blocklistTooLarge, .blocklistExceedsRuleLimit,
                 .noRulesAvailable, .customBlocklistUnavailable:
                return syncError.localizedDescription
            case .missingEnabledBlocklistSource:
                return "A selected blocklist is no longer available. Choose another list and try again."
            }
        }

        return error.localizedDescription
    }

    static func domainHistoryDomainActionRejectionTitle(for error: DomainHistoryDomainActionError) -> String {
        switch error {
        case .invalidDomain:
            return "Domain cannot be added"
        case .alreadyBlocked:
            return "Already blocked"
        case .alreadyAllowed:
            return "Already allowed"
        case .blockedDomainLimitReached:
            return "Blocked domain limit reached"
        case .allowedDomainLimitReached:
            return "Allowed exception limit reached"
        case .allowedDomainRejected:
            return "Exception cannot be added"
        }
    }

    func retryFilterPreparation() {
        Task {
            // Retry whatever the failure was: a filter switch (no draft) re-runs the
            // switch; otherwise re-apply the edit draft.
            if let id = pendingSwitchFilterID {
                await switchToFilter(id: id)
            } else {
                // Retry keeps the original surface's origin (e.g. a Domain History apply).
                await prepareAndApplyFilterDraft(origin: filterPreparationOrigin)
            }
        }
    }

    var tunnelCacheHitRateText: String {
        tunnelHealth.cacheHitRate.formatted(.percent.precision(.fractionLength(0)))
    }

    var tunnelTCPFallbackText: String {
        "\(tunnelHealth.tcpFallbackSuccessCount)/\(tunnelHealth.tcpFallbackAttemptCount)"
    }

    var tunnelDeviceDNSFallbackText: String {
        // Nerd Stats display value (UR-56 localization sweep): localized format key so
        // the "activations"/"query fallbacks" words don't leak English into other locales.
        "%1$@ activations · %2$@ query fallbacks".lavaLocalizedFormat(
            tunnelHealth.deviceDNSFallbackActivationCount.formatted(),
            "\(tunnelHealth.deviceDNSFallbackSuccessCount)/\(tunnelHealth.deviceDNSFallbackAttemptCount)"
        )
    }

    var tunnelDNSSmokeProbeText: String {
        "\(tunnelHealth.dnsSmokeProbeSuccessCount)/\(tunnelHealth.dnsSmokeProbeSuccessCount + tunnelHealth.dnsSmokeProbeFailureCount)"
    }

    var tunnelDoHProtocolText: String {
        guard let version = tunnelHealth.lastDoHHTTPVersion else {
            return "None yet".lavaLocalized
        }

        return "\(DoHHTTPVersion.dohAnnotation(negotiatedHTTPVersion: version)) (\(version))"
    }

    /// Nerd Stats "Last DNS response" value: the round-trip time of the most recent
    /// *successful* resolution (LAV-119; plans/2026-07-11-nerd-stats-dns-latency-plan.md).
    /// DNS RTT, not ICMP ping. Uses the success-only duration, not the raw
    /// `lastUpstreamDurationMilliseconds`, so a timeout is never shown as a "response".
    var tunnelLastUpstreamLatencyText: String {
        guard let milliseconds = tunnelHealth.lastUpstreamSuccessDurationMilliseconds else {
            return "None yet".lavaLocalized
        }
        return "\(milliseconds.formatted()) ms"
    }

    /// Nerd Stats "DNS response time" value: session-cumulative p50/p90/p95 upstream
    /// latency plus the sample count, read off the fixed-bucket histogram (LAV-119). The
    /// value is locale-neutral (numbers + ms/s units), so it needs no translated string.
    var tunnelLatencyPercentileText: String {
        let histogram = tunnelHealth.upstreamLatencyHistogram
        guard histogram.sampleCount > 0,
            let p50 = histogram.percentile(0.50),
            let p90 = histogram.percentile(0.90),
            let p95 = histogram.percentile(0.95)
        else {
            return "None yet".lavaLocalized
        }

        func text(_ estimate: DNSLatencyHistogram.Estimate) -> String {
            switch estimate {
            case .atMost(let milliseconds):
                return "≤ \(milliseconds) ms"
            case .greaterThan(let milliseconds):
                let seconds = (Double(milliseconds) / 1_000)
                    .formatted(.number.precision(.fractionLength(0...1)))
                return "> \(seconds) s"
            }
        }

        return "p50 \(text(p50)) · p90 \(text(p90)) · p95 \(text(p95)) (n=\(histogram.sampleCount.formatted()))"
    }

    var tunnelHealthUpdatedText: String {
        tunnelHealth.updatedAt.formatted(date: .omitted, time: .shortened)
    }

    #if DEBUG || LAVA_QA_TOOLS
    var qaProbeSummaryText: String {
        configuration.qaProbeSet == nil ? "Off" : "Active"
    }

    var qaProbeDomains: [String] {
        configuration.qaProbeSet?.allDomains ?? QADomainProbeSet.hosted.allDomains
    }
    #endif

    // The rage-shake routing (canOpenPhoneQAFromRageShake, handleRageShake, the
    // confirm/cancel/dismiss handlers) lives on `reports` (DiagnosticsController)
    // since the Phase D4 peel.

    func performProtectionPrimaryAction() {
        performProtectionPrimaryAction(guardStatusPresentation.primaryAction)
    }

    // Authorization may suspend while a tier recovers. Dispatch the accepted action, never
    // reinterpret a Reconnect tap as Turn off after that recovery changes the current surface.
    // pinned: DNSResolverTierHealthSourceTests.testAuthorizationPreservesTheTappedRepairAndRejectsNewerOffIntent
    func performProtectionPrimaryAction(_ capturedAction: GuardStatusPresentation.PrimaryAction) {
        switch capturedAction {
        case .resume: resumeProtectionNow()
        case .reconnect: reconnectProtection()
        case .turnOff: turnOffProtection()
        case .turnOn:
            guard guardStatusPresentation.primaryAction == .turnOn else { return }
            toggleProtection()
        }
    }
}
