@preconcurrency import ActivityKit
import Foundation
import Darwin
import Network
@preconcurrency import NetworkExtension
import Security
@preconcurrency import UserNotifications
import LavaSecChainedUpstream
import LavaSecDNS
import LavaSecFilterPipeline
import LavaSecKit

// One concern of `PacketTunnelProvider`, split out of the former single-file provider.
// Stored state lives in LavaSecTunnel/PacketTunnelProvider.swift (extensions cannot declare
// stored properties, so a property declared beside its concern moved there); the other
// `PacketTunnelProvider+*.swift` files each hold one `// MARK:` section of the class, and the
// remaining files under Provider/ hold the types the single file declared outside it.

extension PacketTunnelProvider {
    // MARK: - Resident snapshot state & DNS runtime resets

    @discardableResult
    func replaceSnapshot(
        _ newSnapshot: any FilterRuntimeSnapshot,
        protectionPolicySnapshot newProtectionPolicySnapshot: (any FilterRuntimeSnapshot)? = nil,
        identity newIdentity: PreparedFilterSnapshotIdentity? = nil,
        failClosedDueToUnavailableSnapshot: Bool = false,
        residentHasEnabledFilters: Bool = false,
        generation: UInt64,
        onCommittedWhileHoldingQueue: ((_ replacedBlockAllResident: Bool) -> Void)? = nil
    ) -> Bool {
        // The reload-generation coordinator lives on dnsStateQueue; the snapshot pointer
        // lives on snapshotQueue. Gate the commit on the LIVE token while holding
        // dnsStateQueue, then swap under snapshotQueue. Comparing against the live token
        // (not merely a "highest committed" high-water mark) rejects a stale load as soon as a newer reload
        // has been *requested* — even before that newer load has committed anything —
        // so a slow stale decode can't briefly reinstall an older/permissive snapshot
        // for the new configuration. Holding dnsStateQueue across the read+swap closes
        // the cross-queue gap (the token can only change on dnsStateQueue). `==` still
        // admits the one load that legitimately commits twice at the same generation
        // (fail-closed before decode, then the real snapshot) as long as no newer
        // reload has been requested in between. Ordering is always
        // dnsStateQueue -> snapshotQueue (snapshotQueue is a leaf lock on the decision
        // hot path and never reaches back to dnsStateQueue), so this can't deadlock.
        // Reported back so OBSERVABILITY at the call sites (the incident ledger's
        // fail-closed records) can key on whether the commit actually LANDED — a
        // superseded reload's no-op must not record an incident that was never served.
        var didCommit = false
        let applyIfStillCurrent: () -> Void = { [self] in
            guard isCurrentSnapshotReloadGeneration(generation) else {
                return
            }
            // ASK THE OUTGOING RESIDENT WHAT IT DID, rather than which flag was set or what type
            // it was. Three paths install a block-all resident and each sets a DIFFERENT marker —
            // the unavailable marker, the pre-decode free, the startup bootstrap (whose marker is
            // deliberately false and whose identity is nil) — so enumerating them missed one each
            // time. Replacing that with a concrete-type test then missed a fail-closed snapshot
            // WRAPPED for a resolver change, which still blocks every lookup (Codex review, PR
            // #645). `blocksEveryLookup` is the property itself: the wrapper forwards it, and the
            // protocol requires it with no default so a future wrapper cannot silently answer no.
            var replacedBlockAllResident = false
            snapshotQueue.sync {
                replacedBlockAllResident = snapshot.blocksEveryLookup
                snapshot = newSnapshot
                protectionPolicySnapshot = newProtectionPolicySnapshot ?? newSnapshot
                residentSnapshotIdentity = newIdentity
                // Committed atomically with the snapshot under the SAME generation gate, so
                // the markers can never disagree with the resident (a stale-generation commit
                // that doesn't apply also doesn't flip the flags).
                residentFailClosedDueToUnavailableSnapshot = failClosedDueToUnavailableSnapshot
                // Leaving fail-closed is exactly the outcome the bootstrap broker exists to
                // produce, so its per-window budget resets here rather than persisting into a
                // healthy session. Placed on the COMMIT, not the request, so a superseded
                // reload cannot clear a window that is still open.
                if !failClosedDueToUnavailableSnapshot {
                    resetBrokeredBootstrapHostnames()
                }
                residentSnapshotHasEnabledFilters = residentHasEnabledFilters
            }
            didCommit = true
            // Commit-ordered work, INSIDE the same dnsStateQueue hold as the generation gate above.
            // A caller that reacquires the queue after this function returns is not ordered against
            // it: the queue is released in between, so a newer reload can commit and record first
            // and the older task then overwrites with its stale value — an older loosening followed
            // by a newer tightening leaves the LOWER counts recorded while the tighter snapshot is
            // resident, and the next genuine loosening compares against a baseline that was never
            // served (Codex review, PR #645). Runs only when the commit actually landed.
            onCommittedWhileHoldingQueue?(replacedBlockAllResident)
            // Recovery must clear its banner even when chained mode has no periodic probe.
            scheduleProtectionNotificationIfNeeded()
        }

        if DispatchQueue.getSpecific(key: dnsStateQueueSpecificKey) == true {
            applyIfStillCurrent()
        } else {
            dnsStateQueue.sync(execute: applyIfStillCurrent)
        }
        return didCommit
    }

