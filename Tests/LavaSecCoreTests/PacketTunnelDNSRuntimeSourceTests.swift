import Foundation
import LavaSecCore
import XCTest

final class PacketTunnelDNSRuntimeSourceTests: XCTestCase {
    // PacketTunnelProvider is an NE extension type with private queue-confined DNS internals.
    // This suite intentionally pins source-level contracts for wiring that cannot be safely
    // exercised from the SwiftPM test host without adding production-only seams.
    func testHealthAndDiagnosticsWritesAreCoalescedNotPerEvent() throws {
        let source = try readSource(.packetTunnelProvider)

        // The dirty + interval-throttle + debounced-flush machinery (the disk-churn
        // guard against the heat-regression class, P0) is now the extracted, unit-
        // tested DebouncedPersistenceController (see DebouncedPersistenceControllerTests
        // for the cadence behavior). Both health and diagnostics must route through it
        // rather than writing per event; this pins the wiring so the coalescing path
        // can't silently regress back to inline per-event writes.
        XCTAssertTrue(source.contains("healthPersistence = DebouncedPersistenceController("))
        XCTAssertTrue(source.contains("diagnosticsPersistence = DebouncedPersistenceController("))
        XCTAssertTrue(source.contains("writeInterval: healthWriteInterval"))
        XCTAssertTrue(source.contains("writeInterval: diagnosticsWriteInterval"))
        XCTAssertTrue(source.contains("private let healthWriteInterval: TimeInterval = 30"))
        XCTAssertTrue(source.contains("private let diagnosticsWriteInterval: TimeInterval = 30"))

        // Mutations funnel into the controller's debounced flush; persist* delegates
        // the force/throttled write — there is no inline per-event disk write left.
        XCTAssertTrue(source.contains("healthPersistence.markDirty()"))
        XCTAssertTrue(source.contains("diagnosticsPersistence.markDirty()"))
        XCTAssertTrue(source.contains("healthPersistence.flush(force: force)"))
        XCTAssertTrue(source.contains("diagnosticsPersistence.flush(force: force)"))
    }

    /// A buffered best-effort DNS event append isn't in the SQLite table yet, so any drain
    /// that commits it WITHOUT a coupled same-pass prune can resurrect pre-clear rows —
    /// through the debounced write (prune-before-flush), through a contention-skipped prune
    /// whose closure still reported success (cancelling the dirty retry), or through the
    /// stop/sleep paths' bare terminal flush landing the retained batch with no later pass
    /// ever running (P1 chain: lavasec-ios#54 promotion review + PR #351 rounds 2-4). One
    /// primitive — `drainAndPruneDNSEventLog` — owns the coupling; these pins lock its
    /// internal order, its use at ALL three drain sites, and ban any bare flush that would
    /// bypass it.
    /// - pinned: DNSEventLogTests.testFlushingBeforePruneRemovesABufferedPreClearEvent
    /// - pinned: DNSEventLogTests.testPruningBeforeFlushLeavesABufferedPreClearEventToBeResurrectedLater
    /// - pinned: DNSEventLogTests.testFlushReportsFailureWhenTheBatchCommitCannotAcquireTheWriteLock
    func testDiagnosticsPersistenceFlushesBufferedDNSEventsBeforePruning() throws {
        let source = try readSource(.packetTunnelProvider)

        // The primitive itself: prune only ever runs AFTER a successful drain (guard shape).
        let helperBlock = try sourceBlock(
            in: source,
            startingAt: "private func drainAndPruneDNSEventLog(",
            endingBefore: "// MARK: - Configuration & device-DNS state accessors"
        )
        let drainGuardRange = try XCTUnwrap(helperBlock.range(of: "guard drained else"))
        let pruneRange = try XCTUnwrap(helperBlock.range(of: "try dnsEventLog.prune(before: cutoff)"))
        XCTAssertLessThan(
            drainGuardRange.lowerBound,
            pruneRange.lowerBound,
            "the buffer must drain successfully before the prune runs, or a buffered pre-clear event can be reinserted after the clear"
        )
        // The prune's OWN failure must surface in the return value too: a `try?` here reports
        // a pass complete with pre-clear rows freshly committed and unpruned, clearing the
        // dirty flag that guarantees the retry (PR #351 round 5).
        XCTAssertFalse(
            helperBlock.contains("try? dnsEventLog.prune"),
            "a swallowed prune failure after a successful drain silently completes an incomplete pass"
        )

        // The debounced write closure routes through the primitive and folds its result into
        // the closure's return value — a skipped prune must keep the controller dirty so the
        // pass is guaranteed to re-run (PR #351 round 3).
        let writeBlock = try sourceBlock(
            in: source,
            startingAt: "private lazy var diagnosticsPersistence = DebouncedPersistenceController(",
            endingBefore: "private let dohResolver = DoHTransport("
        )
        XCTAssertTrue(writeBlock.contains("let dnsEventLogPruneCompleted = self.drainAndPruneDNSEventLog(now: now, discardOnFailure: false)"))
        XCTAssertTrue(writeBlock.contains("return dnsEventLogPruneCompleted"))
        XCTAssertFalse(writeBlock.contains("return true"), "the closure must not unconditionally report success once a prune can be skipped")

        // The terminal paths use the SAME coupled primitive, in DISCARD mode: a failed
        // flush() retains its batch and arms an async retry that can commit pre-clear rows
        // in the teardown/pre-suspension window with no later prune (PR #351 rounds 4 and
        // 7) — so stop and sleep must pass discardOnFailure: true, and the debounced
        // closure (which HAS a guaranteed dirty-retained re-run) must not. A bare
        // `dnsEventLog?.flush()` anywhere in the provider is a drain decoupled from the
        // prune — banned outright.
        XCTAssertTrue(helperBlock.contains("discardOnFailure ? dnsEventLog.flushOrDiscard() : dnsEventLog.flush()"))
        let stopBlock = try sourceBlock(
            in: source,
            startingAt: "private func cleanUpTunnelRuntimeAfterStop(",
            endingBefore: "private static func errorDebugDetails("
        )
        XCTAssertTrue(stopBlock.contains("self.drainAndPruneDNSEventLog(discardOnFailure: true)"))
        let sleepBlock = try sourceBlock(
            in: source,
            startingAt: "override func sleep(",
            endingBefore: "override func wake("
        )
        XCTAssertTrue(sleepBlock.contains("self?.drainAndPruneDNSEventLog(discardOnFailure: true)"))
        XCTAssertFalse(source.contains("dnsEventLog?.flush()"), "every drain must go through drainAndPruneDNSEventLog so no commit can land without its coupled prune")
    }

    /// NRG: the DNS hot path (`readPackets` → `handle` → `forward`) runs for every
    /// inbound query while the tunnel is up, so steady-state CPU work there is the
    /// dominant always-on energy cost. These pins guard four reductions that remove
    /// per-query work without changing any observable behavior — they must not regress.
    func testDNSHotPathAvoidsRedundantPerQueryWork() throws {
        let source = try readSource(.packetTunnelProvider)

        // (1) `forward` reuses the resolver runtime configuration `handle` already
        // computed for the bootstrap/pause/filter decision instead of re-deriving it
        // — each derivation performs several blocking dnsStateQueue.sync reads, so the
        // old second call per forwarded query was pure redundant work on the hot path.
        let forwardBlock = try sourceBlock(
            in: source,
            startingAt: "private func forward(",
            endingBefore: "private func dispatchForwardResolution("
        )
        XCTAssertTrue(
            forwardBlock.contains("resolverConfiguration: ResolverRuntimeConfiguration,"),
            "forward must accept the resolverConfiguration handle already computed."
        )
        XCTAssertFalse(
            forwardBlock.contains("let resolverConfiguration = currentResolverRuntimeConfiguration()"),
            "forward must reuse handle's resolverConfiguration, not re-derive it (per-query queue hops)."
        )

        // (2) The per-query counter bumps (cache hit/miss/coalesce) update only stats
        // fields the connectivity assessment never reads, so they route through the
        // stats-only mark and must NOT re-run the full ProtectionConnectivityPolicy
        // cascade (which always produced the same severity — the Darwin nudge is deduped
        // by key anyway, so the post was already a no-op there).
        let recordCacheHitBlock = try sourceBlock(
            in: source,
            startingAt: "private func recordCacheHit",
            endingBefore: "private func recordCacheMiss"
        )
        let recordCacheMissBlock = try sourceBlock(
            in: source,
            startingAt: "private func recordCacheMiss",
            endingBefore: "private func recordCoalescedQuery"
        )
        let recordCoalescedBlock = try sourceBlock(
            in: source,
            startingAt: "private func recordCoalescedQuery",
            endingBefore: "private func recordUpstreamResult"
        )
        XCTAssertTrue(recordCacheHitBlock.contains("markHealthCountersUpdated()"))
        XCTAssertTrue(recordCacheMissBlock.contains("markHealthCountersUpdated()"))
        XCTAssertTrue(recordCoalescedBlock.contains("markHealthCountersUpdated()"))
        XCTAssertFalse(recordCacheHitBlock.contains("markHealthUpdated()"))
        XCTAssertFalse(recordCacheMissBlock.contains("markHealthUpdated()"))
        XCTAssertFalse(recordCoalescedBlock.contains("markHealthUpdated()"))

        let countersMarkBlock = try sourceBlock(
            in: source,
            startingAt: "private func markHealthCountersUpdated",
            endingBefore: "private func signalAppIfConnectivityStateChanged"
        )
        XCTAssertTrue(countersMarkBlock.contains("healthPersistence.markDirty()"))
        XCTAssertFalse(
            countersMarkBlock.contains("signalAppIfConnectivityStateChanged"),
            "The per-query stats mark must not re-run the connectivity cascade."
        )
        // The connectivity-relevant mark still reassesses and signals (unchanged).
        let healthMarkBlock = try sourceBlock(
            in: source,
            startingAt: "private func markHealthUpdated",
            endingBefore: "private func markHealthCountersUpdated"
        )
        XCTAssertTrue(healthMarkBlock.contains("signalAppIfConnectivityStateChanged()"))

        // (3) A cache hit must still route through the shared write-path normalizer. That
        // keeps the optional TTL cap and malformed-cache fail-closed fallback identical to
        // the upstream/coalesced paths, even when maximumAnswerTTL is nil.
        let cacheHitBlock = try sourceBlock(
            in: forwardBlock,
            startingAt: "if let cachedResponse = self.dnsResponseCache.cachedResponse",
            endingBefore: "self.recordCacheMiss()"
        )
        XCTAssertTrue(
            cacheHitBlock.contains("responseByApplyingMaximumAnswerTTL("),
            "Cache hits must use the shared TTL/well-formedness helper before writing."
        )
        XCTAssertTrue(
            cacheHitBlock.contains("DNSResponseFactory.serverFailure(for: dnsPayload)"),
            "Malformed cached packets must still fail closed before writing."
        )
        XCTAssertFalse(
            cacheHitBlock.contains("responseToWrite = cachedResponse"),
            "Cache hits must not bypass the shared write-path normalizer."
        )

        // (4) The bootstrap checks reuse the question domain already normalized in
        // parseQuestion instead of re-normalizing it per transport on every query.
        XCTAssertTrue(source.contains("let normalizedQuestionDomain = question.normalizedDomain"))

        // (5) Because (1) makes `forward` reuse the identifier `handle` captured, the
        // per-query (non-forced, lazy) runtime reset must NOT clobber a newer runtime that
        // a concurrent authoritative reload already installed: it is dropped when the
        // captured identifier no longer matches the freshly recomputed resident config.
        // Runs only on the rare active-differs path (the identity guard above it short-
        // circuits the steady-state no-op), so it adds no hot-path cost. Forced resets and
        // the authoritative apply path pass the current identifier and are unaffected.
        let runtimeResetBlock = try sourceBlock(
            in: source,
            startingAt: "private func collectPendingResponsesAndResetResolverRuntime(",
            endingBefore: "private func writeServerFailures("
        )
        XCTAssertTrue(
            runtimeResetBlock.contains("if !force, identifier != currentResolverRuntimeConfiguration().cacheIdentifier {"),
            "The lazy per-query resolver-runtime reset must skip a stale captured identifier so it can't clobber a newer runtime installed by a concurrent authoritative reload."
        )

        // (6) The ONE volatile plan input that is not covered by cacheIdentifier or the generation
        // guard — the device-resolver wedge bit behind `treatsResolverRejectionAsFallbackTrigger` —
        // must be re-read fresh onto the captured plan before resolving, so a query straddling a
        // Device-DNS wedge onset is still carried by the encrypted fallback instead of being handed
        // the wedged resolver's SERVFAIL/REFUSED as authoritative. Gated on `shouldFallbackToEncrypted`
        // so encrypted-primary resolvers keep the full per-query savings; the rest of the captured
        // plan (everything folded into cacheIdentifier) is still reused.
        XCTAssertTrue(
            forwardBlock.contains("recomputingResolverRejectionFallbackTrigger("),
            "forward must re-read the volatile wedge bit onto the captured plan so the encrypted-fallback safety net still engages at a wedge transition."
        )
    }

    /// NRG round 2: companion reductions to the hot-path work trimmed in #285. These remove
    /// per-query / per-resolution redundant computation that provably produces the same result,
    /// without touching any validation gate, fail-closed check, or the #288 cache-hit guard.
    func testDNSHotPathAvoidsRedundantNormalizationAndEvidenceRecomputation() throws {
        let source = try readSource(.packetTunnelProvider)

        // (1) The bootstrap checks (which run FIRST on every DNS packet, including cache hits)
        // must normalize resolver endpoint hostnames through the memoizing helper, not re-run
        // `DomainName.normalize` per query per endpoint. Resolver hostnames are stable for a
        // tunnel session, so the memo never goes stale and is naturally bounded. All three
        // transports are pinned (each scoped to its own function) so none can silently regress
        // to the inline per-query normalize.
        let bootstrapBoundaries: [(function: String, endMarker: String)] = [
            ("dohBootstrapResponse", "private func doqBootstrapResponse"),
            ("doqBootstrapResponse", "private func dotBootstrapResponse"),
            ("dotBootstrapResponse", "private func startPeriodicResolverSmokeProbe")
        ]
        for (function, endMarker) in bootstrapBoundaries {
            let block = try sourceBlock(
                in: source,
                startingAt: "private func \(function)",
                endingBefore: endMarker
            )
            XCTAssertTrue(
                block.contains("normalizedEndpointHostname("),
                "\(function) must normalize endpoint hosts via the memoizing helper, not inline DomainName.normalize per query."
            )
            XCTAssertFalse(
                block.contains("try? DomainName.normalize(endpoint"),
                "\(function) must not re-normalize endpoint hosts per query (use the memo)."
            )
        }
        // The memo helper itself exists and is the single normalization site for endpoint hosts.
        XCTAssertTrue(source.contains("private func normalizedEndpointHostname(_ hostname: String) -> String?"))
        let endpointHostMemoBlock = try sourceBlock(
            in: source,
            startingAt: "private func normalizedEndpointHostname(_ hostname: String) -> String?",
            endingBefore: "private func dohBootstrapResponse"
        )
        XCTAssertTrue(source.contains("private static let endpointHostnameNormalizationCacheLimit = 32"))
        XCTAssertTrue(
            endpointHostMemoBlock.contains("endpointHostnameNormalizationCache.count >= Self.endpointHostnameNormalizationCacheLimit"),
            "Endpoint-host memoization must have an explicit safety cap, not rely only on today's small caller set."
        )
        XCTAssertTrue(
            endpointHostMemoBlock.contains("endpointHostnameNormalizationCache.removeAll(keepingCapacity: true)"),
            "Endpoint-host memoization must evict before it can grow without bound."
        )
        XCTAssertTrue(source.contains("private func clearEndpointHostnameNormalizationCache()"))
        let policyResetBlock = try sourceBlock(
            in: source,
            startingAt: "private func resetDNSRuntimeForProtectionPolicyChange",
            endingBefore: "private func resetResolverRuntimeStateIfNeeded"
        )
        let lifecycleResetBlock = try sourceBlock(
            in: source,
            startingAt: "private func resetResolverRuntimeForTunnelLifecycle",
            endingBefore: "private func collectPendingResponsesAndResetResolverRuntime"
        )
        let collectedResetBlock = try sourceBlock(
            in: source,
            startingAt: "private func collectPendingResponsesAndResetResolverRuntime",
            endingBefore: "private func currentResolverPreset"
        )
        XCTAssertTrue(policyResetBlock.contains("clearEndpointHostnameNormalizationCache()"))
        XCTAssertTrue(lifecycleResetBlock.contains("clearEndpointHostnameNormalizationCache()"))
        XCTAssertTrue(collectedResetBlock.contains("clearEndpointHostnameNormalizationCache()"))

        // Organic response-quality classification is performed once by the response-free
        // coordinator completion and is covered behaviorally by the pure organic reducer tests.
    }

    func testDiagnosticsClearDedupGateReadsTheDurableStoreMarkerNotAnInMemoryIvar() throws {
        let source = try readSource(.packetTunnelProvider)

        // PST-1: the "already applied this clear" markers must be durable (on the
        // diagnostics store, persisted in the same file the clear mutates), never
        // in-memory ivars — those were nil in every fresh process, so the force-apply on
        // every start re-wiped all post-clear history/counts/uptime. Pin the gate to the
        // durable read and forbid a regression to the old ivars.
        XCTAssertTrue(source.contains("requestedAt > (diagnostics.lastAppliedDomainHistoryClearAt ?? .distantPast)"))
        XCTAssertTrue(source.contains("requestedAt > (diagnostics.lastAppliedFilteringCountsClearAt ?? .distantPast)"))
        XCTAssertTrue(source.contains("diagnostics.clearDomainHistory(clearedAt: requestedAt)"))
        XCTAssertFalse(source.contains("private var lastAppliedDiagnosticsClearAt"))
        XCTAssertFalse(source.contains("private var lastAppliedFilteringCountsClearAt"))

        // The IPC clear messages route through the SAME marker-gated apply as the poll + start
        // force-apply, so a clear is deduped against a concurrent poll apply (requestedAt > lastApplied)
        // instead of wiping a second time and destroying events recorded since (Codex #226). Both clear
        // messages share one handler; it must NOT clear unconditionally with Date().
        XCTAssertTrue(
            source.contains("case LavaSecAppGroup.clearDiagnosticsMessage, LavaSecAppGroup.clearFilteringCountsMessage:"),
            "The two IPC clear messages must share one handler routed through the marker-gated apply."
        )
        XCTAssertFalse(
            source.contains("self.diagnostics.clearDomainHistory(clearedAt: Date())"),
            "The IPC clear must route through applyDiagnosticsControlIfNeeded, not clear unconditionally with Date()."
        )
    }

    func testDeviceDNSRefreshUsesFallbackPolicyInsteadOfClearingOnEmptyCapture() throws {
        let source = try readSource(.packetTunnelProvider)
        let refreshBlock = try sourceBlock(
            in: source,
            startingAt: "private func refreshDeviceDNSResolverAddressesOnDNSQueue",
            endingBefore: "private static func currentSystemDNSServerAddresses()"
        )
        let setterBlock = try sourceBlock(
            in: source,
            startingAt: "private func setDeviceDNSResolverAddresses",
            endingBefore: "private func currentDeviceDNSFallbackModeActive()"
        )

        XCTAssertTrue(
            refreshBlock.contains("DeviceDNSFallbackPolicy.refreshedResolverAddresses"),
            "The tunnel should keep the last usable device DNS resolvers when iOS only reports Lava's tunnel DNS."
        )
        XCTAssertTrue(
            setterBlock.contains("DeviceDNSFallbackPolicy.refreshedResolverAddresses"),
            "The non-queue setter should use the same empty-capture policy as DNS-queue refreshes."
        )
        XCTAssertTrue(
            setterBlock.contains("preserveOnEmptyCapture"),
            "The setter should make empty-capture preservation explicit."
        )
        let pathBlock = try sourceBlock(
            in: source,
            startingAt: "private func handleNetworkPathUpdate(",
            endingBefore: "private func reapplyTunnelNetworkSettings("
        )
        XCTAssertTrue(
            pathBlock.containsInOrder([
                "refreshDeviceDNSResolverAddressesOnDNSQueue(",
                "reason: \"network-path-changed\""
            ]),
            "Network changes should keep the last usable Device DNS capture when iOS briefly reports only Lava's tunnel DNS."
        )
        XCTAssertFalse(
            refreshBlock.contains("deviceDNSResolverAddresses = addresses"),
            "Assigning the raw capture directly can wipe fallback DNS while the tunnel is active."
        )
        // Canary: the negative pins above key on these identifiers - if a rename removes
        // one from the pinned source, those pins pass vacuously. Fail here instead, then
        // re-anchor both sides to the new name.
        XCTAssertTrue(source.contains("deviceDNSResolverAddresses"))
    }

    func testDeviceDNSCaptureExhaustionPreservesResolversAndVerifiesByProbe() throws {
        let source = try readSource(.packetTunnelProvider)
        let retryBlock = try sourceBlock(
            in: source,
            startingAt: "private func runDeviceDNSCaptureRetry",
            endingBefore: "private func cancelDeviceDNSCaptureRetry"
        )

        // UR-55 (plans/2026-07-11-ur-55-device-dns-fallback-under-tunnel-plan.md):
        // a masked exhaustion carries ZERO handoff evidence — steady-state masking makes
        // every armed cycle exhaust on a chronically-masked stable network. Exhaustion
        // must stay observable but must never mutate the captured addresses; the
        // discriminator is a wire probe of the preserved primary, whose outcome flows
        // through the ordinary smoke-evidence chain (INV-DNS-5).
        XCTAssertTrue(
            retryBlock.contains("event: \"device-dns-capture-retry-exhausted\""),
            "Exhaustion must still be observable in the device log."
        )

        // The exhaustion branch is everything after the cycle's continuation gate.
        let gateRange = try XCTUnwrap(
            retryBlock.range(of: "cycle.shouldContinue(capturedNonEmpty: false)"),
            "Expected the cycle's retry-continuation gate in runDeviceDNSCaptureRetry."
        )
        let exhaustionBlock = String(retryBlock[gateRange.upperBound...])

        // The 1.2.1 regression shape: `preserveOnEmptyCapture: !routesToEncryptedFallback`
        // dropped a working resolver on chronically-masked stable networks and the empty
        // list blinded the recovery probes (nothing left to probe). No address-list
        // mutation of ANY kind is allowed at exhaustion anymore.
        XCTAssertFalse(
            exhaustionBlock.contains("preserveOnEmptyCapture: !routesToEncryptedFallback"),
            "The fallback-gated exhaustion drop is the UR-55 regression — it must not return."
        )
        XCTAssertFalse(
            exhaustionBlock.contains("preserveOnEmptyCapture: false"),
            "Exhaustion must never discard the captured addresses on masked-read evidence alone (INV-DNS-5)."
        )
        XCTAssertFalse(
            exhaustionBlock.contains("DeviceDNSFallbackPolicy.refreshedResolverAddresses"),
            "Exhaustion must not touch the captured address list at all — preservation is unconditional."
        )
        XCTAssertFalse(
            exhaustionBlock.contains("collectPendingResponsesAndResetResolverRuntime("),
            "No runtime reset at exhaustion: the addresses did not change, so live queries keep their runtime."
        )

        // The verdict comes from the wire, policy-gated so equivalent evidence
        // (fresh accepted-primary proof, or an already-confirmed chronic failure
        // streak within its backoff spacing) does not burn radio per exhaustion.
        XCTAssertTrue(
            exhaustionBlock.contains("DeviceDNSFallbackPolicy.exhaustionVerificationDecision("),
            "The verification probe must be gated by the pure policy decision (executable-tested)."
        )
        XCTAssertTrue(
            exhaustionBlock.contains("scheduleResolverSmokeProbeIfNeeded(reason: \"device-dns-exhaustion-verification\")"),
            "The preserved primary must be verified by the standing smoke-probe machinery, not inferred stale."
        )
        XCTAssertTrue(
            exhaustionBlock.contains("\"verification\": verification.rawValue"),
            "The probe-vs-skip decision must be observable in the exhaustion log line."
        )

        // Canary for the negative pins above: they key on these identifiers — if a
        // rename removes one from the pinned source they pass vacuously. Fail here
        // instead, then re-anchor both sides to the new name.
        XCTAssertTrue(retryBlock.contains("DeviceDNSFallbackPolicy.refreshedResolverAddresses"),
                      "per-attempt refresh should still use the shared empty-capture policy")
        XCTAssertTrue(source.contains("collectPendingResponsesAndResetResolverRuntime("))
        XCTAssertTrue(source.contains("preserveOnEmptyCapture"))
    }

    func testWakeCaptureRetryHonoursExhaustionCooldownOnChronicallyMaskedNetwork() throws {
        let source = try readSource(.packetTunnelProvider)
        let scheduleBlock = try sourceBlock(
            in: source,
            startingAt: "private func scheduleDeviceDNSCaptureRetryIfNeeded",
            endingBefore: "private func armDeviceDNSCaptureRetry"
        )
        let retryBlock = try sourceBlock(
            in: source,
            startingAt: "private func runDeviceDNSCaptureRetry",
            endingBefore: "private func cancelDeviceDNSCaptureRetry"
        )

        // UR-48 follow-up log: a sleep/wake-thrashing device (median 5 s wake gap)
        // restarted the full 5x1 s masked capture-retry cycle on every wake — ~1,500
        // futile reads + log appends over ~4.7 h, 108 exhaustions, zero recoveries.
        // A wake-reason restart must honour the exhaustion cooldown; the wake path's
        // one-shot re-read still samples the network every wake.
        // Phase E2: the cooldown/stamp STATE machine moved into
        // DeviceDNSCaptureRetryCycle (LavaSecDNS), where its transitions are
        // EXECUTABLE (DeviceDNSCaptureRetryCycleTests replay the rc5 field timeline —
        // something these presence-pins could never catch: they passed on rc5 while
        // the cooldown was bypassed in the field). What remains compiler-invisible is
        // the WIRING: the provider must route schedule requests through the cycle and
        // keep the suppression observable in the device log. (Actors slice 2: the
        // cycle is a dispatch-backed actor; confined regions reach it through
        // `deviceDNSCaptureRetryCycle.assumeIsolated { cycle in … }`, so the pins
        // anchor on the isolated `cycle` calls.)
        XCTAssertTrue(
            scheduleBlock.contains("cycle.noteScheduleRequest(isWake: reason == \"wake\")"),
            "Wake-triggered retry-cycle restarts must consult the extracted cycle's cooldown gate."
        )
        XCTAssertTrue(
            scheduleBlock.contains("event: \"device-dns-capture-retry-suppressed\""),
            "The first suppressed wake after an exhaustion must stay observable in the device log."
        )
        XCTAssertTrue(
            retryBlock.contains("cycle.noteExhausted()"),
            "Masked exhaustion must stamp the cycle's cooldown."
        )
        XCTAssertTrue(
            retryBlock.contains("cycle.noteCaptureSucceeded("),
            "A non-empty capture must report success to the cycle."
        )
        XCTAssertTrue(
            retryBlock.contains("addressesChanged: deviceDNSResolverAddresses != previousAddresses"),
            "The cycle must learn whether the capture was a REAL recovery or an address-neutral flap (rc5 field-log fix)."
        )
    }

    func testDeviceDNSRecaptureRestartIsGatedAndProductiveCreditIsPersisted() throws {
        let source = try readSource(.packetTunnelProvider)

        // Track 4: the no-fallback exhaustion path escalates to the gated cold-restart;
        // the fallback case must NOT (Option-A keeps serving over the encrypted path).
        let retryBlock = try sourceBlock(
            in: source,
            startingAt: "private func runDeviceDNSCaptureRetry",
            endingBefore: "private func cancelDeviceDNSCaptureRetry"
        )
        let gateRange = try XCTUnwrap(
            retryBlock.range(of: "if !routesToEncryptedFallback {"),
            "The recapture restart must be gated on there being no encrypted fallback."
        )
        let callRange = try XCTUnwrap(
            retryBlock.range(of: "promptDeviceDNSRecaptureRestartIfPolicyAllows(now:"),
            "The exhaustion branch must escalate to the gated recapture restart."
        )
        XCTAssertTrue(gateRange.lowerBound < callRange.lowerBound)

        // The recapture entry uses its OWN cap reason (higher ceiling) and shares the
        // guarded teardown (Track-1 path guard + on-demand + atomic cancel, no main hop).
        let promptBlock = try sourceBlock(
            in: source,
            startingAt: "private func promptDeviceDNSRecaptureRestartIfPolicyAllows",
            endingBefore: "private func performGuardedSelfReconnectTeardown"
        )
        XCTAssertTrue(promptBlock.contains("reason: .deviceDNSRecapture"))
        XCTAssertTrue(promptBlock.contains("performGuardedSelfReconnectTeardown(reason: .deviceDNSRecapture"))
        // A throttled/declined recapture still arms the in-place wedge probe (always-eventually-retry).
        XCTAssertTrue(promptBlock.contains("scheduleResolverWedgeRecoveryProbeIfNeeded()"))

        // The shared teardown persists the restart-survivable credit marker BEFORE the
        // cancel — the cancel kills the process, so an in-memory marker would not survive.
        let teardownBlock = try sourceBlock(
            in: source,
            startingAt: "private func performGuardedSelfReconnectTeardown",
            endingBefore: "private static func isOnDemandConfirmedEnabled"
        )
        let saveMarkerRange = try XCTUnwrap(
            teardownBlock.range(of: "Self.saveLastSelfReconnectAt(now)"),
            "The teardown must persist the credit marker."
        )
        let cancelRange = try XCTUnwrap(teardownBlock.range(of: "cancelTunnelWithError(nil)"))
        XCTAssertTrue(
            saveMarkerRange.lowerBound < cancelRange.lowerBound,
            "The credit marker must be persisted before the cancel that kills the process."
        )

        // THE LOAD-BEARING CORRECTION: the productive-recovery credit reads the PERSISTED
        // lastSelfReconnectAt (which survives the restart's process kill) and prunes the
        // persisted attempt store — it does NOT rely on the in-memory wedge marker, which
        // the cancel wipes (crediting through that would be a silent no-op for the cold
        // restart this exists to credit).
        let creditBlock = try sourceBlock(
            in: source,
            startingAt: "private func creditProductiveSelfReconnectIfPending",
            endingBefore: "private func logQAConnectivityAssessmentIfNeeded"
        )
        XCTAssertTrue(
            creditBlock.contains("Self.loadLastSelfReconnectAt()"),
            "The credit must read the persisted (restart-survivable) marker."
        )
        XCTAssertTrue(
            creditBlock.contains("Self.saveSelfReconnectAttemptTimes("),
            "The credit must prune the persisted attempt store."
        )
        XCTAssertFalse(creditBlock.contains("currentResolverHealthSchedulingView"))
        XCTAssertFalse(creditBlock.contains("reconnectEpisodeIsActive"))
        XCTAssertFalse(creditBlock.contains("resolverHealthCoordinator"))
        // Credit removes ONLY the recovered restart's own attempt (the marker), not every
        // attempt at-or-before it — earlier unproductive restarts stay counted so an
        // intermittent loop still hits the per-window cap after one success.
        XCTAssertTrue(
            creditBlock.contains("firstIndex(of: lastSelfReconnectAt)"),
            "The credit must remove a single matching attempt, not a range."
        )
        XCTAssertFalse(
            creditBlock.contains("filter { $0 > lastSelfReconnectAt }"),
            "The credit must not erase every attempt at-or-before the marker."
        )

        // Confirmed smoke recovery emits a semantic credit effect; the common executor
        // applies it without depending on the reconnect episode marker that a restart wipes.
        XCTAssertTrue(source.contains("case .creditProductiveSelfReconnect(let occurredAt):"))
        XCTAssertTrue(
            source.contains("creditProductiveSelfReconnectIfPending(now: occurredAt)")
        )
        XCTAssertTrue(source.contains("reconnectEpisodeIsActive"))
    }

    func testRecaptureIntentIsCarriedIntoTheWedgeRetry() throws {
        let source = try readSource(.packetTunnelProvider)

        // When a no-fallback recapture restart cannot fire now (throttled by
        // cooldown, OR `.noAction` because idle/low traffic keeps severity below
        // `.needsReconnect`), the recovery retry re-enters the WEDGE path
        // (selfReconnectIfPolicyAllows). Without carrying the recapture intent it applies the
        // lower `.wedge` cap (2) and discards the recapture cap (3), suppressing the intended
        // third recapture restart. Fix: a sticky `deviceDNSRecaptureRestartPending` flag set
        // on ANY decline (recapture is owed once recapture exhausted), read by the wedge path
        // to pick the ceiling, cleared on confirmed recovery.

        // 1) The recapture decline branch marks the pending flag — on ANY decline, NOT only
        //    `.throttled` (`.noAction` also covers the idle/low-traffic case).
        let promptBlock = try sourceBlock(
            in: source,
            startingAt: "private func promptDeviceDNSRecaptureRestartIfPolicyAllows",
            endingBefore: "private func performGuardedSelfReconnectTeardown"
        )
        XCTAssertFalse(
            promptBlock.contains("if decision == .throttled"),
            "The recapture-pending flag must not be gated on .throttled only."
        )
        let declineGuardRange = try XCTUnwrap(
            promptBlock.range(of: "guard decision == .reconnect else {"),
            "The recapture restart must decline when the policy does not say reconnect."
        )
        let setPendingRange = try XCTUnwrap(
            promptBlock.range(of: "deviceDNSRecaptureRestartPending = true"),
            "A declined recapture restart must mark the recapture restart as pending."
        )
        let probeRange = try XCTUnwrap(promptBlock.range(of: "scheduleResolverWedgeRecoveryProbeIfNeeded()"))
        // Set inside the decline branch, before the always-eventually-retry backstop probe.
        XCTAssertTrue(declineGuardRange.lowerBound < setPendingRange.lowerBound)
        XCTAssertTrue(setPendingRange.lowerBound < probeRange.lowerBound)

        // 2) The wedge path picks its restart reason from the flag and threads it into BOTH
        //    the policy decision (so the ceiling matches) and the shared teardown.
        let wedgeBlock = try sourceBlock(
            in: source,
            startingAt: "private func selfReconnectIfPolicyAllows",
            endingBefore: "// Track 4 — the gated cold-restart"
        )
        XCTAssertTrue(wedgeBlock.contains("deviceDNSRecaptureRestartPending ? .deviceDNSRecapture : .wedge"))
        XCTAssertTrue(wedgeBlock.contains("reason: restartReason,"))
        XCTAssertTrue(wedgeBlock.contains("performGuardedSelfReconnectTeardown(reason: restartReason"))
        // The wedge path must no longer hard-code `.wedge` for the teardown.
        XCTAssertFalse(wedgeBlock.contains("performGuardedSelfReconnectTeardown(reason: .wedge"))

        // Recovery and fresh-lifecycle clearing are reducer effects pinned by the common
        // executor and resolver-health evidence tests.
    }

    func testWakeProactivelyReHandshakesResolverAfterSuspend() throws {
        let source = try readSource(.packetTunnelProvider)
        let wakeBlock = try sourceBlock(
            in: source,
            startingAt: "override func wake()",
            endingBefore: "#if DEBUG || LAVA_QA_TOOLS"
        )

        // On wake the upstream connections are stale, so wake() drops them and
        // re-probes: refresh device DNS, force-drop cached responses + tear down
        // stale sockets/connections, invalidate the bootstrap cache, then
        // re-handshake on settle. The forced reset closes the pre-settle-probe
        // window where a query could otherwise reuse a pre-sleep connection.
        XCTAssertTrue(wakeBlock.contains("dnsStateQueue.async"))
        // In-flight smoke probes are invalidated so a pre-sleep result can't apply
        // after resume and flip fallback on stale conditions.
        XCTAssertTrue(wakeBlock.contains("invalidateInFlightSmokeProbes()"))
        XCTAssertTrue(wakeBlock.contains("refreshDeviceDNSResolverAddressesOnDNSQueue(reason: \"wake\")"))
        XCTAssertTrue(wakeBlock.contains("collectPendingResponsesAndResetResolverRuntime("))
        XCTAssertTrue(wakeBlock.contains("reason: \"wake\""))
        XCTAssertTrue(wakeBlock.contains("force: true"))
        XCTAssertTrue(wakeBlock.contains("writeServerFailures(for: pendingResponses, reason: \"wake\")"))
        XCTAssertTrue(wakeBlock.contains("resolverBootstrapService.invalidateAll()"))
        XCTAssertTrue(wakeBlock.contains("resolverProbeCoalescer.noteUnsettled()"))
        // Wake intentionally has no network-path event: ordinary sleep preserves
        // the fallback decision, while a real path change clears it in the reducer.
    }

