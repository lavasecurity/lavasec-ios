import XCTest
@testable import LavaSecCore

/// Pins the tunnel half of INV-PERSIST-1 (Phase 1 of lavasec-infra
/// `plans/2026-07-14-reboot-first-unlock-data-reset-incident-plan.md`): a
/// Connect-On-Demand boot start before first unlock reads the shared config as
/// existing-but-unreadable and must (1) bootstrap FAIL-CLOSED, never the empty
/// pass-through (INV-DNS-1); (2) keep the config-refresh retry alive past the
/// unchanged-mtime gate (file metadata is readable while content is locked); (3) abort
/// the background snapshot reload instead of adopting the boot placeholder; and (4)
/// defer the earliest shared-suite writes so cfprefsd can never re-materialize the
/// locked plist with only the tunnel's keys (incident latent-2). The classification
/// logic itself is executable-tested in `SharedStateFileReaderTests`; these pins cover
/// the provider wiring the compiler can't see.
final class TunnelPreUnlockGuardSourceTests: XCTestCase {
    func testUnreadableConfigBootstrapsFailClosedNeverPassThrough() throws {
        let source = try readSource(.packetTunnelProvider)
        XCTAssertTrue(source.contains("private func loadConfigurationClassified()"),
                      "The tunnel's config read must classify unreadable distinctly (INV-PERSIST-1).")
        XCTAssertTrue(source.contains("SharedStateFileReader.read(AppConfiguration.self"),
                      "Classification must go through the shared INV-PERSIST-1 reader.")

        let initialStateBlock = try sourceBlock(
            in: source,
            startingAt: "private func loadInitialSharedState() -> Bool",
            endingBefore: "private func refreshConfigurationIfNeeded"
        )
        let unreadableIdx = try XCTUnwrap(
            initialStateBlock.range(of: "if configurationIsUnreadable {")?.lowerBound,
            "The bootstrap must branch on the unreadable classification."
        )
        let emptyIdx = try XCTUnwrap(
            initialStateBlock.range(of: "configuration.enabledBlocklistIDs.isEmpty {")?.lowerBound
        )
        XCTAssertLessThan(unreadableIdx, emptyIdx,
                          "Unreadable must be decided BEFORE the empty pass-through — a locked config is not \"no filters\".")

        let unreadableBranch = try sourceBlock(
            in: initialStateBlock,
            startingAt: "if configurationIsUnreadable {",
            endingBefore: "configuration.enabledBlocklistIDs.isEmpty {"
        )
        XCTAssertTrue(unreadableBranch.contains("FailClosedRuntimeSnapshot(resolver: configuration.resolverPreset)"),
                      "An unreadable config must serve fail-closed, never the empty pass-through (INV-DNS-1).")
    }

    func testUnreadableConfigLeavesRefreshMarkerNilSoRetriesContinue() throws {
        let source = try readSource(.packetTunnelProvider)
        let initialStateBlock = try sourceBlock(
            in: source,
            startingAt: "private func loadInitialSharedState() -> Bool",
            endingBefore: "private func refreshConfigurationIfNeeded"
        )
        XCTAssertTrue(
            initialStateBlock.contains(
                "let configurationModifiedAt = (configurationIsUnreadable || hasPendingFreshProtectionVPNSessionBegin())"
            ),
            "A locked (failed) load must not stamp the real mtime — metadata reads succeed while content is locked, and stamping would make the unchanged-mtime gate suppress every retry (the sticky fail-open). A PENDING deferred begin keeps the marker nil too: unlock can land between the begin canary and this read, and the cadence tick this marker un-gates is then the only flush path (Codex P2 round 14)."
        )
        XCTAssertTrue(
            initialStateBlock.contains(": modificationDate(for: configurationURL)"),
            "The readable, nothing-pending boot must still stamp the real mtime so the unchanged-mtime throttle works."
        )
        let refreshBlock = try sourceBlock(
            in: source,
            startingAt: "private func refreshConfigurationIfNeeded",
            endingBefore: "private static func resolverNetworkIdentity"
        )
        XCTAssertTrue(refreshBlock.contains("modifiedAt != lastConfigurationModifiedAt"),
                      "The unchanged-mtime gate the nil marker defeats must remain the refresh throttle.")
    }