    func currentResidentSnapshotIdentity() -> PreparedFilterSnapshotIdentity? {
        snapshotQueue.sync { residentSnapshotIdentity }
    }

    // Generation-gated clear of the snapshot-unavailable marker. The keep-resident and
    // filters-disabled reload branches run on a detached task OUTSIDE replaceSnapshot's
    // generation gate, so an UNGATED clear here could erase a newer reload's true marker
    // (committed via replaceSnapshot) after this older reload was already superseded —
    // re-arming the self-reconnect loop this change suppresses. Gate the clear on the live
    // token under the same dnsStateQueue -> snapshotQueue ordering as replaceSnapshot so a
    // stale reload can never clear a fresher commit's marker.
    func clearResidentFailClosedDueToUnavailableSnapshot(ifCurrentGeneration generation: UInt64) {
        let applyIfStillCurrent: () -> Void = { [self] in
            guard isCurrentSnapshotReloadGeneration(generation) else {
                return
            }
            snapshotQueue.sync { residentFailClosedDueToUnavailableSnapshot = false }
            // Leaving fail-closed by ANY route retires the window's broker budget.
            resetBrokeredBootstrapHostnames()
            scheduleProtectionNotificationIfNeeded()
        }

        if DispatchQueue.getSpecific(key: dnsStateQueueSpecificKey) == true {
            applyIfStillCurrent()
        } else {
            dnsStateQueue.sync(execute: applyIfStillCurrent)
        }
    }

    func isResidentFailClosedDueToUnavailableSnapshot() -> Bool {
        snapshotQueue.sync { residentFailClosedDueToUnavailableSnapshot }
    }

    func currentResidentSnapshotHasEnabledFilters() -> Bool {
        snapshotQueue.sync { residentSnapshotHasEnabledFilters }
    }