    func testResolverFallbackRunsInlineToAvoidQueueStarvation() throws {
        let source = try readSource(.packetTunnelProvider)
        let resolveBlock = try sourceBlock(
            in: source,
            startingAt: "private func resolveUpstream",
            endingBefore: "private func resolvePrimaryUpstream"
        )
        let orchestratorSource = try readSource(.resolverOrchestrator)
        let orchestratorResolveBlock = try sourceBlock(
            in: orchestratorSource,
            startingAt: "public func resolveUpstream",
            endingBefore: "public func resolvePrimaryUpstream"
        )

        XCTAssertTrue(resolveBlock.contains("resolverOrchestrator.resolveUpstream("))
        XCTAssertTrue(orchestratorResolveBlock.contains("let fallbackResult = executors.resolveDevice(query, plan.deviceDNSFallbackAddresses)"))
        XCTAssertTrue(orchestratorResolveBlock.contains("completion(primaryResult.withDeviceDNSFallback(fallbackResult))"))
        XCTAssertFalse(orchestratorResolveBlock.contains("resolverQueue.async"))
        // Canary: the negative pins above key on these identifiers - if a rename removes
        // one from the pinned source, those pins pass vacuously. Fail here instead, then
        // re-anchor both sides to the new name.
        XCTAssertTrue(source.contains("resolverQueue"))
    }

    // Phase E1 re-anchor: UDPResolverSocket moved to Sources/LavaSecDNS/SocketResolvers.swift.
    // The behavior the old pins guarded is now EXECUTABLE — SocketResolverTests covers
    // loopback round trips, source-address validation (anti-spoofing, both families),
    // the mismatch cap, and bounded receive timeouts. This slim pin keeps only what no
    // behavioral test can observe: the socket must stay UNCONNECTED (a connected UDP
    // socket would pass every loopback round trip but re-poison socket creation on
    // route changes) and each query must go out via sendto, never Darwin.send.
    func testUDPResolverSocketStaysUnconnectedAndSendsPerQuery() throws {
        let source = try readSource(.socketResolvers)
        let udpSocketBlock = try sourceBlock(
            in: source,
            startingAt: "public final class UDPResolverSocket",
            endingBefore: "public enum TCPResolver"
        )
        let sendHelperBlock = try sourceBlock(
            in: source,
            startingAt: "private func send(_ query: Data, endpoint: ResolverEndpoint"
        )

        // The doc comment legitimately mentions `connect(2)`; ban the CALL spellings.
        XCTAssertFalse(
            udpSocketBlock.contains("Darwin.connect("),
            "UDP socket creation must not fail because a resolver route cannot be connected yet."
        )
        XCTAssertFalse(udpSocketBlock.contains("connect(descriptor"))
        XCTAssertFalse(udpSocketBlock.contains("connect(fileDescriptor"))
        XCTAssertTrue(
            udpSocketBlock.contains("send(query, endpoint: endpoint, port: port, fileDescriptor: fileDescriptor)"),
            "Each UDP query should use the sendto helper so route changes do not poison socket creation."
        )
        XCTAssertTrue(sendHelperBlock.contains("sendto("))
        XCTAssertFalse(
            sendHelperBlock.contains("Darwin.send("),
            "Unconnected UDP sockets must use sendto, not send."
        )
        // Canary: the negative pins above key on these identifiers — if a rename removes
        // one from the pinned source, those pins pass vacuously. Fail here instead, then
        // re-anchor both sides to the new name.
        XCTAssertTrue(source.contains("Darwin.connect("))
    }

    func testBlockedDNSResponsesUseShortTTLWithoutChangingUpstreamResponseCache() throws {
        let source = try readSource(.packetTunnelProvider)
        let blockedBlock = try sourceBlock(
            in: source,
            startingAt: "private let blockedTTL",
            endingBefore: "private static let maxConcurrentResolverQueries"
        )
        let cacheSource = try readSource(.dnsResponseCache)
        let upstreamCacheBlock = try sourceBlock(
            in: cacheSource,
            startingAt: "package enum DNSResponseCachePolicy",
            endingBefore: "public final class DNSResponseCache"
        )

        XCTAssertTrue(blockedBlock.contains("private let blockedTTL: UInt32 = 1"))
        XCTAssertTrue(source.contains("ttl: blockedTTL"))
        XCTAssertTrue(upstreamCacheBlock.contains("static func cacheTTL(for response: Data) -> TimeInterval?"))
        XCTAssertTrue(upstreamCacheBlock.contains("return min(TimeInterval(minimumTTL), maximumTTL)"))
    }

    func testTemporaryPauseForwardsWouldBlockDomainsWithShortTTL() throws {
        let source = try readSource(.packetTunnelProvider)
        let handleBlock = try sourceBlock(
            in: source,
            startingAt: "private func handle(packet: Data, protocolNumber: NSNumber)",
            endingBefore: "private func forward("
        )
        let pauseTTLBlock = try sourceBlock(
            in: source,
            startingAt: "private func temporaryPauseMaximumAnswerTTL",
            endingBefore: "private func currentResolverPreset()"
        )
        let completeForwardBlock = try sourceBlock(
            in: source,
            startingAt: "private func completeForward",
            endingBefore: "private func currentResolverRuntimeGeneration()"
        )

        XCTAssertTrue(source.contains("private let pausedWouldBlockForwardTTL: UInt32 = 1"))
        XCTAssertTrue(source.contains("private var protectionPolicySnapshot: any FilterRuntimeSnapshot"))
        XCTAssertTrue(handleBlock.contains("isProtectionPaused: {"))
        XCTAssertTrue(handleBlock.contains("isTemporaryProtectionPauseActive(synchronizesDefaults: false)"))
        XCTAssertTrue(handleBlock.contains("case .pausedForward:"))
        XCTAssertTrue(handleBlock.contains("temporaryPauseMaximumAnswerTTL(forNormalizedDomain: question.normalizedDomain)"))
        XCTAssertTrue(handleBlock.contains("temporaryPauseNormalizedDomain: question.normalizedDomain"))
        XCTAssertTrue(pauseTTLBlock.contains("protectionPolicyDecision(forNormalizedDomain: normalizedDomain)"))
        XCTAssertTrue(pauseTTLBlock.contains("decision.action == .block ? pausedWouldBlockForwardTTL : nil"))
        XCTAssertTrue(completeForwardBlock.contains("maximumAnswerTTL: UInt32?"))
        XCTAssertTrue(completeForwardBlock.contains("pending.maximumAnswerTTL"))
        XCTAssertTrue(source.contains("DNSWireMessage.cappingCacheableTTLs(in: response, to: maximumAnswerTTL)"))
    }

    func testDNSParseFailuresReturnServerFailureInsteadOfForwardingRawQuery() throws {
        let source = try readSource(.packetTunnelProvider)
        let parseFailureBlock = try sourceBlock(
            in: source,
            startingAt: "guard let question = try? DNSMessage.parseQuestion(from: request.dnsPayload)",
            endingBefore: "let resolverConfiguration = currentResolverRuntimeConfiguration()"
        )

        XCTAssertTrue(parseFailureBlock.contains("writeParseFailureResponse"))
        XCTAssertFalse(
            parseFailureBlock.contains("forward(request"),
            "Unparseable DNS must fail closed instead of being forwarded outside the filter."
        )
    }

    // (Phase E1) testUDPResolverSendHelperUsesSendtoForIPv4AndIPv6 and
    // testUDPResolverValidatesReceivedPacketSourceBeforeDNSPayload were text pins on the
    // provider's copy of this logic; the moved code is executable now, so both families'
    // send paths and the source-validation (anti-spoofing) gate are exercised for real
    // in SocketResolverTests. The sendto-not-send spelling stays pinned in
    // testUDPResolverSocketStaysUnconnectedAndSendsPerQuery.

    func testPlainDNSAttemptsTCPFallbackAfterUDPTimeoutOnly() throws {
        let source = try readSource(.packetTunnelProvider)
        let plainResolverBlock = try sourceBlock(
            in: source,
            startingAt: "private func resolvePlainDNS(",
            endingBefore: "private func shouldAttemptTCPFallback(afterUDPOutcome"
        )
        let fallbackDecisionBlock = try sourceBlock(
            in: source,
            startingAt: "private func shouldAttemptTCPFallback(afterUDPOutcome",
            endingBefore: "private func doqEndpointResolvingBootstrapIfNeeded"
        )

        XCTAssertTrue(
            plainResolverBlock.contains("shouldAttemptTCPFallback(afterUDPOutcome: udpResult.outcome)"),
            "Plain DNS should try bounded TCP fallback after a UDP timeout instead of immediately moving on."
        )
        XCTAssertTrue(
            plainResolverBlock.contains("let tcpResult = TCPResolver.resolve(query, endpoint: endpoint, timeoutSeconds: Self.tcpDNSTimeoutSeconds)")
        )
        XCTAssertTrue(
            plainResolverBlock.contains("tcpFallbackAttempted: attemptedTCPFallback"),
            "Health should report TCP fallback attempts even when UDP was not truncated."
        )
        XCTAssertTrue(fallbackDecisionBlock.contains("case .timeout:"))
        XCTAssertTrue(fallbackDecisionBlock.contains("return true"))
        XCTAssertTrue(fallbackDecisionBlock.contains("case .sendFailed:"))
        XCTAssertTrue(fallbackDecisionBlock.contains("return false"))
    }

    func testPlainDNSBackoffDoesNotRetryEveryQueryWhenAllResolversAreBackedOff() throws {
        let source = try readSource(.packetTunnelProvider)
        let plainResolverBlock = try sourceBlock(
            in: source,
            startingAt: "private func resolvePlainDNS(",
            endingBefore: "private func shouldAttemptTCPFallback"
        )
        let addressOrderBlock = try sourceBlock(
            in: source,
            startingAt: "private func orderedResolverAddressesForAttempt",
            endingBefore: "private func isResolverBackedOff"
        )

        XCTAssertTrue(plainResolverBlock.contains("if addressesForAttempt.isEmpty, !resolverAddresses.isEmpty"))
        XCTAssertTrue(plainResolverBlock.contains("ResolverAttempt(address: $0, outcome: .backedOff, transport: transport)"))
        XCTAssertFalse(addressOrderBlock.contains("available.isEmpty ? addresses : available"))
        XCTAssertTrue(addressOrderBlock.contains("resolverBackoffPolicy.availableAddresses(from: addresses, now: now)"))
    }

    // Phase E1 re-anchor: the resolver sockets moved to Sources/LavaSecDNS/SocketResolvers.swift.
    // That the timeouts actually BOUND blocking receives is executable now
    // (SocketResolverTests timeout tests would hang without SO_RCVTIMEO); this pin keeps
    // the branch no behavioral test can force — setsockopt FAILING must abort socket
    // setup (fail closed) rather than run an unbounded socket.
    func testResolverSocketsRequireTimeoutSetup() throws {
        let source = try readSource(.socketResolvers)
        let udpSocketBlock = try sourceBlock(
            in: source,
            startingAt: "public final class UDPResolverSocket",
            endingBefore: "public enum TCPResolver"
        )
        let tcpResolverBlock = try sourceBlock(
            in: source,
            startingAt: "public enum TCPResolver",
            endingBefore: "private func isExpectedSource"
        )

        XCTAssertTrue(
            source.contains("private func configureSocketTimeouts("),
            "Resolver sockets should share checked timeout setup instead of ignoring setsockopt failures."
        )
        XCTAssertTrue(
            udpSocketBlock.contains("guard configureSocketTimeouts(descriptor, receive: true, send: false, timeoutSeconds: timeoutSeconds) else"),
            "UDP resolver sockets must fail closed when receive timeouts cannot be installed."
        )
        XCTAssertTrue(
            tcpResolverBlock.contains("guard configureSocketTimeouts(descriptor, receive: true, send: true, timeoutSeconds: timeoutSeconds) else"),
            "TCP fallback must fail closed when receive/send timeouts cannot be installed."
        )
        XCTAssertFalse(udpSocketBlock.contains("_ = setsockopt"))
        XCTAssertFalse(tcpResolverBlock.contains("_ = setsockopt"))
    }

    func testSelfReconnectEscalatesWedgedDNSWithBackoffGuards() throws {
        let source = try readSource(.packetTunnelProvider)

        let helperBlock = try sourceBlock(
            in: source,
            startingAt: "private func selfReconnectIfPolicyAllows",
            endingBefore: "private static func loadSelfReconnectAttemptTimes"
        )
        // Decision delegates to the pure, tested policy, gated by protectionEnabled
        // AND a confirmed Connect-On-Demand signal (protectionEnabled alone can be
        // persisted even when arming on-demand failed, so a self-cancel without
        // on-demand would strand the user offline).
        XCTAssertTrue(helperBlock.contains("TunnelSelfReconnectPolicy.decision("))
        XCTAssertTrue(helperBlock.contains("protectionEnabled: currentAppConfiguration().protectionEnabled"))
        XCTAssertTrue(helperBlock.contains("onDemandEnabled: Self.isOnDemandConfirmedEnabled()"))
        XCTAssertTrue(helperBlock.contains("guard decision == .reconnect else"))
        // Latched so the cancel is issued once; attempts persisted for the
        // cross-restart backoff (the cancel kills the process).
        XCTAssertTrue(helperBlock.contains("guard !hasRequestedSelfReconnect else"))
        XCTAssertTrue(helperBlock.contains("hasRequestedSelfReconnect = true"))
        XCTAssertTrue(helperBlock.contains("saveSelfReconnectAttemptTimes"))
        XCTAssertTrue(helperBlock.contains("cancelTunnelWithError(nil)"))
    }

    func testSelfReconnectReValidatesNetworkPathBeforeCancel() throws {
        let source = try readSource(.packetTunnelProvider)
        let helperBlock = try sourceBlock(
            in: source,
            startingAt: "private func selfReconnectIfPolicyAllows",
            endingBefore: "private static func loadSelfReconnectAttemptTimes"
        )

        // The .reconnect decision is computed on dnsStateQueue but the network path can
        // flip before the teardown lands. The cancel must be re-validated on a fresh
        // dnsStateQueue turn and gated on the path still being satisfied — tearing down
        // into a dead path hands Connect-On-Demand nothing to recover into and lengthens
        // the OFF window (field-confirmed).
        XCTAssertTrue(
            helperBlock.contains("dnsStateQueue.async"),
            "The cancel must be deferred to a fresh dnsStateQueue turn so an enqueued path update settles first."
        )
        // Must gate on the handler-stamped freshest path state, NOT only
        // health.networkPathIsSatisfied (which lands via a second deferred hop and can be
        // stale-satisfied when a delivered path update hasn't been applied yet).
        XCTAssertTrue(
            helperBlock.contains("self.latestMonitoredPathIsSatisfied"),
            "The teardown must re-check the handler-stamped latestMonitoredPathIsSatisfied, not just the deferred health flag."
        )

        // The path guard must PRECEDE the cancel: the cancel cannot fire on an
        // unsatisfied path.
        let guardRange = try XCTUnwrap(
            helperBlock.range(of: "guard self.latestMonitoredPathIsSatisfied"),
            "Expected a latestMonitoredPathIsSatisfied guard in selfReconnectIfPolicyAllows."
        )
        let cancelRange = try XCTUnwrap(
            helperBlock.range(of: "cancelTunnelWithError(nil)"),
            "Expected a cancelTunnelWithError(nil) call in selfReconnectIfPolicyAllows."
        )
        XCTAssertTrue(
            guardRange.lowerBound < cancelRange.lowerBound,
            "The networkPathIsSatisfied guard must come before cancelTunnelWithError."
        )

        // The persisted attempt (which counts against the per-window cap) must also be
        // committed only on the satisfied path, after the guard — a skipped teardown
        // must not burn a cap slot.
        // Target the COMMIT save (updatedAttempts), not the earlier normalization
        // self-heal save (attempts) that runs before the decision.
        let saveRange = try XCTUnwrap(
            helperBlock.range(of: "saveSelfReconnectAttemptTimes(updatedAttempts)"),
            "Expected the committed-attempt saveSelfReconnectAttemptTimes(updatedAttempts) in selfReconnectIfPolicyAllows."
        )
        XCTAssertTrue(
            guardRange.lowerBound < saveRange.lowerBound,
            "The self-reconnect attempt must be persisted only after the path guard passes."
        )

        // On an unsatisfied path: release the latch so a later satisfied settle can
        // retry, re-arm the lighter wedge-recovery probe, and record why it was skipped.
        XCTAssertTrue(
            helperBlock.contains("self.hasRequestedSelfReconnect = false"),
            "A skipped teardown must release the self-reconnect latch so recovery isn't permanently suppressed."
        )
        XCTAssertTrue(
            helperBlock.contains("scheduleResolverWedgeRecoveryProbeIfNeeded()"),
            "A skipped teardown must re-arm the wedge-recovery probe instead of cancelling blind."
        )
        XCTAssertTrue(
            helperBlock.contains("event: \"self-reconnect-skipped-path-unsatisfied\""),
            "A skipped teardown must be observable in the device log."
        )
    }

    func testSelfReconnectReValidatesWedgeBeforeCancel() throws {
        let source = try readSource(.packetTunnelProvider)
        let helperBlock = try sourceBlock(
            in: source,
            startingAt: "private func selfReconnectIfPolicyAllows",
            endingBefore: "private static func loadSelfReconnectAttemptTimes"
        )

        // A queued smoke-probe / organic-query success can run on dnsStateQueue between the
        // .reconnect decision and the deferred cancel turn, clearing the wedge without
        // clearing hasRequestedSelfReconnect. The deferred turn must RE-RUN THE FULL
        // self-reconnect policy against fresh health and bail unless it still says reconnect
        // — re-deriving only the assessment and checking primaryAction == .reconnect is too
        // loose, because a wedge that cleared to .dnsSlow can still report .reconnect while
        // the policy is .noAction. Otherwise it tears down a now-healthy / covered
        // / merely-slow tunnel.
        let revalidateRange = try XCTUnwrap(
            helperBlock.range(of: "let revalidatedAssessment = ProtectionConnectivityPolicy.assessment"),
            "The deferred cancel turn must re-derive the connectivity assessment."
        )
        let decisionRange = try XCTUnwrap(
            helperBlock.range(of: "let revalidatedDecision = TunnelSelfReconnectPolicy.decision"),
            "The deferred cancel turn must re-run the full self-reconnect policy, not just the assessment."
        )
        let wedgeGuardRange = try XCTUnwrap(
            helperBlock.range(of: "guard revalidatedDecision == .reconnect else"),
            "The deferred cancel must be gated on the FULL policy still returning .reconnect."
        )
        // The wedge re-check must precede both the committed attempt and the cancel.
        let saveRange = try XCTUnwrap(
            helperBlock.range(of: "saveSelfReconnectAttemptTimes(updatedAttempts)"),
            "Expected the committed-attempt save in selfReconnectIfPolicyAllows."
        )
        let cancelRange = try XCTUnwrap(
            helperBlock.range(of: "cancelTunnelWithError(nil)"),
            "Expected a cancelTunnelWithError(nil) call in selfReconnectIfPolicyAllows."
        )
        XCTAssertTrue(revalidateRange.lowerBound < decisionRange.lowerBound)
        XCTAssertTrue(decisionRange.lowerBound < wedgeGuardRange.lowerBound)
        XCTAssertTrue(
            wedgeGuardRange.lowerBound < saveRange.lowerBound,
            "The wedge re-check must come before the persisted attempt."
        )
        XCTAssertTrue(
            wedgeGuardRange.lowerBound < cancelRange.lowerBound,
            "The wedge re-check must come before cancelTunnelWithError."
        )
        // On a cleared wedge, release the latch (so a later real wedge can retry) and bail.
        let latchReleaseRange = try XCTUnwrap(
            helperBlock.range(of: "self.hasRequestedSelfReconnect = false"),
            "A bailed cancel must release the self-reconnect latch."
        )
        XCTAssertTrue(wedgeGuardRange.lowerBound < latchReleaseRange.upperBound)

        // The teardown must be issued on the SAME dnsStateQueue turn the path was validated —
        // no DispatchQueue.main.async hop, which would reopen a path-flip window AFTER the
        // attempt was already burned. cancelTunnelWithError is async to iOS, and
        // setTunnelNetworkSettings is already called off-main here, so an off-main cancel is safe.
        XCTAssertFalse(
            helperBlock.contains("DispatchQueue.main.async"),
            "The cancel must not hop to the main queue — it reopens a cancel-into-dead-network window after the path guard."
        )
    }

    func testPathMonitorStampsFreshSatisfiedStateBeforeDeferringHandling() throws {
        let source = try readSource(.packetTunnelProvider)
        let monitorBlock = try sourceBlock(
            in: source,
            startingAt: "private func startPathMonitor",
            endingBefore: "private func handleNetworkPathUpdate"
        )

        XCTAssertTrue(source.contains("startPathMonitor(lifecycleGeneration: lifecycleGeneration)"))
        XCTAssertTrue(
            monitorBlock.containsInOrder([
                "monitor.pathUpdateHandler =",
                "isCurrentTunnelLifecycle(lifecycleGeneration)",
                "self.latestMonitoredPathIsSatisfied = update.isSatisfied",
                "self.dnsStateQueue.async",
                "isCurrentTunnelLifecycle(lifecycleGeneration)",
                "self.handleNetworkPathUpdate(update)"
            ]),
            "Both path-monitor turns must reject work from an invalidated lifecycle."
        )
        XCTAssertEqual(
            monitorBlock.components(separatedBy: "isCurrentTunnelLifecycle(lifecycleGeneration)").count - 1,
            2
        )

        // The handler runs on dnsStateQueue but defers the heavy handleNetworkPathUpdate
        // (which applies health.networkPathIsSatisfied) to a SECOND dnsStateQueue.async.
        // The freshest-state stamp must happen SYNCHRONOUSLY in the handler, BEFORE that
        // deferral, so the self-reconnect guard can observe a delivered-but-not-yet-applied
        // path change one hop earlier (the cancel-into-dead-network race).
        let stampRange = try XCTUnwrap(
            monitorBlock.range(of: "self.latestMonitoredPathIsSatisfied = update.isSatisfied"),
            "The pathUpdateHandler must stamp latestMonitoredPathIsSatisfied synchronously."
        )
        let deferRange = try XCTUnwrap(
            monitorBlock.range(of: "self.dnsStateQueue.async"),
            "The pathUpdateHandler defers handleNetworkPathUpdate to a second turn."
        )
        XCTAssertTrue(
            stampRange.lowerBound < deferRange.lowerBound,
            "The synchronous stamp must precede the deferred handleNetworkPathUpdate hop."
        )
    }

    func testStartPathMonitorCreatesAFreshMonitorAndResetsObservedPathState() throws {
        let source = try readSource(.packetTunnelProvider)
        let monitorBlock = try sourceBlock(
            in: source,
            startingAt: "private func startPathMonitor",
            endingBefore: "private func clearEncryptedFallbackLogThrottle"
        )

        // CON-2: a cancelled NWPathMonitor delivers ZERO updates when restarted, and
        // cleanup cancels the monitor on every stop AND every failed start. Reusing the
        // same object across a same-instance restart (manual stop/start, or a
        // setTunnelNetworkSettings-error retry) would leave handleNetworkPathUpdate
        // permanently silent — no network-change reset, settle probe, or device-DNS
        // recapture (field-confirmed 2026-06-22). The monitor must therefore be a `var`
        // recreated FRESH per start.
        XCTAssertTrue(
            source.contains("private var pathMonitor = Network.NWPathMonitor()"),
            "pathMonitor must be a var so it can be recreated per lifecycle (a cancelled monitor never delivers again)."
        )
        XCTAssertFalse(
            source.contains("private let pathMonitor"),
            "pathMonitor must not be a one-shot let; a restart reuses a dead (cancelled) monitor."
        )
        XCTAssertTrue(
            monitorBlock.contains("let monitor = Network.NWPathMonitor()"),
            "startPathMonitor must create a fresh NWPathMonitor each time so the handler can fire again after a restart."
        )
        XCTAssertTrue(
            monitorBlock.contains("pathMonitor = monitor"),
            "The fresh monitor must replace the stored one so cleanup cancels the live monitor."
        )
        XCTAssertTrue(
            monitorBlock.contains("monitor.start(queue: dnsStateQueue)"),
            "The fresh monitor (not the outgoing object) must be the one started."
        )

        // A stale "satisfied" must not survive a restart: reset the observed-path state
        // so the self-reconnect teardown guard can't read a frozen `true`
        // (cancel-into-dead-network) and the fresh monitor's first update isn't suppressed
        // as a no-op change (skipping the network-change reset).
        XCTAssertTrue(
            monitorBlock.contains("self.latestMonitoredPathIsSatisfied = true"),
            "The restart must reset latestMonitoredPathIsSatisfied so a stale satisfied doesn't survive."
        )
        XCTAssertTrue(
            monitorBlock.contains("self.lastObservedPathKind = nil"),
            "The restart must reset the last-observed path kind so the first fresh update is treated as initial."
        )
        XCTAssertTrue(
            monitorBlock.contains("self.lastObservedPathIsSatisfied = nil"),
            "The restart must reset the last-observed path-satisfied so the first fresh update is treated as initial."
        )

        // The reset must run on the observed-path fields' owning queue (dnsStateQueue),
        // enqueued BEFORE the fresh monitor is started so it lands ahead of any delivered
        // update rather than clobbering it.
        let resetRange = try XCTUnwrap(
            monitorBlock.range(of: "self.latestMonitoredPathIsSatisfied = true"),
            "Expected the observed-path reset in startPathMonitor."
        )
        let startRange = try XCTUnwrap(
            monitorBlock.range(of: "monitor.start(queue: dnsStateQueue)"),
            "Expected the fresh monitor to be started in startPathMonitor."
        )
        XCTAssertTrue(
            resetRange.lowerBound < startRange.lowerBound,
            "The observed-path reset must be enqueued before the fresh monitor is started."
        )
    }

    func testResolverHealthRecoveryEffectUsesFrozenDiagnostics() throws {
        let source = try readSource(.packetTunnelProvider)
        let recoveryBlock = try sourceBlock(
            in: source,
            startingAt: "private func reportResolverConnectivityRecovery",
            endingBefore: "// MARK: - Health reset & network path monitoring"
        )

        XCTAssertTrue(recoveryBlock.contains("frozenHealthContext: recovery.activityContext"))
        XCTAssertTrue(recoveryBlock.contains("event: \"dns-recovered\""))
        XCTAssertTrue(recoveryBlock.contains("\"verifiedBy\": recovery.verifiedBy"))
        XCTAssertTrue(recoveryBlock.contains(".wedgeRecovered"))
        XCTAssertTrue(
            recoveryBlock.contains(
                "\"consecutiveUpstreamFailureCount\":\n                    \"\\(recovery.peakUpstreamFailureCount)\""
            )
        )
        XCTAssertFalse(recoveryBlock.contains("ProtectionConnectivityPolicy.assessment"))
        XCTAssertFalse(recoveryBlock.contains("clearEncryptedFallbackLogThrottle"))
    }

    func testWedgedResolverSelfRecoversWithoutAManualToggle() throws {
        let source = try readSource(.packetTunnelProvider)

        // The recovery clears the backoff penalty box + stale connections (the
        // clean slate a fresh process gets on a manual toggle) and re-probes; the
        // failed re-probe re-arms it, so it self-sustains at the wedge cadence.
        let recoveryBlock = try sourceBlock(
            in: source,
            startingAt: "private func scheduleResolverWedgeRecoveryProbeIfNeeded()",
            endingBefore: "private func cancelResolverWedgeRecoveryProbe()"
        )
        XCTAssertTrue(recoveryBlock.contains("resolverBackoffPolicy.reset()"))
        XCTAssertTrue(recoveryBlock.contains("resetResolverTransientState()"))
        // A wedge is often stale resolvers from a prior network — re-capture
        // device DNS before re-probing so the device-DNS user gets fresh addresses.
        XCTAssertTrue(recoveryBlock.contains("refreshDeviceDNSResolverAddressesOnDNSQueue(reason: \"resolver-wedge-recovery\")"))
        XCTAssertTrue(recoveryBlock.contains("scheduleResolverSmokeProbeIfNeeded(reason: isCoveredWedge ? \"covered-primary-recapture\" : \"resolver-wedge-recovery\")"))
        XCTAssertTrue(recoveryBlock.contains("assessment.primaryAction == .reconnect"))
        // The recovery loop re-arms on an escalating cadence (LAV-92 fast guide), not a flat
        // 30s interval, so a brief blip recovers in seconds while a sustained wedge backs off to
        // the legacy 30s ceiling. The flat constant must be gone.
        XCTAssertFalse(source.contains("resolverWedgeRecoveryProbeInterval"))
        XCTAssertTrue(source.contains("private let resolverWedgeRecoveryCadence = ResolverWedgeRecoveryCadence()"))
        XCTAssertTrue(recoveryBlock.contains("resolverWedgeRecoveryCadence.delay(forAttempt: resolverWedgeRecoveryAttempt)"))
        XCTAssertTrue(recoveryBlock.contains("resolverWedgeRecoveryAttempt += 1"))
        // The fast ramp is confined to the UNCOVERED down-wedge (user offline). A COVERED wedge
        // (online via encrypted fallback) keeps the gentle ceiling cadence and zeroes the ramp so
        // a later real down-wedge still starts fast.
        XCTAssertTrue(recoveryBlock.contains("ProtectionConnectivityPolicy.isEncryptedFallbackCoveringWedge(health: health, now: now)"))
        XCTAssertTrue(recoveryBlock.contains("resolverWedgeRecoveryCadence.maxInterval"))
        // A pending probe must be preempted whenever a SOONER one is now warranted (coverage lapsed,
        // or a down probe already backed off to the cap) — a deadline comparison that subsumes every
        // covered<->uncovered transition, so the offline user never waits out a stale timer.
        // The fire path and cancel/resetHealth clear the armed deadline.
        // Preempt a pending probe when the cadence MODE changed (covered<->uncovered) OR a sooner
        // probe is warranted within the same mode. The mode check stops a covered/online wedge from
        // being fast-probed (which could tear down a working fallback) AND speeds an offline user up
        // when coverage lapses.
        XCTAssertTrue(recoveryBlock.contains("let modeChanged = resolverWedgeRecoveryArmedCovered != coveredNow"))
        XCTAssertTrue(recoveryBlock.contains("guard modeChanged || deadline < armedDeadline else {"))
        XCTAssertTrue(recoveryBlock.contains("resolverWedgeRecoveryArmedDeadline = deadline"))
        XCTAssertTrue(recoveryBlock.contains("resolverWedgeRecoveryArmedCovered = coveredNow"))
        // The fast ramp is floored at the recovery probe's ACTUAL smoke-probe timeout (computed the
        // same way the probe computes it — transport + device-DNS-fallback availability), so a
        // sooner re-arm can't fire a new probe while the previous one is still in flight and discard
        // it / churn the session. Covers encrypted AND fallback-capable plain primaries.
        XCTAssertTrue(recoveryBlock.contains("Self.smokeProbeTimeoutSeconds("))
        XCTAssertTrue(recoveryBlock.contains("reason: \"resolver-wedge-recovery\""))
        XCTAssertTrue(recoveryBlock.contains("delay = max(rampDelay, probeTimeout)"))
        // The fired probe finding the wedge already gone must end the episode (reset the ramp),
        // not strand the counter at a backed-off value for the next wedge.
        XCTAssertGreaterThanOrEqual(
            recoveryBlock.components(separatedBy: "resolverWedgeRecoveryAttempt = 0").count - 1, 2,
            "the no-longer-wedged early return and the covered branch must both zero the ramp counter"
        )

        // Ordered recovery effects own cancellation; the provider helper remains the
        // implementation of the schedule/cancel work they invoke.
        // Cancelling the probe (recovery / lifecycle reset) resets the episode counter so the
        // next wedge restarts the fast escalation ramp rather than inheriting a backed-off delay.
        XCTAssertTrue(source.contains("resolverWedgeRecoveryAttempt = 0"))
        // Lifecycle wedge-probe teardown is emitted by the reducer and exercised
        // through the coordinator wiring test below.

        // A suppressed self-reconnect must be diagnosable from the Release log so a
        // "said reconnect needed but never recovered" report carries the reason.
        let selfReconnectBlock = try sourceBlock(
            in: source,
            startingAt: "private func selfReconnectIfPolicyAllows",
            endingBefore: "private static func loadSelfReconnectAttemptTimes"
        )
        XCTAssertTrue(selfReconnectBlock.contains("event: \"self-reconnect-suppressed\""))
        // ...but a persistent wedge must not flood the capped log: the line is gated
        // on a changed suppression signature or an elapsed cooldown, not emitted per tick.
        XCTAssertTrue(selfReconnectBlock.contains("lastSelfReconnectSuppressionSignature"))
        XCTAssertTrue(selfReconnectBlock.contains("if changed || cooldownElapsed {"))
    }

    func testRecordDeliveryOnlyAdvancesThrottleForProblems() throws {
        let source = try readSource(.packetTunnelProvider)
        let recordBlock = try sourceBlock(
            in: source,
            startingAt: "private static func recordProtectionNotificationDelivery",
            endingBefore: "private static func removeSupersededProtectionNotifications"
        )

        // The 600s minimum-problem-delivery throttle keys off the delivered-at
        // timestamp; only a problem delivery may advance it. (Only actionable problem
        // banners are delivered now — no recovery acknowledgement.)
        let prefix = try sourceBlock(
            in: recordBlock,
            startingAt: "let defaults",
            endingBefore: "if notification.kind.isProblem {"
        )
        XCTAssertFalse(prefix.contains("protectionLastDeliveredNotificationAtDefaultsKeyName"))
        let problemBranch = try sourceBlock(
            in: source,
            startingAt: "if notification.kind.isProblem {",
            endingBefore: "private static func removeSupersededProtectionNotifications"
        )
        XCTAssertTrue(problemBranch.contains("protectionLastDeliveredNotificationAtDefaultsKeyName"))
        // No recovery-acknowledgement delivery path remains in recordDelivery.
        XCTAssertFalse(recordBlock.contains(".reconnected"))
    }

    func testEncryptedFallbackSilentClearAlsoLiftsTheDuplicateGuardID() throws {
        let source = try readSource(.packetTunnelProvider)
        // Back-dating `lastDeliveredAt` alone is not enough: the silent supersede removed
        // the reconnect banner, so the persisted last-delivered *id* must also be cleared.
        // Otherwise a lapse back to `.needsReconnect` with the same event id is suppressed by
        // notification(for:)'s exact-id duplicate guard until a later probe shifts the id,
        // defeating the back-dated cooldown. The clear must live in the cooldown branch so a
        // real `.healthy` recovery (cooldownAnchor == nil) keeps its duplicate guard intact.
        let cooldownBranch = try sourceBlock(
            in: source,
            startingAt: "if let cooldownAnchor {",
            endingBefore: "let requestIdentifiers = identifiers.map {"
        )
        XCTAssertTrue(
            cooldownBranch.contains("removeObject(forKey: LavaSecAppGroup.protectionLastDeliveredNotificationIDDefaultsKeyName)"),
            "The encrypted-fallback silent clear must also clear the duplicate-guard id so a lapsed wedge re-posts."
        )
    }