    func testBackgroundReloadAbortsInsteadOfAdoptingPlaceholderOnUnreadableConfig() throws {
        let source = try readSource(.packetTunnelProvider)
        let loadSnapshotBlock = try sourceBlock(
            in: source,
            startingAt: "private func loadSnapshotInBackground(reason: String, operationID: LatencyOperationID? = nil)",
            endingBefore: "private func scheduleProtectionPauseResumeIfNeeded"
        )
        let abortIdx = try XCTUnwrap(
            loadSnapshotBlock.range(of: "loadSnapshot-aborted-config-unreadable")?.lowerBound,
            "A reload against an unreadable config must abort (keeping the resident snapshot), not rebuild from the in-memory boot placeholder."
        )
        let noOpGateIdx = try XCTUnwrap(
            loadSnapshotBlock.range(of: "residentSnapshotSatisfiesReload(configuration: configuration)")?.lowerBound
        )
        XCTAssertLessThan(abortIdx, noOpGateIdx,
                          "The unreadable abort must run before any adoption/no-op gating.")
    }

    func testBootSuiteWritesAreDeferredUntilProtectedContentIsReadable() throws {
        let source = try readSource(.packetTunnelProvider)
        let beginBlock = try sourceBlock(
            in: source,
            startingAt: "private func beginFreshProtectionVPNSession(reason: String)",
            endingBefore: "private func endProtectionVPNSession(reason: String)"
        )
        let guardIdx = try XCTUnwrap(
            beginBlock.range(of: "guard sharedProtectedContentIsReadable() else")?.lowerBound,
            "The session-begin suite writes must be canary-gated (latent-2: cfprefsd plist re-materialization)."
        )
        let writeIdx = try XCTUnwrap(beginBlock.range(of: "protectionSessionStore.beginFreshSession()")?.lowerBound)
        XCTAssertLessThan(guardIdx, writeIdx, "The canary must precede the first suite write.")

        // The canary must probe a Class-C file whose ABSENCE means "nothing to clobber":
        // the config is disqualified (Class-None post-INV-PERSIST-2, readable pre-unlock)
        // and diagnostics.json is disqualified too (legitimately absent long past install
        // when counts + history are disabled — PR #378 review). The suite plist is the
        // clobber target itself, so probing it makes both semantics exact.
        XCTAssertTrue(source.contains("SharedStateFileReader.fileExistsButIsUnreadable(at: suitePlistURL)"),
                      "The canary must probe the suite plist — the very file the deferred writes protect.")
        XCTAssertTrue(source.contains("appendingPathComponent(LavaSecAppGroup.identifier + \".plist\")"),
                      "The probe must target the app-group preferences plist by its stable layout.")
        XCTAssertFalse(source.contains("SharedStateFileReader.fileExistsButIsUnreadable(at: configurationURL)"),
                       "No canary may probe the config file — it is Class-None post-INV-PERSIST-2 and reads fine while Class C is still locked.")
        XCTAssertFalse(source.contains("SharedStateFileReader.fileExistsButIsUnreadable(at: diagnosticsURL)"),
                       "No canary may probe diagnostics — it can be legitimately absent while the locked suite exists.")

        let refreshBlock = try sourceBlock(
            in: source,
            startingAt: "private func refreshConfigurationIfNeeded",
            endingBefore: "private static func resolverNetworkIdentity"
        )
        // BOTH readable-content outcomes must flush: .loaded AND .absentOrCorrupt each prove
        // first unlock happened, and a config that turns out corrupt behind a locked boot
        // would otherwise strand the pending begin forever (Codex P2 round 17). Only the
        // still-locked .unreadable branch may skip the flush.
        XCTAssertTrue(
            refreshBlock.contains("flushDeferredFreshProtectionVPNSessionIfNeeded(hasDecodableConfiguration: true)"),
            "The .loaded branch must flush with the recovery reload enabled — a real config exists to load."
        )
        // Post-INV-PERSIST-2 a pre-unlock tick can classify .loaded (Class-None config)
        // while the begin re-defers on the suite-plist canary — stamping the mtime there
        // would wall the flush off behind the unchanged-mtime gate (PR #378 review). The
        // stamp must follow the flush and be gated on nothing pending.
        let loadedFlushIdx = try XCTUnwrap(
            refreshBlock.range(of: "flushDeferredFreshProtectionVPNSessionIfNeeded(hasDecodableConfiguration: true)")?.lowerBound
        )
        let stampGateIdx = try XCTUnwrap(
            refreshBlock.range(of: "if !hasPendingFreshProtectionVPNSessionBegin() {")?.lowerBound,
            "The .loaded mtime stamp must be gated on no pending begin."
        )
        let stampIdx = try XCTUnwrap(
            refreshBlock.range(of: "lastConfigurationModifiedAt = modifiedAt")?.lowerBound
        )
        XCTAssertLessThan(loadedFlushIdx, stampGateIdx, "The flush must run before the stamp decision.")
        XCTAssertLessThan(stampGateIdx, stampIdx, "The stamp must sit inside the pending-begin gate.")
        XCTAssertTrue(
            refreshBlock.contains("flushDeferredFreshProtectionVPNSessionIfNeeded(hasDecodableConfiguration: false)"),
            "The .absentOrCorrupt branch must flush WITHOUT the recovery reload — loading would install the empty placeholder's pass-through over fail-closed (Codex P1 round 18)."
        )
        XCTAssertEqual(
            sourceOccurrenceCount(of: "flushDeferredFreshProtectionVPNSessionIfNeeded(", in: refreshBlock), 2,
            "The refresh must flush the deferred begin from .loaded AND .absentOrCorrupt — readability, not decodability, is the unlock proof."
        )
        let unreadableCaseRange = try XCTUnwrap(
            refreshBlock.range(of: "case .unreadable:"),
            "The refresh must classify the read — nil-for-both would conflate locked with corrupt again."
        )
        XCTAssertFalse(
            refreshBlock[unreadableCaseRange.upperBound...].contains("flushDeferredFreshProtectionVPNSessionIfNeeded("),
            "The still-locked branch must never flush — the begin would write into a locked suite."
        )

        let flushBlock = try sourceBlock(
            in: source,
            startingAt: "private func flushDeferredFreshProtectionVPNSessionIfNeeded(hasDecodableConfiguration: Bool)",
            endingBefore: "private func beginFreshProtectionVPNSession(reason: String)"
        )
        XCTAssertTrue(flushBlock.contains("Self.closeDanglingSelfReconnectGapIfNeeded()"),
                      "The flush must also close the gap marker the pre-unlock start skipped (locked reads bailed without writing).")
        // The recovered boot replaces its fail-closed placeholder via an explicit forced
        // reload — the Focus poll's generation watermark can never fire for a legacy
        // gen-zero config (0 > 0), so convergence must not depend on it (Codex P2 on #377).
        XCTAssertTrue(flushBlock.contains("requestSnapshotReload(reason: \"config-recovered-after-unlock\", force: true)"),
                      "Recovering from an unreadable boot config must force a snapshot reload, not rely on generation advancement.")
        // The forced reload must yield to a reload already in flight — the flush can run
        // from inside loadSnapshotInBackground, and forcing there would discard the very
        // snapshot that just recovered (Codex P2 round 3 on #377).
        let inFlightIdx = try XCTUnwrap(
            flushBlock.range(of: "snapshotReloadCoordinator.assumeIsolated { $0.isReloadInFlight }")?.lowerBound,
            "The recovery reload must check for an in-flight reload before forcing."
        )
        let forceIdx = try XCTUnwrap(
            flushBlock.range(of: "requestSnapshotReload(reason: \"config-recovered-after-unlock\", force: true)")?.lowerBound
        )
        XCTAssertLessThan(inFlightIdx, forceIdx,
                          "The in-flight check must precede (and gate) the forced recovery reload.")
        // Yielding must DEFER, never skip: the in-flight reload can be the pre-unlock abort
        // (adopts nothing), and a plain skip would strand a generation-0 config fail-closed
        // (Codex P1 round 8). The handoff fires in clearSnapshotReloadInFlight after the
        // previous reload fully finishes.
        XCTAssertTrue(flushBlock.contains("deferredRecoveryReloadPending = true"),
                      "An in-flight reload defers the recovery force — it must never be dropped.")
        let clearBlock = try sourceBlock(
            in: source,
            startingAt: "private func clearSnapshotReloadInFlight(ifCurrentGeneration generation: UInt64)",
            endingBefore: "private func isCurrentSnapshotReloadGeneration("
        )
        XCTAssertTrue(clearBlock.contains("requestSnapshotReload(reason: \"config-recovered-after-unlock-deferred\", force: true)"),
                      "The deferred recovery force must fire once the in-flight reload's clear runs.")
        // The fire is additionally gated on the coordinator being idle: finish() is
        // generation-gated, so a STALE clear (superseded by a newer reload) leaves
        // reloadInFlight true — firing there would discard that newer in-flight snapshot.
        XCTAssertTrue(clearBlock.contains("!self.snapshotReloadCoordinator.assumeIsolated({ $0.isReloadInFlight })"),
                      "The deferred fire must re-check in-flight so a stale (superseded) clear keeps the handoff armed.")
        // The deferred-begin race boot (unlock between the begin canary and the boot loads —
        // Codex P2 round 14) reaches the flush with REAL stores and a REAL resident, so the
        // recovery duties are gated: stores reload only when the boot loaded them locked,
        // and the forced reload only when the resident is still the placeholder (nil
        // identity) — otherwise the force would reset the DNS runtime behind a healthy
        // resident (the round-13 blip through the direct path).
        XCTAssertTrue(flushBlock.contains("if diagnosticsStoresReflectLockedBoot {"),
                      "The flush must not reload real (post-unlock-loaded) stores — that discards live serve marks.")
        XCTAssertTrue(flushBlock.contains("if hasDecodableConfiguration, currentResidentSnapshotIdentity() == nil {"),
                      "The recovery force must be gated on a DECODABLE config AND the placeholder resident — an .absentOrCorrupt flush that forced a reload would install the empty placeholder's pass-through over fail-closed (Codex P1 round 18).")
        // A PRODUCTIVE in-flight reload disarms the handoff at adoption (FIFO-before its own
        // clear), so the deferred force only fires for a non-adopting clear — firing behind
        // a successful adoption would reset the DNS runtime (SERVFAIL-draining in-flight
        // queries) before the pre-decode no-op gate runs (Codex P2 round 13).
        let adoptionBlock = try sourceBlock(
            in: source,
            startingAt: "event: \"loadSnapshot-loaded\"",
            endingBefore: "// MARK: - Temporary protection pause / resume"
        )
        XCTAssertTrue(adoptionBlock.contains("self.deferredRecoveryReloadPending = false"),
                      "The adoption path must disarm the deferred recovery handoff — its committed snapshot IS the recovery.")
        // Stop-path invalidation must DISARM the handoff: invalidate() drops reloadInFlight,
        // so the superseded reload's late clear would otherwise see the coordinator idle and
        // fire a forced reload into a stopped lifecycle (Codex P2 round 9).
        let invalidateBlock = try sourceBlock(
            in: source,
            startingAt: "private func invalidateSnapshotReloadGeneration(reason: String)",
            endingBefore: "private func loadSnapshotInBackground("
        )
        XCTAssertTrue(invalidateBlock.contains("deferredRecoveryReloadPending = false"),
                      "Reload invalidation (tunnel stop) must clear the deferred recovery handoff.")
        // The recovery must also RELOAD the diagnostics + depth stores (the boot loaded them
        // as locked-empty and serve-path markers dirtied that emptiness — Codex P1 round 6)
        // and re-mark the uptime the boot stamped on the discarded store, all BEFORE the
        // forced snapshot reload can generate fresh serve-path writes.
        let storesReloadIdx = try XCTUnwrap(
            flushBlock.range(of: "loadDiagnosticsAndEventLogStores()")?.lowerBound,
            "The deferred-begin flush must reload the diagnostics/depth stores from the now-readable files."
        )
        XCTAssertTrue(flushBlock.contains("markLocalProtectionUptimeStarted()"),
                      "The uptime marker must be re-stamped against the reloaded store.")
        XCTAssertLessThan(storesReloadIdx, forceIdx,
                          "The stores reload must precede the forced snapshot reload.")
    }