    // Reads only the on-disk compact artifact header (no rule-table decode) and
    // returns true when decoding it would reproduce the resident snapshot for
    // the current configuration — i.e. the reload is a no-op and the
    // multi-megabyte decode (and its 2x-resident memory peak) can be skipped.
    func residentSnapshotSatisfiesReload(configuration: AppConfiguration) -> Bool {
        guard let residentIdentity = currentResidentSnapshotIdentity() else {
            return false
        }

        // A resident snapshot compiled from EXACTLY the inputs this reload would compile
        // from (same configuration inputs + same cached-catalog source versions/hashes)
        // already satisfies the reload even when NO on-disk artifact is reusable — the
        // stale-store state UR-48 exposed, where the artifact store lags the cached
        // catalog and the tunnel compiled in-extension. Identity is stamped from
        // (configuration, cachedCatalog) at compile, so identical inputs reproduce the
        // resident byte-for-byte; without this gate every appMessage reload repeats the
        // same streaming compile (observed 6.9 s / 356 k rules on device) and its
        // compile-peak for an identical result. A fail-closed resident commits with a
        // nil identity and a last-known-good resident carries stale source hashes, so
        // neither can satisfy this gate and recovery reloads still run.
        if !configuration.enabledBlocklistIDs.isEmpty,
           residentIdentity.resolverTransport == configuration.resolverPreset.transport,
           let cachedCatalog = loadCachedCatalogMetadata(),
           residentIdentity.hasSameSnapshotInputs(
               as: PreparedFilterSnapshotIdentity.make(configuration: configuration, catalog: cachedCatalog)
           ) {
            return true
        }

        let compactSummary = readCompactSnapshotSummary(configuration: configuration)
        // With no enabled subscription lists and no reusable compact artifact,
        // loadCompiledSnapshot builds directly from configuration.filterSnapshot().
        // That snapshot has no catalog-derived rule tables, so matching configuration
        // inputs + resolver transport prove it is still identical even when the cached
        // catalog identity moved. This covers pass-through and manual-domain-only
        // residents without flushing live DNS for the same direct-build result.
        if configuration.enabledBlocklistIDs.isEmpty,
           compactSummary == nil,
           !hasReusablePreparedSnapshotCandidate(configuration: configuration),
           residentIdentity.hasSameConfiguration(as: configuration) {
            return true
        }

        guard let summary = compactSummary else {
            return false
        }

        return summary.canReuseForProtectionStartup(
            configuration: configuration,
            cachedCatalog: loadCachedCatalogMetadata()
        ) && summary.identity.hasSameSnapshotInputs(as: residentIdentity)
    }

    // Prepared JSON has no cheap embedded header, so do not decode it merely to
    // decide whether a reload is a no-op: that would recreate the memory peak the
    // pre-decode gate exists to avoid. Its small manifest is enough to conservatively
    // rule the direct-build shortcut OUT. A candidate passing the same manifest,
    // device-budget, and tier-budget pre-gates as reusablePreparedSnapshot must let
    // the real reload inspect it, because it may carry catalog-derived guardrail rules
    // that configuration.filterSnapshot() does not.
    private func hasReusablePreparedSnapshotCandidate(configuration: AppConfiguration) -> Bool {
        let cachedCatalog = loadCachedCatalogMetadata()

        var stores: [FilterArtifactStore] = []
        if let resolved = readableArtifactStore() {
            stores.append(resolved)
        }
        if let containerURL = LavaSecAppGroup.containerURL {
            let rootStore = FilterArtifactStore(directoryURL: containerURL)
            if stores.first?.directoryURL != rootStore.directoryURL {
                stores.append(rootStore)
            }
        }
        if let tunnelCompiledStore = retainedTunnelCompiledArtifactStoreIfPresent() {
            stores.append(tunnelCompiledStore)
        }

        for store in stores {
            guard FileManager.default.fileExists(atPath: store.preparedSnapshotURL.path),
                  let manifest = (try? store.loadManifest()).flatMap({ $0 }),
                  manifest.reuseRejectionReason(
                      configuration: configuration,
                      cachedCatalog: cachedCatalog
                  ) == nil
            else {
                continue
            }

            let ruleCount = manifest.summary.blockRuleCount
                + manifest.summary.allowRuleCount
                + manifest.summary.guardrailRuleCount
            guard !FilterSnapshotMemoryBudget.exceedsBudget(ruleCount: ruleCount),
                  let tierBudgetRuleCount = manifest.summary.tierBudgetRuleCount,
                  FilterRuleBudget.fitsTierBudget(
                      compiledTotal: tierBudgetRuleCount,
                      maxFilterRules: configuration.limits.maxFilterRules
                  )
            else {
                continue
            }
            return true
        }
        return false
    }