    func testCoveredWedgeRecaptureRunsWithoutTheMarkerAndDoesNotChurnTheFallback() throws {
        let source = try readSource(.packetTunnelProvider)
        let scheduleBlock = try sourceBlock(
            in: source,
            startingAt: "private func scheduleResolverWedgeRecoveryProbeIfNeeded()",
            endingBefore: "private func cancelResolverWedgeRecoveryProbe()"
        )

        // The covered wedge (encrypted fallback carrying a transition-stale primary) holds
        // no marker, so the accelerated recovery probe must re-confirm on the policy's coverage
        // predicate — the explicit named helper, derived purely from health — alongside the
        // down-wedge signals, or it would abort and strand the primary on the fallback.
        XCTAssertTrue(scheduleBlock.contains("let isCoveredWedge = ProtectionConnectivityPolicy.isEncryptedFallbackCoveringWedge(health: self.health, now: now)"))
        // The loop stays ALIVE on the broader carrying signal (survives a rejected recapture probe,
        // which flips the gated covered predicate false while the marker is unstamped); isCoveredWedge
        // still drives the recapture reason + churn-skip.
        XCTAssertTrue(scheduleBlock.contains("let isCarryingFallback = ProtectionConnectivityPolicy.isEncryptedFallbackCarryingWedge(health: self.health, now: now)"))
        XCTAssertTrue(scheduleBlock.contains("isDownWedge || isCarryingFallback"))
        XCTAssertTrue(scheduleBlock.contains("\"covered-primary-recapture\""))

        // HARD CONSTRAINT — the reason recovery-in-place was deferred: the covered recapture
        // must never regain a provider-owned wedge marker. The coordinator's reducer alone owns
        // reconnect episodes and preserves the authoritative rejection behavior here.
        XCTAssertTrue(scheduleBlock.contains("self.currentDeviceResolverWedged()"))
        XCTAssertFalse(
            scheduleBlock.contains("applyResolverHealthEvent("),
            "Covered-state recapture may read actor evidence but must not start an episode."
        )
        XCTAssertFalse(scheduleBlock.contains("resolverHealthCoordinator.assumeIsolated"))

        // The DoH/DoT session churn must be gated to a DOWN wedge that the fallback is NOT
        // carrying. In the covered state — INCLUDING the overlap where a stale down-wedge
        // marker is also held — those sessions are ACTIVELY carrying the fallback, so resetting
        // them would disrupt the very path keeping the user online. The `!isCoveredWedge`
        // conjunct is what suppresses the churn when the marker is held but coverage is live.
        let gatedResetRegion = try sourceBlock(
            in: scheduleBlock,
            startingAt: "self.resolverBackoffPolicy.reset()",
            endingBefore: "self.scheduleResolverSmokeProbeIfNeeded("
        )
        XCTAssertTrue(
            gatedResetRegion.contains("if isDownWedge, !isCoveredWedge {"),
            "resetResolverTransientState must skip the churn whenever coverage is live, even if the wedge marker is also held."
        )
        XCTAssertTrue(gatedResetRegion.contains("resetResolverTransientState()"))
        XCTAssertFalse(source.contains("reconnectNeededSince"))
        XCTAssertTrue(source.contains("reconnectEpisodeIsActive"))
    }

    func testDeviceResolverWedgedStaysPurelyTheDownWedgeMarker() throws {
        let source = try readSource(.packetTunnelProvider)
        // HARD CONSTRAINT (the reason the covered recapture got its own read, not the marker):
        // currentDeviceResolverWedged() — which feeds DNSResolverRuntimePlan.make's
        // deviceResolverWedged and thus treatsResolverRejectionAsFallbackTrigger (the
        // authoritative-SERVFAIL/REFUSED bypass) — must read ONLY the coordinator's active
        // reconnect episode, never the encrypted-fallback coverage signal. If a future edit routes coverage through here, a
        // transition blip would start bypassing authoritative rejections.
        let wedgedBlock = try sourceBlock(
            in: source,
            startingAt: "private func currentDeviceResolverWedged() -> Bool {",
            endingBefore: "private func orderedResolverAddressesForCurrentNetwork"
        )
        XCTAssertTrue(
            wedgedBlock.contains(
                "currentResolverHealthSchedulingView().reconnectEpisodeIsActive"
            )
        )
        XCTAssertFalse(
            wedgedBlock.contains("EncryptedFallback") || wedgedBlock.contains("isEncryptedFallbackCoveringWedge"),
            "currentDeviceResolverWedged() must stay purely the down-wedge marker — no coverage signal."
        )
        // And the rejection-trigger feed stays the marker only.
        XCTAssertTrue(source.contains("deviceResolverWedged: schedulingView.reconnectEpisodeIsActive"))
        // Canary: the ban above keys on the coverage-signal name - if it is renamed, the
        // ban passes vacuously. Anchored to the live gated call (a bare "EncryptedFallback"
        // match would be satisfied by any camelCase identifier containing it).
        XCTAssertTrue(source.contains("ProtectionConnectivityPolicy.isEncryptedFallbackCoveringWedge("))
    }

    func testResolverRuntimeIdentityUsesActorOwnedPreviousAndModeInsensitiveCurrent() throws {
        let source = try readSource(.packetTunnelProvider)
        // The actor owns the previous primary identity. The provider supplies only the current
        // mode-insensitive identity at runtime-reset boundaries; rejected-response re-scoping
        // is covered behaviorally by the pure reducer tests.
        let resetBlock = try sourceBlock(
            in: source,
            startingAt: "let currentPrimaryIdentifier = currentResolverRuntimeConfiguration(",
            endingBefore: "return pendingResponses"
        )
        XCTAssertTrue(
            resetBlock.contains(
                "let currentPrimaryIdentifier = currentResolverRuntimeConfiguration(ignoresDeviceDNSFallbackMode: true).primaryCacheIdentifier"
            ),
            "The identity-change baseline must be taken mode-insensitively so a fallback-mode flip is not a primary change (COH-1)."
        )
        XCTAssertFalse(resetBlock.contains("previousPrimaryIdentifier"))
        XCTAssertFalse(source.contains("activeResolverPrimaryIdentifier"))
    }

    // (LAV-96) The former `testEncryptedFallbackCoverageWindowExceedsRecoveryProbeCadence`
    // invariant was removed with the `encryptedFallbackCoverageWindow` constant: coverage no
    // longer lapses on a wall-clock timer, so there is no window-vs-cadence knife-edge to lock.
    // The new behaviour (idle does not lapse coverage; a sustained carried-query failure does)
    // is locked behaviourally in ProtectionConnectivityPolicyTests.

    func testEncryptedFallbackCoverageLiftsDuplicateGuardWithNoOutstandingBanner() throws {
        let source = try readSource(.packetTunnelProvider)
        // Tunnel-side mirror of the app: coverage with no outstanding banner must still lift the
        // exact-id duplicate guard so a later lapse to a same-second reconnect id isn't suppressed.
        let coverageBranch = try sourceBlock(
            in: source,
            startingAt: "} else if assessment.severity == .usingEncryptedFallback {",
            endingBefore: "// Use the pre-clear"
        )
        XCTAssertTrue(
            coverageBranch.contains("removeObject(forKey: LavaSecAppGroup.protectionLastDeliveredNotificationIDDefaultsKeyName)"),
            "Coverage with no outstanding banner must lift the duplicate-guard id (tunnel consumer)."
        )
    }

    func testResolverHealthUsesOneCoordinatorChokepoint() throws {
        let source = try readSource(.packetTunnelProvider)
        let propertyBlock = try sourceBlock(
            in: source,
            startingAt: "final class PacketTunnelProvider",
            endingBefore: "// MARK: - Tunnel lifecycle (start / stop / wake)"
        )
        XCTAssertTrue(
            propertyBlock.contains(
                "private lazy var resolverHealthCoordinator = ResolverHealthCoordinator(\n        queue: dnsStateQueue\n    )"
            )
        )
        for replacedOwner in [
            "private var deviceDNSFallbackModeActive",
            "private var consecutiveQueryFallbackSuccessCount",
            "private var consecutiveCarriedQueryFailureCount",
            "private var resolverSmokeProbeGeneration",
            "private var lastAcceptedPrimaryEvidenceAt",
            "private var activeResolverPrimaryIdentifier",
            "private var lastReconnectNeededActivityAt",
            "private var reconnectNeededSince",
            "private var reconnectNeededReason",
            "private var reconnectNeededPeakFailureCount",
        ] {
            XCTAssertFalse(propertyBlock.contains(replacedOwner), "Retained raw owner: \(replacedOwner)")
        }
        XCTAssertFalse(source.contains("private func captureResolverHealthProviderEvidence("))
        XCTAssertFalse(source.contains("private func applyResolverHealthProviderEvidence("))
        XCTAssertFalse(source.contains("ResolverHealthGateway.reduce("))

        let coordinatorBlock = try sourceBlock(
            in: source,
            startingAt: "private func applyResolverHealthEvent(",
            endingBefore: "private func applyResolverHealthTransition("
        )
        XCTAssertTrue(
            coordinatorBlock.containsInOrder([
                "dispatchPrecondition(condition: .onQueue(dnsStateQueue))",
                "let snapshot = health",
                "resolverHealthCoordinator.assumeIsolated",
                "$0.apply(event, projectingOnto: snapshot)",
                "applyResolverHealthTransition("
            ]),
            "Every non-smoke event must reduce synchronously through the queue-bound coordinator."
        )
        XCTAssertFalse(coordinatorBlock.contains("Task {"))
        XCTAssertFalse(coordinatorBlock.contains("dnsStateQueue.async"))

        let commitBlock = try sourceBlock(
            in: source,
            startingAt: "private func applyResolverHealthTransition(",
            endingBefore: "private func currentResolverHealthSchedulingView("
        )
        XCTAssertTrue(
            commitBlock.containsInOrder([
                "dispatchPrecondition(condition: .onQueue(dnsStateQueue))",
                "transition.projection.apply(to: &health)",
                "executeResolverHealthEffects("
            ]),
            "Projection must commit before emitted effects execute."
        )
        XCTAssertEqual(
            source.components(separatedBy: "transition.projection.apply(to: &health)").count - 1,
            1
        )
        XCTAssertFalse(commitBlock.contains("Task {"))
        XCTAssertFalse(commitBlock.contains("dnsStateQueue.async"))

        let schedulingViewBlock = try sourceBlock(
            in: source,
            startingAt: "private func currentResolverHealthSchedulingView(",
            endingBefore: "private func executeResolverHealthEffects("
        )
        XCTAssertTrue(
            schedulingViewBlock.contains(
                "resolverHealthCoordinator.assumeIsolated { $0.schedulingView }"
            )
        )
        XCTAssertTrue(schedulingViewBlock.contains("return dnsStateQueue.sync"))
        XCTAssertFalse(propertyBlock.contains("ResolverHealthProviderEvidence"))
        XCTAssertFalse(propertyBlock.contains("ResolverHealthEvidenceState"))

        let effectBlock = try sourceBlock(
            in: source,
            startingAt: "private func executeResolverHealthEffects(",
            endingBefore: "// MARK: - Health reset & network path monitoring"
        )
        XCTAssertTrue(effectBlock.contains("var pendingResponses: [PendingDNSResponse] = []"))
        XCTAssertTrue(effectBlock.contains("for effect in effects"))
        XCTAssertFalse(effectBlock.contains(".sorted"))
        XCTAssertFalse(effectBlock.contains(".reversed"))
        XCTAssertFalse(effectBlock.contains("Task {"))
        XCTAssertFalse(effectBlock.contains("dnsStateQueue.async"))
    }

    func testResolverHealthSchedulingGuardsReadCoordinatorViews() throws {
        let source = try readSource(.packetTunnelProvider)
        let runtimeBlock = try sourceBlock(
            in: source,
            startingAt: "private func currentResolverRuntimeConfiguration(",
            endingBefore: "private func orderedResolverAddressesForCurrentNetwork("
        )
        XCTAssertTrue(
            runtimeBlock.containsInOrder([
                "let schedulingView = currentResolverHealthSchedulingView()",
                "deviceDNSFallbackModeActive: schedulingView.deviceDNSFallbackModeActive",
                "deviceResolverWedged: schedulingView.reconnectEpisodeIsActive"
            ])
        )

        let fallbackRecoveryBlock = try sourceBlock(
            in: source,
            startingAt: "private func scheduleFallbackRecoverySmokeProbeIfNeeded()",
            endingBefore: "private func cancelFallbackRecoverySmokeProbe()"
        )
        XCTAssertGreaterThanOrEqual(
            fallbackRecoveryBlock.components(separatedBy: "currentResolverHealthSchedulingView()").count - 1,
            2,
            "Admission and delayed fire must each re-read one coherent coordinator view."
        )
        XCTAssertTrue(fallbackRecoveryBlock.contains("deviceDNSFallbackModeActive: schedulingView.deviceDNSFallbackModeActive"))
        XCTAssertTrue(fallbackRecoveryBlock.contains("consecutiveFallbackEvidenceCount: schedulingView.deviceDNSFallbackEvidenceCount"))

        let smokeSchedulingBlock = try sourceBlock(
            in: source,
            startingAt: "private func scheduleResolverSmokeProbeIfNeeded(reason: String)",
            endingBefore: "let resolverConfiguration = currentResolverRuntimeConfiguration("
        )
        XCTAssertTrue(smokeSchedulingBlock.contains("let schedulingView = currentResolverHealthSchedulingView()"))
        for field in [
            "networkPathIsSatisfied",
            "consecutiveRejectedResponseCount",
            "consecutiveSmokeProbeFailureCount",
            "consecutiveUpstreamFailureCount",
            "deviceDNSFallbackModeActive",
            "reconnectEpisodeIsActive",
            "lastAcceptedPrimaryEvidenceAt",
        ] {
            XCTAssertTrue(
                smokeSchedulingBlock.contains("schedulingView.\(field)"),
                "Smoke scheduling bypasses coordinator field: \(field)"
            )
        }

        let fallbackAccessor = try sourceBlock(
            in: source,
            startingAt: "private func currentDeviceDNSFallbackModeActive() -> Bool {",
            endingBefore: "private func refreshDeviceDNSResolverAddresses("
        )
        XCTAssertTrue(
            fallbackAccessor.contains(
                "currentResolverHealthSchedulingView().deviceDNSFallbackModeActive"
            )
        )

        for schedulingFunction in [
            "private func performCoalescedNetworkSettleProbe()",
            "private func scheduleResolverWedgeRecoveryProbeIfNeeded()",
            "private func scheduleDeviceDNSCaptureRetryIfNeeded(reason: String)",
            "private func runDeviceDNSCaptureRetry(reason: String)",
        ] {
            let block = try sourceBlock(
                in: source,
                startingAt: schedulingFunction,
                endingBefore: "\n    }"
            )
            XCTAssertTrue(
                block.contains("currentResolverHealthSchedulingView().networkPathIsSatisfied"),
                "Path scheduling bypasses coordinator in \(schedulingFunction)"
            )
        }

        let teardownBlock = try sourceBlock(
            in: source,
            startingAt: "private func performGuardedSelfReconnectTeardown(",
            endingBefore: "private static func isOnDemandConfirmedEnabled()"
        )
        XCTAssertTrue(
            teardownBlock.containsInOrder([
                "let schedulingView = self.currentResolverHealthSchedulingView()",
                "self.latestMonitoredPathIsSatisfied, schedulingView.networkPathIsSatisfied"
            ])
        )
    }

    func testResolverHealthContextWritersRouteDistinctEventsWithExactFencing() throws {
        let source = try readSource(.packetTunnelProvider)

        XCTAssertTrue(source.contains("private var tunnelLifecycleIsActive = false"))

        let lifecycleBeginBlock = try sourceBlock(
            in: source,
            startingAt: "private func beginTunnelLifecycle(reason: String)",
            endingBefore: "private func invalidateTunnelLifecycle(reason: String)"
        )
        XCTAssertTrue(
            lifecycleBeginBlock.containsInOrder([
                "tunnelLifecycleGeneration += 1",
                "tunnelLifecycleIsActive = true"
            ])
        )

        let lifecycleInvalidationBlock = try sourceBlock(
            in: source,
            startingAt: "private func invalidateTunnelLifecycle(reason: String)",
            endingBefore: "private func isCurrentTunnelLifecycle("
        )
        XCTAssertTrue(
            lifecycleInvalidationBlock.containsInOrder([
                "tunnelLifecycleGeneration += 1",
                "tunnelLifecycleIsActive = false",
                "invalidateResolverSmokeProbeToken()",
                "cancelTransientBootstrapDNSWait("
            ]),
            "Lifecycle invalidation must synchronously retire a smoke token before teardown can race a completion."
        )

        let schedulingBlock = try sourceBlock(
            in: source,
            startingAt: "private func scheduleResolverSmokeProbeIfNeeded(reason: String)",
            endingBefore: "private func resolverSmokeProbeTimeoutResult("
        )
        XCTAssertTrue(
            schedulingBlock.containsInOrder([
                "guard tunnelLifecycleIsActive else",
                "resolverHealthCoordinator.assumeIsolated { $0.beginSmokeProbe() }"
            ]),
            "A callback that outlives lifecycle invalidation must not admit a new smoke owner."
        )

        let cleanupBlock = try sourceBlock(
            in: source,
            startingAt: "private func cleanUpTunnelRuntimeAfterStop(",
            endingBefore: "private static func errorDebugDetails("
        )
        XCTAssertTrue(
            cleanupBlock.containsInOrder([
                "dnsStateQueue.async",
                "resolverProbeCoalescer.cancel()",
                "invalidateResolverSmokeProbeToken()",
                "invalidateSnapshotReloadGeneration("
            ]),
            "Final queue cleanup must retain a defense-in-depth fence after source cancellation."
        )

        let smokeInvalidationBlock = try sourceBlock(
            in: source,
            startingAt: "private func invalidateInFlightSmokeProbes()",
            endingBefore: "private func handleNetworkPathUpdate("
        )
        XCTAssertTrue(
            smokeInvalidationBlock.containsInOrder([
                "cancelFallbackRecoverySmokeProbe()",
                "invalidateResolverSmokeProbeToken()",
                "resolverHealthCoordinator.assumeIsolated { $0.invalidateInFlightSmokeProbe() }"
            ])
        )

        let resetBlock = try sourceBlock(
            in: source,
            startingAt: "private func resetHealth()",
            endingBefore: "private func startPathMonitor("
        )
        XCTAssertTrue(
            resetBlock.containsInOrder([
                "health = TunnelHealthSnapshot(networkKind:",
                "applyResolverHealthEvent(.lifecycleReset("
            ])
        )
        XCTAssertEqual(
            resetBlock.components(separatedBy: "applyResolverHealthEvent(.lifecycleReset(").count - 1,
            1
        )
        XCTAssertFalse(resetBlock.contains("reconnectNeededSince ="))
        XCTAssertFalse(resetBlock.contains("consecutiveCarriedQueryFailureCount ="))
        XCTAssertFalse(resetBlock.contains("cancelResolverWedgeRecoveryProbe()"))

        let pathBlock = try sourceBlock(
            in: source,
            startingAt: "private func handleNetworkPathUpdate(",
            endingBefore: "private func reapplyTunnelNetworkSettings("
        )
        XCTAssertTrue(pathBlock.contains(".networkPathObserved("))
        XCTAssertEqual(pathBlock.components(separatedBy: ".networkPathObserved(").count - 1, 1)
        XCTAssertTrue(
            pathBlock.containsInOrder([
                "health.networkKind = update.kind",
                ".networkPathObserved("
            ])
        )
        XCTAssertFalse(pathBlock.contains("health.networkPathIsSatisfied ="))
        XCTAssertFalse(pathBlock.contains("health.lastFailureReason ="))
        XCTAssertFalse(pathBlock.contains("collectPendingResponsesAndResetResolverRuntime("))
        XCTAssertTrue(pathBlock.contains("beforeResolverRuntimeReset:"))
        XCTAssertTrue(
            pathBlock.containsInOrder([
                "invalidateInFlightSmokeProbes()",
                "refreshDeviceDNSResolverAddressesOnDNSQueue(",
                "reason: \"network-path-changed\""
            ])
        )
        let configurationBlock = try sourceBlock(
            in: source,
            startingAt: "case LavaSecAppGroup.reloadConfigurationMessage:",
            endingBefore: "case LavaSecAppGroup.clearDiagnosticsMessage"
        )
        let resolverChangedBlock = try sourceBlock(
            in: configurationBlock,
            startingAt: "if resolverChanged {",
            endingBefore: "completion.complete(Data(\"ok\".utf8))"
        )
        XCTAssertTrue(
            resolverChangedBlock.containsInOrder([
                "applyResolverHealthEvent(.resolverConfigurationChanged(",
                "invalidateResolverSmokeProbeToken()",
                "replaceSnapshotResolver(",
                "refreshDNSRuntimeAfterSnapshotOrConfigurationChange()"
            ]),
            "Configuration persistence/effects must complete before the smoke fence and runtime replacement."
        )
        XCTAssertEqual(
            configurationBlock.components(separatedBy: ".resolverConfigurationChanged(").count - 1,
            1
        )
        XCTAssertFalse(resolverChangedBlock.contains("deviceDNSFallbackModeActive ="))
        XCTAssertFalse(resolverChangedBlock.contains("consecutiveQueryFallbackSuccessCount ="))
        XCTAssertFalse(resolverChangedBlock.contains("health.consecutiveUpstreamFailureCount ="))

        let policyResetBlock = try sourceBlock(
            in: source,
            startingAt: "private func resetDNSRuntimeForProtectionPolicyChange(",
            endingBefore: "private func resetResolverRuntimeStateIfNeeded("
        )
        XCTAssertTrue(policyResetBlock.contains("kind: .protectionPolicyRefresh"))
        XCTAssertFalse(policyResetBlock.contains("kind: .fullRuntime("))
        XCTAssertTrue(
            policyResetBlock.containsInOrder([
                "applyResolverHealthEvent(",
                ".resolverRuntimeResetOccurred("
            ])
        )
        XCTAssertEqual(
            policyResetBlock.components(separatedBy: ".resolverRuntimeResetOccurred(").count - 1,
            1
        )
        XCTAssertTrue(
            policyResetBlock.containsInOrder([
                "resolverRuntimeGeneration += 1",
                "inFlightQueryCoalescer.drainAll()",
                "dnsResponseCache.removeAll()",
                "clearEndpointHostnameNormalizationCache()",
                ".resolverRuntimeResetOccurred("
            ])
        )
        XCTAssertFalse(policyResetBlock.contains("lastAcceptedPrimaryEvidenceAt ="))
        XCTAssertFalse(policyResetBlock.contains("health.lastResolverRuntimeResetAt ="))

        let fullResetBlock = try sourceBlock(
            in: source,
            startingAt: "private func collectPendingResponsesAndResetResolverRuntime(",
            endingBefore: "private func writeServerFailures("
        )
        XCTAssertTrue(
            fullResetBlock.contains(
                "currentResolverRuntimeConfiguration(ignoresDeviceDNSFallbackMode: true).primaryCacheIdentifier"
            )
        )
        XCTAssertTrue(fullResetBlock.contains("kind: .fullRuntime("))
        XCTAssertFalse(fullResetBlock.contains("previousPrimaryIdentifier"))
        XCTAssertTrue(fullResetBlock.contains("currentPrimaryIdentifier: currentPrimaryIdentifier"))
        XCTAssertTrue(fullResetBlock.contains("recordsObservableReset: force || !isInitialActivation"))
        XCTAssertTrue(
            fullResetBlock.containsInOrder([
                "applyResolverHealthEvent(",
                ".resolverRuntimeResetOccurred("
            ])
        )
        XCTAssertEqual(
            fullResetBlock.components(separatedBy: ".resolverRuntimeResetOccurred(").count - 1,
            1
        )
        XCTAssertTrue(
            fullResetBlock.containsInOrder([
                "activeResolverRuntimeIdentifier = identifier",
                "resolverRuntimeGeneration += 1",
                "inFlightQueryCoalescer.drainAll()",
                "dnsResponseCache.removeAll()",
                "resolverBackoffPolicy.reset()",
                "resetResolverTransientState()",
                "prewarmResolverBootstrapIfNeeded()",
                ".resolverRuntimeResetOccurred("
            ])
        )
        XCTAssertFalse(fullResetBlock.contains("lastAcceptedPrimaryEvidenceAt ="))
        XCTAssertFalse(fullResetBlock.contains("health.lastResolverRuntimeResetAt ="))

        let settingsFailureBlock = try sourceBlock(
            in: source,
            startingAt: "private func recordNetworkSettingsReapplyFailure(",
            endingBefore: "// MARK: - Startup shared state"
        )
        XCTAssertTrue(settingsFailureBlock.contains(".networkSettingsReapplyFailed("))
        XCTAssertEqual(
            settingsFailureBlock.components(separatedBy: ".networkSettingsReapplyFailed(").count - 1,
            1
        )
        XCTAssertTrue(
            settingsFailureBlock.containsInOrder([
                "health.lastNetworkSettingsReapplyFailureAt = now",
                "health.lastNetworkSettingsReapplyFailureReason = failureReason",
                "health.networkSettingsReapplyFailureCount += 1",
                ".networkSettingsReapplyFailed("
            ])
        )
        XCTAssertFalse(settingsFailureBlock.contains("health.lastFailureReason ="))
        XCTAssertFalse(settingsFailureBlock.contains("markHealthUpdated()"))
        XCTAssertFalse(settingsFailureBlock.contains("persistHealthIfNeeded(force: true)"))
        XCTAssertFalse(settingsFailureBlock.contains("appendNetworkActivity("))
        XCTAssertFalse(settingsFailureBlock.contains("scheduleProtectionNotificationIfNeeded("))

        let effectBlock = try sourceBlock(
            in: source,
            startingAt: "private func executeResolverHealthEffects(",
            endingBefore: "// MARK: - Health reset & network path monitoring"
        )
        let persistCase = try sourceBlock(
            in: effectBlock,
            startingAt: "case .persistHealth",
            endingBefore: "case .evaluateProtectionNotification"
        )
        XCTAssertTrue(
            persistCase.containsInOrder([
                "markResolverHealthProjectionUpdated()",
                "if urgency == .immediate",
                "persistHealthIfNeeded(force: true)"
            ])
        )
        let notificationCase = try sourceBlock(
            in: effectBlock,
            startingAt: "case .evaluateProtectionNotification",
            endingBefore: "case .evaluateQAConnectivityLog"
        )
        XCTAssertTrue(
            notificationCase.containsInOrder([
                "beforeProtectionNotification?()",
                "scheduleProtectionNotificationIfNeeded("
            ])
        )
        let qaCase = try sourceBlock(
            in: effectBlock,
            startingAt: "case .evaluateQAConnectivityLog",
            endingBefore: "case .appendNetworkActivity"
        )
        XCTAssertTrue(qaCase.contains("logQAConnectivityAssessmentIfNeeded("))
        let activityCase = try sourceBlock(
            in: effectBlock,
            startingAt: "case .appendNetworkActivity",
            endingBefore: "case .endEncryptedFallbackLogEpisode"
        )
        XCTAssertTrue(activityCase.contains("appendNetworkActivity(event: event, now: occurredAt)"))
        let fallbackLogCase = try sourceBlock(
            in: effectBlock,
            startingAt: "case .endEncryptedFallbackLogEpisode",
            endingBefore: "case .cancelFallbackRecoveryProbe"
        )
        XCTAssertTrue(fallbackLogCase.contains("clearEncryptedFallbackLogThrottle()"))
        XCTAssertTrue(
            fallbackLogCase.contains("clearEncryptedFallbackLogThrottle(phase: \"context-reset\")")
        )
        let cancelFallbackCase = try sourceBlock(
            in: effectBlock,
            startingAt: "case .cancelFallbackRecoveryProbe",
            endingBefore: "case .cancelWedgeRecoveryProbe"
        )
        XCTAssertTrue(cancelFallbackCase.contains("cancelFallbackRecoverySmokeProbe()"))
        let cancelWedgeCase = try sourceBlock(
            in: effectBlock,
            startingAt: "case .cancelWedgeRecoveryProbe",
            endingBefore: "case .requestResolverRuntimeReset"
        )
        XCTAssertTrue(cancelWedgeCase.contains("cancelResolverWedgeRecoveryProbe()"))
        let resetCase = try sourceBlock(
            in: effectBlock,
            startingAt: "case .requestResolverRuntimeReset",
            endingBefore: "case .deliverPendingResolverFailures"
        )
        XCTAssertTrue(
            resetCase.containsInOrder([
                "beforeResolverRuntimeReset?()",
                "let resolverIdentifier =",
                "collectPendingResponsesAndResetResolverRuntime(",
                "pendingResolverIdentifier = resolverIdentifier",
                "afterResolverRuntimeReset?()"
            ]),
            "The caller-owned fence/Device-DNS refresh hook must run after earlier cancellation effects and before replacement."
        )
        let deliveryCase = try sourceBlock(
            in: effectBlock,
            startingAt: "case .deliverPendingResolverFailures",
            endingBefore: "case .clearDeviceDNSRecaptureRestartPending"
        )
        XCTAssertTrue(
            deliveryCase.containsInOrder([
                "guard let pendingResolverIdentifier else",
                "assertionFailure(",
                "beforePendingResolverFailures?(",
                "writeServerFailures(for: pendingResponses, reason: reason)"
            ])
        )
        let recaptureCase = try sourceBlock(
            in: effectBlock,
            startingAt: "case .clearDeviceDNSRecaptureRestartPending",
            endingBefore: "case .signalConnectivityProjectionChanged"
        )
        XCTAssertTrue(recaptureCase.contains("deviceDNSRecaptureRestartPending = false"))
        let signalRange = try XCTUnwrap(
            effectBlock.range(of: "case .signalConnectivityProjectionChanged:")
        )
        XCTAssertTrue(
            effectBlock[signalRange.lowerBound...].contains("signalAppIfConnectivityStateChanged()")
        )
        XCTAssertFalse(effectBlock.contains("default:"))
        XCTAssertFalse(effectBlock.contains("@unknown default"))
    }

    func testResolverSmokeCompletionUsesOneOpaqueCoordinatorToken() throws {
        let source = try readSource(.packetTunnelProvider)
        let smokeBlock = try sourceBlock(
            in: source,
            startingAt: "private func completeResolverSmokeProbeResult(",
            endingBefore: "private func applyResolverHealthEvent("
        )

        XCTAssertTrue(
            smokeBlock.containsInOrder([
                "token: ResolverSmokeProbeToken",
                "let completion = ResolverHealthSmokeProbeCompletion(",
                "occurredAt: Date()",
                "primaryResult: primaryResult",
                "primaryAccepted: primarySucceeded",
                "fallbackResult: fallbackResult",
                "fallbackAccepted: fallbackSucceeded",
                "modeInsensitivePrimaryIdentifier:",
                "currentResolverRuntimeConfiguration(ignoresDeviceDNSFallbackMode: true).primaryCacheIdentifier",
                "configuredResolverDisplayName:",
                "currentAppConfiguration().resolverPreset.displayName",
                "let snapshot = health",
                "resolverHealthCoordinator.assumeIsolated",
                "$0.completeSmokeProbe(",
                "token: token",
                "projectingOnto: snapshot",
                "applyResolverHealthTransition(transition)"
            ]),
            "Only the coordinator may admit and retire a response-free smoke completion."
        )
        for legacyMutation in [
            "health.lastDNSSmokeProbeAt =",
            "health.lastDNSSmokeProbeSucceeded =",
            "consecutiveQueryFallbackSuccessCount =",
            "deviceDNSFallbackModeActive =",
            "health.dnsSmokeProbeSuccessCount +=",
            "health.dnsSmokeProbeFailureCount +=",
            "health.lastFailureReason =",
            "markHealthUpdated()",
            "appendNetworkActivity(",
            "scheduleProtectionNotificationIfNeeded(",
            "collectPendingResponsesAndResetResolverRuntime(",
            "LavaSecDeviceDebugLog.append("
        ] {
            XCTAssertFalse(
                smokeBlock.contains(legacyMutation),
                "Smoke completion retained reducer/effect work: \(legacyMutation)"
            )
        }
        XCTAssertFalse(smokeBlock.contains("if primarySucceeded"))
        XCTAssertFalse(smokeBlock.contains("if fallbackSucceeded"))
        XCTAssertFalse(smokeBlock.contains("health."))
        XCTAssertFalse(smokeBlock.contains("resolverSmokeProbeGeneration"))
        XCTAssertFalse(source.contains("applyResolverHealthEvent(.smokeProbeCompleted"))
    }

    func testResolverHealthExecutorHandlesEverySmokeEffectInEmissionOrder() throws {
        let source = try readSource(.packetTunnelProvider)
        let effectBlock = try sourceBlock(
            in: source,
            startingAt: "private func executeResolverHealthEffects(",
            endingBefore: "// MARK: - Health reset & network path monitoring"
        )

        XCTAssertTrue(effectBlock.contains("for effect in effects"))
        for smokeEffect in [
            "case .recordIncident",
            "case .deviceLog",
            "case .reportConnectivityRecovery",
            "case .creditProductiveSelfReconnect",
            "case .evaluateSelfReconnect",
            "case .scheduleFallbackRecoveryProbe",
            "case .scheduleWedgeRecoveryProbe"
        ] {
            XCTAssertTrue(effectBlock.contains(smokeEffect), "Missing smoke effect: \(smokeEffect)")
        }
        XCTAssertFalse(effectBlock.contains(".sorted"))
        XCTAssertFalse(effectBlock.contains(".reversed"))
        XCTAssertFalse(effectBlock.contains("default:"))
        XCTAssertFalse(effectBlock.contains("preconditionFailure("))

        let incidentCase = try sourceBlock(
            in: effectBlock,
            startingAt: "case .recordIncident",
            endingBefore: "case .deviceLog"
        )
        XCTAssertTrue(
            incidentCase.containsInOrder([
                "Self.recordIncident(",
                "incident.kind",
                "reason: incident.reason",
                "durationMs: incident.durationMilliseconds",
                "verifiedBy: incident.verifiedBy",
                "now: incident.occurredAt"
            ])
        )

        let deviceLogCase = try sourceBlock(
            in: effectBlock,
            startingAt: "case .deviceLog",
            endingBefore: "case .reportConnectivityRecovery"
        )
        XCTAssertTrue(deviceLogCase.contains("appendResolverHealthDeviceLog(event)"))

        let recoveryCase = try sourceBlock(
            in: effectBlock,
            startingAt: "case .reportConnectivityRecovery",
            endingBefore: "case .creditProductiveSelfReconnect"
        )
        XCTAssertTrue(recoveryCase.contains("reportResolverConnectivityRecovery(recovery)"))

        let creditCase = try sourceBlock(
            in: effectBlock,
            startingAt: "case .creditProductiveSelfReconnect",
            endingBefore: "case .evaluateSelfReconnect"
        )
        XCTAssertTrue(
            creditCase.contains("creditProductiveSelfReconnectIfPending(now: occurredAt)")
        )

        let reconnectCase = try sourceBlock(
            in: effectBlock,
            startingAt: "case .evaluateSelfReconnect",
            endingBefore: "case .scheduleFallbackRecoveryProbe"
        )
        XCTAssertTrue(
            reconnectCase.containsInOrder([
                "ProtectionConnectivityPolicy.assessment(",
                "isConnected: true",
                "health: health",
                "now: occurredAt",
                "selfReconnectIfPolicyAllows(assessment: assessment, now: occurredAt)"
            ])
        )

        XCTAssertFalse(effectBlock.contains("case .fallbackModeChanged"))

        let fallbackScheduleCase = try sourceBlock(
            in: effectBlock,
            startingAt: "case .scheduleFallbackRecoveryProbe",
            endingBefore: "case .scheduleWedgeRecoveryProbe"
        )
        XCTAssertTrue(
            fallbackScheduleCase.contains("scheduleFallbackRecoverySmokeProbeIfNeeded()")
        )

        let wedgeScheduleCase = try sourceBlock(
            in: effectBlock,
            startingAt: "case .scheduleWedgeRecoveryProbe",
            endingBefore: "private func appendResolverHealthDeviceLog("
        )
        XCTAssertTrue(
            wedgeScheduleCase.contains("scheduleResolverWedgeRecoveryProbeIfNeeded()")
        )

        let deviceLogBlock = try sourceBlock(
            in: effectBlock,
            startingAt: "private func appendResolverHealthDeviceLog(",
            endingBefore: "private func reportResolverConnectivityRecovery("
        )
        let successLogCase = try sourceBlock(
            in: deviceLogBlock,
            startingAt: "case .smokeProbeSucceeded(",
            endingBefore: "case .smokeProbeDeviceFallback("
        )
        for mapping in [
            "event: \"dns-smoke-probe-success\"",
            "\"reason\": reason",
            "\"transport\": transport.rawValue",
            "\"resolver\": resolverAddress ?? \"nil\"",
            "\"dohHTTPVersion\": dohHTTPVersion ?? \"nil\""
        ] {
            XCTAssertTrue(successLogCase.contains(mapping), "Missing success-log mapping: \(mapping)")
        }

        let fallbackLogCase = try sourceBlock(
            in: deviceLogBlock,
            startingAt: "case .smokeProbeDeviceFallback(",
            endingBefore: "case .smokeProbeFailed("
        )
        for mapping in [
            "event: \"dns-smoke-probe-device-fallback\"",
            "\"reason\": reason",
            "\"evidenceCount\": \"\\(evidenceCount)\"",
            "\"fallbackModeActive\": \"\\(fallbackModeActive)\"",
            "\"resolver\": resolverAddress ?? \"nil\""
        ] {
            XCTAssertTrue(fallbackLogCase.contains(mapping), "Missing fallback-log mapping: \(mapping)")
        }

        let failureLogCase = try sourceBlock(
            in: effectBlock,
            startingAt: "case .smokeProbeFailed(",
            endingBefore: "private func reportResolverConnectivityRecovery("
        )
        for mapping in [
            "event: \"dns-smoke-probe-failed\"",
            "\"reason\": reason",
            "\"failure\": failure",
            "\"consecutiveSmokeFailures\": \"\\(consecutiveSmokeFailures)\"",
            "\"consecutiveRejectedResponses\": \"\\(consecutiveRejectedResponses)\""
        ] {
            XCTAssertTrue(failureLogCase.contains(mapping), "Missing failure-log mapping: \(mapping)")
        }
    }