    func testStalePauseIsMaskedWhileSessionBeginIsDeferred() throws {
        let source = try readSource(.packetTunnelProvider)
        let pauseReadBlock = try sourceBlock(
            in: source,
            startingAt: "private func currentTemporaryProtectionPauseUntil(",
            endingBefore: "private func refreshTemporaryProtectionPauseState("
        )
        // A pre-reboot pause whose clearing begin is still deferred must read as NO pause —
        // honoring it would forward DNS unfiltered on a freshly rebooted device (INV-DNS-1,
        // Codex P2 round 4 on #377). The mask must be the FIRST decision in the single
        // pause-read choke point (isTemporaryProtectionPauseActive routes through here).
        let maskIdx = try XCTUnwrap(
            pauseReadBlock.range(of: "guard !hasPendingFreshProtectionVPNSessionBegin() else")?.lowerBound,
            "The pause read must mask stored pauses while the boot-deferred session begin is pending."
        )
        let refreshGateIdx = try XCTUnwrap(pauseReadBlock.range(of: "let now = Date()")?.lowerBound)
        XCTAssertLessThan(maskIdx, refreshGateIdx,
                          "The deferred-begin mask must precede every store read/refresh decision.")

        // The pause reload message is the ONLY wake an idle tunnel gets when the user
        // presses Pause post-unlock — it must flush a pending begin (forced config refresh)
        // BEFORE reading pause state, or the mask above swallows the fresh pause
        // indefinitely (Codex P2 round 15).
        let pauseMessageBlock = try sourceBlock(
            in: source,
            startingAt: "case LavaSecAppGroup.reloadProtectionPauseMessage:",
            endingBefore: "case LavaSecAppGroup.reloadConfigurationMessage:"
        )
        XCTAssertTrue(pauseMessageBlock.contains("if self.hasPendingFreshProtectionVPNSessionBegin() {"),
                      "The pause message must flush a boot-deferred begin — an idle tunnel has no other flush trigger.")
        let messageFlushIdx = try XCTUnwrap(
            pauseMessageBlock.range(of: "refreshConfigurationIfNeeded(force: true)")?.lowerBound
        )
        let pauseRefreshIdx = try XCTUnwrap(
            pauseMessageBlock.range(of: "refreshProtectionPauseStateOnly(reason:")?.lowerBound
        )
        XCTAssertLessThan(messageFlushIdx, pauseRefreshIdx,
                          "The flush must precede the pause-state read so the read sees post-begin state.")
        // The command's pause must be CARRIED across the flush's fresh begin: captured
        // before the flush (the begin clears the keys), re-issued against the fresh session
        // afterward, and all of it before the pause-state read — otherwise the user's first
        // post-unlock Pause tap is a silent no-op while the intent path already published
        // .paused (Codex P2 round 16). Sound only because every sender writes the pause
        // keys immediately before sending this message.
        let captureIdx = try XCTUnwrap(
            pauseMessageBlock.range(of: "let commandPause = try? self.protectionPauseStore.storedPauseState()")?.lowerBound,
            "The just-written pause must be captured before the flush clears it."
        )
        let reissueIdx = try XCTUnwrap(
            pauseMessageBlock.range(of: "self.protectionPauseStore.pause(")?.lowerBound,
            "The carried pause must be re-issued against the fresh session."
        )
        XCTAssertLessThan(captureIdx, messageFlushIdx, "Capture must precede the flush.")
        XCTAssertLessThan(messageFlushIdx, reissueIdx, "Re-issue must follow the flush (fresh session exists).")
        XCTAssertLessThan(reissueIdx, pauseRefreshIdx, "Re-issue must precede the pause-state read that caches it.")
        XCTAssertTrue(pauseMessageBlock.contains("if !self.hasPendingFreshProtectionVPNSessionBegin(),"),
                      "The re-issue must be gated on the begin having actually landed — a still-locked config keeps the mask.")
    }