    /// Resolve the artifact store the tunnel should READ from: the pointer-named
    /// versioned directory if a pointer is published and its dir exists, else the
    /// legacy root. `readableStore()` falls back to root for no-pointer / first launch
    /// / a whole-dir GC (re-resolved next pass). The app no longer dual-writes root:
    /// `persistArtifacts` writes only versioned dirs + the pointer (test-asserted), and the
    /// legacy root is deliberately left unswept — so under the current build the root store
    /// only ages, and a FRESH root can only come from a rollback to an old root-writing
    /// build. The root retry stays correct either way: every root read is identity-gated
    /// against the live config.
    /// `loadCompiledSnapshot` additionally retries the root store in the SAME pass when
    /// the resolved store misses (rejected identity, or a nil read from a dir GC'd in
    /// the post-resolve / pre-open window). Resolve-once is intra-`loadCompiledSnapshot`;
    /// the reload gates resolve independently but `readCompactSnapshotSummary` applies
    /// the same [pointer-resolved, root] fallback and returns only a summary reusable
    /// for the live config — so the no-op / over-budget gates never act on a stale
    /// shadow (a cross-gate generation skew costs at most a redundant decode, never a
    /// wrong fail-closed or torn rules).
    ///
    /// Device-gated (LAV-90 Task 6) GC-unlink safety has two distinct arguments:
    /// - compact (`.mappedIfSafe`): the mapping pins the file inode past an unlink (no
    ///   SIGBUS), and content-addressed immutability means a published dir is never
    ///   rewritten/truncated in place — an in-place `ftruncate` of a mapped file is the
    ///   only Darwin op that faults mapped pages past EOF, and it cannot happen here.
    /// - prepared (eager `Data(contentsOf:)`): the `open()` fd pins the inode so a
    ///   mid-read unlink completes against the orphaned inode; a pre-open unlink ENOENTs
    ///   to nil and retries root / fails closed.
    /// The mmap-survives-unlink assumption (and the real flap rate under burst) is still
    /// pending on-device validation with a rapid-publish-burst stress against a MAP-LARGE
    /// artifact. (The root dual-write this note originally gated is already dropped on the
    /// writer side; the validation matters on its own for the pointer-dir read path.)
    func readableArtifactStore() -> FilterArtifactStore? {
        guard let containerURL = LavaSecAppGroup.containerURL else {
            return nil
        }
        return FilterArtifactStore(directoryURL: containerURL).readableStore()
    }

    func readCompactSnapshotSummary(configuration: AppConfiguration) -> CompactFilterSnapshotSummary? {
        let cachedCatalog = loadCachedCatalogMetadata()

        var stores: [FilterArtifactStore] = []
        if let resolved = readableArtifactStore() {
            stores.append(resolved)
        }
        if let containerURL = LavaSecAppGroup.containerURL {
            let rootStore = FilterArtifactStore(directoryURL: containerURL)
            if stores.first?.directoryURL != rootStore.directoryURL {
                stores.append(rootStore)
            }
        }
        // Use the loader's candidate order, including the retained tunnel compile.
        if let tunnelCompiledStore = retainedTunnelCompiledArtifactStoreIfPresent() {
            stores.append(tunnelCompiledStore)
        }

        // An unusable candidate cannot justify discarding the resident before decode.
        for store in stores {
            guard let data = try? Data(contentsOf: store.compactSnapshotURL, options: [.mappedIfSafe]),
                  let summary = try? CompactFilterSnapshot.readSummary(from: data)
            else {
                continue
            }
            if summary.canReuseForProtectionStartup(configuration: configuration, cachedCatalog: cachedCatalog),
               !FilterSnapshotMemoryBudget.exceedsBudget(ruleCount:
                    summary.blockRuleCount + summary.allowRuleCount + summary.guardrailRuleCount),
               FilterRuleBudget.fitsTierBudget(recordedTotal: summary.tierBudgetRuleCount,
                                               maxFilterRules: configuration.limits.maxFilterRules) {
                return summary
            }
        }
        return nil
    }

    func replaceSnapshotResolver(_ resolver: DNSResolverPreset) {
        snapshotQueue.sync {
            snapshot = ResolverAdjustedRuntimeSnapshot(base: snapshot, resolver: resolver)
            protectionPolicySnapshot = ResolverAdjustedRuntimeSnapshot(base: protectionPolicySnapshot, resolver: resolver)
        }
    }