    func testOrganicUpstreamCompletionRoutesOneCanonicalEventThroughTheCoordinator() throws {
        let source = try readSource(.packetTunnelProvider)
        let organicBlock = try sourceBlock(
            in: source,
            startingAt: "private func recordUpstreamResult(",
            endingBefore: "private func updateResolverBackoff("
        )

        XCTAssertTrue(
            organicBlock.containsInOrder([
                "updateResolverBackoff(from: result.attempts)",
                "let now = Date()",
                "health.networkKind = currentNetworkKind()",
                "let completion = ResolverHealthOrganicUpstreamCompletion(",
                "occurredAt: now",
                "result: result",
                "applyResolverHealthEvent(.organicUpstreamCompleted(completion))"
            ]),
            "Organic completion must retain backoff/envelope work and route one response-free event."
        )
        XCTAssertEqual(
            organicBlock.components(separatedBy: ".organicUpstreamCompleted(").count - 1,
            1
        )
        XCTAssertEqual(
            organicBlock.components(separatedBy: "updateResolverBackoff(").count - 1,
            1
        )
        XCTAssertEqual(
            organicBlock.components(separatedBy: "health.").count - 1,
            1,
            "Only the provider-owned network-kind envelope may remain a direct health write."
        )
        for legacyWork in [
            "if !didResolve",
            "if result.usedEncryptedFallback",
            "consecutiveQueryFallbackSuccessCount =",
            "consecutiveCarriedQueryFailureCount +=",
            "deviceDNSFallbackModeActive =",
            "lastAcceptedPrimaryEvidenceAt =",
            "scheduleResolverWedgeRecoveryProbeIfNeeded()",
            "logConnectivityRecoveredIfWedged(",
            "clearReconnectNeededActivitySuppression()",
            "cancelFallbackRecoverySmokeProbe()",
            "markHealthUpdated()",
            "appendNetworkActivity(",
            "appendReconnectNeededIfPolicyRequiresReconnect(",
            "LavaSecDeviceDebugLog.append(",
            "clearEncryptedFallbackLogThrottle()",
            "logQAConnectivityAssessmentIfNeeded(",
            "scheduleProtectionNotificationIfNeeded("
        ] {
            XCTAssertFalse(
                organicBlock.contains(legacyWork),
                "Organic provider callback retained reducer/effect work: \(legacyWork)"
            )
        }
    }

    func testResolverHealthExecutorHandlesEncryptedFallbackCarry() throws {
        let source = try readSource(.packetTunnelProvider)
        let effectBlock = try sourceBlock(
            in: source,
            startingAt: "private func executeResolverHealthEffects(",
            endingBefore: "// MARK: - Health reset & network path monitoring"
        )
        let carryCase = try sourceBlock(
            in: effectBlock,
            startingAt: "case .recordEncryptedFallbackCarry",
            endingBefore: "case .endEncryptedFallbackLogEpisode"
        )
        XCTAssertTrue(carryCase.contains("recordEncryptedFallbackCarry(carry)"))

        let carryHelper = try sourceBlock(
            in: effectBlock,
            startingAt: "private func recordEncryptedFallbackCarry(",
            endingBefore: "private func appendResolverHealthDeviceLog("
        )
        XCTAssertTrue(
            carryHelper.containsInOrder([
                "encryptedFallbackCarriedSinceLastLog += 1",
                "carry.occurredAt.timeIntervalSince($0) >= encryptedFallbackLogThrottleInterval",
                "event: \"dns-encrypted-fallback\"",
                "\"transport\": carry.transport.rawValue",
                "\"resolver\": carry.resolverAddress ?? \"nil\"",
                "\"carriedSinceLastLog\": \"\\(encryptedFallbackCarriedSinceLastLog)\"",
                "lastEncryptedFallbackLogAt = carry.occurredAt",
                "encryptedFallbackCarriedSinceLastLog = 0"
            ])
        )
        XCTAssertFalse(carryHelper.contains("domain"))
        XCTAssertFalse(carryHelper.contains("query"))
    }

    func testLegacyOrganicRecoveryHelpersAreRemovedAfterCoordinatorRouting() throws {
        let source = try readSource(.packetTunnelProvider)
        for legacyDeclaration in [
            "private func appendReconnectNeededIfPolicyRequiresReconnect(",
            "private func logConnectivityRecoveredIfWedged(",
            "private func clearReconnectNeededActivitySuppression()",
            "slowUpstreamResponseThresholdMilliseconds",
            "encryptedFallbackCoverageClearFailureThreshold",
            "reconnectNeededActivityReminderInterval"
        ] {
            XCTAssertFalse(
                source.contains(legacyDeclaration),
                "Reducer-owned organic scaffold remains: \(legacyDeclaration)"
            )
        }
    }

    func testResolverHealthReducerOwnedWritersHaveNoProviderBypasses() throws {
        let auditedSource = try readSource(.packetTunnelProvider)

        for target in [
            "health.networkPathIsSatisfied",
            "health.lastResolverAddress",
            "health.lastResolverTransport",
            "health.lastUpstreamDurationMilliseconds",
            "health.upstreamSuccessCount",
            "health.upstreamFailureCount",
            "health.consecutiveUpstreamFailureCount",
            "health.lastFailureReason",
            "health.lastUpstreamFailureAt",
            "health.lastUpstreamSuccessAt",
            "health.lastPrimaryUpstreamSuccessAt",
            "health.lastEncryptedFallbackSuccessAt",
            "health.consecutiveSlowUpstreamResponseCount",
            "health.slowUpstreamResponseCount",
            "health.lastSlowUpstreamResponseAt",
            "health.udpTruncatedResponseCount",
            "health.tcpFallbackAttemptCount",
            "health.tcpFallbackSuccessCount",
            "health.deviceDNSFallbackAttemptCount",
            "health.deviceDNSFallbackSuccessCount",
            "health.deviceDNSUnavailableCount",
            "health.lastDoHHTTPVersion",
            "health.lastDNSSmokeProbeAt",
            "health.lastDNSSmokeProbeSucceeded",
            "health.dnsSmokeProbeSuccessCount",
            "health.dnsSmokeProbeFailureCount",
            "health.consecutiveDNSSmokeProbeFailureCount",
            "health.consecutiveRejectedSmokeResponseCount",
            "health.rejectedSmokeResponseResolverIdentity",
            "health.rejectedSmokeResponseRescopeCount",
            "health.deviceDNSFallbackModeActive",
            "health.lastDeviceDNSFallbackActivatedAt",
            "health.deviceDNSFallbackActivationCount",
            "health.lastNetworkChangeAt",
            "health.networkChangeCount",
            "health.lastResolverRuntimeResetAt",
            "health.lastResolverRuntimeResetReason",
            "health.lastResolverIdentityChangeAt",
            "health.resolverRuntimeResetCount",
            "health.dohHTTPFailureCount",
            "health.upstreamTimeoutCount",
            "health.resolverAttemptCounts",
            "health.resolverSuccessCounts",
            "health.resolverFailureCounts",
            "consecutiveQueryFallbackSuccessCount",
            "consecutiveCarriedQueryFailureCount",
            "lastAcceptedPrimaryEvidenceAt",
            "reconnectNeededSince",
            "reconnectNeededReason",
            "reconnectNeededPeakFailureCount",
            "lastReconnectNeededActivityAt",
            "deviceDNSFallbackModeActive",
        ] {
            let hasDirectWrite = auditedSource.hasDirectMutation(of: target)
            XCTAssertFalse(
                hasDirectWrite,
                "Reducer-owned resolver-health write bypasses the coordinator: \(target)"
            )
        }
    }

    func testResolverHealthWriterAuditRecognizesIndirectMutationForms() {
        let counts = "health.resolverAttemptCounts"
        let reason = "health.lastFailureReason"

        XCTAssertTrue(
            "health.resolverAttemptCounts.removeAll()".hasDirectMutation(of: counts)
        )
        XCTAssertTrue(
            "consume(&\n    health.resolverAttemptCounts)".hasDirectMutation(of: counts)
        )
        XCTAssertTrue(
            "health.lastFailureReason\n    = \"mutation\"".hasDirectMutation(of: reason)
        )
        XCTAssertFalse(
            "// health.resolverAttemptCounts.removeAll()".hasDirectMutation(of: counts)
        )
        XCTAssertFalse("health.resolverAttemptCounts.isEmpty".hasDirectMutation(of: counts))
        XCTAssertFalse("health.lastFailureReason == nil".hasDirectMutation(of: reason))
    }

    func testNetworkFlapCoalescesProactiveResolverRebuild() throws {
        let source = try readSource(.packetTunnelProvider)
        let pathBlock = try sourceBlock(
            in: source,
            startingAt: "private func handleNetworkPathUpdate(",
            endingBefore: "private func reapplyTunnelNetworkSettings("
        )
        let settleProbeBlock = try sourceBlock(
            in: source,
            startingAt: "private func performCoalescedNetworkSettleProbe()",
            endingBefore: "private func doqEndpointResolvingBootstrapIfNeeded("
        )

        // Immediate teardown stays in the synchronous path-event effect sequence;
        // the provider hook still invalidates bootstrap state after replacement.
        XCTAssertTrue(pathBlock.contains(".networkPathObserved("))
        XCTAssertTrue(pathBlock.contains("afterResolverRuntimeReset:"))
        XCTAssertTrue(pathBlock.contains("resolverBootstrapService.invalidateAll()"))

        // The proactive rebuild is coalesced, not run per flap: a satisfied change
        // re-arms the settle timer, an unsatisfied change cancels it, and the
        // inline per-flap prewarm + smoke probe are gone.
        XCTAssertTrue(pathBlock.contains("resolverProbeCoalescer.noteUnsettled()"))
        XCTAssertTrue(pathBlock.contains("resolverProbeCoalescer.cancel()"))
        XCTAssertFalse(
            pathBlock.contains("scheduleResolverSmokeProbeIfNeeded(reason: \"network-path-changed\")"),
            "The smoke probe must be deferred to the coalesced settle probe, not fired on every flap."
        )
        XCTAssertFalse(
            pathBlock.contains("prewarmResolverBootstrapIfNeeded()"),
            "Bootstrap pre-warm must be deferred to the coalesced settle probe, not run on every flap."
        )

        // The deferred probe does the proactive rebuild once, gated on a live path.
        XCTAssertTrue(
            settleProbeBlock.contains(
                "guard currentResolverHealthSchedulingView().networkPathIsSatisfied else"
            )
        )
        XCTAssertTrue(settleProbeBlock.contains("prewarmResolverBootstrapIfNeeded()"))
        XCTAssertTrue(settleProbeBlock.contains("scheduleResolverSmokeProbeIfNeeded(reason: \"network-settled\")"))

        // Once the new network settles, re-capture device DNS — the capture at the
        // instant of a handoff can preserve the previous network's (now
        // unreachable) resolvers, which wedge a device-DNS user until the next
        // change. Reset the runtime only when the addresses actually changed.
        XCTAssertTrue(settleProbeBlock.contains("refreshDeviceDNSResolverAddressesOnDNSQueue(reason: \"network-settled\")"))
        XCTAssertTrue(settleProbeBlock.contains("deviceDNSResolverAddresses != previousDeviceDNSResolverAddresses"))

        // Settle window + scheduler wiring.
        XCTAssertTrue(source.contains("private let resolverProbeSettleInterval: TimeInterval = 1.5"))
        XCTAssertTrue(source.contains("NetworkSettleCoalescer("))
        XCTAssertTrue(source.contains("DispatchSettleWorkScheduler(queue: dnsStateQueue)"))
    }

    func testHandlePacketRoutesThroughDNSQueryDispatcher() throws {
        let source = try readSource(.packetTunnelProvider)
        let handleBlock = try sourceBlock(
            in: source,
            startingAt: "private func handle(packet: Data, protocolNumber: NSNumber)",
            endingBefore: "private func forward("
        )

        // The decision precedence is delegated to the pure DNSQueryDispatcher
        // (unit-tested in DNSQueryDispatcherTests); the provider supplies lazy
        // state closures and performs I/O on the returned decision.
        XCTAssertTrue(source.contains("private let dnsQueryDispatcher = DNSQueryDispatcher()"))
        XCTAssertTrue(handleBlock.contains("dnsQueryDispatcher.decide("))
        XCTAssertTrue(handleBlock.contains("bootstrapResponse: {"))
        XCTAssertTrue(handleBlock.contains("isProtectionPaused: {"))
        XCTAssertTrue(handleBlock.contains("filterDecision: {"))
        XCTAssertTrue(handleBlock.contains("case .bootstrap(let bootstrapResponse):"))
        XCTAssertTrue(handleBlock.contains("case .pausedForward:"))
        XCTAssertTrue(handleBlock.contains("case .filtered(let filterDecision):"))
        // Bootstrap still resets resolver runtime; filtered-block still builds the
        // blocked response — the per-branch I/O is unchanged.
        XCTAssertTrue(handleBlock.contains("resetResolverRuntimeStateIfNeeded(identifier: resolverConfiguration.cacheIdentifier)"))
        XCTAssertTrue(handleBlock.contains("DNSMessage.blockedResponse("))
    }

    func testSmokeProbesDoNotMutateLiveResolverBackoff() throws {
        let source = try readSource(.packetTunnelProvider)
        let smokeProbeBlock = try sourceBlock(
            in: source,
            startingAt: "private func completeResolverSmokeProbeResult",
            endingBefore: "private func resetHealth"
        )
        let queryResultBlock = try sourceBlock(
            in: source,
            startingAt: "private func recordUpstreamResult",
            endingBefore: "private func updateResolverBackoff"
        )

        XCTAssertFalse(
            smokeProbeBlock.contains("updateResolverBackoff"),
            "Smoke probes should not poison live resolver backoff or make user DNS fail."
        )
        XCTAssertTrue(
            queryResultBlock.contains("updateResolverBackoff(from: result.attempts)"),
            "Real query failures may still update resolver backoff."
        )
    }

    func testTunnelStartClearsResolverRuntimeAndRefreshesEncryptedResolverSessions() throws {
        let source = try readSource(.packetTunnelProvider)
        let startBlock = try sourceBlock(
            in: source,
            startingAt: "override func startTunnel",
            endingBefore: "override func stopTunnel"
        )
        let lifecycleResetBlock = try sourceBlock(
            in: source,
            startingAt: "private func resetResolverRuntimeForTunnelLifecycle",
            endingBefore: "private func collectPendingResponsesAndResetResolverRuntime"
        )

        XCTAssertTrue(startBlock.contains("let lifecycleGeneration = beginTunnelLifecycle(reason: \"startTunnel\")"))
        XCTAssertTrue(startBlock.contains("isCurrentTunnelLifecycle(lifecycleGeneration)"))
        XCTAssertTrue(startBlock.contains("cleanUpTunnelRuntimeAfterFailedStart"))
        XCTAssertTrue(startBlock.contains("resetResolverRuntimeForTunnelLifecycle(reason: \"startTunnel\")"))
        XCTAssertTrue(lifecycleResetBlock.contains("activeResolverRuntimeIdentifier = nil"))
        XCTAssertTrue(lifecycleResetBlock.contains("dnsResponseCache.removeAll()"))
        XCTAssertTrue(lifecycleResetBlock.contains("inFlightQueryCoalescer.drainAll()"))
        XCTAssertTrue(lifecycleResetBlock.contains("resolverBackoffPolicy.reset()"))
        XCTAssertTrue(lifecycleResetBlock.contains("dohResolver.resetSession()"))
        XCTAssertTrue(lifecycleResetBlock.contains("dotResolver.resetConnections()"))
        XCTAssertTrue(lifecycleResetBlock.contains("doqResolver.resetConnections()"))
    }

    func testTemporaryPauseExpiryRefreshesLiveActivityFromTunnel() throws {
        let source = try readSource(.packetTunnelProvider)
        let project = try readSource(.xcodeProject)
        let expiryBlock = try sourceBlock(
            in: source,
            startingAt: "private func resumeExpiredTemporaryProtectionPauseIfNeeded()",
            endingBefore: "private func currentTemporaryProtectionPauseUntil("
        )

        XCTAssertTrue(project.contains("LavaActivityAttributes.swift in Sources"))
        XCTAssertTrue(source.contains("import ActivityKit"))
        XCTAssertTrue(
            expiryBlock.contains("protectionPauseStore.clearStoredPause()"),
            "Expiry must clear stored pause through the store (no revision mint, no inline key removal)."
        )
        XCTAssertTrue(expiryBlock.contains("updateLiveActivitiesAfterTemporaryProtectionPauseExpired()"))
        XCTAssertFalse(
            expiryBlock.contains("loadSnapshotInBackground"),
            "Pause expiry must not reload the snapshot; it is identity-unchanged (plan F2)."
        )
        XCTAssertFalse(
            expiryBlock.contains("resetDNSRuntimeForProtectionPolicyChange"),
            "Pause expiry must not reset the DNS runtime; pause-era cache entries expire with the pause window."
        )
        XCTAssertTrue(source.contains("private func updateLiveActivitiesAfterTemporaryProtectionPauseExpired()"))
        XCTAssertTrue(source.contains("Activity<LavaActivityAttributes>.activities"))
        XCTAssertTrue(source.contains("LavaActivityAttributes.ContentState("))
        XCTAssertTrue(source.contains("protectionState: .on"))
        XCTAssertTrue(source.contains("pause-expired-live-activity-update"))
        // Canary: the negative pins above key on these identifiers - if a rename removes
        // one from the pinned source, those pins pass vacuously. Fail here instead, then
        // re-anchor both sides to the new name.
        XCTAssertTrue(source.contains("loadSnapshotInBackground"))
        XCTAssertTrue(source.contains("resetDNSRuntimeForProtectionPolicyChange"))
    }

    func testTunnelLifecycleBoundsTemporaryPauseToCurrentVPNSession() throws {
        let source = try readSource(.packetTunnelProvider)
        let startBlock = try sourceBlock(
            in: source,
            startingAt: "override func startTunnel",
            endingBefore: "override func stopTunnel"
        )
        let stopBlock = try sourceBlock(
            in: source,
            startingAt: "override func stopTunnel",
            endingBefore: "private static func errorDebugDetails"
        )
        let stopCleanupBlock = try sourceBlock(
            in: source,
            startingAt: "private func cleanUpTunnelRuntimeAfterStop",
            endingBefore: "private static func errorDebugDetails"
        )
        let currentPauseBlock = try sourceBlock(
            in: source,
            startingAt: "private func currentTemporaryProtectionPauseUntil(",
            endingBefore: "private var protectionPauseDefaults"
        )
        let expiryBlock = try sourceBlock(
            in: source,
            startingAt: "private func resumeExpiredTemporaryProtectionPauseIfNeeded()",
            endingBefore: "private func updateLiveActivitiesAfterTemporaryProtectionPauseExpired()"
        )

        let beginSessionIndex = try XCTUnwrap(startBlock.range(of: "beginFreshProtectionVPNSession(reason: \"startTunnel\")")?.lowerBound)
        let scheduleIndex = try XCTUnwrap(startBlock.range(of: "scheduleProtectionPauseResumeIfNeeded(reason: \"startTunnel\")")?.lowerBound)
        XCTAssertLessThan(
            beginSessionIndex,
            scheduleIndex,
            "The tunnel must clear stale pause state before scheduling pause expiry on a fresh VPN session."
        )
        XCTAssertTrue(stopBlock.contains("cleanUpTunnelRuntimeAfterStop(reason: \"stopTunnel\")"))
        XCTAssertTrue(stopCleanupBlock.contains("endProtectionVPNSession(reason: reason)"))
        XCTAssertTrue(source.contains("private func beginFreshProtectionVPNSession(reason: String)"))
        XCTAssertTrue(source.contains("private func endProtectionVPNSession(reason: String)"))
        // Session binding (pauseSessionID == activeSessionID) is enforced inside
        // ProtectionPauseStore and covered by ProtectionPauseStoreTests; the
        // tunnel must route reads and cleanup through the stores.
        XCTAssertTrue(currentPauseBlock.contains("protectionPauseStore.storedPauseStateApplyingSanityCap()"))
        XCTAssertTrue(currentPauseBlock.contains("protectionSessionStore.beginFreshSession()"))
        XCTAssertTrue(currentPauseBlock.contains("protectionSessionStore.clearActiveSessionID()"))
        XCTAssertTrue(expiryBlock.contains("protectionPauseStore.clearStoredPause()"))
    }

    func testTemporaryPauseKeepsFullPolicySnapshotLoaded() throws {
        let source = try readSource(.packetTunnelProvider)
        let loadBlock = try sourceBlock(
            in: source,
            startingAt: "private func loadCompiledSnapshot(",
            endingBefore: "private func reusableCompactSnapshot("
        )
        let activePauseBlock = try sourceBlock(
            in: source,
            startingAt: "private func isTemporaryProtectionPauseActive",
            endingBefore: "private func currentTemporaryProtectionPauseUntil("
        )

        XCTAssertFalse(loadBlock.contains("allowsTemporaryPassThrough"))
        XCTAssertFalse(loadBlock.contains("isTemporaryProtectionPauseActive()"))
        XCTAssertFalse(source.contains("canUseTemporaryPassThroughSnapshot"))
        XCTAssertTrue(loadBlock.contains("return (compactSnapshot, compactSnapshot.identity)"))
        XCTAssertTrue(loadBlock.contains("return (preparedSnapshot.snapshot, preparedSnapshot.identity)"))
        XCTAssertTrue(activePauseBlock.contains("pauseUntil > now"))
    }

    func testTunnelArtifactReadsResolveThroughThePointer() throws {
        let source = try readSource(.packetTunnelProvider)

        // The tunnel must read artifacts through the published pointer (versioned dir,
        // root fallback), not by hardcoding the root container artifact paths.
        XCTAssertTrue(
            source.contains("FilterArtifactStore(directoryURL: containerURL).readableStore()"),
            "Tunnel artifact reads must resolve through readableStore() (pointer -> versioned, root fallback)."
        )

        let loadBlock = try sourceBlock(
            in: source,
            startingAt: "private func loadCompiledSnapshot(",
            endingBefore: "private func reusableCompactSnapshot("
        )
        XCTAssertTrue(
            loadBlock.contains("readableArtifactStore()"),
            "loadCompiledSnapshot must resolve the pointer store."
        )
        XCTAssertTrue(
            loadBlock.contains("FilterArtifactStore(directoryURL: containerURL)"),
            "A resolved-store miss must fall back to the fresh root store before recompiling."
        )
        XCTAssertTrue(
            loadBlock.contains("reusableCompactSnapshot(") && loadBlock.contains("reusablePreparedSnapshot("),
            "Both reads must go through the reuse+budget gated helpers (no decode before the gate)."
        )
    }

    func testTunnelKeepsLastKnownGoodOnFailedReloadAndDoesNotFlicker() throws {
        let source = try readSource(.packetTunnelProvider)

        // A reload must only DISCARD the resident snapshot pre-decode when a reusable,
        // in-budget artifact is present (the decode is then all-but-certain). Otherwise
        // the resident is kept so a build failure (e.g. a stale-pinned-hash refresh)
        // degrades to "keep last-known-good", never to fail-closed.
        XCTAssertTrue(
            source.contains("let hasReusableArtifact = self.readCompactSnapshotSummary(configuration: configuration) != nil"),
            "Pre-decode discard must be gated on a reusable artifact being present."
        )
        // Keep-last-known-good must require the resident to be a genuine FILTERING
        // snapshot. A non-nil identity also covers the permissive pass-through built for
        // an empty config; keeping that when the new config wants filtering would fail
        // OPEN (protection connected, nothing filtered). So the keep guard must also test
        // currentResidentSnapshotHasEnabledFilters(); otherwise it falls through to
        // fail-closed.
        XCTAssertTrue(
            source.contains("if hasResidentSnapshot && !freedResidentBeforeDecode && self.currentResidentSnapshotHasEnabledFilters() {"),
            "A failed reload may only keep last-known-good when the resident is a genuine filtering snapshot."
        )
        XCTAssertTrue(
            source.contains("residentHasEnabledFilters: !configuration.enabledBlocklistIDs.isEmpty"),
            "The resident's filtering status must be committed atomically with the loaded snapshot."
        )
        XCTAssertTrue(
            source.contains("event: \"loadSnapshot-reload-failed-keeping-resident\""),
            "Keeping last-known-good on a failed reload must be observable."
        )

        // Clearing the snapshot-unavailable marker from a detached reload branch (no-op,
        // keep-resident, filters-disabled) must be generation-gated, so a stale reload
        // can't erase a newer reload's fail-closed marker and re-arm the self-reconnect
        // loop. The ungated setter must not exist for the clear path.
        XCTAssertTrue(
            source.contains("private func clearResidentFailClosedDueToUnavailableSnapshot(ifCurrentGeneration generation: UInt64)"),
            "Marker clears from detached reload branches must be generation-gated."
        )
        XCTAssertFalse(
            source.contains("setResidentFailClosedDueToUnavailableSnapshot(false)"),
            "Marker must never be cleared ungated (use the generation-gated clear)."
        )

        // A snapshot-unavailable fail-closed must NOT escalate to a self-reconnect
        // restart loop (the wedge that bricked Guard). The suppression guard must run
        // BEFORE the reconnect policy decision.
        let reconnectBlock = try sourceBlock(
            in: source,
            startingAt: "private func selfReconnectIfPolicyAllows(",
            endingBefore: "private static func isOnDemandConfirmedEnabled("
        )
        let guardRange = try XCTUnwrap(reconnectBlock.range(of: "guard !isResidentFailClosedDueToUnavailableSnapshot() else {"))
        let decisionRange = try XCTUnwrap(reconnectBlock.range(of: "TunnelSelfReconnectPolicy.decision("))
        XCTAssertTrue(
            guardRange.lowerBound < decisionRange.lowerBound,
            "Self-reconnect must be suppressed for a snapshot-unavailable fail-closed before the policy decision."
        )
        XCTAssertTrue(
            reconnectBlock.contains("event: \"self-reconnect-suppressed-snapshot-unavailable\""),
            "Suppressing self-reconnect for an unavailable snapshot must be observable."
        )
    }

    func testTunnelServesLastKnownGoodOnColdStartBuildFailure() throws {
        let source = try readSource(.packetTunnelProvider)

        // The live-reload keep-resident path only protects reloads that have an in-memory
        // resident. On a COLD start (forced by a DNS-handoff self-reconnect) there is no
        // resident, so a failed fresh (re)compile — the rotating-upstream / stale-pinned-
        // hash wedge — would fail CLOSED and clear protection to zero. loadCompiledSnapshot
        // must instead serve a config-matched last-known-good artifact from disk.
        let loadBlock = try sourceBlock(
            in: source,
            startingAt: "private func loadCompiledSnapshot(",
            endingBefore: "private func reusableCompactSnapshot("
        )

        // The compile-error catch must fall back, not return nil/fail-closed directly.
        let compileErrorRange = try XCTUnwrap(
            loadBlock.range(of: "event: \"loadSnapshot-cache-compile-error\"")
        )
        let fallbackCallRange = try XCTUnwrap(
            loadBlock.range(
                of: "return serveLastKnownGoodOrFailClosed()",
                range: compileErrorRange.upperBound ..< loadBlock.endIndex
            )
        )
        XCTAssertTrue(
            compileErrorRange.upperBound <= fallbackCallRange.lowerBound,
            "A failed in-extension recompile must attempt the last-known-good fallback, not fail closed directly."
        )

        // An over-budget FRESH compile (a same-config rotation can grow a source past the
        // budget while an older in-budget artifact for the same config still exists) must
        // also route through the fallback, not return nil and clear protection. The fallback
        // is itself budget-gated, so it can only ever serve an in-budget last-known-good.
        let overBudgetRange = try XCTUnwrap(
            loadBlock.range(of: "event: \"loadSnapshot-compiled-over-budget\"")
        )
        let overBudgetFallbackRange = try XCTUnwrap(
            loadBlock.range(
                of: "return serveLastKnownGoodOrFailClosed()",
                range: overBudgetRange.upperBound ..< loadBlock.endIndex
            )
        )
        XCTAssertTrue(
            overBudgetRange.upperBound <= overBudgetFallbackRange.lowerBound,
            "An over-budget fresh compile must attempt the last-known-good fallback before failing closed."
        )

        // The fallback is gated on the user wanting filtering (non-empty config) AND on
        // there being no keepable resident, so an empty config still returns the permissive
        // pass-through and a live reload keeps its in-memory snapshot.
        XCTAssertTrue(
            loadBlock.contains("if !hasKeepableFilteringResident, !configuration.enabledBlocklistIDs.isEmpty {"),
            "The last-known-good fallback must only serve for a filtering config with no keepable resident."
        )
        XCTAssertTrue(
            loadBlock.contains("event: \"loadSnapshot-last-known-good\""),
            "Serving a last-known-good artifact on a failed cold-start build must be observable."
        )

        // The disk decode is COLD-START ONLY: it must be gated on there being no keepable
        // filtering resident, so a live reload that still holds a healthy resident keeps it
        // in memory (the caller's existing keep-resident branch) instead of decoding a
        // multi-MB artifact and risking the 2x-resident jetsam peak.
        let keepableGateRange = try XCTUnwrap(
            loadBlock.range(of: "let hasKeepableFilteringResident = self.currentResidentSnapshotIdentity() != nil")
        )
        XCTAssertTrue(
            loadBlock.contains("&& self.currentResidentSnapshotHasEnabledFilters()"),
            "The keepable-resident gate must require the resident to be a genuine filtering snapshot."
        )
        let lastKnownGoodEventRange = try XCTUnwrap(
            loadBlock.range(of: "event: \"loadSnapshot-last-known-good\"")
        )
        XCTAssertTrue(
            keepableGateRange.upperBound <= lastKnownGoodEventRange.lowerBound,
            "The disk last-known-good decode must be gated on no keepable filtering resident (cold-start only)."
        )

        // The fallback reader must use the config-only gate (canServeAsLastKnownGood),
        // NOT the strict catalog-hash gate — otherwise it would reject the very artifact
        // the rotated catalog invalidated and we would still fail closed.
        let fallbackBlock = try sourceBlock(
            in: source,
            startingAt: "private func lastKnownGoodCompactSnapshot(",
            endingBefore: "private func reusablePreparedSnapshot("
        )
        XCTAssertTrue(
            fallbackBlock.contains("summary.canServeAsLastKnownGood(for: configuration)"),
            "The last-known-good reader must gate on the config-only predicate, not the strict catalog-hash gate."
        )
        XCTAssertTrue(
            fallbackBlock.contains("FilterSnapshotMemoryBudget.exceedsBudget(ruleCount: ruleCount)"),
            "The last-known-good reader must still enforce the compact memory budget before decoding."
        )
    }

    func testReusablePreparedSnapshotRebindsToManifestAndRebudgetsAfterDecode() throws {
        let source = try readSource(.packetTunnelProvider)
        let preparedBlock = try sourceBlock(
            in: source,
            startingAt: "private func reusablePreparedSnapshot(",
            endingBefore: "private func loadPreparedSnapshot("
        )

        // The manifest and prepared file are read separately, so a concurrent root
        // republish can pair an in-budget manifest with over-budget prepared bytes.
        // The decoded prepared must be re-bound to the manifest it was budget-gated on
        // (identity + generatedAt + summary, mirroring FilterArtifactStore.preparedSelection)
        // and re-budgeted against its OWN summary before it can become resident — never
        // weaker than the baseline it replaced.
        XCTAssertTrue(
            preparedBlock.contains("prepared.identity == manifest.snapshotIdentity"),
            "Prepared decode must re-bind to the manifest identity (no manifest<->prepared skew)."
        )
        XCTAssertTrue(
            preparedBlock.contains("prepared.snapshot.generatedAt == manifest.generatedAt"),
            "Prepared decode must re-bind to the manifest generation."
        )
        XCTAssertTrue(
            preparedBlock.contains("prepared.summary == manifest.summary"),
            "Prepared decode must re-bind to the manifest summary (the budget-gated counts)."
        )
        // Authority budget gate is the DECODED prepared's own counts, not the manifest's.
        XCTAssertTrue(
            preparedBlock.contains("let ruleCount = prepared.summary.blockRuleCount + prepared.summary.allowRuleCount + prepared.summary.guardrailRuleCount"),
            "Budget must be re-checked against the decoded prepared's own summary post-decode."
        )
        XCTAssertTrue(
            preparedBlock.contains("FilterSnapshotMemoryBudget.exceedsBudget(ruleCount: ruleCount)"),
            "An over-budget decoded prepared must be refused before becoming resident."
        )
    }

    func testTunnelDoesNotFallBackToUnboundLegacySnapshots() throws {
        let source = try readSource(.packetTunnelProvider)
        let loadBlock = try sourceBlock(
            in: source,
            startingAt: "private func loadCompiledSnapshot(",
            endingBefore: "private func reusableCompactSnapshot("
        )
        let initialStateBlock = try sourceBlock(
            in: source,
            startingAt: "private func loadInitialSharedState() -> Bool",
            endingBefore: "private func refreshConfigurationIfNeeded"
        )
        let loadSnapshotBlock = try sourceBlock(
            in: source,
            startingAt: "private func loadSnapshotInBackground(reason: String, operationID: LatencyOperationID? = nil)",
            endingBefore: "private func scheduleProtectionPauseResumeIfNeeded"
        )

        XCTAssertFalse(source.contains("loadLegacyPersistedSnapshot"))
        XCTAssertTrue(loadBlock.contains("let baseSnapshot = configuration.filterSnapshot()"))
        // The in-extension compile streams sources into a memory-mapped CompactFilterSnapshot
        // (never a dirty union), so the resident snapshot is the 9 B/rule mapped-compact form
        // and the last-line resident gate is the compact device budget (`exceedsBudget` /
        // `maxFilterRuleCount`) — the same ceiling the app's mapped artifact uses. The
        // streaming compiler enforces its own (lower) transient ceiling and fails closed
        // before this point. A post-upgrade re-parse that overshoots fails closed instead of
        // jetsamming the extension.
        XCTAssertTrue(loadBlock.contains("FilterSnapshotMemoryBudget.exceedsBudget(ruleCount: compiledRuleCount)"))
        XCTAssertTrue(loadBlock.contains("configuration.enabledBlocklistIDs.isEmpty ? (baseSnapshot, expectedIdentity) : nil"))
        // The compiler call is now nested inside the CON-3 single-flight gate closure (see
        // testInExtensionCompileIsSingleFlightedAndSkipsDoomedGenerations), so it sits one
        // indent deeper than before — the compiler itself is unchanged.
        XCTAssertTrue(loadBlock.contains("CachedFilterSnapshotCompiler(\n                    cacheDirectoryURL: catalogCacheURL\n                )"))
        // Scratch from a jetsam-killed compile is reclaimed ONCE at startTunnel, before any
        // reload spawns a compile — NOT per-compile, which would race a concurrent reload's
        // in-flight scratch dir. So the sweep must be absent from the compile path and sit
        // before the transient wait is armed and before the startTunnel snapshot load.
        XCTAssertFalse(loadBlock.contains("sweepStaleScratch"))
        XCTAssertTrue(source.contains(
            "CachedFilterSnapshotCompiler.sweepStaleScratch(cacheDirectoryURL: catalogCacheURL)\n            }\n            if shouldBeginTransientBootstrapDNSWaitAfterNetworkSettings {\n                self.beginTransientBootstrapDNSWait(reason: \"setTunnelNetworkSettings-success\")\n            }\n            self.loadSnapshotInBackground(reason: \"startTunnel\""
        ))
        XCTAssertTrue(initialStateBlock.contains("FailClosedRuntimeSnapshot(resolver: configuration.resolverPreset)"))
        XCTAssertTrue(loadSnapshotBlock.contains("FailClosedRuntimeSnapshot(resolver: configuration.resolverPreset)"))
        XCTAssertTrue(loadSnapshotBlock.contains("\"resolver\": configuration.resolverDiagnosticDisplayName"))
        XCTAssertFalse(loadSnapshotBlock.contains("\"resolver\": runtimeSnapshot.resolver.displayName"))
        // Canary: the negative pins above key on these identifiers - if a rename removes
        // one from the pinned source, those pins pass vacuously. Fail here instead, then
        // re-anchor both sides to the new name.
        XCTAssertTrue(source.contains("runtimeSnapshot"))
    }