    func testObservabilityWritersAreCanaryGated() throws {
        let source = try readSource(.packetTunnelProvider)
        // Serve-path observability writes read locked app-group files as empty and then
        // atomically save — the same INV-PERSIST-1 clobber class as the suite writes
        // (Codex P2 round 5 on #377). The Class-C funnels gate on the canary: the
        // diagnostics write closure returns false (stays dirty, retries post-unlock) and
        // the two static ledger writers early-return. The HEALTH closure is deliberately
        // UNGATED post-INV-PERSIST-2: its file is control-plane Class-None (pre-unlock
        // writes land) and health is never reloaded from disk, so it has no locked-file
        // clobber class — a canary gate there would only delay the boot session's
        // observability.
        XCTAssertEqual(
            sourceOccurrenceCount(of: "guard self.sharedProtectedContentIsReadable() else", in: source), 0,
            "No single-condition canary guard should remain — health is ungated (Class-None) and diagnostics uses the dual guard."
        )
        // The diagnostics closure additionally gates on the locked-boot flag: a tick after
        // first unlock but before the recovery reload — or a stop-time forced flush after
        // the pending begin was legitimately dropped — would persist the boot-empty store
        // the reload discards (Codex P1 rounds 6 + 7 on #377).
        XCTAssertEqual(
            sourceOccurrenceCount(
                of: "guard self.sharedProtectedContentIsReadable(),\n                  !self.diagnosticsStoresReflectLockedBoot else",
                in: source
            ), 1,
            "The diagnostics write closure must gate on BOTH the canary and the locked-boot store state."
        )
        // The flag is derived from the canary at load time, in the load function itself —
        // never from the session lifecycle.
        XCTAssertEqual(
            sourceOccurrenceCount(of: "diagnosticsStoresReflectLockedBoot = !sharedProtectedContentIsReadable()", in: source), 1,
            "Only loadDiagnosticsAndEventLogStores may set/clear the locked-boot store flag, from the canary."
        )
        XCTAssertEqual(
            sourceOccurrenceCount(of: "guard sharedProtectedContentIsReadableForObservabilityWriters() else", in: source), 2,
            "Both static ledger writers (recordIncident + sweepIncidentLedger) must canary-gate."
        )
        // The instance canary must delegate to the static twin so the probes can't diverge.
        XCTAssertTrue(source.contains("Self.sharedProtectedContentIsReadableForObservabilityWriters()"),
                      "The instance canary must single-source through the static twin.")
    }