    func refreshDNSRuntimeAfterSnapshotOrConfigurationChange() {
        let resolverIdentifier = currentResolverRuntimeConfiguration().cacheIdentifier
        if let activeResolverRuntimeIdentifier,
           activeResolverRuntimeIdentifier != resolverIdentifier {
            resetResolverRuntimeStateOnDNSQueueIfNeeded(identifier: resolverIdentifier)
            return
        }

        resetDNSRuntimeForProtectionPolicyChange(reason: "snapshot-or-configuration-changed")
    }

    func resetDNSRuntimeForProtectionPolicyChange(reason: String) {
        guard DispatchQueue.getSpecific(key: dnsStateQueueSpecificKey) == true else {
            dnsStateQueue.async { [weak self] in
                self?.resetDNSRuntimeForProtectionPolicyChange(reason: reason)
            }
            return
        }

        resolverRuntimeGeneration += 1
        let pendingResponses = drainPendingDNSResponses()
        dnsResponseCache.removeAll()
        clearEndpointHostnameNormalizationCache()
        applyResolverHealthEvent(
            .resolverRuntimeResetOccurred(
                kind: .protectionPolicyRefresh,
                reason: reason,
                occurredAt: Date()
            )
        )
        writeServerFailures(for: pendingResponses, reason: reason)
    }

    func resetResolverRuntimeStateIfNeeded(identifier: String) {
        let pendingResponses = dnsStateQueue.sync {
            collectPendingResponsesAndResetResolverRuntime(
                identifier: identifier,
                reason: "resolver-configuration-changed"
            )
        }

        writeServerFailures(for: pendingResponses, reason: "resolver-configuration-changed")
    }

    private func resetResolverRuntimeStateOnDNSQueueIfNeeded(identifier: String) {
        let pendingResponses = collectPendingResponsesAndResetResolverRuntime(
            identifier: identifier,
            reason: "resolver-configuration-changed"
        )
        writeServerFailures(for: pendingResponses, reason: "resolver-configuration-changed")
    }

    func resetResolverRuntimeForTunnelLifecycle(reason: String) {
        let abandoned: [PendingDNSResponse] = dnsStateQueue.sync {
            activeResolverRuntimeIdentifier = nil
            resolverRuntimeGeneration += 1
            dnsResponseCache.removeAll()
            clearEndpointHostnameNormalizationCache()
            let drained = drainPendingDNSResponses()
            resolverBackoffStateQueue.sync {
                resolverBackoffPolicy.reset()
            }
            return drained
        }
        // Backstop for a start without prior teardown; normal teardown already drains waiters.
        // Trace and drop any old-flow batch rather than writing it into the new lifecycle
        // (PR #508, #620). Log outside the state queue's critical section.
        recordUnansweredDNSBatch(
            reason: "lifecycle-reset-abandoned-\(reason)", pendingResponses: abandoned)

        dohResolver.resetSession()
        dotResolver.resetConnections()
        doqResolver.resetConnections()
        // Re-arm the DoQ transport for the lifecycle now starting — the other half of the
        // `cancel()` in cleanUpTunnelRuntimeAfterStop, which leaves it refusing work for as
        // long as the tunnel is down. This is the one place it belongs: called only from
        // startTunnel, and per LIFECYCLE, which is the scope being restored.
        //
        // NOT a guarantee that nothing spans a stop/start, which is what this comment used to
        // claim: re-admission here is unconditional, so a lane whose queued cancellation runs
        // AFTER this line can still advance its resolution into this session (Codex P2 on
        // PR #522 — the same residual documented at `DoQTransport.cancel()`, which I had
        // corrected there and not here). Generation-tagged admission is what closes it, and
        // it is a separate slice; this pairing only bounds the window.
        // Ordering inside this function is irrelevant (resetConnections cannot rebuild a
        // pool by itself) but ordering within startTunnel is not — this runs before the
        // network settings, so nothing can be admitted to a still-quiesced transport.
        // pinned: PacketTunnelDNSRuntimeSourceTests.testTunnelStartClearsResolverRuntimeAndRefreshesEncryptedResolverSessions
        doqResolver.resume()
        dotResolver.resume()
    }