    func testLoadInitialSharedStatePersistsAPruneThatHappenedDuringLoad() throws {
        let source = try readSource(.packetTunnelProvider)
        let initialStateBlock = try sourceBlock(
            in: source,
            startingAt: "private func loadInitialSharedState() -> Bool",
            endingBefore: "private func refreshConfigurationIfNeeded"
        )

        // A prune performed inside DiagnosticsPersistence.load (the fine-grained retention
        // window elapsed at an idle start) sets the store's pending-prune flag, NOT the
        // persistence controller's dirty flag — so loadInitialSharedState must consume that
        // flag and force a persist, or the stale on-disk events linger until the next DNS
        // event dirties diagnostics, breaking the on-disk retention guarantee.
        XCTAssertTrue(initialStateBlock.contains("consumePendingFineGrainedPrunePersist()"))
        XCTAssertTrue(initialStateBlock.contains("prunedDuringLoad || diagnosticsPersistence.isDirty"))
        XCTAssertTrue(initialStateBlock.contains("persistDiagnosticsIfNeeded(force: true)"))
    }

    func testLoadInitialSharedStateWarmResumesFromDiskBeforeFailingClosed() throws {
        let source = try readSource(.packetTunnelProvider)
        let initialStateBlock = try sourceBlock(
            in: source,
            startingAt: "private func loadInitialSharedState() -> Bool",
            endingBefore: "private func refreshConfigurationIfNeeded"
        )
        let bootstrapBlock = try sourceBlock(
            in: source,
            startingAt: "private func bootstrapResidentSnapshotFromDisk(",
            endingBefore: "private func reusablePreparedSnapshot("
        )

        // A non-empty config attempts a synchronous on-disk fast-resume BEFORE installing the
        // block-all FailClosedRuntimeSnapshot — eliminating the cold-start (post-self-reconnect)
        // false-positive window whenever a serviceable in-budget artifact exists.
        XCTAssertTrue(initialStateBlock.contains("bootstrapResidentSnapshotFromDisk(configuration: configuration)"))
        // Resume installs a real resident: wrapped like the async commit, identity set so the
        // immediately-following async load hits the no-op reload gate, and marked filtering.
        XCTAssertTrue(initialStateBlock.contains("base: resumed.snapshot"))
        XCTAssertTrue(initialStateBlock.contains("bootstrapIdentity = resumed.identity"))
        XCTAssertTrue(initialStateBlock.contains("bootstrapHasEnabledFilters = true"))
        // NEVER fail open: no serviceable / over-cap artifact still installs fail-closed.
        XCTAssertTrue(initialStateBlock.contains("FailClosedRuntimeSnapshot(resolver: configuration.resolverPreset)"))
        // The bootstrap FULLY OWNS the resident markers in EVERY branch (unconditional reset),
        // so a same-instance startTunnel retry after a setTunnelNetworkSettings failure cannot
        // carry a stale "healthy filtering resident" marker into a later fail-closed bootstrap
        // (Codex P2 — would make the async loader keep the block-all snapshot unmarked).
        XCTAssertTrue(initialStateBlock.contains("residentSnapshotIdentity = bootstrapIdentity"))
        XCTAssertTrue(initialStateBlock.contains("residentSnapshotHasEnabledFilters = bootstrapHasEnabledFilters"))
        XCTAssertTrue(initialStateBlock.contains("residentFailClosedDueToUnavailableSnapshot = false"))
        // The resident-state install is confined to snapshotQueue: a detached snapshot load from
        // a prior provider lifecycle (not cancelled on stop/restart) may read these queue-guarded
        // markers concurrently with this new start. Two critical sections: release-before-decode
        // then install — the release frees a same-instance restart's prior resident so the
        // bootstrap decode doesn't stack into a 2x-resident jetsam peak.
        XCTAssertEqual(initialStateBlock.components(separatedBy: "snapshotQueue.sync {").count - 1, 2)
        XCTAssertTrue(initialStateBlock.contains("snapshot = FilterSnapshot(blockRules: DomainRuleSet())"))

        // The bootstrap reuses the SAME budget/header-gated strict-reuse helper as the async
        // path, and on a strict miss falls back to config-exact LAST-KNOWN-GOOD (INV-DNS-1,
        // founder decision 2026-07-09, UR-48 Phase 2a) — strict is tried FIRST so current rules
        // always win over stale ones, and LKG runs only over the sync-eligible (capped,
        // summary-schema) stores so the startTunnel path stays bounded.
        XCTAssertTrue(bootstrapBlock.contains("reusableCompactSnapshot("))
        XCTAssertTrue(bootstrapBlock.contains("lastKnownGoodCompactSnapshot("))
        XCTAssertTrue(
            try XCTUnwrap(bootstrapBlock.range(of: "reusableCompactSnapshot(")).lowerBound
                < XCTUnwrap(bootstrapBlock.range(of: "lastKnownGoodCompactSnapshot(")).lowerBound,
            "strict reuse must be attempted before the last-known-good fallback"
        )
        XCTAssertTrue(bootstrapBlock.contains("bootstrap-last-known-good-resume"))
        // BOTH synchronous reads — strict AND the LKG fallback — re-enforce the decode cap on
        // the same bytes they decode (the LKG read is a separate read from the pre-gate, so an
        // atomic republish in between could otherwise slip an over-cap artifact into a
        // synchronous startTunnel decode — PR #330 review).
        XCTAssertEqual(bootstrapBlock.components(separatedBy: "syncDecodeRuleCap: cap").count - 1, 2)
        XCTAssertTrue(bootstrapBlock.contains("Self.maxSynchronousBootstrapRuleCount"))
        XCTAssertTrue(source.contains("maxSynchronousBootstrapRuleCount = 1_000_000"))
        // The gate MUST run via the skip-only readSyncBootstrapInfo BEFORE any reuse/LKG read
        // (which call readSummary): it both caps the size AND excludes legacy (pre-summary-schema)
        // artifacts, which readSummary would full-decode — and reusableCompactSnapshot would then
        // decode again — doubling the synchronous decode on cold start.
        XCTAssertTrue(bootstrapBlock.contains("CompactFilterSnapshot.readSyncBootstrapInfo(from: data)"))
        XCTAssertTrue(bootstrapBlock.contains("info.hasStoredSummary"))
        XCTAssertTrue(bootstrapBlock.contains("info.totalRuleCount > cap"))
        // The pre-gate is best-effort; the cap is RE-ENFORCED authoritatively inside
        // reusableCompactSnapshot on the same mmapped bytes it decodes, so an atomic republish
        // between the two reads can't slip an over-cap artifact into a synchronous decode.
        XCTAssertTrue(bootstrapBlock.contains("syncDecodeRuleCap: cap"))
        XCTAssertTrue(source.contains("syncDecodeRuleCap: Int? = nil"))
        // NEVER fail open: with neither a strict nor an LKG candidate the bootstrap still
        // installs the block-all snapshot (the FailClosedRuntimeSnapshot pin above) — the
        // LKG fallback loops eligibleStores and returns nil past it.
        XCTAssertTrue(bootstrapBlock.contains("strict-and-lkg-miss"))
    }

    func testWakePreservesResolverRuntimeAcrossBriefSleeps() throws {
        let source = try readSource(.packetTunnelProvider)
        let wakeBlock = try sourceBlock(
            in: source,
            startingAt: "override func wake()",
            endingBefore: "#if DEBUG || LAVA_QA_TOOLS"
        )

        // sleep() stamps the suspension start on dnsStateQueue (INV-QUEUE-1) and signals the
        // OS completion only after the stamp lands.
        XCTAssertTrue(source.contains("override func sleep(completionHandler: @escaping () -> Void)"))
        XCTAssertTrue(source.contains("self?.resolverSleepBeganAt = Date()"))

        // wake() consumes-and-clears the stamp, so a wake with no paired sleep (nil) takes the
        // conservative teardown, and decides via the pure policy (behaviorally tested in
        // DeviceDNSFallbackPolicyTests).
        XCTAssertTrue(wakeBlock.contains("let sleepBeganAt = self.resolverSleepBeganAt"))
        XCTAssertTrue(wakeBlock.contains("self.resolverSleepBeganAt = nil"))
        XCTAssertTrue(wakeBlock.contains("DeviceDNSFallbackPolicy.shouldPreserveResolverRuntimeAcrossWake("))
        // Preservation additionally requires the wake device-DNS capture to keep the SAME
        // effective resolver identity (captured before vs after the refresh): a handoff that
        // adopts different resolvers must take the full reset even after a brief sleep, or
        // in-flight completions from the old runtime stay valid against the new resolvers.
        XCTAssertTrue(wakeBlock.contains("let preWakeResolverIdentifier = self.currentResolverRuntimeConfiguration().cacheIdentifier"))
        XCTAssertTrue(wakeBlock.contains("if resolverIdentifier == preWakeResolverIdentifier,"))

        // The preserve path must still arm the safety nets — settle probe (probe-confirm /
        // wedge recovery) and the capture-retry schedule — and must NOT SERVFAIL pending
        // queries or tear down the runtime; the full-reset path below it stays intact.
        // It MUST drop the response cache: a same-identity network swap (Wi-Fi→Wi-Fi with an
        // identical device resolver) is invisible to the identity guard and to the path
        // handler's meaningful-change test, and cached answers have no failure-driven
        // self-heal the way dead sockets do.
        XCTAssertTrue(wakeBlock.contains("self.dnsResponseCache.removeAll()"))
        // ...and the bootstrap hostname→IP cache, which prewarm otherwise keeps serving even
        // through a later wedge reset (both the preserve path AND the full-reset path
        // invalidate it — hence exactly two occurrences).
        XCTAssertEqual(wakeBlock.components(separatedBy: "resolverBootstrapService.invalidateAll()").count - 1, 2)
        XCTAssertTrue(wakeBlock.contains("wake-resolver-reset-skipped"))
        XCTAssertEqual(wakeBlock.components(separatedBy: "resolverProbeCoalescer.noteUnsettled()").count - 1, 2)
        XCTAssertEqual(wakeBlock.components(separatedBy: "scheduleDeviceDNSCaptureRetryIfNeeded(reason: \"wake\")").count - 1, 2)
        XCTAssertEqual(wakeBlock.components(separatedBy: "collectPendingResponsesAndResetResolverRuntime(").count - 1, 1)
        XCTAssertEqual(wakeBlock.components(separatedBy: "writeServerFailures(for: pendingResponses, reason: \"wake\")").count - 1, 1)
        // Stale-verdict guard runs on EVERY wake, before the preserve decision.
        XCTAssertTrue(wakeBlock.contains("self.invalidateInFlightSmokeProbes()"))
    }

    func testChronicFailureBackoffThrottlesOnlyTheRoutineSmokeProbe() throws {
        let source = try readSource(.packetTunnelProvider)
        let probeBlock = try sourceBlock(
            in: source,
            startingAt: "private func scheduleResolverSmokeProbeIfNeeded(reason: String)",
            endingBefore: "let resolverConfiguration = currentResolverRuntimeConfiguration("
        )

        // Backoff gates on the ROUTINE reason only — the same scoping rule as NRG-3a — so
        // wedge/fallback-recovery/settle/config/startTunnel probes are never delayed. Both
        // routine-only gates key on the literal reason string.
        XCTAssertEqual(probeBlock.components(separatedBy: "reason == \"periodic-health-check\"").count - 1, 2)
        XCTAssertTrue(probeBlock.contains("DeviceDNSFallbackPolicy.smokeProbeBackoffActivationFailureCount"))
        XCTAssertTrue(probeBlock.contains("DeviceDNSFallbackPolicy.routineSmokeProbeInterval("))
        // Clock-jump guard: a negative elapsed probes normally instead of trusting a future
        // stamp (mirrors the NRG-3a evidence-age guard).
        XCTAssertTrue(probeBlock.contains("sinceLastWireProbe >= 0"))
        // The wire stamp is set where the probe actually goes to the wire, so skipped ticks
        // never push the anchor forward.
        XCTAssertTrue(source.contains("lastWireSmokeProbeAt = Date()"))
        // dnsStateQueue-confined state per INV-QUEUE-1.
        XCTAssertTrue(source.contains("private var lastWireSmokeProbeAt: Date?"))

        // Log hygiene (same plan item): the dnsStateQueue capture read gates its
        // `device-dns-captured` line on episode transitions via the pure policy, carries the
        // suppressed-repeat tally on the next allowed line, and the gate state is
        // queue-confined. The off-queue refresh variant stays unconditionally logged.
        let dnsQueueRefreshBlock = try sourceBlock(
            in: source,
            startingAt: "private func refreshDeviceDNSResolverAddressesOnDNSQueue(",
            endingBefore: "private static func currentSystemDNSServerAddresses()"
        )
        XCTAssertTrue(dnsQueueRefreshBlock.contains("DeviceDNSFallbackPolicy.shouldLogDeviceDNSCapture("))
        XCTAssertTrue(dnsQueueRefreshBlock.contains("suppressedRepeats"))
        // Gate is context-aware: a masked→masked handoff under a new `reason` still logs, so the
        // gate reads AND writes the last-logged reason alongside the count.
        XCTAssertTrue(dnsQueueRefreshBlock.contains("lastLoggedReason: lastLoggedDeviceDNSCaptureReason"))
        XCTAssertTrue(dnsQueueRefreshBlock.contains("lastLoggedDeviceDNSCaptureReason = reason"))
        XCTAssertTrue(source.contains("private var lastLoggedDeviceDNSCaptureCount: Int?"))
        XCTAssertTrue(source.contains("private var lastLoggedDeviceDNSCaptureReason: String?"))
    }

    func testTransientBootstrapFailClosedQueuesRecentSelfReconnectQueriesInsteadOfBlocking() throws {
        let source = try readSource(.packetTunnelProvider)
        let startTunnelBlock = try sourceBlock(
            in: source,
            startingAt: "override func startTunnel",
            endingBefore: "override func stopTunnel"
        )
        let initialStateBlock = try sourceBlock(
            in: source,
            startingAt: "private func loadInitialSharedState() -> Bool",
            endingBefore: "private func recordDiagnostic("
        )
        let filteredBlock = try sourceBlock(
            in: source,
            startingAt: "case .filtered(let filterDecision):",
            endingBefore: "// `resolverConfiguration` is taken from the caller"
        )
        let enqueueBlock = try sourceBlock(
            in: source,
            startingAt: "private func enqueueTransientBootstrapDNSRequestIfNeeded(",
            endingBefore: "private func drainTransientBootstrapDNSWait("
        )

        // Phase E2: the wait's STATE (64-deep/4 s bounds, active flag, generation +
        // expired-generation markers, pending queue, timer handle, overflow-log dedup)
        // moved into TransientBootstrapDNSWait (LavaSecDNS), where the INV-DNS-2
        // bounds and transitions are EXECUTABLE (TransientBootstrapDNSWaitTests)
        // instead of text-pinned constants and ivars. What stays compiler-invisible
        // is the WIRING: the provider must route the wait through the machine on the
        // confinement queue and feed it the CURRENT lifecycle generation per call —
        // the machine never owns tunnelLifecycleGeneration.
        XCTAssertTrue(source.contains("private lazy var transientBootstrapDNSWait = TransientBootstrapDNSWait<PendingDNSResponse>("))
        XCTAssertTrue(source.contains("queue: dnsStateQueue,"))

        XCTAssertTrue(initialStateBlock.contains("let launchFollowsRecentSelfReconnect = Self.launchFollowsRecentSelfReconnect(now: Date())"))
        XCTAssertTrue(startTunnelBlock.contains("let shouldBeginTransientBootstrapDNSWaitAfterNetworkSettings = loadInitialSharedState()"))
        XCTAssertTrue(startTunnelBlock.contains("if shouldBeginTransientBootstrapDNSWaitAfterNetworkSettings"))
        XCTAssertTrue(startTunnelBlock.contains("self.beginTransientBootstrapDNSWait(reason: \"setTunnelNetworkSettings-success\")"))
        XCTAssertTrue(initialStateBlock.contains("cancelTransientBootstrapDNSWait(reason: \"loadInitialSharedState\")"))
        XCTAssertTrue(initialStateBlock.contains("return shouldBeginTransientBootstrapDNSWait"))
        XCTAssertTrue(enqueueBlock.contains("filterDecision.action == .block"))
        XCTAssertTrue(enqueueBlock.contains("filterDecision.reason == .protectionUnavailable"))
        XCTAssertTrue(enqueueBlock.contains("failClosedReason == \"transient-protection-unavailable\""))
        // Phase E2: the admission transitions (expired-generation latecomer, stale
        // lifecycle, 64-cap overflow with one-shot log dedup, first-append marker)
        // are executable in TransientBootstrapDNSWaitTests. The wiring pins below
        // hold the provider to: consulting the machine under the CURRENT lifecycle
        // generation, and mapping its decisions onto the unchanged SERVFAIL reasons
        // and device-log events. (Actors slice 3: the wait is a dispatch-backed
        // actor; confined regions reach it through
        // `transientBootstrapDNSWait.assumeIsolated { wait in … }`, so the pins
        // anchor on the isolated `wait` calls.)
        XCTAssertTrue(enqueueBlock.contains("wait.enqueue(pending, generation: tunnelLifecycleGeneration)"))
        XCTAssertTrue(enqueueBlock.containsInOrder([
            "case .rejectExpiredGeneration:",
            "serverFailureReason = \"transient-bootstrap-dns-wait-timeout\"",
            "case .notHandled:",
            "return false",
            "case .rejectOverflow(let logOnce, let pendingCount):",
            "serverFailureReason = \"transient-bootstrap-dns-wait-overflow\"",
            "if logOnce {",
            "case .queued(let isFirst):",
            "if isFirst {"
        ]))
        XCTAssertTrue(
            initialStateBlock.contains("Queued DNS is not forwarded while the snapshot is unavailable"),
            "The self-reconnect transient wait must document that queued DNS is held fail-closed, not forwarded past filtering."
        )

        let enqueueIndex = try XCTUnwrap(filteredBlock.range(of: "enqueueTransientBootstrapDNSRequestIfNeeded(")?.lowerBound)
        let diagnosticIndex = try XCTUnwrap(filteredBlock.range(of: "recordDiagnostic(")?.lowerBound)
        let syntheticBlockIndex = try XCTUnwrap(filteredBlock.range(of: "DNSMessage.blockedResponse(")?.lowerBound)
        XCTAssertLessThan(enqueueIndex, diagnosticIndex)
        XCTAssertLessThan(enqueueIndex, syntheticBlockIndex)

        let settingsSuccessIndex = try XCTUnwrap(startTunnelBlock.range(of: "setTunnelNetworkSettings-success")?.lowerBound)
        let waitBeginIndex = try XCTUnwrap(startTunnelBlock.range(of: "self.beginTransientBootstrapDNSWait(reason: \"setTunnelNetworkSettings-success\")")?.lowerBound)
        let snapshotLoadIndex = try XCTUnwrap(startTunnelBlock.range(of: "self.loadSnapshotInBackground(reason: \"startTunnel\"")?.lowerBound)
        let readPacketsIndex = try XCTUnwrap(startTunnelBlock.range(of: "self.readPackets()")?.lowerBound)
        XCTAssertLessThan(settingsSuccessIndex, waitBeginIndex)
        XCTAssertLessThan(waitBeginIndex, snapshotLoadIndex)
        XCTAssertLessThan(waitBeginIndex, readPacketsIndex)
    }

    func testTransientBootstrapDNSWaitDrainsOnSnapshotLoadAndSERVFAILsOnTimeoutOrOverflow() throws {
        let source = try readSource(.packetTunnelProvider)
        let loadSnapshotBlock = try sourceBlock(
            in: source,
            startingAt: "private func loadSnapshotInBackground(reason: String, operationID: LatencyOperationID? = nil)",
            endingBefore: "private func scheduleProtectionPauseResumeIfNeeded"
        )
        let drainBlock = try sourceBlock(
            in: source,
            startingAt: "private func drainTransientBootstrapDNSWait(",
            endingBefore: "private func failTransientBootstrapDNSWait("
        )
        let enqueueBlock = try sourceBlock(
            in: source,
            startingAt: "private func enqueueTransientBootstrapDNSRequestIfNeeded(",
            endingBefore: "private func drainTransientBootstrapDNSWait("
        )
        let invalidateLifecycleBlock = try sourceBlock(
            in: source,
            startingAt: "private func invalidateTunnelLifecycle(reason: String)",
            endingBefore: "private func isCurrentTunnelLifecycle"
        )
        let failBlock = try sourceBlock(
            in: source,
            startingAt: "private func failTransientBootstrapDNSWait(",
            endingBefore: "private func replayTransientBootstrapDNSRequests("
        )
        let replayBlock = try sourceBlock(
            in: source,
            startingAt: "private func replayTransientBootstrapDNSRequests(",
            endingBefore: "private func recordDiagnostic("
        )
        let writeServerFailureBlock = try sourceBlock(
            in: source,
            startingAt: "private func writeServerFailures(",
            endingBefore: "private func filterDecision(for domain:"
        )

        XCTAssertTrue(loadSnapshotBlock.contains("drainTransientBootstrapDNSWait(reason: \"snapshot-loaded-\\(reason)\")"))
        XCTAssertTrue(loadSnapshotBlock.contains("failTransientBootstrapDNSWait(reason: \"snapshot-unavailable-\\(reason)\")"))
        XCTAssertTrue(loadSnapshotBlock.containsInOrder([
            "if didCommitFailClosed {",
            "self.failTransientBootstrapDNSWait(reason: \"snapshot-unavailable-\\(reason)\")",
            "}"
        ]))
        XCTAssertTrue(invalidateLifecycleBlock.contains("cancelTransientBootstrapDNSWait(reason: \"lifecycle-invalidated-\\(reason)\")"))
        XCTAssertTrue(drainBlock.contains("let drain = { [self] () ->"))
        XCTAssertTrue(failBlock.contains("let fail = { [self] () ->"))
        // Phase E2: the generation-match/stale-lifecycle split and the timeout's
        // expired-generation stamping are executable transitions in
        // TransientBootstrapDNSWaitTests. These pins hold the WIRING: drain/fail
        // consult the machine under the CURRENT lifecycle generation, a stale
        // lifecycle's queue goes to SERVFAIL (never replay), and only the TIMEOUT
        // reason marks the generation expired. (Actors slice 3: anchored on the
        // isolated `wait` calls inside the regions' assumeIsolated blocks.)
        XCTAssertTrue(drainBlock.contains("wait.drain(currentGeneration: tunnelLifecycleGeneration)"))
        XCTAssertTrue(drainBlock.containsInOrder([
            "case .staleLifecycle(let pendingResponses):",
            "case .replay(let pendingResponses, let replayGeneration):"
        ]))
        XCTAssertTrue(drainBlock.contains("transient-bootstrap-dns-wait-stale-lifecycle"))
        XCTAssertTrue(drainBlock.contains("expectedLifecycleGeneration: result.replayGeneration"))
        XCTAssertTrue(failBlock.contains("writeServerFailures(for: pendingResponses, reason: reason)"))
        XCTAssertTrue(failBlock.contains("let isTimeout = reason == \"transient-bootstrap-dns-wait-timeout\""))
        XCTAssertTrue(failBlock.contains("marksGenerationExpired: isTimeout"))
        XCTAssertTrue(replayBlock.contains("expectedLifecycleGeneration: UInt64?"))
        XCTAssertTrue(replayBlock.contains("self.isCurrentTunnelLifecycle(expectedLifecycleGeneration)"))
        XCTAssertTrue(replayBlock.contains("transient-bootstrap-dns-wait-stale-lifecycle"))
        XCTAssertTrue(replayBlock.contains("allowsTransientBootstrapDeferral: false"))
        XCTAssertTrue(replayBlock.contains("expectedLifecycleGeneration: expectedLifecycleGeneration"))
        XCTAssertFalse(replayBlock.contains("for (index, pending) in pendingResponses.enumerated()"))
        XCTAssertTrue(replayBlock.contains("for pending in pendingResponses"))
        // Phase E2: the finish/reset transition (timer cancel, both generation
        // markers cleared, overflow dedup reset, queue handed back) is executable —
        // TransientBootstrapDNSWaitTests
        // .testTeardownReturnsTheQueueForSERVFAILAndResetsForTheNextLifecycle —
        // so the old finishTransientBootstrapDNSWaitOnDNSQueue text pins are gone.
        XCTAssertTrue(source.contains("wait.cancelWait()"))
        XCTAssertTrue(source.contains("let cancel = { [self] () ->"))
        XCTAssertTrue(failBlock.contains("event: \"transient-bootstrap-dns-wait-timeout\""))
        XCTAssertTrue(enqueueBlock.contains("event: \"transient-bootstrap-dns-wait-overflow\""))

        XCTAssertTrue(writeServerFailureBlock.contains("event: \"pending-dns-servfail\""))
        XCTAssertFalse(writeServerFailureBlock.contains("event: \"resolver-runtime-pending-servfail\""))
        XCTAssertTrue(writeServerFailureBlock.contains("\"reason\": reason"))
        XCTAssertTrue(writeServerFailureBlock.contains("\"pendingResponses\": \"\\(pendingResponses.count)\""))
    }

    func testSnapshotArtifactMissDiagnosticsExplainFastResumeFailures() throws {
        let source = try readSource(.packetTunnelProvider)
        let loadCompiledBlock = try sourceBlock(
            in: source,
            startingAt: "private func loadCompiledSnapshot(",
            endingBefore: "private func reusableCompactSnapshot("
        )
        let bootstrapBlock = try sourceBlock(
            in: source,
            startingAt: "private func bootstrapResidentSnapshotFromDisk(",
            endingBefore: "private func reusablePreparedSnapshot("
        )

        // Async load misses must carry route + controlled reason tokens. A raw expected identity
        // does not survive bug-report redaction and does not explain why the artifact was missed.
        XCTAssertTrue(loadCompiledBlock.contains("event: \"loadSnapshot-store-miss\""))
        XCTAssertTrue(loadCompiledBlock.contains("\"route\": route"))
        XCTAssertTrue(loadCompiledBlock.contains("resolved.directoryURL == rootStore.directoryURL ? \"root\" : \"resolved\""))
        XCTAssertTrue(loadCompiledBlock.contains("\"compactReason\": compactResult.missReason ?? \"unknown\""))
        XCTAssertTrue(loadCompiledBlock.contains("\"preparedReason\": preparedResult.missReason ?? \"unknown\""))
        XCTAssertTrue(loadCompiledBlock.contains("\"generation\": \"\\(generation)\""))
        XCTAssertFalse(loadCompiledBlock.contains("\"expected\": expectedIdentity.fingerprint"))

        // Synchronous bootstrap misses must explain whether the startup gap was caused by no
        // readable artifact, legacy/over-cap pre-gating, or a strict reuse miss.
        XCTAssertTrue(bootstrapBlock.contains("event: \"bootstrap-store-miss\""))
        XCTAssertTrue(bootstrapBlock.contains("event: \"bootstrap-fast-resume-miss\""))
        XCTAssertTrue(bootstrapBlock.contains("\"route\": route"))
        XCTAssertTrue(bootstrapBlock.contains("resolved.directoryURL == rootStore.directoryURL ? \"root\" : \"resolved\""))
        XCTAssertTrue(bootstrapBlock.contains("\"storeCount\": \"\\(artifactStores.count)\""))
        XCTAssertTrue(bootstrapBlock.contains("\"eligibleStoreCount\": \"\\(eligibleStores.count)\""))
        XCTAssertTrue(bootstrapBlock.contains("\"ruleCount\": \"\\(info.totalRuleCount)\""))
        XCTAssertTrue(bootstrapBlock.contains("\"syncCap\": \"\\(cap)\""))
        XCTAssertTrue(bootstrapBlock.contains("event: \"bootstrap-skip-legacy-artifact\", details: [\n                    \"route\": route,"))
        XCTAssertTrue(bootstrapBlock.contains("event: \"bootstrap-over-sync-cap\", details: [\n                    \"route\": route,"))
        XCTAssertTrue(bootstrapBlock.contains("event: \"bootstrap-compact-resume\", details: [\n                    \"route\": route,"))
    }

    func testConfigurationRefreshMarkersAreQueueConfinedNotWrittenOffQueue() throws {
        let source = try readSource(.packetTunnelProvider)
        let initialStateBlock = try sourceBlock(
            in: source,
            startingAt: "private func loadInitialSharedState() -> Bool",
            endingBefore: "private func refreshConfigurationIfNeeded"
        )
        let loadSnapshotBlock = try sourceBlock(
            in: source,
            startingAt: "private func loadSnapshotInBackground(reason: String, operationID: LatencyOperationID? = nil)",
            endingBefore: "private func scheduleProtectionPauseResumeIfNeeded"
        )

        // CON-6: the lastConfigurationRefreshAt / lastConfigurationModifiedAt markers are
        // dnsStateQueue-confined (every other access runs via refreshConfigurationIfNeeded on
        // that queue). A prior-lifecycle detached snapshot load can still be inside
        // loadSnapshotInBackground and touch the same markers on dnsStateQueue while a new
        // off-queue startTunnel runs loadInitialSharedState — so those writes must be routed
        // through the queue too (mirroring setAppConfiguration / nextSnapshotReloadGeneration),
        // not left as bare off-queue property mutations.
        XCTAssertTrue(
            initialStateBlock.contains(
                "dnsStateQueue.sync {\n            lastConfigurationModifiedAt = configurationModifiedAt\n            lastConfigurationRefreshAt = Date()\n        }"
            ),
            "loadInitialSharedState must write the configuration-refresh markers on dnsStateQueue, not off-queue."
        )
        // The snapshot of the modification date is read off-queue (a plain disk read) and only
        // the assignment is confined — so no bare off-queue write of either marker may remain.
        XCTAssertFalse(
            initialStateBlock.contains("\n        lastConfigurationModifiedAt = modificationDate(for: configurationURL)"),
            "The lastConfigurationModifiedAt write must not run off-queue in loadInitialSharedState."
        )
        XCTAssertFalse(
            initialStateBlock.contains("\n        lastConfigurationRefreshAt = Date()"),
            "The lastConfigurationRefreshAt write must not run off-queue in loadInitialSharedState."
        )

        // The one dnsStateQueue block in loadSnapshotInBackground that refreshes the same
        // markers (via refreshConfigurationIfNeeded) must be generation-gated like every other
        // dnsStateQueue access in that method, so a superseded prior-lifecycle load can't refresh
        // the current lifecycle's markers out from under its loadInitialSharedState.
        let syncRefreshRange = try XCTUnwrap(
            loadSnapshotBlock.range(of: "self.dnsStateQueue.sync {"),
            "loadSnapshotInBackground must confine the config refresh to a dnsStateQueue.sync block."
        )
        let gatedRefresh = String(loadSnapshotBlock[syncRefreshRange.lowerBound...])
        let gateRange = try XCTUnwrap(
            gatedRefresh.range(of: "guard self.isCurrentSnapshotReloadGeneration(generation) else"),
            "The dnsStateQueue.sync config-refresh block must re-check the reload generation."
        )
        let refreshRange = try XCTUnwrap(
            gatedRefresh.range(of: "self.refreshConfigurationIfNeeded(force: true)"),
            "The dnsStateQueue.sync block must still refresh the configuration when current."
        )
        XCTAssertTrue(
            gateRange.lowerBound < refreshRange.lowerBound,
            "The generation re-check must precede refreshConfigurationIfNeeded in the sync block."
        )
        // Canary: the pins above key on these identifiers - a rename must trip here, not pass
        // the assertions vacuously.
        XCTAssertTrue(source.contains("lastConfigurationRefreshAt"))
        XCTAssertTrue(source.contains("lastConfigurationModifiedAt"))
    }

    func testProtectionStateRefreshClearsInFlightQueriesEvenWhenResolverIsUnchanged() throws {
        let source = try readSource(.packetTunnelProvider)
        let refreshBlock = try sourceBlock(
            in: source,
            startingAt: "private func refreshDNSRuntimeAfterSnapshotOrConfigurationChange()",
            endingBefore: "private func resetResolverRuntimeStateIfNeeded"
        )
        let resetBlock = try sourceBlock(
            in: source,
            startingAt: "private func resetDNSRuntimeForProtectionPolicyChange",
            endingBefore: "private func resetResolverRuntimeStateIfNeeded"
        )

        XCTAssertTrue(refreshBlock.contains("resetDNSRuntimeForProtectionPolicyChange"))
        XCTAssertTrue(resetBlock.contains("resolverRuntimeGeneration += 1"))
        XCTAssertTrue(resetBlock.contains("inFlightQueryCoalescer.drainAll()"))
        XCTAssertTrue(resetBlock.contains("dnsResponseCache.removeAll()"))
        XCTAssertTrue(resetBlock.contains("writeServerFailures(for: pendingResponses, reason: reason)"))
    }