    func testStopCleanupSuiteWritesAreCanaryGated() throws {
        let source = try readSource(.packetTunnelProvider)
        let endBlock = try sourceBlock(
            in: source,
            startingAt: "private func endProtectionVPNSession(reason: String)",
            endingBefore: "private var protectionPauseDefaults"
        )
        // A pre-unlock stop/cleanup must not write the locked suite either — same cfprefsd
        // re-materialization hazard as the boot-time begin (Codex P2 round 2 on #377).
        let pendingDropIdx = try XCTUnwrap(
            endBlock.range(of: "setPendingFreshProtectionVPNSessionReason(nil)")?.lowerBound,
            "Ending the session must drop any boot-deferred begin — its lifecycle is over."
        )
        let guardIdx = try XCTUnwrap(
            endBlock.range(of: "guard sharedProtectedContentIsReadable() else")?.lowerBound,
            "The stop/cleanup suite clears must be canary-gated like the begin."
        )
        let clearIdx = try XCTUnwrap(endBlock.range(of: "protectionSessionStore.clearActiveSessionID()")?.lowerBound)
        XCTAssertLessThan(pendingDropIdx, guardIdx,
                          "The pending-begin drop must be unconditional — it applies whether or not the suite is readable.")
        XCTAssertLessThan(guardIdx, clearIdx, "The canary must precede the suite clears.")

        // A pre-unlock stop leaves diagnostics permanently unpersistable: the locked-boot
        // flag clears only via loadDiagnosticsAndEventLogStores, which a stopped lifecycle
        // never runs, and every refused flush re-arms its own retry — so the cleanup must
        // abandon that dead-end retry or the stopped process wakes every interval forever
        // (Codex P2 round 10).
        let cleanupBlock = try sourceBlock(
            in: source,
            startingAt: "private func cleanUpTunnelRuntimeAfterStop(reason: String",
            endingBefore: "private static func errorDebugDetails("
        )
        XCTAssertTrue(cleanupBlock.contains("if self.diagnosticsStoresReflectLockedBoot {"),
                      "The abandon must be scoped to locked-boot stores — a readable-boot stop persists normally.")
        XCTAssertTrue(cleanupBlock.contains("self.diagnosticsPersistence.abandonUnpersistedState()"),
                      "A stopped lifecycle must abandon the permanently-refused diagnostics retry.")
        XCTAssertTrue(cleanupBlock.contains("self.healthPersistence.abandonUnpersistedState()"),
                      "Health's retry converges at unlock but wakes the stopped process until then — abandon it with diagnostics.")
    }