    func resetResolverTransientState() {
        dohResolver.resetSession()
        dotResolver.resetConnections()
        doqResolver.resetConnections()
    }

    func collectPendingResponsesAndResetResolverRuntime(
        identifier: String,
        reason: String,
        force: Bool = false
    ) -> [PendingDNSResponse] {
        guard force || activeResolverRuntimeIdentifier != identifier else {
            return []
        }

        // Don't let a stale per-query identifier clobber a newer runtime. The non-forced
        // (per-query, lazy) reset carries the resolver identifier `handle` captured when it
        // classified the packet, then reused by `forward`. If a concurrent authoritative reload
        // (snapshot/config change, fallback flip, network-path change) has since advanced BOTH
        // `appConfiguration` and the active runtime to a different resolver, honoring the captured
        // identifier here would flip the active runtime BACK to the resolver the config has already
        // moved away from — draining the new runtime's in-flight queries and clearing its cache,
        // only for the next query to flip it forward again. Every forced reset and the authoritative
        // apply path (`refreshDNSRuntimeAfterSnapshotOrConfigurationChange`) pass the CURRENT
        // identifier, so this drops ONLY the stale lazy case: leave the current runtime in place —
        // the racing query then fails its `isActiveResolverRuntime` gate and is retried under the
        // current resolver. dnsStateQueue-confined; the plan rebuild runs only on this rare
        // active-differs path, never the steady-state no-op returned above.
        if !force, identifier != currentResolverRuntimeConfiguration().cacheIdentifier {
            return []
        }

        if resolverTierContextIdentity != currentResolverTierContextIdentity() {
            resetResolverTierEvidence()
        }
        let previousIdentifier = activeResolverRuntimeIdentifier
        let isInitialActivation = previousIdentifier == nil
        activeResolverRuntimeIdentifier = identifier
        // Supply only the current PRIMARY-only identity. The coordinator owns the prior identity,
        // so fallback-only runtime resets cannot accidentally rewrite the comparison baseline.
        // Taken MODE-INSENSITIVELY (COH-1): a Device-DNS fallback-mode flip must not look like a
        // configured-primary change or clear the rejected-response streak.
        let currentPrimaryIdentifier = currentResolverRuntimeConfiguration(ignoresDeviceDNSFallbackMode: true).primaryCacheIdentifier
        resolverRuntimeGeneration += 1
        let pendingResponses = drainPendingDNSResponses()
        dnsResponseCache.removeAll()
        clearEndpointHostnameNormalizationCache()
        resolverBackoffStateQueue.sync {
            resolverBackoffPolicy.reset()
        }
        resetResolverTransientState()
        // dnsStateQueue-confined; this reset is the acceptance boundary for its pre-warms
        // (PR #524, same rule as the network-settle site).
        prewarmResolverBootstrapIfNeeded(admittedAtEpoch: currentResolverAdmissionEpoch())
        applyResolverHealthEvent(
            .resolverRuntimeResetOccurred(
                kind: .fullRuntime(
                    currentPrimaryIdentifier: currentPrimaryIdentifier,
                    recordsObservableReset: force || !isInitialActivation
                ),
                reason: reason,
                occurredAt: Date()
            )
        )
        return pendingResponses
    }