    func testReloadSnapshotRequestsAreCoalescedAndEpochGuarded() throws {
        let source = try readSource(.packetTunnelProvider)
        let appMessageBlock = try sourceBlock(
            in: source,
            startingAt: "override func handleAppMessage",
            endingBefore: "case LavaSecAppGroup.reloadConfigurationMessage"
        )
        let loadBlock = try sourceBlock(
            in: source,
            startingAt: "private func loadSnapshotInBackground(reason: String, operationID: LatencyOperationID? = nil)",
            endingBefore: "private func scheduleProtectionPauseResumeIfNeeded"
        )
        let replaceSnapshotBlock = try sourceBlock(
            in: source,
            startingAt: "private func replaceSnapshot(",
            endingBefore: "private func currentResidentSnapshotIdentity"
        )
        let replaceSnapshotApplyBlock = try sourceBlock(
            in: replaceSnapshotBlock,
            startingAt: "let applyIfStillCurrent: () -> Void = { [self] in",
            endingBefore: "\n        }\n\n        if DispatchQueue.getSpecific"
        )
        let clearUnavailableBlock = try sourceBlock(
            in: source,
            startingAt: "private func clearResidentFailClosedDueToUnavailableSnapshot(",
            endingBefore: "private func isResidentFailClosedDueToUnavailableSnapshot"
        )
        let clearUnavailableApplyBlock = try sourceBlock(
            in: clearUnavailableBlock,
            startingAt: "let applyIfStillCurrent: () -> Void = { [self] in",
            endingBefore: "\n        }\n\n        if DispatchQueue.getSpecific"
        )

        let reloadCoordinatorProperty = "private lazy var snapshotReloadCoordinator = "
            + "SnapshotReloadCoordinator(queue: dnsStateQueue)"
        XCTAssertTrue(
            source.contains(reloadCoordinatorProperty),
            "Snapshot reload state must execute on the provider's dnsStateQueue-backed coordinator."
        )
        XCTAssertFalse(
            source.contains("private var snapshotReloadGeneration"),
            "The provider must not retain a second raw generation state mirror."
        )
        XCTAssertFalse(
            source.contains("private var snapshotReloadInFlight"),
            "The provider must not retain a second raw in-flight state mirror."
        )
        XCTAssertTrue(source.contains("private var lastAppliedTemporaryProtectionPauseIsActive = false"))
        XCTAssertTrue(source.contains("private func requestSnapshotReload(reason: String, force: Bool = false, operationID: LatencyOperationID? = nil)"))
        XCTAssertTrue(source.contains("private func nextSnapshotReloadGeneration() -> UInt64"))
        XCTAssertTrue(
            source.contains("return snapshotReloadCoordinator.assumeIsolated { $0.begin() }"),
            "The provider's reload chokepoint must delegate generation ownership to the coordinator."
        )
        XCTAssertTrue(
            source.contains("return snapshotReloadCoordinator.assumeIsolated { $0.isCurrent(generation) }"),
            "All existing commit gates must resolve through the coordinator-backed generation adapter."
        )
        let liveGenerationGuard = "guard isCurrentSnapshotReloadGeneration(generation) else {"
        let replaceGuardIdx = try XCTUnwrap(
            replaceSnapshotApplyBlock.range(of: liveGenerationGuard)?.lowerBound
        )
        let replaceMutationIdx = try XCTUnwrap(
            replaceSnapshotApplyBlock.range(of: "snapshotQueue.sync {")?.lowerBound
        )
        XCTAssertLessThan(
            replaceGuardIdx,
            replaceMutationIdx,
            "replaceSnapshot must generation-fence the snapshotQueue mutation inside its apply closure."
        )
        XCTAssertEqual(
            replaceSnapshotBlock.components(separatedBy: liveGenerationGuard).count - 1,
            1,
            "replaceSnapshot must have one block-scoped live-generation commit guard."
        )
        let clearGuardIdx = try XCTUnwrap(
            clearUnavailableApplyBlock.range(of: liveGenerationGuard)?.lowerBound
        )
        let clearMutation = "snapshotQueue.sync { residentFailClosedDueToUnavailableSnapshot = false }"
        let clearMutationIdx = try XCTUnwrap(
            clearUnavailableApplyBlock.range(of: clearMutation)?.lowerBound
        )
        XCTAssertLessThan(
            clearGuardIdx,
            clearMutationIdx,
            "The fail-closed marker clear must remain generation-fenced inside its apply closure."
        )
        XCTAssertEqual(
            clearUnavailableBlock.components(separatedBy: liveGenerationGuard).count - 1,
            1,
            "The fail-closed marker clear must have one block-scoped live-generation guard."
        )
        XCTAssertTrue(
            appMessageBlock.contains("reason: \"appMessage\","),
            "Snapshot reload app messages must force a reload and carry the caller's operation id."
        )
        XCTAssertTrue(appMessageBlock.contains("operationID: providerMessage.operationID.map(LatencyOperationID.init(rawValue:))"))
        XCTAssertTrue(appMessageBlock.contains("case LavaSecAppGroup.reloadProtectionPauseMessage:"))
        XCTAssertTrue(
            appMessageBlock.contains("refreshProtectionPauseStateOnly(reason: \"protectionPause\")"),
            "Pause messages must refresh pause state without forcing a snapshot reload (plan F2)."
        )
        XCTAssertFalse(
            appMessageBlock.contains("requestSnapshotReload(reason: \"protectionPause\")"),
            "Pause flips must not reset the DNS runtime or reload the snapshot."
        )
        // The CFNotificationCenter Darwin-notify IPC was removed: it never fired
        // reliably in the NE extension (0 callbacks across 14 device probe runs)
        // and sendProviderMessage is the sole tunnel IPC. Guard reintroduction.
        XCTAssertFalse(source.contains("CFNotificationCenterAddObserver"))
        XCTAssertFalse(source.contains("handlePauseStateChangedDarwinNotification"))
        XCTAssertFalse(source.contains("refreshProtectionPauseStateOnly(reason: \"darwin-pause\")"))

        let appGroupSource = try readSource(.appGroup)
        XCTAssertFalse(
            appGroupSource.contains("DarwinNotificationName"),
            "The Darwin-notify name aliases were removed with the unreliable observer path."
        )
        XCTAssertTrue(loadBlock.contains("guard self.isCurrentSnapshotReloadGeneration(generation) else"))
        XCTAssertTrue(loadBlock.contains("self.refreshConfigurationIfNeeded(force: true)"))
        XCTAssertTrue(loadBlock.contains("protectionPolicySnapshot: runtimePolicySnapshot,"))
        XCTAssertTrue(loadBlock.contains("identity: loaded.identity"))
        // The cheap no-op gate must skip the decode when the on-disk artifact
        // matches the resident snapshot, and the genuine-change path must drop
        // the resident snapshot (fail-closed) before decoding to avoid the
        // 2x-resident memory peak that jetsams the extension.
        XCTAssertTrue(loadBlock.contains("residentSnapshotSatisfiesReload(configuration: configuration)"))
        XCTAssertTrue(loadBlock.contains("loadSnapshot-reload-noop"))
        XCTAssertTrue(loadBlock.contains("loadSnapshot-failclosed-before-decode"))
        // Tunnel backstop: an over-budget artifact must be refused (fail-closed)
        // before the decode, never jetsam.
        XCTAssertTrue(loadBlock.contains("compactSnapshotRuleCountExceedingBudget(configuration: configuration)"))
        XCTAssertTrue(loadBlock.contains("loadSnapshot-over-budget"))

        let refreshConfigIndex = try XCTUnwrap(loadBlock.range(of: "self.refreshConfigurationIfNeeded(force: true)")?.lowerBound)
        let replaceSnapshotIndex = try XCTUnwrap(loadBlock.range(of: "self.replaceSnapshot(\n                runtimeSnapshot")?.lowerBound)
        XCTAssertLessThan(
            refreshConfigIndex,
            replaceSnapshotIndex,
            "Snapshot reloads must apply config before replacing runtime snapshots so DNS transport state matches the newest config."
        )
    }

    func testReloadNoOpGateAcceptsResidentCompiledFromIdenticalInputs() throws {
        let source = try readSource(.packetTunnelProvider)
        let gateBlock = try sourceBlock(
            in: source,
            startingAt: "private func residentSnapshotSatisfiesReload",
            endingBefore: "private func readableArtifactStore"
        )

        // UR-48 follow-up log: with the artifact store lagging the cached catalog
        // (reuse:inputs miss on every read), the disk-only no-op gate could never
        // pass, so every appMessage reload repeated the identical in-extension
        // streaming compile — observed 6.9 s / 356k rules per reload. A resident
        // compiled from EXACTLY the inputs the reload would compile from must
        // satisfy the reload without any on-disk artifact.
        XCTAssertTrue(
            gateBlock.contains(
                "residentIdentity.hasSameSnapshotInputs(\n               as: PreparedFilterSnapshotIdentity.make(configuration: configuration, catalog: cachedCatalog)\n           )"
            ),
            "The no-op gate must compare the resident identity against the identity this reload would stamp (same construction as loadCompiledSnapshot)."
        )
        // The resident-identity branch must mirror the disk gate's transport check —
        // hasSameSnapshotInputs deliberately excludes resolverTransport.
        XCTAssertTrue(
            gateBlock.contains("residentIdentity.resolverTransport == configuration.resolverPreset.transport"),
            "A transport change must fall through to a full reload, matching the disk-summary gate."
        )
        // Fail-closed residents commit with a nil identity; a nil identity must never
        // satisfy a reload (recovery reloads must run).
        XCTAssertTrue(
            gateBlock.contains("guard let residentIdentity = currentResidentSnapshotIdentity() else {\n            return false\n        }"),
            "A missing resident identity (fail-closed resident) must never no-op a reload."
        )
        // The disk-artifact path is preserved for residents adopted from disk whose
        // inputs legitimately lag the catalog (e.g. after a pointer publish).
        XCTAssertTrue(
            gateBlock.contains("readCompactSnapshotSummary(configuration: configuration)"),
            "The disk-summary reuse check must remain as the second gate."
        )
    }

    func testTunnelRetainsCompiledArtifactAndFastResumesFromIt() throws {
        let source = try readSource(.packetTunnelProvider)

        // UR-48 root cause: when the app-published artifact store lags the cached
        // catalog, EVERY tunnel start strict-missed fast-resume, served the transient
        // fail-closed bootstrap window, and repeated a ~7 s streaming recompile. The
        // tunnel now retains its own successful compile at a stable path and every
        // artifact reader accepts it as a LAST, identity-gated candidate.

        // Write side: the in-extension compile passes the retained path into the
        // compiler (retention is atomic + best-effort inside the compiler).
        let compileBlock = try sourceBlock(
            in: source,
            startingAt: "private func loadCompiledSnapshot(",
            endingBefore: "private func reusableCompactSnapshot("
        )
        XCTAssertTrue(
            compileBlock.contains("retainedArtifactURL: self?.tunnelCompiledArtifactStore?.compactSnapshotURL"),
            "The in-extension compile must retain its artifact for the next cold start."
        )
        XCTAssertTrue(
            compileBlock.contains("if let tunnelCompiledStore = retainedTunnelCompiledArtifactStoreIfPresent() {"),
            "The async load must accept the retained compile as a candidate store."
        )

        // Read side: cold-start fast-resume tries [resolved, root, tunnel-compiled];
        // the retained compile is LAST so app-published stores keep precedence.
        let bootstrapBlock = try sourceBlock(
            in: source,
            startingAt: "private func bootstrapResidentSnapshotFromDisk",
            endingBefore: "private func reusablePreparedSnapshot"
        )
        let rootAppendRange = try XCTUnwrap(
            bootstrapBlock.range(of: "artifactStores.append((store: rootStore, route: \"root\"))"),
            "Expected the root store append in bootstrapResidentSnapshotFromDisk."
        )
        let tunnelAppendRange = try XCTUnwrap(
            bootstrapBlock.range(of: "artifactStores.append((store: tunnelCompiledStore, route: \"tunnel-compiled\"))"),
            "Cold-start fast-resume must include the retained tunnel compile."
        )
        XCTAssertTrue(
            rootAppendRange.lowerBound < tunnelAppendRange.lowerBound,
            "The retained tunnel compile must be the LAST fast-resume candidate."
        )

        // The no-op / over-budget gates must judge the same candidate set the load
        // adopts, so the summary reader includes the retained store too.
        let summaryBlock = try sourceBlock(
            in: source,
            startingAt: "private func readCompactSnapshotSummary",
            endingBefore: "private func replaceSnapshotResolver"
        )
        XCTAssertTrue(
            summaryBlock.contains("if let tunnelCompiledStore = retainedTunnelCompiledArtifactStoreIfPresent() {"),
            "readCompactSnapshotSummary must stay consistent with loadCompiledSnapshot's candidates."
        )

        // The read-side accessor is presence-gated so devices that never in-extension
        // compile add no per-start store-miss logging, and the retained artifact lives
        // under the catalog cache dir — never inside the app-owned store/pointer layout.
        let accessorBlock = try sourceBlock(
            in: source,
            startingAt: "private static let tunnelCompiledArtifactDirectoryName",
            endingBefore: "private var configurationURL"
        )
        XCTAssertTrue(
            accessorBlock.contains("FileManager.default.fileExists(atPath: store.compactSnapshotURL.path)"),
            "The retained store must only join the candidate list once a compile was actually retained."
        )
        XCTAssertTrue(
            accessorBlock.contains("catalogCacheURL.map {"),
            "The retained artifact must live under the catalog cache dir, outside the app-owned artifact store layout."
        )
    }

    func testInExtensionCompileIsSingleFlightedAndSkipsDoomedGenerations() throws {
        let source = try readSource(.packetTunnelProvider)
        let compileBlock = try sourceBlock(
            in: source,
            startingAt: "private func loadCompiledSnapshot(",
            endingBefore: "private func reusableCompactSnapshot("
        )

        // CON-3: the ~32 MiB in-extension compile is the jetsam-risk peak. The reload
        // generation only fences the COMMIT — without these two guards, two overlapping
        // reloads (a first-start compile still running when a pull-to-refresh requests
        // another) each run a full compile peak, ≈60 MiB in the 50 MB-limited NE process.

        // (a) A generation re-check must precede the compiler call so a superseded reload
        //     skips the doomed compile entirely rather than spending the peak.
        //     loadCompiledSnapshot now takes the reload generation for exactly this check.
        XCTAssertTrue(
            source.contains("private func loadCompiledSnapshot(\n        configuration: AppConfiguration,\n        generation: UInt64\n    )"),
            "loadCompiledSnapshot must receive the reload generation to re-check before compiling."
        )
        XCTAssertTrue(
            source.contains("loadCompiledSnapshot(configuration: configuration, generation: generation)"),
            "The reload must thread its generation into loadCompiledSnapshot."
        )
        let recheckRange = try XCTUnwrap(
            compileBlock.range(of: "guard isCurrentSnapshotReloadGeneration(generation) else"),
            "The compile must re-check the reload generation immediately before the compiler."
        )
        XCTAssertTrue(
            compileBlock.contains("event: \"loadSnapshot-compile-skipped-stale\""),
            "A doomed compile skip must be observable in the device log."
        )

        // (b) The compile itself must run behind the single-flight gate so two reloads can
        //     never hold two compile peaks at once. The gate holds exclusivity across the
        //     whole await (an actor alone would interleave at the await).
        XCTAssertTrue(source.contains("private let snapshotCompileGate = SnapshotCompileGate()"))
        let gateRange = try XCTUnwrap(
            compileBlock.range(of: "try await snapshotCompileGate.run {"),
            "The in-extension compile must be serialized behind snapshotCompileGate.run."
        )
        // The doomed-compile re-check must PRECEDE the gated compile (skip before queueing).
        XCTAssertTrue(
            recheckRange.lowerBound < gateRange.lowerBound,
            "The generation re-check must come before the gated compile so a superseded reload never enters the gate."
        )
        // The gate wraps the compiler call — the CachedFilterSnapshotCompiler().compile must
        // live inside the gate closure, not run unguarded.
        let compilerCallRange = try XCTUnwrap(
            compileBlock.range(of: "CachedFilterSnapshotCompiler(\n                    cacheDirectoryURL: catalogCacheURL\n                ).compile("),
            "The compiler call must be nested inside the single-flight gate closure."
        )
        XCTAssertTrue(gateRange.lowerBound < compilerCallRange.lowerBound)
        // No unguarded compiler invocation may remain outside the gate closure.
        XCTAssertFalse(
            compileBlock.contains("let compiled = try await CachedFilterSnapshotCompiler("),
            "The compile must not be invoked directly (outside the gate) anymore."
        )

        // (c) CON-3 (Codex #213): the generation must ALSO be re-checked INSIDE the gate closure.
        //     The pre-gate check (a) only catches supersession before entering the gate; a reload
        //     that queues behind an earlier compile can be superseded WHILE it waits its turn, so
        //     the in-gate re-check bails the doomed compile before the peak. It sits between the
        //     gate open and the compiler call and throws the sentinel routed to the fallback.
        let inGateRecheckRange = try XCTUnwrap(
            compileBlock.range(of: "self?.isCurrentSnapshotReloadGeneration(generation) ?? false else"),
            "The compile gate closure must re-check the reload generation before invoking the compiler."
        )
        XCTAssertTrue(
            gateRange.lowerBound < inGateRecheckRange.lowerBound
                && inGateRecheckRange.lowerBound < compilerCallRange.lowerBound,
            "The in-gate generation re-check must sit inside the gate closure, before the compiler (Codex #213)."
        )
        XCTAssertTrue(
            compileBlock.contains("throw SnapshotCompileSuperseded()")
                && compileBlock.contains("event: \"loadSnapshot-compile-skipped-stale-in-gate\""),
            "A superseded-in-gate compile must throw the sentinel and be observable in the device log."
        )

        // (d) CON-3 (Codex #213): a superseded generation must return nil, NOT a fallback decode.
        //     serveLastKnownGoodOrFailClosed() materializes a multi-MB last-known-good that the stale
        //     commit discards and that can overlap the winning compile — reintroducing the peak the
        //     gate prevents. The caller re-checks the generation and bails on nil, so nil is correct.
        //     Both superseded paths (pre-gate skip and in-gate catch) must return nil.
        let supersededCatchStart = try XCTUnwrap(
            compileBlock.range(of: "catch is SnapshotCompileSuperseded {")?.upperBound
        )
        let afterSupersededCatch = String(compileBlock[supersededCatchStart...])
        let supersededCatchBody = String(
            afterSupersededCatch[..<(afterSupersededCatch.range(of: "} catch {")?.lowerBound ?? afterSupersededCatch.endIndex)]
        )
        XCTAssertTrue(
            supersededCatchBody.contains("return nil"),
            "The in-gate superseded catch must return nil (Codex #213)."
        )
        XCTAssertFalse(
            supersededCatchBody.contains("serveLastKnownGoodOrFailClosed"),
            "The in-gate superseded catch must NOT decode a fallback — return nil (Codex #213)."
        )
        // The pre-gate skip must likewise return nil, not the fallback.
        XCTAssertTrue(
            compileBlock.contains("event: \"loadSnapshot-compile-skipped-stale\", details: [\n                \"generation\": \"\\(generation)\"\n            ])\n            return nil"),
            "The pre-gate superseded skip must return nil, not decode a fallback (Codex #213)."
        )

        // (e) CON-3 (Codex #213 P1): a SECOND generation re-check must sit AFTER the compiler call but
        //     still inside the gate closure. A reload superseded WHILE the compile runs must discard the
        //     result BEFORE `run` returns and releases the gate — otherwise the next queued compile
        //     starts while this stale caller still holds its multi-MB result, and the two overlap and
        //     recreate the peak. So there are TWO in-gate re-checks: one before compile, one after.
        let postCompileRecheckRange = try XCTUnwrap(
            compileBlock.range(
                of: "self?.isCurrentSnapshotReloadGeneration(generation) ?? false else",
                range: compilerCallRange.upperBound..<compileBlock.endIndex
            ),
            "The gate closure must re-check the generation AFTER the compiler call (Codex #213 P1)."
        )
        let afterGateBudgetCheckRange = try XCTUnwrap(
            compileBlock.range(of: "let compiledRuleCount = compiled.blockRuleCount"),
            "expected the post-gate budget check as the boundary marker"
        )
        XCTAssertTrue(
            postCompileRecheckRange.lowerBound < afterGateBudgetCheckRange.lowerBound,
            "The post-compile re-check must be INSIDE the gate closure, before it returns (Codex #213 P1)."
        )
        XCTAssertLessThan(
            inGateRecheckRange.lowerBound, postCompileRecheckRange.lowerBound,
            "The two in-gate re-checks must be distinct: one before the compiler, one after (Codex #213 P1)."
        )

        // (f) CON-3 (Codex #213): the shared fallback sink is gated on generation currency at its ROOT,
        //     so EVERY caller (missing catalog, over-budget, compile-error catch) skips the multi-MB
        //     last-known-good decode when superseded — closing the class instead of patching each site.
        let serveBlockStart = try XCTUnwrap(
            compileBlock.range(of: "func serveLastKnownGoodOrFailClosed()")?.upperBound
        )
        let serveGuardRange = try XCTUnwrap(
            compileBlock.range(
                of: "guard self.isCurrentSnapshotReloadGeneration(generation) else",
                range: serveBlockStart..<compileBlock.endIndex
            ),
            "serveLastKnownGoodOrFailClosed must guard on generation currency (Codex #213)."
        )
        let lastKnownGoodDecodeRange = try XCTUnwrap(
            compileBlock.range(
                of: "self.lastKnownGoodCompactSnapshot(",
                range: serveBlockStart..<compileBlock.endIndex
            )
        )
        XCTAssertLessThan(
            serveGuardRange.lowerBound, lastKnownGoodDecodeRange.lowerBound,
            "The generation guard must precede the multi-MB last-known-good decode in the sink (Codex #213)."
        )
    }

    func testProviderMessagesDecodeOperationEnvelopeAndLogReceiveReplySpans() throws {
        let source = try readSource(.packetTunnelProvider)
        let appMessageCompletionBlock = try sourceBlock(
            in: source,
            startingAt: "private struct AppMessageCompletion",
            endingBefore: "private final class ResolverWorkCompletion"
        )
        let appMessageBlock = try sourceBlock(
            in: source,
            startingAt: "override func handleAppMessage",
            endingBefore: "private func readPackets()"
        )

        XCTAssertTrue(appMessageCompletionBlock.contains("let latencySpan: LatencySpan?"))
        XCTAssertTrue(appMessageCompletionBlock.contains("latencySpan?.end(details: [\"status\": response == nil ? \"nil-reply\" : \"reply\"])"))
        XCTAssertTrue(appMessageBlock.contains("guard let providerMessage = LavaSecProviderMessageCodec.decode(messageData)"))
        XCTAssertTrue(appMessageBlock.contains("let message = providerMessage.kind"))
        XCTAssertTrue(appMessageBlock.contains("operationID: LatencyOperationID(rawValue: operationID)"))
        XCTAssertTrue(appMessageBlock.contains("LatencyDebugLogEventSink(operationKind: \"providerMessage\""))
        XCTAssertTrue(appMessageBlock.contains("trace?.record(\"provider.message.received\""))
        XCTAssertTrue(appMessageBlock.contains("trace?.beginSpan(\"provider.message.reply\""))
        XCTAssertFalse(appMessageBlock.contains("String(data: messageData, encoding: .utf8)"))
    }

    func testStartTunnelRecordsOperationScopedLifecycleAndNetworkSettingsSpans() throws {
        let source = try readSource(.packetTunnelProvider)
        let startTunnelBlock = try sourceBlock(
            in: source,
            startingAt: "override func startTunnel",
            endingBefore: "override func stopTunnel"
        )
        let latencyHelperBlock = try sourceBlock(
            in: source,
            startingAt: "private static func makeLatencyTrace(",
            endingBefore: "private func readPackets()"
        )

        XCTAssertTrue(source.contains("LavaSecAppGroup.latencyOperationIDOptionKeyName"))
        XCTAssertTrue(source.contains("private static func latencyOperationID(from options: [String: NSObject]?) -> LatencyOperationID?"))
        XCTAssertTrue(latencyHelperBlock.contains("LatencyDebugLogEventSink(operationKind: operationKind)"))
        XCTAssertTrue(latencyHelperBlock.contains("LavaSecDeviceDebugLog.append(component: \"tunnel\""))
        XCTAssertTrue(startTunnelBlock.contains("let operationID = Self.latencyOperationID(from: options)"))
        XCTAssertTrue(startTunnelBlock.contains("Self.makeLatencyTrace(operationID: operationID, operationKind: \"tunnelStart\")"))
        XCTAssertTrue(startTunnelBlock.contains("trace.beginSpan(\"tunnel.start\""))
        XCTAssertTrue(startTunnelBlock.contains("trace.beginSpan(\"tunnel.setNetworkSettings\", parent: startSpan"))
        XCTAssertTrue(startTunnelBlock.contains("networkSettingsSpan.end(details: [\"status\": \"error\""))
        XCTAssertTrue(startTunnelBlock.contains("networkSettingsSpan.end(details: [\"status\": \"stale\""))
        XCTAssertTrue(startTunnelBlock.contains("networkSettingsSpan.end(details: [\"status\": \"ok\""))
        XCTAssertTrue(startTunnelBlock.contains("startSpan.end(details: [\"status\": \"ready\""))
    }

    func testResolverTransportSeamsEmitLatencySpans() throws {
        let source = try readSource(.packetTunnelProvider)
        let executorsBlock = try sourceBlock(
            in: source,
            startingAt: "private func makeResolverExecutors()",
            endingBefore: "private func resolveDeviceDNS("
        )
        let bootstrapBlock = try sourceBlock(
            in: source,
            startingAt: "private lazy var resolverBootstrapService = ResolverBootstrapService(",
            endingBefore: "private func doqEndpointResolvingBootstrapIfNeeded"
        )

        // One operation id groups the resolver-path spans for a session.
        XCTAssertTrue(source.contains("private let resolverLatencyOperationID = LatencyOperationID.make()"))
        XCTAssertTrue(executorsBlock.contains("Self.makeLatencyTrace(operationID: resolverLatencyOperationID, operationKind: \"resolver\")"))
        // Every encrypted wire attempt is spanned; "endpoint fallback" is the
        // multi-attempt subset of resolver.endpointAttempt.
        XCTAssertTrue(executorsBlock.contains("beginResolverSpan(\"resolver.endpointAttempt\", [\"transport\": \"DoH\"])"))
        XCTAssertTrue(executorsBlock.contains("beginResolverSpan(\"resolver.endpointAttempt\", [\"transport\": \"DoT\"])"))
        XCTAssertTrue(executorsBlock.contains("beginResolverSpan(\"resolver.endpointAttempt\", [\"transport\": \"DoQ\"])"))
        // Plain DNS is the dominant path for plain-IP-resolver users, so it is
        // spanned too (one span over the whole UDP/TCP/iteration resolution).
        XCTAssertTrue(executorsBlock.contains("beginResolverSpan(\"resolver.endpointAttempt\", [\"transport\": \"plain\"])"))
        XCTAssertTrue(executorsBlock.contains("beginResolverSpan(\"resolver.deviceFallback\", [:])"))
        // Spans are stripped from Release: every emission sits behind the
        // latency build gate, like the rest of the tunnel spans.
        XCTAssertTrue(executorsBlock.contains("#if DEBUG || LAVA_QA_TOOLS"))
        XCTAssertTrue(bootstrapBlock.contains(".beginSpan(\"resolver.bootstrap\")"))
        XCTAssertTrue(bootstrapBlock.contains("#if DEBUG || LAVA_QA_TOOLS"))
    }

    func testDeviceDebugLogShipsInReleaseForFeedbackReport() throws {
        let appGroup = try readSource(.appGroup)
        // The device debug log is compiled in all configurations (including
        // Release/TestFlight) so the optional Feedback report can carry on-device
        // VPN diagnostics. A privacy audit confirmed no event records a queried
        // domain. Guard against accidental re-gating behind #if DEBUG.
        let enumIndex = try XCTUnwrap(appGroup.range(of: "enum LavaSecDeviceDebugLog {")?.lowerBound)
        let prefix = String(appGroup[..<enumIndex])
        XCTAssertFalse(
            prefix.hasSuffix("#if DEBUG || LAVA_QA_TOOLS\n"),
            "LavaSecDeviceDebugLog must stay un-gated so Release builds emit the device log."
        )
        XCTAssertFalse(
            prefix.hasSuffix("#if DEBUG\n"),
            "LavaSecDeviceDebugLog must stay un-gated so Release builds emit the device log."
        )

        // The core network-change DNS-recovery events must fire in Release: no bare
        // `#if DEBUG` may remain wrapping a device-log append in the tunnel.
        let tunnel = try readSource(.packetTunnelProvider)
        XCTAssertFalse(
            tunnel.contains("#if DEBUG\n            LavaSecDeviceDebugLog.append")
                || tunnel.contains("#if DEBUG\n        LavaSecDeviceDebugLog.append"),
            "Tunnel device-log appends must not be re-gated behind #if DEBUG."
        )
    }

    /// PST-2/CON-5: `LavaSecDeviceDebugLog.rotate` must serialize across processes with a
    /// NON-BLOCKING exclusive advisory lock and RE-FSTAT under it before rotating. The app,
    /// tunnel, and every NWConnection queue append to the same log; two crossing the 8 MB cap
    /// at once would double-rotate — the second removeItem deletes the first's fresh `.1` and
    /// installs a near-empty file over it, destroying the rotated generation the report/export
    /// loaders read under incident load. `AppGroup.swift` is compiled by the app/tunnel target,
    /// not `swift test`, so pin the guard as text here.
    func testDeviceDebugLogRotationIsCrossProcessLocked() throws {
        let appGroup = try readSource(.appGroup)

        // The rotate must go through the non-blocking (`withTryExclusiveLock`) helper, never
        // the blocking one — nothing on the tunnel's DNS-serving path may block (CON-1).
        let rotateIndex = try XCTUnwrap(
            appGroup.range(of: "private static func rotate(_ url: URL) {")?.upperBound
        )
        let rotateBody = String(appGroup[rotateIndex...])
        let nextFuncIndex = rotateBody.range(of: "private static func")?.lowerBound ?? rotateBody.endIndex
        let rotateBlock = String(rotateBody[..<nextFuncIndex])

        XCTAssertTrue(
            rotateBlock.contains("FilterPublishLock.withTryExclusiveLock(at: rotationLockURL)"),
            "rotate() must serialize via the non-blocking cross-process lock (PST-2/CON-5)."
        )
        XCTAssertFalse(
            rotateBlock.contains("withExclusiveLock"),
            "rotate() must never take the BLOCKING lock — it runs on the tunnel's serving path (CON-1)."
        )
        // Re-fstat under the lock is what prevents the double-rotate: a writer serialized ahead of
        // us may have already rotated (our over-cap size was read before we held the lock), leaving
        // a fresh below-cap file, so we must skip.
        XCTAssertTrue(
            rotateBlock.contains("fstat(descriptor, &info)")
                && rotateBlock.contains("info.st_size >= Int64(maxLogFileBytes)"),
            "rotate() must RE-FSTAT under the lock and skip if already below the cap."
        )
        XCTAssertTrue(
            rotateBlock.contains("guard stillOverCap else"),
            "rotate() must skip the removeItem/moveItem when the re-check finds it below the cap."
        )
        // In-process guard (Codex #212): the cross-process flock does NOT exclude same-process
        // threads on Darwin (a separate descriptor doesn't reliably conflict), so rotate() must ALSO
        // take a non-blocking in-process lock, and take it BEFORE the cross-process flock.
        XCTAssertTrue(appGroup.contains("rotationInProcessLock = NSLock()"))
        let inProcessLockIndex = try XCTUnwrap(
            rotateBlock.range(of: "rotationInProcessLock.`try`()")?.lowerBound,
            "rotate() must take the non-blocking in-process lock (Codex #212)."
        )
        let crossProcessLockIndex = try XCTUnwrap(
            rotateBlock.range(of: "FilterPublishLock.withTryExclusiveLock")?.lowerBound
        )
        XCTAssertLessThan(
            inProcessLockIndex, crossProcessLockIndex,
            "The in-process guard must be taken before the cross-process flock (Codex #212)."
        )

        // A dedicated rotation lock file, distinct from the config/command locks so log
        // rotation neither blocks nor is blocked by a filter publish or protection command.
        XCTAssertTrue(
            appGroup.contains("static let vpnDebugLogRotationLockFilename ="),
            "The rotation lock must use its own dedicated app-group lock file."
        )
    }

    func testEncryptedTransportsEmitHandshakeObservations() throws {
        let dotSource = try readSource(.doTTransport)
        let doqSource = try readSource(.doQTransport)
        let dohSource = try readSource(.doHTransport)

        // Handshake cost is the per-connection sub-phase under an endpoint
        // attempt; it is reported when a debug logger is injected (the tunnel now
        // injects one in all configurations), measured connect -> ready / connect
        // timings.
        XCTAssertTrue(dotSource.contains("debugLogger: DNSTransportDebugLogger?"))
        XCTAssertTrue(dotSource.contains("\"dns-dot-connection-ready\""))
        XCTAssertTrue(dotSource.contains("\"handshakeMs\""))
        XCTAssertTrue(dotSource.contains("connectionStartedAtMonotonicTime"))

        XCTAssertTrue(doqSource.contains("\"dns-doq-connection-ready\""))
        XCTAssertTrue(doqSource.contains("details[\"handshakeMs\"]"))
        XCTAssertTrue(doqSource.contains("currentConnectionStartedAtMonotonicTime"))

        XCTAssertTrue(dohSource.contains("debugLogger: DNSTransportDebugLogger?"))
        XCTAssertTrue(dohSource.contains("\"dns-doh-connection-ready\""))
        XCTAssertTrue(dohSource.contains("!transaction.isReusedConnection"))
        XCTAssertTrue(dohSource.contains("\"handshakeMs\""))

        // The tunnel injects the device-debug-log sink into every transport
        // unconditionally (including Release) so the optional Feedback report can
        // carry resolver handshake/health observations. The injected details are
        // audited to never include a queried domain — only endpoints and timings.
        let tunnelSource = try readSource(.packetTunnelProvider)
        XCTAssertTrue(tunnelSource.contains("private let dohResolver = DoHTransport(timeoutSeconds: PacketTunnelProvider.dohTimeoutSeconds) { event, details in"))
        XCTAssertTrue(tunnelSource.contains("private let dotResolver = DoTTransport(timeoutSeconds: PacketTunnelProvider.dotTimeoutSeconds) { event, details in"))
    }

    func testMalformedUpstreamResponsesFailClosedBeforeForwardingOrCaching() throws {
        let source = try readSource(.packetTunnelProvider)
        let completeForwardBlock = try sourceBlock(
            in: source,
            startingAt: "private func completeForward",
            endingBefore: "private func responseByApplyingMaximumAnswerTTL"
        )
        let ttlApplyBlock = try sourceBlock(
            in: source,
            startingAt: "private func responseByApplyingMaximumAnswerTTL",
            endingBefore: "private func writeParseFailureResponse"
        )
        let cachePolicyBlock = try sourceBlock(
            in: try readSource(.dnsResponseCache),
            startingAt: "package enum DNSResponseCachePolicy",
            endingBefore: "public final class DNSResponseCache"
        )

        XCTAssertTrue(completeForwardBlock.contains("DNSWireMessage.hasWellFormedResourceRecords(upstreamResponse)"))
        XCTAssertTrue(completeForwardBlock.contains("DNSResponseFactory.serverFailure(for: query)"))
        XCTAssertTrue(ttlApplyBlock.contains("DNSWireMessage.cappingCacheableTTLs(in: response, to: maximumAnswerTTL)"))
        XCTAssertTrue(cachePolicyBlock.contains("recordType != 41"))
        XCTAssertTrue(cachePolicyBlock.contains("if recordType != 41, ttl == 0"))
        XCTAssertTrue(cachePolicyBlock.contains("isValidCompressedNameTarget"))
    }

    func testDoHFailuresRefreshURLSessionWhenIdleWithoutCancellingParallelTasks() throws {
        let source = try readSource(.packetTunnelProvider)
        let executorsBlock = try sourceBlock(
            in: source,
            startingAt: "private func makeResolverExecutors",
            endingBefore: "private func resolveDeviceDNS"
        )

        XCTAssertTrue(executorsBlock.contains("if upstreamResponse.response == nil"))
        XCTAssertTrue(executorsBlock.contains("dohResolver.resetSessionWhenIdle()"))
        XCTAssertFalse(
            executorsBlock.contains("dohResolver.resetSession()"),
            "A single failed DoH request must not cancel unrelated active DoH tasks after resolver work becomes parallel."
        )
    }

    func testDoHTransportTracksActiveTasksBeforeIdleReset() throws {
        let source = try readSource(.doHTransport)
        let dohTransportBlock = try sourceBlock(
            in: source,
            startingAt: "public final class DoHTransport",
            endingBefore: "private final class DoHTaskMetricsRecorder"
        )

        XCTAssertTrue(dohTransportBlock.contains("private var activeTaskCount = 0"))
        XCTAssertTrue(dohTransportBlock.contains("private var shouldResetWhenIdle = false"))
        XCTAssertTrue(dohTransportBlock.contains("func resetSessionWhenIdle()"))
        XCTAssertTrue(dohTransportBlock.contains("private func beginTaskSession() -> URLSession"))
        XCTAssertTrue(dohTransportBlock.contains("private func finishTask()"))
    }

    func testResolverWorkIsBoundedButNotSingleSerialQueue() throws {
        let source = try readSource(.packetTunnelProvider)

        XCTAssertTrue(
            source.contains("private let resolverQueue = DispatchQueue(label: \"com.lavasec.tunnel.resolver\", qos: .utility, attributes: .concurrent)"),
            "Resolver work should be able to make bounded progress in parallel instead of funnelling every query through one serial queue."
        )
        // CON-4: admission must remain bounded but WITHOUT parking a thread per waiter — the
        // blocking DispatchSemaphore is replaced by a serial admission queue that confines a
        // BoundedWorkAdmission FIFO+activeCount. The old gate + its wait()/signal() must be gone.
        XCTAssertFalse(
            source.contains("resolverConcurrencyGate"),
            "The blocking semaphore admission (which parked one worker thread per waiting query) must be removed."
        )
        XCTAssertTrue(
            source.contains("private let resolverAdmissionQueue = DispatchQueue(label: \"com.lavasec.tunnel.resolver.admission\", qos: .utility)"),
            "Resolver admission must be confined to a dedicated serial queue instead of a blocking semaphore."
        )
        XCTAssertTrue(
            source.contains("private let resolverConcurrencyAdmission = BoundedWorkAdmission")
                && source.contains("bound: PacketTunnelProvider.maxConcurrentResolverQueries"),
            "Concurrent resolver work must remain bounded at the same ceiling via queue-confined admission."
        )
        XCTAssertTrue(
            source.contains("private func runBoundedResolverWork"),
            "Resolver dispatch should centralize admission handling so every path releases exactly once."
        )
        XCTAssertTrue(
            source.contains("resolverConcurrencyAdmission.admit(start)")
                && source.contains("resolverConcurrencyAdmission.release()"),
            "Admission and release must both go through the queue-confined BoundedWorkAdmission (admit under the bound, release + start the next pending unit)."
        )
    }