    // MARK: - Locked-boot filtering evidence lands in Class-None health (QA gate "Path A")

    func testLockedBootServesAreBucketedIntoClassNoneHealthEvidence() throws {
        let source = try readSource(.packetTunnelProvider)
        let recordBlock = try sourceBlock(
            in: source,
            startingAt: "private func recordDiagnostic(",
            endingBefore: "private func markLocalProtectionUptimeStarted()"
        )
        // Membership is two-branch (Codex review, #381): a fresh canary probe observing
        // locked NOW admits exactly (the flag alone over-admits — it clears only at the
        // throttled readable reload, so it stays set for up to one refresh interval of
        // post-unlock traffic); everything else passes through the conservative
        // observed-locked boundary. Both run BEFORE the diagnostics-preferences gate:
        // this is observability evidence, not a user-facing count — a user who disabled
        // filtering counts must still leave the gate its locked-window record.
        let certainlyLockedIdx = try XCTUnwrap(
            recordBlock.range(of: "if self.diagnosticsStoresReflectLockedBoot, !self.sharedProtectedContentIsReadable() {")?.lowerBound,
            "The certainly-locked branch must re-probe the canary, never trust the throttled flag alone."
        )
        let lockedGuardIdx = try XCTUnwrap(
            recordBlock.range(of: "} else if self.health.lockedBootWindowCovers(decisionAt: decisionTime, lastObservedLockedAt: self.lastObservedLockedSharedContentAt) {")?.lowerBound,
            "The fallback must compare decision time against the observed-locked boundary."
        )
        XCTAssertLessThan(certainlyLockedIdx, lockedGuardIdx,
                          "The exact probe branch precedes the conservative boundary fallback.")
        let bucketIdx = try XCTUnwrap(
            recordBlock.range(of: "self.health.recordLockedBootServe(action: decision.action, reason: decision.reason)")?.lowerBound,
            "Locked-window serves must bucket into the health snapshot's lockedBoot* counters."
        )
        let preferencesGateIdx = try XCTUnwrap(
            recordBlock.range(of: "guard configuration.keepFilteringCounts || configuration.keepDomainDiagnostics else")?.lowerBound
        )
        XCTAssertLessThan(certainlyLockedIdx, bucketIdx,
                          "The certainly-locked branch must wrap the FIRST bucketing call (the fallback's own call is covered by the two-site count below).")
        XCTAssertLessThan(bucketIdx, preferencesGateIdx,
                          "Evidence must land before the diagnostics-preferences gate can return early.")
        // Exactly TWO bucketing call sites — the two membership branches of the ONE
        // recordDiagnostic funnel. A third caller would double-count serves.
        XCTAssertEqual(sourceOccurrenceCount(of: ".recordLockedBootServe(", in: source), 2,
                       "Only the recordDiagnostic funnel's two membership branches may bucket locked-boot serves.")
        // A straggler admitted by the boundary fallback lands at/after the unlock — the
        // window stamp's forced write may already be done, so it must force-persist its
        // own count, or a jetsam inside the 30 s debounce keeps the stamp but loses the
        // count (Codex review, #381).
        let stragglerForceIdx = try XCTUnwrap(
            recordBlock.range(of: "self.persistHealthIfNeeded(force: true)", range: lockedGuardIdx..<recordBlock.endIndex)?.lowerBound,
            "A fallback-admitted straggler must force-persist its own count."
        )
        XCTAssertLessThan(lockedGuardIdx, stragglerForceIdx,
                          "The straggler force lives inside the boundary-fallback branch.")
        XCTAssertLessThan(stragglerForceIdx, preferencesGateIdx,
                          "The straggler force still precedes the diagnostics-preferences gate.")
    }