    /// Trace ONE query that ended without the client receiving a usable answer.
    ///
    /// Every seam that answers SERVFAIL or drops a request calls this, so a capture can show
    /// what the aggregate counters structurally cannot: those counters describe resolutions the
    /// tunnel COMPLETED, and a query that is dropped or synthesized-failed never becomes one.
    /// The 2026-08-29 reports are exactly that blind spot — `tunnelDNSAnswered` 195 /
    /// `tunnelDNSUnanswered` 0 and every failure counter at zero, for a session where a domain
    /// the user asked for did not resolve.
    ///
    /// NO DOMAIN, deliberately: this log ships in Release and TestFlight feedback and its
    /// standing rule is that no event records a queried name (#21). The reason and the address
    /// family are what remain, and they are enough — `domain-history` already carries the name
    /// against a timestamp, so a failure here identifies the domain by lining the two up, and
    /// the A/AAAA split says whether the losses are one family or both without ever naming one.
    /// QA-GATED, unlike the device-log appends around it. `wake` and `pending-dns-servfail` are
    /// deliberately un-gated so Release and TestFlight feedback carry them (#21); this is NEW
    /// telemetry and what reaches Release is a decision to take on its own evidence, not one to
    /// inherit by sitting next to them. The gate is `LAVA_QA_TOOLS`, which project.yml defines
    /// for the QA configuration — the build the field captures come from — so nothing is lost
    /// where it is being read. Keeping the function itself unconditional keeps every call site
    /// free of `#if`, so a seam cannot be added inside a gate and silently lose its trace.
    /// pinned: PacketTunnelDNSRuntimeSourceTests.testEveryUnansweredQuerySeamLeavesATrace
    func recordUnansweredDNSQuery(
        reason: String, query: Data, clientQueries: Int = 1, parseFailureCategory: String? = nil
    ) {
        #if DEBUG || LAVA_QA_TOOLS
        let shape = DNSQuestionAddressShape.shape(ofQuery: query)?.rawValue ?? "unparsed"
        // Fixed reason, shape and parse category keep distinct failure boundaries visible
        // while the existing bounded suppressor prevents per-query log growth.
        let diagnosticKey = "\(reason)|\(shape)|\(parseFailureCategory ?? "none")"
        guard case .emit(let suppressedRepeats, let suppressedWeight) =
            unansweredDNSQuerySuppressor.admit(
                diagnosticKey, weight: clientQueries, now: Date())
        else {
            return
        }

        var details = [
            "reason": reason,
            "recordShape": shape,
            // How many CLIENT queries this one resolution settles. Duplicates coalesce onto a
            // single upstream resolution, so one event can stand for several waiting clients
            // and a per-event count would undercount the failure by an arbitrary factor during
            // a retry storm (Codex P2, PR #620).
            "clientQueries": "\(clientQueries)"
        ]
        if let parseFailureCategory { details["parseFailureCategory"] = parseFailureCategory }
        if suppressedRepeats > 0 {
            details["suppressedRepeats"] = "\(suppressedRepeats)"
            // The WEIGHT, not just the count: a suppressed occurrence can stand for many
            // coalesced client queries, and reporting "1 repeat" for a 20-client batch would
            // let the outage total read arbitrarily low.
            details["suppressedClientQueries"] = "\(suppressedWeight)"
        }
        LavaSecDeviceDebugLog.append(
            component: "tunnel", event: "dns-query-unanswered", details: details)
        #endif
    }