    func testDoHTransportUsesCompletionBasedURLSessionWithoutSemaphoreWait() throws {
        let source = try readSource(.doHTransport)
        let dohTransportBlock = try sourceBlock(
            in: source,
            startingAt: "public final class DoHTransport",
            endingBefore: "private final class DoHTaskMetricsRecorder"
        )

        XCTAssertTrue(
            dohTransportBlock.contains("completion: @escaping @Sendable (DNSTransportResponse) -> Void"),
            "DoH should complete asynchronously instead of blocking a resolver worker thread."
        )
        XCTAssertTrue(dohTransportBlock.contains("dataTask(with: request)"))
        XCTAssertFalse(
            dohTransportBlock.contains("DispatchSemaphore"),
            "DoH URLSession callbacks should not be bridged by blocking on a semaphore."
        )
        XCTAssertFalse(
            dohTransportBlock.contains("semaphore.wait"),
            "DoH should preserve the URLSession timeout without occupying a worker while waiting."
        )
        XCTAssertTrue(
            dohTransportBlock.contains("task.delegate = metricsRecorder"),
            "The per-task delegate is what captures the negotiated HTTP protocol for DoH3 reporting."
        )
    }

    func testResolverRuntimeRoutesDoTThroughDedicatedTransport() throws {
        let source = try readSource(.packetTunnelProvider)
        let primaryResolverBlock = try sourceBlock(
            in: source,
            startingAt: "private func resolvePrimaryUpstream",
            endingBefore: "private func resolveDeviceDNS"
        )
        let runtimeConfigBlock = try sourceBlock(
            in: source,
            startingAt: "private func currentResolverRuntimeConfiguration",
            endingBefore: "private func orderedResolverAddressesForCurrentNetwork"
        )

        XCTAssertTrue(primaryResolverBlock.contains("resolverOrchestrator.resolvePrimaryUpstream("))
        XCTAssertTrue(primaryResolverBlock.contains("usesIsolatedEncryptedConnections: purpose.usesIsolatedEncryptedConnection"))
        XCTAssertTrue(primaryResolverBlock.contains("dotResolver.resolveIsolated(query, endpoint: endpoint, completion: finish)"))
        XCTAssertTrue(primaryResolverBlock.contains("dotResolver.resolve(query, endpoint: endpoint, completion: finish)"))
        XCTAssertTrue(runtimeConfigBlock.contains("DNSResolverRuntimePlan.make"))
        XCTAssertTrue(source.contains("private typealias ResolverRuntimeConfiguration = DNSResolverRuntimePlan"))
    }

    func testResolverRuntimeRoutesDoQThroughDedicatedTransport() throws {
        let source = try readSource(.packetTunnelProvider)
        let primaryResolverBlock = try sourceBlock(
            in: source,
            startingAt: "private func resolvePrimaryUpstream",
            endingBefore: "private func resolveDeviceDNS"
        )
        let runtimeConfigBlock = try sourceBlock(
            in: source,
            startingAt: "private func currentResolverRuntimeConfiguration",
            endingBefore: "private func orderedResolverAddressesForCurrentNetwork"
        )
        let stopBlock = try sourceBlock(
            in: source,
            startingAt: "override func stopTunnel",
            endingBefore: "private static func errorDebugDetails"
        )

        XCTAssertTrue(primaryResolverBlock.contains("resolverOrchestrator.resolvePrimaryUpstream("))
        XCTAssertTrue(primaryResolverBlock.contains("doqResolver.resolveIsolated(query, endpoint: endpoint, completion: finish)"))
        XCTAssertTrue(primaryResolverBlock.contains("doqResolver.resolve(query, endpoint: endpoint, completion: finish)"))
        XCTAssertTrue(runtimeConfigBlock.contains("DNSResolverRuntimePlan.make"))
        XCTAssertTrue(source.contains("private typealias ResolverRuntimeConfiguration = DNSResolverRuntimePlan"))
        XCTAssertTrue(stopBlock.contains("doqResolver.cancel()"))
    }

    func testDoTTransportUsesNetworkTLSAndCompletionCallbacks() throws {
        let source = try readSource(.doTTransport)
        let dotTransportBlock = try sourceBlock(
            in: source,
            startingAt: "public final class DoTTransport",
            endingBefore: "final class DoTConnection"
        )
        let dotConnectionBlock = try sourceBlock(
            in: source,
            startingAt: "final class DoTConnection",
            endingBefore: "enum DNSLengthPrefixedWireMessage"
        )

        XCTAssertTrue(dotTransportBlock.contains("completion: @escaping @Sendable (DNSTransportResponse) -> Void"))
        XCTAssertTrue(dotTransportBlock.contains("resetConnections()"))
        XCTAssertTrue(dotTransportBlock.contains("resetConnectionsWhenIdle()"))
        XCTAssertTrue(dotConnectionBlock.contains("NWConnection("))
        XCTAssertTrue(dotConnectionBlock.contains("NWProtocolTLS.Options()"))
        XCTAssertTrue(dotConnectionBlock.contains("sec_protocol_options_set_tls_server_name"))
        XCTAssertTrue(dotConnectionBlock.contains("NWParameters(tls: tlsOptions, tcp: tcpOptions)"))
        XCTAssertTrue(dotConnectionBlock.contains("receiveExact"))
        XCTAssertTrue(dotConnectionBlock.contains("DNSWireMessage.isValidResponse"))
        XCTAssertFalse(source.contains("DispatchSemaphore"))
        XCTAssertFalse(source.contains("semaphore.wait"))
    }

    func testDoTConnectionFailureAdvancesBootstrapAddressOnlyOnce() throws {
        let source = try readSource(.doTTransport)
        let dotConnectionBlock = try sourceBlock(
            in: source,
            startingAt: "final class DoTConnection",
            endingBefore: "enum DNSLengthPrefixedWireMessage"
        )
        let stateBlock = try sourceBlock(
            in: dotConnectionBlock,
            startingAt: "private func handleConnectionState",
            endingBefore: "private func sendCurrentQuery"
        )

        XCTAssertTrue(stateBlock.contains("let hadReadyCompletions = !readyCompletions.isEmpty"))
        XCTAssertTrue(stateBlock.contains("resetConnectionLocked(advanceBootstrapAddress: !hadReadyCompletions)"))
        XCTAssertTrue(stateBlock.contains("failOrRetryCurrentQuery(outcome: .receiveFailed, resetsConnection: false)"))
    }

    func testDoTTransportUsesPerEndpointConnectionPoolToAvoidHeadOfLineBlocking() throws {
        let source = try readSource(.doTTransport)
        let dotTransportBlock = try sourceBlock(
            in: source,
            startingAt: "public final class DoTTransport",
            endingBefore: "final class DoTConnection"
        )

        XCTAssertTrue(dotTransportBlock.contains("private static let maxConnectionsPerEndpoint"))
        XCTAssertTrue(dotTransportBlock.contains("private var connections: [String: [DoTConnection]]"))
        XCTAssertTrue(dotTransportBlock.contains("private var nextConnectionIndexByKey: [String: Int]"))
        XCTAssertTrue(dotTransportBlock.contains("private func connectionPool(for endpoint: DNSOverTLSEndpoint) -> [DoTConnection]"))
        XCTAssertTrue(dotTransportBlock.contains("connections.values.flatMap"))
        XCTAssertFalse(dotTransportBlock.contains("private var connections: [String: DoTConnection]"))
        // Canary: the negative pins above key on these identifiers - if a rename removes
        // one from the pinned source, those pins pass vacuously. Fail here instead, then
        // re-anchor both sides to the new name.
        XCTAssertTrue(source.contains("DoTConnection"))
    }

    func testDoQTransportUsesCompletionCallbacksWithoutBlocking() throws {
        let source = try readSource(.doQTransport)
        let doqTransportBlock = try sourceBlock(
            in: source,
            startingAt: "public final class DoQTransport",
            endingBefore: "final class DoQConnection"
        )

        XCTAssertTrue(doqTransportBlock.contains("completion: @escaping @Sendable (DNSTransportResponse) -> Void"))
        XCTAssertTrue(doqTransportBlock.contains("resetConnections()"))
        XCTAssertTrue(doqTransportBlock.contains("resetConnectionsWhenIdle()"))
        XCTAssertTrue(source.contains("NWParameters.quic(alpn: [\"doq\"])"))
        XCTAssertTrue(source.contains("NWConnection(host: NWEndpoint.Host(endpoint.hostname), port: port, using: parameters)"))
        XCTAssertTrue(source.contains("contentContext: .finalMessage"))
        XCTAssertTrue(source.contains("DNSLengthPrefixedWireMessage.framedQuery"))
        XCTAssertTrue(source.contains("DNSWireMessage.clearingTransactionID"))
        XCTAssertTrue(source.contains("DNSWireMessage.replacingTransactionID"))
        XCTAssertTrue(source.contains("DNSWireMessage.isValidResponse"))
        XCTAssertFalse(source.contains("DispatchSemaphore"))
        XCTAssertFalse(source.contains("semaphore.wait"))
    }

    func testDoQTransportUsesPerEndpointConnectionPoolToAvoidHeadOfLineBlocking() throws {
        let source = try readSource(.doQTransport)
        let doqTransportBlock = try sourceBlock(
            in: source,
            startingAt: "public final class DoQTransport",
            endingBefore: "final class DoQConnection"
        )

        XCTAssertTrue(doqTransportBlock.contains("private static let maxConnectionsPerEndpoint"))
        XCTAssertTrue(doqTransportBlock.contains("private var connections: [String: [DoQConnection]]"))
        XCTAssertTrue(doqTransportBlock.contains("private var nextConnectionIndexByKey: [String: Int]"))
        XCTAssertTrue(doqTransportBlock.contains("private func connectionPool(for endpoint: DNSOverQUICEndpoint) -> [DoQConnection]"))
        XCTAssertTrue(doqTransportBlock.contains("connections.values.flatMap"))
        XCTAssertFalse(doqTransportBlock.contains("private var connections: [String: DoQConnection]"))
        // Canary: the negative pins above key on these identifiers - if a rename removes
        // one from the pinned source, those pins pass vacuously. Fail here instead, then
        // re-anchor both sides to the new name.
        XCTAssertTrue(source.contains("DoQConnection"))
    }

    func testDoQTransportUsesPublicQUICConnectionWithoutCustomStack() throws {
        // RATIONALE (recovered 2026-06-14): DoQ connection REUSE is impossible
        // with a single reused NWConnection — RFC 9250 maps each query to its own
        // QUIC stream (with FIN), so reuse needs NWConnectionGroup/openStream,
        // and that public multi-stream QUIC API is iOS 26.0+. The app floor is
        // iOS 17, so the custom stack would force an #available(iOS 26.0)-gated
        // dual path (+ an .unsupported fallback). This pin keeps DoQ on the
        // simple, uniform NWParameters.quic(alpn:) single-connection-per-query
        // path across the whole floor. 2026-06-14: the iOS-26-gated reuse path
        // (NetworkConnection<QUIC> + openStream) WAS built and device-tested on
        // iOS 26.5 against AdGuard DoQ — it failed on every attempt (openStream/
        // receive errored, the fallback then hit "Socket is not connected"), net
        // WORSE than this path, confirming Apple DTS's "hold off on QUIC" guidance.
        // It was reverted. Re-attempt only after a later iOS 26.x proves the QUIC
        // stream API reliable. If you do, update this pin deliberately — do not
        // delete it to make a change pass. See plan item 413.
        let source = try readSource(.doQTransport)

        XCTAssertTrue(source.contains("NWParameters.quic(alpn: [\"doq\"])"))
        XCTAssertTrue(source.contains("NWConnection(host: NWEndpoint.Host(endpoint.hostname), port: port, using: parameters)"))
        XCTAssertTrue(source.contains("connection.start(queue: queue)"))
        XCTAssertTrue(source.contains("connection.send("))
        XCTAssertTrue(source.contains("connection.receive(minimumIncompleteLength: 1, maximumLength:"))
        XCTAssertTrue(source.contains("contentContext: .finalMessage"))
        XCTAssertTrue(source.contains("isComplete: true"))
        XCTAssertFalse(source.contains("NetworkConnection(to:"))
        XCTAssertFalse(source.contains("openStream(directionality: .bidirectional)"))
        XCTAssertFalse(source.contains("AsyncDoQConnection"))
        XCTAssertFalse(source.contains("NWProtocolQUIC.Options(alpn: [\"doq\"])"))
        XCTAssertFalse(source.contains("NWParameters(quic: options)"))
        XCTAssertFalse(source.contains("NWConnectionGroup"))
        XCTAssertFalse(source.contains("DispatchSemaphore"))
    }

    func testDoQConnectionUsesPublicQUICAvailableOnSupportedIOSVersions() throws {
        let source = try readSource(.doQTransport)
        let resolveBlock = try sourceBlock(
            in: source,
            startingAt: "private func resolveCurrentQuery",
            endingBefore: "private func finishCurrentQuery"
        )

        XCTAssertFalse(resolveBlock.contains("#available(iOS 26.0"))
        XCTAssertFalse(resolveBlock.contains("outcome: .unsupported"))
        XCTAssertTrue(source.contains("NWParameters.quic(alpn: [\"doq\"])"))
        XCTAssertFalse(source.contains("NWParameters(quic: options)"))
    }

    func testDoQConnectionMapsTimeoutToResolverOutcome() throws {
        let source = try readSource(.doQTransport)

        XCTAssertTrue(source.contains("queue.asyncAfter(deadline: .now() + .seconds(timeoutSeconds), execute: timeout)"))
        XCTAssertTrue(source.contains("DNSTransportResponse(response: nil, outcome: .timeout)"))
        XCTAssertTrue(source.contains("currentTimeout?.cancel()"))
    }

    func testResolverSmokeProbeUsesDedicatedLaneAndEncryptedConnections() throws {
        let source = try readSource(.packetTunnelProvider)
        let smokeProbeBlock = try sourceBlock(
            in: source,
            startingAt: "private func scheduleResolverSmokeProbeIfNeeded",
            endingBefore: "private func resolverSmokeProbeTimeoutResult"
        )
        let primaryResolverBlock = try sourceBlock(
            in: source,
            startingAt: "private func resolvePrimaryUpstream",
            endingBefore: "private func resolveDeviceDNS"
        )
        let dotTransportSource = try readSource(.doTTransport)
        let doqTransportSource = try readSource(.doQTransport)

        XCTAssertTrue(source.contains("private enum ResolverQueryPurpose: Sendable"))
        XCTAssertTrue(
            source.contains("private let resolverSmokeProbeQueue = DispatchQueue(label: \"com.lavasec.tunnel.resolver.smoke-probe\""),
            "Smoke probes should not wait behind forwarded DNS work in the shared resolver gate."
        )
        XCTAssertTrue(source.contains("private func runResolverSmokeProbeWork"))
        XCTAssertTrue(smokeProbeBlock.contains("runResolverSmokeProbeWork"))
        XCTAssertFalse(smokeProbeBlock.contains("runBoundedResolverWork"))
        XCTAssertTrue(smokeProbeBlock.contains("resolvePrimaryUpstream(query, resolverConfiguration: resolverConfiguration, purpose: .smokeProbe)"))
        XCTAssertTrue(primaryResolverBlock.contains("purpose: ResolverQueryPurpose = .forwarding"))
        XCTAssertTrue(primaryResolverBlock.contains("resolverOrchestrator.resolvePrimaryUpstream("))
        XCTAssertTrue(primaryResolverBlock.contains("usesIsolatedEncryptedConnections: purpose.usesIsolatedEncryptedConnection"))
        XCTAssertTrue(dotTransportSource.contains("public func resolveIsolated("))
        XCTAssertTrue(doqTransportSource.contains("public func resolveIsolated("))
        XCTAssertTrue(source.contains("if usesIsolatedConnection"))
        XCTAssertTrue(source.contains("if upstreamResponse.response == nil, !usesIsolatedConnection"))
        // Canary: the negative pins above key on these identifiers - if a rename removes
        // one from the pinned source, those pins pass vacuously. Fail here instead, then
        // re-anchor both sides to the new name.
        XCTAssertTrue(source.contains("runBoundedResolverWork"))
    }

    func testDoQBootstrapsHostnamesBeforeForwardingAndKeepsQUICHostnameBased() throws {
        let source = try readSource(.packetTunnelProvider)
        let packetHandlerBlock = try sourceBlock(
            in: source,
            startingAt: "private func handle(packet: Data, protocolNumber: NSNumber)",
            endingBefore: "private func forward("
        )
        let executorsBlock = try sourceBlock(
            in: source,
            startingAt: "private func makeResolverExecutors",
            endingBefore: "private func resolveDeviceDNS"
        )
        let bootstrapEndpointBlock = try sourceBlock(
            in: source,
            startingAt: "private func doqEndpointResolvingBootstrapIfNeeded",
            endingBefore: "private func resolveDoQBootstrapAddresses"
        )
        let bootstrapAddressesBlock = try sourceBlock(
            in: source,
            startingAt: "private func resolveDoQBootstrapAddresses",
            endingBefore: "private func startPeriodicResolverSmokeProbe"
        )
        let prewarmBlock = try sourceBlock(
            in: source,
            startingAt: "private func prewarmResolverBootstrapIfNeeded",
            endingBefore: "private func resolveDoQBootstrapAddresses"
        )
        let doqBootstrapResponseBlock = try sourceBlock(
            in: source,
            startingAt: "private func doqBootstrapResponse",
            endingBefore: "private func startPeriodicResolverSmokeProbe"
        )
        let doqTransportSource = try readSource(.doQTransport)

        XCTAssertTrue(packetHandlerBlock.contains("doqBootstrapResponse("))
        XCTAssertTrue(executorsBlock.contains("doqResolver.resolve(query, endpoint: endpoint, completion: finish)"))
        XCTAssertFalse(executorsBlock.contains("doqEndpointResolvingBootstrapIfNeeded(endpoint)"))
        XCTAssertTrue(
            bootstrapEndpointBlock.contains("resolverBootstrapService.cachedAddresses(forHostname: endpoint.hostname)"),
            "The packet path may only consult the bootstrap cache."
        )
        XCTAssertTrue(bootstrapEndpointBlock.contains("resolverBootstrapService.prewarm(hostname: endpoint.hostname)"))
        XCTAssertFalse(
            bootstrapEndpointBlock.contains("resolveDoQBootstrapAddresses("),
            "Synchronous bootstrap lookups must never run on the packet path."
        )
        XCTAssertTrue(bootstrapEndpointBlock.contains("DNSOverQUICEndpoint("))
        XCTAssertTrue(bootstrapEndpointBlock.contains("bootstrapIPv4Servers: cached.ipv4"))
        XCTAssertTrue(bootstrapEndpointBlock.contains("bootstrapIPv6Servers: cached.ipv6"))
        XCTAssertTrue(source.contains("self.prewarmResolverBootstrapIfNeeded()"))
        XCTAssertTrue(source.contains("resolverBootstrapService.invalidateAll()"))
        XCTAssertTrue(bootstrapAddressesBlock.contains("DNSResolverSmokeProbe.query("))
        XCTAssertTrue(bootstrapAddressesBlock.contains("resolvePlainDNS(aQuery, resolverAddresses: resolverAddresses, transport: .deviceDNS)"))
        XCTAssertTrue(bootstrapAddressesBlock.contains("DNSBootstrapAddressExtractor.addresses"))
        XCTAssertTrue(doqBootstrapResponseBlock.contains("resolverConfiguration.transport == .dnsOverQUIC"))
        // A custom doq:// encrypted fallback keeps its hostname in the nested plan, so
        // the bootstrap (and the prewarm) must consider the fallback's DoQ endpoints
        // too — otherwise its lookup recurses through the wedged Device DNS.
        XCTAssertTrue(doqBootstrapResponseBlock.contains("resolverConfiguration.encryptedFallbackDoQEndpoints"))
        XCTAssertTrue(prewarmBlock.contains("resolverConfiguration.encryptedFallbackDoQEndpoints"))
        // The question domain must be NORMALIZED before matching against endpoint
        // hostnames. The packet path reuses `question.normalizedDomain` (already
        // `DomainName.normalize(question.domain)` from `DNSMessage.parseQuestion`)
        // instead of re-normalizing per query; the endpoint host is normalized via the
        // memoizing helper `normalizedEndpointHostname` (the same `DomainName.normalize`,
        // cached because resolver hostnames are stable across queries).
        XCTAssertTrue(doqBootstrapResponseBlock.contains("question.normalizedDomain"))
        XCTAssertTrue(doqBootstrapResponseBlock.contains("normalizedEndpointHostname(endpoint.hostname)"))
        XCTAssertTrue(doqBootstrapResponseBlock.contains("doqEndpointResolvingBootstrapIfNeeded(endpoint)"))
        XCTAssertTrue(doqBootstrapResponseBlock.contains("DNSBootstrapResponseFactory.response(for: query, question: question, endpoint: bootstrappedEndpoint)"))
        XCTAssertTrue(doqTransportSource.contains("NWConnection(host: NWEndpoint.Host(endpoint.hostname), port: port, using: parameters)"))
        XCTAssertFalse(doqTransportSource.contains("NWEndpoint.Host(connectionHost)"))
        XCTAssertFalse(doqTransportSource.contains("sec_protocol_options_set_verify_block"))
    }

    func testDoTBootstrapsCustomHostnamesBeforeForwarding() throws {
        let source = try readSource(.packetTunnelProvider)
        let packetHandlerBlock = try sourceBlock(
            in: source,
            startingAt: "private func handle(packet: Data, protocolNumber: NSNumber)",
            endingBefore: "private func forward("
        )
        let dotBootstrapResponseBlock = try sourceBlock(
            in: source,
            startingAt: "private func dotBootstrapResponse",
            endingBefore: "private func startPeriodicResolverSmokeProbe"
        )
        let resolveBlock = try sourceBlock(
            in: source,
            startingAt: "private func dotEndpointResolvingBootstrapIfNeeded",
            endingBefore: "private func doqEndpointResolvingBootstrapIfNeeded"
        )
        let prewarmBlock = try sourceBlock(
            in: source,
            startingAt: "private func prewarmResolverBootstrapIfNeeded",
            endingBefore: "private func resolveDoQBootstrapAddresses"
        )

        // The packet path must intercept DoT hostnames too (a custom `tls://` fallback
        // or primary connects by hostname when it has no bootstrap IPs), so the lookup
        // is answered from cached bootstrap IPs rather than recursing through a wedged
        // Device DNS — mirroring DoH/DoQ.
        XCTAssertTrue(packetHandlerBlock.contains("dotBootstrapResponse("))
        XCTAssertTrue(dotBootstrapResponseBlock.contains("resolverConfiguration.encryptedFallbackDoTEndpoints"))
        XCTAssertTrue(dotBootstrapResponseBlock.contains("resolverConfiguration.transport == .dnsOverTLS"))
        XCTAssertTrue(dotBootstrapResponseBlock.contains("dotEndpointResolvingBootstrapIfNeeded(endpoint)"))
        XCTAssertTrue(dotBootstrapResponseBlock.contains("guard !bootstrappedEndpoint.allBootstrapServers.isEmpty else {"))
        XCTAssertTrue(dotBootstrapResponseBlock.contains("DNSBootstrapResponseFactory.response(for: query, question: question, endpoint: bootstrappedEndpoint)"))

        // The cache resolver only consults the cache on the packet path and warms it
        // asynchronously — never blocking the packet path on a lookup.
        XCTAssertTrue(resolveBlock.contains("resolverBootstrapService.cachedAddresses(forHostname: endpoint.hostname)"))
        XCTAssertTrue(resolveBlock.contains("resolverBootstrapService.prewarm(hostname: endpoint.hostname)"))

        // Prewarm must cover empty-bootstrap DoT endpoints (primary + fallback).
        XCTAssertTrue(prewarmBlock.contains("resolverConfiguration.encryptedFallbackDoTEndpoints"))
        XCTAssertTrue(prewarmBlock.contains("resolverConfiguration.dotEndpoints"))
    }

    func testResolverNetworkIdentityIncludesEncryptedFallbackFields() throws {
        let source = try readSource(.packetTunnelProvider)
        let identityBlock = try sourceBlock(
            in: source,
            startingAt: "private static func resolverNetworkIdentity",
            endingBefore: "private func recordCacheHit"
        )

        // Changing the encrypted Device-DNS fallback resolver (e.g. saving a
        // hostname-based Custom DoH/DoT/DoQ alternative while the VPN is running) must
        // register as a resolver change so the reload re-warms its bootstrap hostname.
        // If the identity omitted these, resolverChanged would be false and the new
        // fallback host would stay un-warmed until a later packet reset.
        XCTAssertTrue(identityBlock.contains("configuration.usesEncryptedDeviceDNSFallback"))
        XCTAssertTrue(identityBlock.contains("configuration.fallbackResolverPresetID"))
        XCTAssertTrue(identityBlock.contains("configuration.fallbackCustomResolverAddress"))
        XCTAssertTrue(identityBlock.contains("configuration.fallbackCustomResolverSecondaryAddress"))
    }

    func testDoTConnectionReadinessCannotHangWithoutAQueryTimeout() throws {
        let source = try readSource(.doTTransport)
        let dotConnectionBlock = try sourceBlock(
            in: source,
            startingAt: "final class DoTConnection",
            endingBefore: "enum DNSLengthPrefixedWireMessage"
        )
        let startConnectionBlock = try sourceBlock(
            in: dotConnectionBlock,
            startingAt: "private func startConnectionLocked()",
            endingBefore: "private func handleConnectionState"
        )
        let timeoutBlock = try sourceBlock(
            in: dotConnectionBlock,
            startingAt: "private func scheduleTimeout(generation: Int)",
            endingBefore: "private func failOrRetryCurrentQuery"
        )

        XCTAssertTrue(startConnectionBlock.contains("scheduleTimeout(generation: generation)"))
        XCTAssertTrue(timeoutBlock.contains("readyCompletions = []"))
        XCTAssertTrue(
            timeoutBlock.contains("failOrRetryCurrentQuery(outcome: .timeout, resetsConnection: false)"),
            "Timeouts route through failOrRetryCurrentQuery so a stale reused connection gets one fresh retry before failing."
        )
    }

    func testForwardResolutionAttachesResolverLatencyBeforeCoordinator() throws {
        let source = try readSource(.packetTunnelProvider)
        let dispatchBlock = try sourceBlock(
            in: source,
            startingAt: "private func dispatchForwardResolution",
            endingBefore: "private func runBoundedResolverWork"
        )

        XCTAssertTrue(dispatchBlock.contains("let startedAt = Date()"))
        XCTAssertTrue(dispatchBlock.contains("result.recordingDuration(since: startedAt)"))
    }

    func testResolverSmokeProbeCannotRemainInProgressForever() throws {
        let source = try readSource(.packetTunnelProvider)
        let constantsBlock = try sourceBlock(
            in: source,
            startingAt: "private static let udpDNSTimeoutSeconds",
            endingBefore: "private let resolverBackoffStateQueue"
        )
        let probeBlock = try sourceBlock(
            in: source,
            startingAt: "private func scheduleResolverSmokeProbeIfNeeded",
            endingBefore: "private func resolverSmokeProbeTimeoutResult"
        )
        let completionBlock = try sourceBlock(
            in: source,
            startingAt: "private func completeResolverSmokeProbeResult",
            endingBefore: "private func applyResolverHealthEvent"
        )
        let timeoutResultBlock = try sourceBlock(
            in: source,
            startingAt: "private func resolverSmokeProbeTimeoutResult",
            endingBefore: "private func completeResolverSmokeProbeResult"
        )

        XCTAssertTrue(constantsBlock.contains("private static let resolverSmokeProbeTimeoutSeconds"))
        XCTAssertTrue(source.contains("private final class ResolverSmokeProbeTimeout: @unchecked Sendable"))
        XCTAssertTrue(source.contains("private let workItem: DispatchWorkItem"))
        XCTAssertTrue(probeBlock.contains("let timeout = ResolverSmokeProbeTimeout"))
        // The probe timeout is reason-derived: recovery-context probes use the
        // shorter recovery timeout so a wedge is detected (and self-reconnect fired)
        // faster; routine/startup probes keep the generous timeout.
        XCTAssertTrue(probeBlock.contains("timeoutSeconds: Self.smokeProbeTimeoutSeconds("))
        XCTAssertTrue(probeBlock.contains("transport: resolverConfiguration.transport"))
        XCTAssertTrue(probeBlock.contains("canUseDeviceDNSFallback: canUseDeviceDNSFallback"))
        XCTAssertTrue(probeBlock.contains("timeout.cancel()"))
        XCTAssertTrue(probeBlock.contains("completeResolverSmokeProbeResult("))
        XCTAssertTrue(completionBlock.contains("$0.completeSmokeProbe("))
        XCTAssertTrue(completionBlock.contains("token: token"))
        XCTAssertFalse(completionBlock.contains("resolverSmokeProbeGeneration"))
        XCTAssertTrue(timeoutResultBlock.contains("outcome: .timeout"))
        XCTAssertTrue(timeoutResultBlock.contains("address: resolverConfiguration.cacheIdentifier"))
    }

    func testEncryptedFallbackLogEpisodeClearFlushesPendingCarry() throws {
        let source = try readSource(.packetTunnelProvider)
        let effectBlock = try sourceBlock(
            in: source,
            startingAt: "private func executeResolverHealthEffects(",
            endingBefore: "// MARK: - Health reset & network path monitoring"
        )
        let contextResetBlock = try sourceBlock(
            in: effectBlock,
            startingAt: "case .endEncryptedFallbackLogEpisode",
            endingBefore: "case .cancelFallbackRecoveryProbe"
        )
        XCTAssertTrue(
            contextResetBlock.contains("clearEncryptedFallbackLogThrottle(phase: \"context-reset\")")
        )

        let clearThrottleBlock = try sourceBlock(
            in: source,
            startingAt: "private func clearEncryptedFallbackLogThrottle",
            endingBefore: "// Cancels a scheduled fallback-recovery probe"
        )
        XCTAssertTrue(clearThrottleBlock.contains("if encryptedFallbackCarriedSinceLastLog > 0 {"))
        XCTAssertTrue(clearThrottleBlock.contains("\"phase\": phase"))
        XCTAssertTrue(clearThrottleBlock.contains("phase: String = \"episode-end\""))
        XCTAssertTrue(clearThrottleBlock.contains("lastEncryptedFallbackLogAt = nil"))
        XCTAssertTrue(clearThrottleBlock.contains("encryptedFallbackCarriedSinceLastLog = 0"))
    }

    func testWedgeRecoveryProbeGateHonoursHeldWedgeMarkerNotJustHealth() throws {
        let source = try readSource(.packetTunnelProvider)
        let scheduleBlock = try sourceBlock(
            in: source,
            startingAt: "private func scheduleResolverWedgeRecoveryProbeIfNeeded",
            endingBefore: "private func cancelResolverWedgeRecoveryProbe"
        )

        // The wedge marker the encrypted-fallback success path deliberately holds
        // (covered by ResolverHealthOrganicEvidenceTests) is only useful if the
        // recovery probe actually re-probes the primary while it's held. A fallback-
        // carried success clears health's failure counters, so the assessment reads
        // healthy — gating the re-probe on the assessment ALONE would strand the primary
        // on the fallback until a routine probe / manual toggle. The fire condition must
        // also honour the wedge marker.
        XCTAssertTrue(
            scheduleBlock.contains("self.currentDeviceResolverWedged()"),
            "The wedge-recovery probe must fire while the wedge marker is held, even when a fallback-carried success has made the health-derived assessment look healthy."
        )
        // Must be OR'd with the assessment (either signal fires the probe), not AND'd
        // (which would re-introduce the masked-healthy bail this guards against).
        XCTAssertTrue(
            scheduleBlock.contains("assessment.primaryAction == .reconnect || self.currentDeviceResolverWedged()"),
            "The gate must fire on EITHER the assessment or the held wedge marker."
        )
    }

    func testEncryptedFallbackHostnameIsBootstrapped() throws {
        let source = try readSource(.packetTunnelProvider)
        let bootstrapBlock = try sourceBlock(
            in: source,
            startingAt: "private func dohBootstrapResponse",
            endingBefore: "private func doqBootstrapResponse"
        )

        // The encrypted fallback host (Mullvad) must be bootstrapped from its bundled
        // IPs even under a Device-DNS plan — otherwise the fallback's own
        // `dns.mullvad.net` lookup is forwarded to the (possibly wedged) Device DNS
        // and the safety net can never recover a cold/cache-miss device.
        XCTAssertTrue(
            bootstrapBlock.contains("resolverConfiguration.encryptedFallbackEndpoints"),
            "DoH bootstrap must also answer the encrypted fallback hostname so the wedge safety net can resolve its own endpoint."
        )
        // A custom `https://host` resolver (primary or fallback) carries no bootstrap
        // IPs, so the DoH bootstrap must resolve them from the warmed hostname cache
        // (mirroring DoQ) and, when none are cached yet, forward the lookup rather than
        // answer from empty arrays — an empty record set would guarantee a failed connect.
        XCTAssertTrue(
            bootstrapBlock.contains("dohEndpointResolvingBootstrapIfNeeded(endpoint)"),
            "DoH bootstrap must resolve missing bootstrap IPs from the cache for custom https resolvers."
        )
        XCTAssertTrue(
            bootstrapBlock.contains("guard !bootstrappedEndpoint.allBootstrapServers.isEmpty else {"),
            "DoH bootstrap must forward (not answer empty) when a custom endpoint has no bootstrap IPs yet."
        )

        // The cache resolver only consults the cache on the packet path and warms it
        // asynchronously — it must never block the packet path on a lookup.
        let resolveBlock = try sourceBlock(
            in: source,
            startingAt: "private func dohEndpointResolvingBootstrapIfNeeded",
            endingBefore: "private func doqEndpointResolvingBootstrapIfNeeded"
        )
        XCTAssertTrue(resolveBlock.contains("resolverBootstrapService.cachedAddresses(forHostname: host)"))
        XCTAssertTrue(resolveBlock.contains("resolverBootstrapService.prewarm(hostname: host)"))

        // Prewarm must also cover empty-bootstrap DoH endpoints (primary + fallback).
        let prewarmBlock = try sourceBlock(
            in: source,
            startingAt: "private func prewarmResolverBootstrapIfNeeded",
            endingBefore: "private func resolveDoQBootstrapAddresses"
        )
        XCTAssertTrue(prewarmBlock.contains("resolverConfiguration.encryptedFallbackEndpoints"))
        XCTAssertTrue(prewarmBlock.contains("resolverConfiguration.dohEndpoints"))
    }

    func testResolverSmokeProbeRotatesCanaryDomain() throws {
        let source = try readSource(.packetTunnelProvider)
        // The health probe rotates its canary domain per coordinator sequence so a single
        // blocked/hijacked domain can't sustain a false unhealthy verdict. Completion
        // classification is covered by ResolverHealthSmokeEvidenceTests.
        let probeBlock = try sourceBlock(
            in: source,
            startingAt: "private func scheduleResolverSmokeProbeIfNeeded",
            endingBefore: "private func resolverSmokeProbeTimeoutResult"
        )
        XCTAssertTrue(probeBlock.contains("let probeStart = resolverHealthCoordinator.assumeIsolated { $0.beginSmokeProbe() }"))
        XCTAssertTrue(probeBlock.contains("DNSResolverSmokeProbe.probeDomain(forSequence: probeStart.rotationSequence)"))
        XCTAssertTrue(probeBlock.contains("token: probeStart.token"))
        XCTAssertTrue(probeBlock.contains("domain: probeDomain"))
    }