    func testLockedBootWindowEndStampIsForcePersistedAtTheReadableReload() throws {
        let source = try readSource(.packetTunnelProvider)
        // The transition stamp lives at the deferred-begin FLUSH — the only mid-session
        // (dnsStateQueue-confined) readable reload. It must never return to the loader:
        // the loader's other caller (loadInitialSharedState / startTunnel) runs
        // off-queue, where a reused provider instance's stale flag would fire the stamp
        // against the queue-confined health persistence off-queue (INV-QUEUE-1), and
        // startTunnel's resetHealth clobbers it there regardless (Codex review, #381).
        let flushBlock = try sourceBlock(
            in: source,
            startingAt: "private func flushDeferredFreshProtectionVPNSessionIfNeeded(hasDecodableConfiguration: Bool)",
            endingBefore: "private func beginFreshProtectionVPNSession(reason: String)"
        )
        let gateIdx = try XCTUnwrap(
            flushBlock.range(of: "if diagnosticsStoresReflectLockedBoot {")?.lowerBound,
            "The transition is only observable behind the flush's locked-boot gate."
        )
        let reloadIdx = try XCTUnwrap(
            flushBlock.range(of: "loadDiagnosticsAndEventLogStores()")?.lowerBound
        )
        let transitionIdx = try XCTUnwrap(
            flushBlock.range(of: "if !diagnosticsStoresReflectLockedBoot {")?.lowerBound,
            "The stamp must fire only when the reload's fresh canary probe flipped the flag readable."
        )
        let stampIdx = try XCTUnwrap(
            flushBlock.range(of: "health.markLockedBootWindowEnded(at: lastObservedLockedSharedContentAt ?? Date())")?.lowerBound,
            "The transition must stamp the CONSERVATIVE boundary — the last observed-locked instant, never the reload's own wall clock, which would admit post-unlock decisions as boot evidence."
        )
        let persistIdx = try XCTUnwrap(
            flushBlock.range(of: "persistHealthIfNeeded(force: true)", range: transitionIdx..<flushBlock.endIndex)?.lowerBound,
            "The evidence must be force-persisted at the transition, not left to the debounce."
        )
        XCTAssertLessThan(gateIdx, reloadIdx, "The reload runs behind the locked-boot gate.")
        XCTAssertLessThan(reloadIdx, transitionIdx, "The transition check reads the flag AFTER the reload re-derives it.")
        XCTAssertLessThan(transitionIdx, stampIdx, "The stamp lives inside the transition branch.")
        XCTAssertLessThan(stampIdx, persistIdx, "Stamp before persist — the forced write must carry it.")
        // Exactly TWO stamp call sites, both dnsStateQueue-confined: this flush
        // transition, and the flush-tunnel-health handler's capture-race stamp (a
        // Feedback sample seconds after unlock can precede the flush's next tick —
        // Codex review, #381). Any additional site must share the queue confinement
        // story; the off-queue loader must never regain one.
        XCTAssertEqual(sourceOccurrenceCount(of: "health.markLockedBootWindowEnded(", in: source), 2,
                       "The window-end stamp fires only at the two audited on-queue sites (flush transition + health-flush handler).")
        // The loader still derives the flag from a fresh canary probe and records the
        // fresh locked observation — but stays stamp-free.
        let loadBlock = try sourceBlock(
            in: source,
            startingAt: "private func loadDiagnosticsAndEventLogStores() {",
            endingBefore: "private func drainAndPruneDNSEventLog("
        )
        XCTAssertTrue(loadBlock.contains("diagnosticsStoresReflectLockedBoot = !sharedProtectedContentIsReadable()"),
                      "The loader must derive the flag from a fresh canary probe.")
        XCTAssertFalse(loadBlock.contains("markLockedBootWindowEnded"),
                       "The loader must stay stamp-free — its startTunnel caller runs off dnsStateQueue.")
        // Exactly four locked-observation stamp sites feed the boundary: the begin's
        // re-defer (every pre-unlock flush tick, post-migration boots), the
        // still-unreadable config classification (pre-migration boots), the locked-boot
        // store load (boot), and the bucketing branch's own fresh probe (per
        // locked-window decision). A dropped site widens the ambiguous under-count gap;
        // a new one must share the flag's confinement story.
        XCTAssertEqual(sourceOccurrenceCount(of: "lastObservedLockedSharedContentAt = Date()", in: source), 4,
                       "The last-observed-locked boundary must be fed by exactly the four audited observation sites.")
        // The refresh's .unreadable observation is the one site a NEVER-locked session
        // can reach: post-migration the Class-None config classifies .unreadable on a
        // transient I/O error too, and an ungated stamp there would seed the covers
        // boundary and admit ordinary traffic as locked-boot evidence (Codex review,
        // #381). It must carry the same flag+fresh-probe gate as the bucketing branch.
        XCTAssertTrue(
            source.contains("""
            if diagnosticsStoresReflectLockedBoot, !sharedProtectedContentIsReadable() {
                lastObservedLockedSharedContentAt = Date()
            }
"""),
            "The .unreadable-config observation must be gated on the locked-boot flag AND a fresh canary probe — a transient I/O blip on a never-locked session must not seed the covers boundary."
        )
    }