    /// Emits whatever the unanswered-query suppressor is still holding, so a burst that stopped
    /// before its interval elapsed does not strand its tail.
    ///
    /// Without it the tail is only reported when the SAME failure recurs, so a short outage
    /// that recovers and never repeats would read as a single occurrence however large it was
    /// (Codex P2, PR #620).
    ///
    /// Called from four seams, because a periodic checkpoint alone is not enough:
    ///
    /// - the 60 s focus poll — the steady-state tick;
    /// - the app's health-flush message — the boundary a Feedback capture awaits, since a report
    ///   taken between two polls would otherwise export only the burst's first occurrence;
    /// - `sleep`, synchronously, because queued work is not guaranteed to run once iOS has
    ///   suspended the process and a jetsam takes the held counts with it;
    /// - the END of `cleanUpTunnelRuntimeAfterStop`, which is the teardown funnel BOTH stop
    ///   shapes reach. Last there, not in `stopTunnel`: the teardown itself produces traced
    ///   failures (the cancelled bootstrap wait SERVFAILs its batch), so an earlier flush would
    ///   leave those suppressed with nothing after them.
    ///
    /// Every seam is safe from any queue: the suppressor holds its own lock and the log append
    /// is best-effort.
    /// pinned: PacketTunnelDNSRuntimeSourceTests.testTheSuppressedTailIsFlushedAtEveryCaptureBoundary
    /// pinned: RepeatedEventSuppressorTests.testFlushHandsBackStrandedCountsWithoutResettingTheClock
    func flushSuppressedUnansweredDNSQueries() {
        #if DEBUG || LAVA_QA_TOOLS
        for entry in unansweredDNSQuerySuppressor.flushSuppressed() {
            // All three fields are fixed diagnostic vocabulary, never query content.
            let parts = entry.key.split(separator: "|", maxSplits: 2).map(String.init)
            var details = [
                    "reason": parts.first ?? entry.key,
                    "recordShape": parts.count > 1 ? parts[1] : "unparsed",
                    "clientQueries": "0",
                    "suppressedRepeats": "\(entry.suppressedRepeats)",
                    "suppressedClientQueries": "\(entry.suppressedWeight)"
            ]
            if parts.count > 2, parts[2] != "none" { details["parseFailureCategory"] = parts[2] }
            LavaSecDeviceDebugLog.append(
                component: "tunnel", event: "dns-query-unanswered", details: details)
        }
        #endif
    }

    /// Traces a whole batch of client queries that ended without a usable answer, ONE EVENT PER
    /// ADDRESS FAMILY rather than one per request.
    ///
    /// Per-request would defeat the trace: a 40-request drain puts 40 lines into a 40-entry
    /// report tail and evicts the lifecycle and reset lines that explain the drain. Per-batch
    /// alone would lose the A/AAAA split, which is the distinction the whole trace exists to
    /// make — a drain that is all AAAA is a different finding from one that is all A. Grouping
    /// keeps both: each event carries its share of the batch as `clientQueries`, and the shapes
    /// are emitted in sorted order so two captures of the same drain diff cleanly.
    /// pinned: PacketTunnelDNSRuntimeSourceTests.testEveryDroppedBatchIsTracedByAddressFamily
    func recordUnansweredDNSBatch(reason: String, pendingResponses: [PendingDNSResponse]) {
        var queriesByShape: [String: (query: Data, count: Int)] = [:]
        for pending in pendingResponses {
            let payload = pending.request.dnsPayload
            let shape = DNSQuestionAddressShape.shape(ofQuery: payload)?.rawValue ?? "unparsed"
            queriesByShape[shape, default: (payload, 0)].count += 1
        }
        for shape in queriesByShape.keys.sorted() {
            guard let entry = queriesByShape[shape] else { continue }
            recordUnansweredDNSQuery(reason: reason, query: entry.query, clientQueries: entry.count)
        }
    }

    func writeServerFailures(for pendingResponses: [PendingDNSResponse], reason: String? = nil) {
        var failedClients: [PendingDNSResponse] = []
        for pending in pendingResponses {
            guard let failure = DNSResponseFactory.serverFailure(for: pending.request.dnsPayload) else {
                failedClients.append(pending)
                continue
            }
            let answer = responseForPendingForward(failure, pending: pending)
            if !answer.isAnsweredByBlock || answer.response == nil { failedClients.append(pending) }
            guard let response = answer.response else { continue }
            writeDNSResponse(response, for: pending.request, protocolNumber: pending.protocolNumber,
                             tracesDiscardedAnswer: answer.isAnsweredByBlock)
        }
        guard !failedClients.isEmpty else { return }
        LavaSecDeviceDebugLog.append(component: "tunnel", event: "pending-dns-servfail", details: [
            "reason": reason ?? "resolver-failure",
            "pendingResponses": "\(failedClients.count)"
        ])
        // A client served a block received a usable answer; only actual failures enter this batch.
        // pinned: PacketTunnelDNSRuntimeSourceTests.testEveryDroppedBatchIsTracedByAddressFamily
        recordUnansweredDNSBatch(reason: "servfail-\(reason ?? "resolver-failure")", pendingResponses: failedClients)
    }
}