    func testRecoveryContextProbesUseAShorterTimeoutForFasterDetection() throws {
        let source = try readSource(.packetTunnelProvider)

        // Recovery-context probes (post-handoff / wedge / fallback-recovery) get a
        // tight timeout so an unreachable resolver is detected quickly and
        // self-reconnect fires sooner — the lever that halves the handoff blip per
        // the 1758 device log. Routine/startup probes keep the generous timeout.
        XCTAssertTrue(source.contains("private static let resolverRecoveryProbeTimeoutSeconds = 4"))
        XCTAssertTrue(source.contains("private static let resolverSmokeProbeTimeoutSeconds = 8"))

        let selectorBlock = try sourceBlock(
            in: source,
            startingAt: "private static func smokeProbeTimeoutSeconds(",
            endingBefore: "private let resolverBackoffStateQueue"
        )
        // The short timeout is gated to the fast device/plain primary path with no
        // fallback branch — an encrypted primary (5s transport) or a fallback-capable
        // probe keeps the routine timeout, so a 3s cut can't deactivate a working
        // device-DNS fallback while the primary is still down (P1).
        XCTAssertTrue(selectorBlock.contains("recoveryContextProbeReasons.contains(reason)"))
        XCTAssertTrue(selectorBlock.contains("transport == .deviceDNS || transport == .plainDNS"))
        XCTAssertTrue(selectorBlock.contains("!canUseDeviceDNSFallback"))
        XCTAssertTrue(selectorBlock.contains("return resolverRecoveryProbeTimeoutSeconds"))
        XCTAssertTrue(selectorBlock.contains("return resolverSmokeProbeTimeoutSeconds"))

        let reasonsBlock = try sourceBlock(
            in: source,
            startingAt: "private static let recoveryContextProbeReasons",
            endingBefore: "private static func smokeProbeTimeoutSeconds"
        )
        // "device-dns-exhaustion-verification" rides the same tight timeout (UR-55):
        // post-handoff it is the first wire check that can classify the preserved
        // Device-DNS primary as dead; the selector's existing guards keep the short
        // cut away from encrypted primaries and fallback-capable probes.
        for reason in [
            "network-settled",
            "resolver-wedge-recovery",
            "device-dns-fallback-recovery",
            "device-dns-exhaustion-verification"
        ] {
            XCTAssertTrue(reasonsBlock.contains("\"\(reason)\""), "recovery-context reasons should include \(reason)")
        }
    }

    func testResolverSmokeProbeLogsPrimaryAndFallbackDecisionEvidence() throws {
        let source = try readSource(.packetTunnelProvider)
        let probeBlock = try sourceBlock(
            in: source,
            startingAt: "private func scheduleResolverSmokeProbeIfNeeded",
            endingBefore: "private func resolverSmokeProbeTimeoutResult"
        )

        XCTAssertTrue(probeBlock.contains("dns-smoke-probe-primary-result"))
        XCTAssertTrue(probeBlock.contains("\"primaryAccepted\": \"\\(primarySucceeded)\""))
        XCTAssertTrue(probeBlock.contains("\"primaryOutcome\": primaryResult.failureSummary ??"))
        XCTAssertTrue(probeBlock.contains("dns-smoke-probe-fallback-begin"))
        XCTAssertTrue(probeBlock.contains("dns-smoke-probe-fallback-result"))
        XCTAssertTrue(probeBlock.contains("\"fallbackAccepted\": \"\\(fallbackSucceeded)\""))
    }

    /// The app reads the self-reconnect timeline for a bug report's incident summary (LAV-94 B)
    /// from `LavaSecAppGroup.selfReconnectAttemptTimesDefaultsKeyName`, while the tunnel WRITES it under
    /// its own private `selfReconnectAttemptsDefaultsKeyName`. Both are the same magic string — lock the
    /// two literals together (cross-file) so a future rename on one side can't silently strand the
    /// app's read of a key the tunnel no longer writes.
    func testSelfReconnectAttemptTimesDefaultsKeyMatchesSharedConstant() throws {
        let sharedKeyValue = "tunnel.selfReconnectAttemptTimes"
        let tunnelSource = try readSource(.packetTunnelProvider)
        let sharedSource = try readSource(.appGroup)
        XCTAssertTrue(
            tunnelSource.contains("selfReconnectAttemptsDefaultsKeyName = \"\(sharedKeyValue)\""),
            "Tunnel must persist the self-reconnect timeline under the shared key literal."
        )
        XCTAssertTrue(
            sharedSource.contains("selfReconnectAttemptTimesDefaultsKeyName = \"\(sharedKeyValue)\""),
            "The shared app-group constant the app reads must equal the tunnel's persisted key."
        )
    }

    /// NRG-3a (founder-approved 2026-07-02): the routine periodic probe may skip its wire
    /// query ONLY from a fully-healthy ladder with acceptance-checked primary evidence
    /// younger than one probe interval. The 300s cadence itself is the honesty budget and
    /// stays untouched; every other probe reason stays unconditional; and evidence never
    /// comes from merely-resolved replies (a hijacking resolver's REFUSED stamps those —
    /// the LAV-87 suppression regression the review warned against) nor survives a
    /// resolver-runtime reset.
    func testPeriodicProbeSkipRequiresHealthyLadderAndAcceptanceCheckedEvidence() throws {
        let source = try readSource(.packetTunnelProvider)
        let scheduleBlock = try sourceBlock(
            in: source,
            startingAt: "private func scheduleResolverSmokeProbeIfNeeded(reason: String)",
            endingBefore: "private func resolverSmokeProbeTimeoutResult"
        )

        // The gate is scoped to the routine tick and demands the FULL healthy ladder —
        // any nonzero streak, active fallback mode, or armed wedge marker means
        // mid-incident, where skipping would freeze the LAV-87 escalation.
        XCTAssertTrue(scheduleBlock.contains("if reason == \"periodic-health-check\","))
        XCTAssertTrue(scheduleBlock.contains("schedulingView.consecutiveRejectedResponseCount == 0,"))
        XCTAssertTrue(scheduleBlock.contains("schedulingView.consecutiveSmokeProbeFailureCount == 0,"))
        XCTAssertTrue(scheduleBlock.contains("schedulingView.consecutiveUpstreamFailureCount == 0,"))
        XCTAssertTrue(scheduleBlock.contains("!schedulingView.deviceDNSFallbackModeActive,"))
        XCTAssertTrue(scheduleBlock.contains("!schedulingView.reconnectEpisodeIsActive,"))
        XCTAssertTrue(scheduleBlock.contains("let evidenceAt = schedulingView.lastAcceptedPrimaryEvidenceAt {"))
        // The freshness window IS the probe interval — a separate constant could
        // silently widen the honesty budget — and it is two-sided: future-dated
        // evidence (backward wall-clock jump) must not suppress probes until the
        // clock catches up (Codex round 6).
        XCTAssertTrue(scheduleBlock.contains("if evidenceAge >= 0, evidenceAge <= Self.resolverSmokeProbeInterval {"))
        XCTAssertTrue(scheduleBlock.contains("\"dns-smoke-probe-skipped\""))
        // The gate must never key on merely-resolved timestamps.
        XCTAssertFalse(scheduleBlock.contains("lastPrimaryUpstreamSuccessAt"))
        XCTAssertFalse(scheduleBlock.contains("lastUpstreamSuccessAt"))

        // Smoke and organic evidence stamping/revocation are reducer-owned and covered
        // behaviorally; this source test pins only the provider-owned probe admission gate.
    }

    /// OBS R2: the append-only incident ledger is written at every incident site as a
    /// pure OBSERVABILITY side effect — synchronously durable before the terminal
    /// self-reconnect cancel, outside QA-only gates on the fail-closed paths, and never
    /// read by anything in the recovery/cap policy (the rate-limiter's stores forget by
    /// design; the ledger is what survives to a late-filed report).
    func testAppGroupLogWritesHopOffTheDNSServingQueue() throws {
        let source = try readSource(.packetTunnelProvider)

        // CON-1: two dedicated SERIAL queues carry app-group diagnostic-log IO, split per
        // file (Codex #200 P2), so a cross-process flock a suspended app holds can never
        // wedge dnsStateQueue.
        XCTAssertTrue(source.contains(#"static let appGroupLogIOQueue = DispatchQueue(label: "com.lavasec.tunnel.app-group-log-io""#))
        XCTAssertTrue(source.contains(#"static let networkActivityLogIOQueue = DispatchQueue(label: "com.lavasec.tunnel.network-activity-log-io""#))

        // The NetworkActivity write runs INSIDE the async hop (entry built on the calling
        // queue, disk write deferred) via the non-blocking `tryAppend` — never the blocking
        // `append` (that's the app's, so user actions aren't dropped — Codex #200 P2). It
        // hops onto the network-activity queue, NOT the incident terminal-sync queue.
        let netAppendBlock = try sourceBlock(
            in: source,
            startingAt: "let logURL = networkActivityLogURL",
            endingBefore: "private func selfReconnectIfPolicyAllows"
        )
        XCTAssertTrue(netAppendBlock.contains("Self.networkActivityLogIOQueue.async {"))
        XCTAssertTrue(netAppendBlock.contains("NetworkActivityLogPersistence.tryAppend(entry, to: logURL)"))
        XCTAssertFalse(
            netAppendBlock.contains("appGroupLogIOQueue"),
            "network-activity IO must hop onto its own queue, not the incident terminal-sync queue"
        )
        XCTAssertFalse(
            source.contains("NetworkActivityLogPersistence.append(entry, to: logURL)"),
            "the tunnel must use the non-blocking tryAppend, not the blocking append"
        )

        // recordIncident hops by default; the incident append and the startup sweep both
        // run inside `appGroupLogIOQueue.async`.
        XCTAssertTrue(source.contains("synchronous: Bool = false"))
        XCTAssertTrue(source.contains("IncidentLedgerPersistence.append(record, to: ledgerURL)"))
        XCTAssertTrue(source.contains("IncidentLedgerPersistence.sweepExpired(at: ledgerURL)"))
        // The terminal synchronous write still SERIALIZES on the IO queue (via `sync`), so
        // it drains queued async incidents first and can't overtake them — the append-only
        // timeline never shows the restart before the incident that caused it (Codex #200).
        XCTAssertTrue(source.contains("appGroupLogIOQueue.sync {"))

        // Exactly ONE synchronous incident write — the terminal self-reconnect commit that
        // must land before cancelTunnelWithError. Every other site is async-hopped.
        XCTAssertEqual(
            source.components(separatedBy: "synchronous: true").count - 1,
            1,
            "only the terminal self-reconnect commit writes synchronously"
        )

        // CON-1 clear ordering (Codex #200 P1/P2): each clear runs on the SAME serial queue
        // as ITS FILE's deferred appends, so a queued append enqueued before the clear runs
        // first and the wipe wins — a pending append can't resurrect a just-cleared log.
        let clearNetBlock = try sourceBlock(
            in: source,
            startingAt: "case LavaSecAppGroup.clearNetworkActivityLogMessage:",
            endingBefore: "case LavaSecAppGroup.clearIncidentLedgerMessage:"
        )
        // The network-activity clear stays BLOCKING/reliable — its queue is never drained by
        // the terminal self-reconnect `sync`, so a privacy wipe is never dropped (Codex #200 P2).
        XCTAssertTrue(clearNetBlock.contains("Self.networkActivityLogIOQueue.async {"))
        XCTAssertTrue(clearNetBlock.contains("NetworkActivityLogPersistence.clear(at: networkActivityLogURL)"))

        let clearLedgerBlock = try sourceBlock(
            in: source,
            startingAt: "case LavaSecAppGroup.clearIncidentLedgerMessage:",
            endingBefore: "case LavaSecAppGroup.flushTunnelHealthMessage:"
        )
        XCTAssertTrue(clearLedgerBlock.contains("Self.appGroupLogIOQueue.async {"))
        // The ledger clear IS on the terminal-sync queue, so it must be the NON-BLOCKING
        // tryClear — a blocking clear could stall the teardown draining behind it (Codex #200 P2).
        XCTAssertTrue(clearLedgerBlock.contains("IncidentLedgerPersistence.tryClear(at: ledgerURL)"))
        XCTAssertFalse(
            clearLedgerBlock.contains("IncidentLedgerPersistence.clear(at: ledgerURL)"),
            "the tunnel-side ledger clear must be the non-blocking tryClear, not the blocking clear"
        )
        // The ledger clear takes a dnsStateQueue turn BEFORE the appGroupLogIOQueue hop, so
        // dnsStateQueue-originated recordIncident appends are already enqueued ahead of it
        // (Codex #200 P2): otherwise a queued DNS-state block could resurrect the ledger.
        let ledgerDNSTurn = try XCTUnwrap(clearLedgerBlock.range(of: "dnsStateQueue.async")).lowerBound
        let ledgerIOHop = try XCTUnwrap(clearLedgerBlock.range(of: "Self.appGroupLogIOQueue.async")).lowerBound
        XCTAssertLessThan(ledgerDNSTurn, ledgerIOHop, "the clear must drain dnsStateQueue before hopping to the IO queue")

        // The app's clear-all sends the ledger clear so the tunnel drains its queue
        // (clearAllLocalLogs lives on DiagnosticsController since the Phase D4 peel;
        // the message still travels the hub's provider-message channel via the bridge).
        let diagnosticsControllerSource = try readSource(.diagnosticsController)
        XCTAssertTrue(diagnosticsControllerSource.contains("sendTunnelMessage(LavaSecAppGroup.clearIncidentLedgerMessage)"))
    }

    func testIncidentLedgerWritesAtEveryIncidentSiteWithoutTouchingPolicy() throws {
        let source = try readSource(.packetTunnelProvider)

        // The single static writer (durable-before-cancel discipline lives here).
        XCTAssertTrue(source.contains("private static func recordIncident("))

        // Self-reconnect COMMIT: recorded BEFORE cancelTunnelWithError kills the process.
        let teardownBlock = try sourceBlock(
            in: source,
            startingAt: "private func performGuardedSelfReconnectTeardown",
            endingBefore: "private static func isOnDemandConfirmedEnabled"
        )
        let commitRecordIndex = try XCTUnwrap(teardownBlock.range(of: ".selfReconnectCommitted")).lowerBound
        let cancelIndex = try XCTUnwrap(teardownBlock.range(of: "self.cancelTunnelWithError(nil)")).lowerBound
        XCTAssertLessThan(
            commitRecordIndex,
            cancelIndex,
            "the ledger write must be durable before the cancel kills the process"
        )

        // Credit, wedge lifecycle, reducer-emitted incidents, and exhaustion sites.
        XCTAssertTrue(source.contains(".selfReconnectCredited"))
        XCTAssertTrue(source.contains(".wedgeRecovered"))
        XCTAssertTrue(source.contains("case .recordIncident(let incident):"))
        XCTAssertTrue(source.contains("Self.recordIncident(\n                    incident.kind,"))
        XCTAssertTrue(source.contains("Self.recordIncident(.deviceDNSRecaptureExhausted, reason: reason)"))

        // Fail-closed: the two PERSISTENT enter sites (over-budget, unbuildable), the
        // serve-path record for a transient window that actually SERVED a query, and the
        // marker-backed EXIT. The transient startTunnel-bootstrap window is deliberately
        // NOT ledgered at entry (OBS-C2): it's taken on every start for over-cap users and
        // the async load fixes it within seconds — an unconditional record there floods
        // the ring with routine startups (OBS-1 misleading-true). Coverage splits on user
        // visibility instead (Codex fast-follow round 2): quiet windows stay silent, a
        // served window records once.
        XCTAssertEqual(
            source.components(separatedBy: "Self.recordIncident(.failClosedEntered").count - 1,
            3,
            "the two persistent enter sites plus the first-serve transient record; the bootstrap entry itself never records"
        )
        XCTAssertTrue(source.contains("Self.recordIncident(.failClosedExited)"))
        // The transient bootstrap else-branch must NOT carry a ledger write (block-scoped,
        // not a substring: the transient REASON is legitimately ledgered from the serve path).
        let bootstrapFailClosedBlock = try sourceBlock(
            in: source,
            startingAt: "// No serviceable in-budget on-disk artifact",
            endingBefore: "// Publish under snapshotQueue."
        )
        XCTAssertFalse(bootstrapFailClosedBlock.contains("recordIncident"))
        // The serve-path record is latched to the first serve of a window class (the
        // health-trace latch — health resets per start, so at most ONE record per tunnel
        // start, never per query) and scoped to the TRANSIENT class only (the persistent
        // classes already record their transition-gated enter at the commit site; a
        // serve-side record for them would double-enter one window).
        XCTAssertTrue(source.contains("""
                if isFirstTraceOfWindowClass {
                    self.persistHealthIfNeeded(force: true)
"""))
        XCTAssertTrue(source.contains("""
                    if resolvedReason == "transient-protection-unavailable" {
                        Self.recordIncident(.failClosedEntered, reason: resolvedReason)
                    }
"""))
        // The over-budget record stays OUTSIDE the QA-gated append (Release visibility),
        // and every reload-path fail-closed record is gated on BOTH the generation-
        // guarded commit actually LANDING (a superseded reload's no-op never served
        // fail-closed — Codex round 1) and the TRANSITION into fail-closed (the Focus
        // poll retries an unadoptable generation once per minute; per-retry records
        // would flood the 50-record ring — Codex round 3).
        XCTAssertTrue(source.contains("""
                if didCommitFailClosed, !wasFailClosedBeforeOverBudget {
                    Self.recordIncident(.failClosedEntered, reason: "snapshot-unavailable")
                }
                #if DEBUG || LAVA_QA_TOOLS
"""))
        XCTAssertTrue(source.contains("if didCommitFailClosed, !wasFailClosedBeforeBuildFailure {"))
        XCTAssertTrue(source.contains("if exitsFailClosed, didCommitRealSnapshot {"))

        // The frozen recovery path never READS the ledger: the policy's inputs are
        // untouched (its file contains no ledger reference), and the tunnel only ever
        // appends and runs the startup retention sweep — it never loads ledger CONTENTS
        // (no IncidentLedgerPersistence.load call anywhere in the provider; the sweep
        // arms/confirms inside the persistence lock and returns nothing).
        let policySource = try readSource(.tunnelSelfReconnectPolicy)
        XCTAssertTrue(policySource.contains("public static func prunedAttemptTimes"))
        XCTAssertFalse(policySource.contains("IncidentLedger"))
        XCTAssertFalse(source.contains("IncidentLedgerPersistence.load"))
        // The on-disk 7-day retention promise (Codex fast-follow round 3): tunnel starts
        // are the recurring hook for the two-phase (arm → 24 h-corroborated confirm)
        // expiry sweep, so stale records are deleted without any single clock reading
        // ever being able to destroy evidence.
        XCTAssertTrue(source.contains("Self.sweepIncidentLedger()"))

        // COH-4: the app's report READ is a pure view — recentRecords filters the window
        // with no write-back, so a skewed clock at read time cannot destroy the timeline
        // (Codex round 1: any persisted single-clock prune re-wipes under combined
        // write+read skew). On-disk retention is the SEPARATE two-phase sweep, skew-safe
        // by construction (arm → 24 h corroborated confirm), hooked to the app's
        // local-log lifecycle as well (Codex round 4: tunnel starts stop happening while
        // the VPN is disabled, and expired rows must not outlive the 7-day promise).
        // The app-side ledger read/sweep/clear lifecycle lives on DiagnosticsController
        // since the Phase D4 peel.
        let appSource = try readSource(.diagnosticsController)
        XCTAssertTrue(appSource.contains("""
        sweepIncidentLedgerRetention()
        let ledgerURL = containerURL.appendingPathComponent(LavaSecAppGroup.incidentLedgerFilename)
        return IncidentLedgerPersistence.load(from: ledgerURL).recentRecords()
"""))
        let refreshDiagnosticsBlock = try sourceBlock(
            in: appSource,
            startingAt: "func refreshDiagnostics() {",
            endingBefore: "guard let diagnosticsURL else {"
        )
        XCTAssertTrue(refreshDiagnosticsBlock.contains("sweepIncidentLedgerRetention()"))

        // Clear-all-logs privacy contract: the ledger is a local log like the others,
        // so the user's clear must wipe it (Codex round 2).
        let clearAllBlock = try sourceBlock(
            in: appSource,
            startingAt: "func clearAllLocalLogs()",
            endingBefore: "func setKeepFilteringCounts"
        )
        XCTAssertTrue(clearAllBlock.contains("clearIncidentLedger()"))
        XCTAssertTrue(appSource.contains("IncidentLedgerPersistence.clear(at: ledgerURL)"))

        // PST-6: clear-all also wipes the device debug log (resolver endpoints + network-change
        // timeline the export would otherwise ship) and the self-reconnect gap markers.
        XCTAssertTrue(clearAllBlock.contains("clearDeviceDebugLog()"))
        XCTAssertTrue(clearAllBlock.contains("clearSelfReconnectGapMarkers()"))
        XCTAssertTrue(appSource.contains("LavaSecDeviceDebugLog.reset()"))
        let gapClearBlock = try sourceBlock(
            in: appSource,
            startingAt: "private func clearSelfReconnectGapMarkers()",
            endingBefore: "private func"
        )
        XCTAssertTrue(gapClearBlock.contains("selfReconnectGapStartedAtDefaultsKeyName"))
        XCTAssertTrue(gapClearBlock.contains("selfReconnectGapEndedAtDefaultsKeyName"))
        XCTAssertTrue(gapClearBlock.contains("selfReconnectGapCountDefaultsKeyName"))
        // The operational cooldown store and tunnel-health are deliberately NOT wiped (frozen
        // recovery control flow); the gap-marker clear must not touch the attempt-times key.
        XCTAssertFalse(gapClearBlock.contains("selfReconnectAttemptTimesDefaultsKeyName"))
    }

    func testRefreshDiagnosticsDefersPruneWriteBackWhileTunnelOwnsFile() throws {
        // UX-4 / PST-3: diagnostics.json is the only multi-writer app-group JSON with no
        // cross-process lock. While the tunnel is connected it OWNS the file (it prunes on
        // every debounced write and on stop-flush, unlocked). The app's `refreshDiagnostics`
        // prune write-back must therefore be skipped while the tunnel may still write, or a
        // write landing between the tunnel's final stop-flush load and save permanently loses
        // the last few Domain History events. The app still prunes IN MEMORY for display and
        // persists its prune once it owns the file (protection off). Config-driven clears are
        // coordinated with the tunnel (control file + IPC) and still persist regardless.
        // refreshDiagnostics lives on DiagnosticsController since the Phase D4 peel;
        // the file-ownership signal reaches it through the hub bridge.
        let appSource = try readSource(.diagnosticsController)
        let block = try sourceBlock(
            in: appSource,
            startingAt: "func refreshDiagnostics() {",
            endingBefore: "// MARK: - Bug reports & rage shake"
        )

        // Ownership must span the whole NON-stopped lifecycle, not just .connected: the permanent
        // lost-update is the tunnel's stop-flush during .disconnecting. The controller reads the
        // classification through the bridge; the hub conformance is what keeps it
        // isProtectionStopPendingStatus(vpnStatus) — true for
        // .connected/.connecting/.reasserting/.disconnecting, false once stopped. Pin BOTH sides.
        XCTAssertTrue(
            block.contains("let tunnelOwnsDiagnosticsFile = hub.isProtectionStopPending"),
            "Ownership of the unlocked diagnostics file must cover the teardown (.disconnecting) window."
        )
        let hubSource = try readSource(.appViewModel)
        XCTAssertTrue(
            hubSource.contains("""
    var isProtectionStopPending: Bool {
        isProtectionStopPendingStatus(vpnStatus)
    }
"""),
            "The bridge's ownership signal must stay the stop-pending classification of the live vpnStatus."
        )

        // Unchanged-file branch: in-memory == disk here, so it's safe to write. Flush a deferred
        // prune (carried from a refresh where the tunnel owned the file) and/or a fresh idle-clock
        // expiry, gated on app ownership; defer otherwise (Codex #225).
        XCTAssertTrue(
            block.contains("let prunedNow = diagnostics.pruneExpiredFineGrainedData()")
                && block.contains("if !tunnelOwnsDiagnosticsFile, diagnosticsPrunePersistDeferred || prunedNow {")
                && block.contains("diagnosticsPrunePersistDeferred = true"),
            "The unchanged-file branch must flush a deferred/idle prune when the app owns the file and defer otherwise (UX-4/#225)."
        )

        // P1 (#225): the deferred prune must NEVER be flushed AHEAD of the read gate. Persisting the
        // stale in-memory copy before `shouldRead` would overwrite the tunnel's final Domain History
        // writes whenever the file changed. Assert no diagnostics write happens between computing
        // ownership and the read-gate guard — a changed file instead drops the flag and lets the
        // fresh reload re-prune and persist the authoritative on-disk store.
        let preReadGate = try sourceBlock(
            in: appSource,
            startingAt: "let tunnelOwnsDiagnosticsFile = hub.isProtectionStopPending",
            endingBefore: "guard diagnosticsReadGate.shouldRead(modifiedAt: modifiedAt, force: shouldForceLocalLogClear) else {"
        )
        XCTAssertFalse(
            preReadGate.contains("persistDiagnostics()"),
            "No diagnostics write may occur before the read gate — it would clobber the tunnel's writes (P1 #225)."
        )

        // Changed-file branch: the prune-only persist is gated on ownership; the pending flag
        // is still consumed (transient) so it can't linger set on the shared store.
        XCTAssertTrue(
            block.contains("let prunePending = store.consumePendingFineGrainedPrunePersist()"),
            "The pending-prune flag must always be consumed off the fresh local store."
        )
        XCTAssertTrue(
            block.contains("var shouldPersistClearedLogs = prunePending && !tunnelOwnsDiagnosticsFile"),
            "The prune-only write-back must be skipped while the tunnel owns the file (PST-3)."
        )

        // Config-driven clears are coordinated with the tunnel and must persist regardless of
        // ownership — they force the persist flag true, not gated on `tunnelOwnsDiagnosticsFile`.
        XCTAssertTrue(
            block.contains("store.clearFilteringCounts()")
                && block.contains("shouldPersistClearedLogs = true"),
            "A config-driven filtering-counts clear must still force a persist."
        )
    }

    func testSelfReconnectGapCloseFloorsEndPastStartOnBackwardClock() throws {
        // COH-2: the app reader accepts a gap's end only when it is STRICTLY AFTER the start
        // (loadSelfReconnectGapRecord: `endedAtRaw > startedAtRaw ? … : nil`). If the tunnel's
        // close stamped a raw `now` and the wall clock had stepped backward past the recorded
        // start, it would write `ended <= started` — which the reader rejects as stale and reads
        // the gap as OPEN forever, so every bug report flags an ongoing incident while serving.
        // The close must instead floor the end past the start on a backward step (never an
        // unconditional `now` stamp), which is observability-only and leaves the frozen reconnect
        // decision untouched.
        let source = try readSource(.packetTunnelProvider)
        let closeBlock = try sourceBlock(
            in: source,
            startingAt: "private static func closeDanglingSelfReconnectGapIfNeeded(",
            endingBefore: "private func creditProductiveSelfReconnectIfPending("
        )
        // A backward step is detected and the persisted end is floored one second past the start
        // so the reader's strict `ended > started` acceptance holds (self-heals once the clock
        // passes the recorded start).
        XCTAssertTrue(
            closeBlock.contains("startedAtRaw + 1"),
            "A backward clock must floor the gap end past the start so the reader reads it as CLOSED (COH-2)."
        )
        XCTAssertTrue(
            closeBlock.contains("nowRaw <= startedAtRaw"),
            "The close must detect a backward clock step relative to the recorded start (COH-2)."
        )
        // The persisted end is the floored value, NOT a raw `now` — so the reader never sees a
        // stale `ended <= started`.
        XCTAssertTrue(
            closeBlock.contains("defaults.set(endedRaw, forKey: LavaSecAppGroup.selfReconnectGapEndedAtDefaultsKeyName)"),
            "The close must persist the floored end, never an unconditional now stamp (COH-2)."
        )
        XCTAssertFalse(
            closeBlock.contains("defaults.set(now.timeIntervalSince1970, forKey: LavaSecAppGroup.selfReconnectGapEndedAtDefaultsKeyName)"),
            "The close must not stamp a raw now for the gap end (COH-2)."
        )
        // The anomaly is observable in the device log so a floored close is diagnosable.
        XCTAssertTrue(
            closeBlock.contains("clockAnomaly"),
            "A backward-clock close must be observable in the device log (COH-2)."
        )
    }

    func testTunnelHotPathPauseReadAppliesSanityCap() throws {
        // UX-2 (Codex #208): the store clamps an over-cap pausedUntil, but the DNS hot path
        // reads a CACHED value whose 1s refresh gate wedges past a backward clock step, so the
        // cap must be re-applied at the point of interpretation or a stale far-future pause
        // keeps filtering off for the clock-step size.
        let source = try readSource(.packetTunnelProvider)
        // The hot-path read re-applies the store's ceiling to the CACHED value; over the cap it
        // FORCES a store refresh (which compare-and-discards + reconciles) then returns not-paused.
        let pauseActiveBlock = try sourceBlock(
            in: source,
            startingAt: "private func isTemporaryProtectionPauseActive(",
            endingBefore: "private func currentTemporaryProtectionPauseUntil("
        )
        XCTAssertTrue(
            pauseActiveBlock.contains("pauseUntil.timeIntervalSince(now) > ProtectionPauseStore.maxPauseDuration"),
            "The cached hot-path pause read must re-apply the store's sanity ceiling (UX-2)."
        )
        XCTAssertTrue(
            pauseActiveBlock.contains("refreshTemporaryProtectionPauseState("),
            "An over-cap cached pause must force a store refresh so the discard + reconcile run (UX-2)."
        )

        // The cached-read refresh gate must ALSO fire on a BACKWARD wall-clock step (a negative
        // interval since the last refresh), so the store's compare-and-discard runs even when the
        // tunnel cache is nil (an intent-written pause the tunnel never learned via a reload
        // message) — otherwise the over-cap keys survive unread and re-activate once the clock
        // catches up to within the cap (UX-2, Codex #208).
        let cachedReadBlock = try sourceBlock(
            in: source,
            startingAt: "private func currentTemporaryProtectionPauseUntil(",
            endingBefore: "private func refreshTemporaryProtectionPauseState("
        )
        XCTAssertTrue(
            cachedReadBlock.contains("sinceLastRefresh < 0"),
            "A backward wall-clock step must force a store refresh even when the cache is nil (UX-2)."
        )

        // The refresh is the SINGLE reconcile point: a pause that vanished from the store
        // (compare-and-discarded / externally cleared) republishes protection ON for EVERY caller
        // (hot path, resume timer's nil branch, any forced refresh), not just the hot path (Codex #208).
        let refreshBlock = try sourceBlock(
            in: source,
            startingAt: "private func refreshTemporaryProtectionPauseState(",
            endingBefore: "private func reconcileProtectionOnAfterVanishedTemporaryPause("
        )
        XCTAssertTrue(refreshBlock.contains("previous != nil && storedRead.pauseUntil == nil"))
        XCTAssertTrue(refreshBlock.contains("reconcileProtectionOnAfterVanishedTemporaryPause()"))
        // Reconcile ALSO fires when the store clamped an over-cap pause with no cache transition
        // (previous == nil) — an intent-written pause the tunnel never learned (Codex #208).
        XCTAssertTrue(refreshBlock.contains("clampedCappedPause = storedRead.clampedCappedPause"))
        // The store READ must sit INSIDE the protectionPauseStateQueue.sync that swaps the cache,
        // or an older overlapping refresh can write a stale pause back after a newer one vanished
        // it (Codex #208 post-merge). Pin the ordering: the sync opens before the store read.
        let syncOpenIndex = try XCTUnwrap(refreshBlock.range(of: "protectionPauseStateQueue.sync {")?.lowerBound)
        let storeReadIndex = try XCTUnwrap(
            refreshBlock.range(of: "readTemporaryProtectionPauseUntilFromDefaults(")?.lowerBound
        )
        XCTAssertLessThan(syncOpenIndex, storeReadIndex, "the store read must be inside the cache-swap serialization")

        // The reconcile is unconditional (single-shot via the vanish transition), so it fires even
        // for an intent-initiated pause the tunnel never marked applied (lastApplied=false).
        let reconcileBlock = try sourceBlock(
            in: source,
            startingAt: "private func reconcileProtectionOnAfterVanishedTemporaryPause()",
            endingBefore: "private func cacheTemporaryProtectionPauseUntil("
        )
        XCTAssertTrue(reconcileBlock.contains("lastAppliedTemporaryProtectionPauseIsActive = false"))
        XCTAssertTrue(reconcileBlock.contains("updateLiveActivitiesAfterTemporaryProtectionPauseExpired()"))
        // The async reconcile must re-read the store on the dnsStateQueue hop and bail if a new
        // pause was started meanwhile, so a stale unconditional ON can't clobber it (Codex #208).
        let recheckIndex = try XCTUnwrap(reconcileBlock.range(of: "protectionPauseStore.currentPauseState()")?.lowerBound)
        let onUpdateIndex = try XCTUnwrap(
            reconcileBlock.range(of: "updateLiveActivitiesAfterTemporaryProtectionPauseExpired()")?.lowerBound
        )
        XCTAssertLessThan(recheckIndex, onUpdateIndex, "the current-pause re-check must gate the ON update")

        // The ON publish's DIRECT ActivityKit path is unversioned, so it must re-verify current
        // pause at the ACTUAL update site (inside the async Task, immediately before
        // activity.update) — an earlier check alone leaves an async window where a new pause is
        // clobbered by a stale .on (Codex #208).
        let onUpdaterBlock = try sourceBlock(
            in: source,
            startingAt: "private func updateLiveActivitiesAfterTemporaryProtectionPauseExpired()",
            endingBefore: "private func isTemporaryProtectionPauseActive("
        )
        let loopIndex = try XCTUnwrap(onUpdaterBlock.range(of: "for activity in activities {")?.lowerBound)
        let siteCheckIndex = try XCTUnwrap(
            onUpdaterBlock.range(of: "protectionPauseStore.currentPauseState()")?.lowerBound
        )
        let activityUpdateIndex = try XCTUnwrap(
            onUpdaterBlock.range(of: "await activity.update(content)")?.lowerBound
        )
        // The check must be INSIDE the loop, before each update: a prior await can suspend long
        // enough for a new pause, so a single pre-loop check leaves later activities exposed.
        XCTAssertLessThan(loopIndex, siteCheckIndex, "the current-pause check must be inside the update loop")
        XCTAssertLessThan(
            siteCheckIndex,
            activityUpdateIndex,
            "the ON updater must re-check current pause immediately before each activity.update"
        )
    }

    /// Extracts the literal value of a `<name>: TimeInterval = <number>` declaration from source.
    private func timeIntervalConstant(_ name: String, in source: String) throws -> Double {
        let start = try XCTUnwrap(source.range(of: "\(name): TimeInterval = ")?.upperBound)
        let digits = source[start...].prefix { $0.isNumber || $0 == "." || $0 == "_" }
        return try XCTUnwrap(Double(String(digits).replacingOccurrences(of: "_", with: "")))
    }
}

private extension String {
    func hasDirectMutation(of target: String) -> Bool {
        let code = replacingOccurrences(
            of: #"/\*[\s\S]*?\*/|//[^\n]*"#,
            with: "",
            options: .regularExpression
        ).replacingOccurrences(of: "self.", with: "")
        let assignmentPrefixes = [
            "+=", "-=", "*=", "/=", "%=", "&=", "|=", "^=", "<<=", ">>=", "??=",
        ]
        let mutatingMethods = [
            "append", "formIntersection", "formSymmetricDifference", "formUnion", "insert",
            "merge", "negate", "partition", "remove", "removeAll", "removeFirst",
            "removeLast", "removeSubrange", "removeValue", "replaceSubrange", "reserveCapacity",
            "reverse", "shuffle", "sort", "subtract", "swapAt", "toggle", "updateValue",
        ]
        var searchStart = code.startIndex

        while let range = code.range(of: target, range: searchStart..<code.endIndex) {
            let prefix = code[..<range.lowerBound]
            if prefix.last(where: { !$0.isWhitespace }) == "&" {
                return true
            }

            var suffix = code[range.upperBound...].drop(while: { $0.isWhitespace })
            if suffix.hasPrefix("=") && !suffix.hasPrefix("==") {
                return true
            }
            if assignmentPrefixes.contains(where: suffix.hasPrefix) {
                return true
            }
            if target.contains("Counts"), suffix.hasPrefix("[") {
                return true
            }
            if suffix.hasPrefix("?") {
                suffix = suffix.dropFirst().drop(while: { $0.isWhitespace })
            }
            if mutatingMethods.contains(where: { suffix.hasPrefix(".\($0)(") }) {
                return true
            }

            searchStart = range.upperBound
        }

        return false
    }

    func containsInOrder(_ needles: [String]) -> Bool {
        var searchRange = startIndex..<endIndex

        for needle in needles {
            guard let range = range(of: needle, range: searchRange) else {
                return false
            }
            searchRange = range.upperBound..<endIndex
        }

        return true
    }
}