    func testHealthFlushMessageStampsAnUnstampedEndedLockedWindow() throws {
        let source = try readSource(.packetTunnelProvider)
        // A Feedback capture seconds after first unlock can precede the deferred-begin
        // flush's next tick: without this handler-side stamp, the sampled payload would
        // carry populated lockedBoot* counters with a "none" window-end — a completed
        // locked window indistinguishable from a still-locked or dead session (Codex
        // review, #381). The handler probes the canary itself and stamps only the
        // window end — never the flag or the store reload, which stay the flush's
        // duties (the flush's later stamp is idempotent).
        let handlerBlock = try sourceBlock(
            in: source,
            startingAt: "case LavaSecAppGroup.flushTunnelHealthMessage:",
            endingBefore: "default:"
        )
        XCTAssertTrue(handlerBlock.contains("dnsStateQueue.async"),
                      "The handler must stay dnsStateQueue-confined — the stamp mutates queue-confined health state.")
        let probeIdx = try XCTUnwrap(
            handlerBlock.range(of: "if self.diagnosticsStoresReflectLockedBoot, self.sharedProtectedContentIsReadable() {")?.lowerBound,
            "The handler must stamp only when a fresh canary probe observes the locked boot's content now readable."
        )
        let stampIdx = try XCTUnwrap(
            handlerBlock.range(of: "self.health.markLockedBootWindowEnded(at: self.lastObservedLockedSharedContentAt ?? Date())")?.lowerBound,
            "The handler's stamp must use the same conservative observed-locked boundary as the flush transition."
        )
        let persistIdx = try XCTUnwrap(
            handlerBlock.range(of: "self.persistHealthIfNeeded(force: true)")?.lowerBound
        )
        XCTAssertLessThan(probeIdx, stampIdx, "The stamp lives inside the probe branch.")
        XCTAssertLessThan(stampIdx, persistIdx,
                          "The stamp must precede the handler's forced persist so the sampled payload carries it.")
        XCTAssertFalse(handlerBlock.contains("diagnosticsStoresReflectLockedBoot ="),
                       "The handler must never clear the flag — the flush's gated store reload depends on it.")
        XCTAssertFalse(handlerBlock.contains("loadDiagnosticsAndEventLogStores()"),
                       "The store reload stays the flush's duty — the handler only stamps.")
    }
}
