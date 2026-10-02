import XCTest

@testable import LavaSecCore

/// Slice 3: the app's DNS-health surfaces show the CHAINED counters while chained instead of the
/// stale physical ones. The counter values and Codable back-compat are executable-tested in
/// `TunnelHealthSnapshotTests`; what only a pin can see is the cross-process wiring — the provider
/// feeding the driver's counters into the SHIPPING snapshot (not merely the QA-only debug log),
/// and the Settings surface branching on the runtime-latch flag.
final class ChainedTelemetrySurfaceSourceTests: XCTestCase {
    /// The mirror runs in PRODUCTION, not behind `#if DEBUG || LAVA_QA_TOOLS`.
    ///
    /// `emitChainedSessionLivenessIfChained()` writes the same counters to a QA-only debug log; if
    /// the snapshot mirror were re-gated the same way, the chained rows would be permanently zero
    /// in a shipped build — the whole point of Slice 3. So the call must sit AFTER the `#endif`
    /// that closes the QA block, with no `#if` reopening a gate before it.
    func testTheProviderMirrorsChainedCountersOutsideTheQAGate() throws {
        let provider = try readPacketTunnelProviderSource()
        // Anchor on the mirror's OWN production comment (unique in the file) and walk BACK to the
        // last `#endif` before it — the QA liveness block's close. This is robust to production
        // calls added between that #endif and the mirror (e.g. the self-heal resume, PR #575) while
        // still proving no `#if` reopens a gate between the QA block and the mirror.
        let mirrorComment = try XCTUnwrap(
            provider.range(of: "// PRODUCTION, not QA-gated"),
            "the production mirror comment is missing")
        let qaEndif = try XCTUnwrap(
            provider.range(
                of: "#endif", options: .backwards,
                range: provider.startIndex..<mirrorComment.lowerBound),
            "the QA liveness block should still close its own gate before the production mirror")
        let between = String(provider[qaEndif.upperBound..<mirrorComment.lowerBound])
        XCTAssertFalse(
            between.contains("#if"),
            "no #if may reopen a gate between the QA block's #endif and the production mirror — "
                + "the mirror has to ship to Release")
        XCTAssertNotNil(
            provider.range(
                of: "mirrorChainedHealthCountersIfChanged()",
                range: mirrorComment.upperBound..<provider.endIndex),
            "the production mirror must be called on the focus tick, after its comment")
    }

    /// The mirror copies the driver's counters and, decisively, sets `isChainedUpstreamActive`
    /// from the LIVE latch (`currentTunnelDataPathMode`), never the configured preference — the
    /// surfaces must branch on the path actually in use, not on intent.
    func testTheMirrorReadsTheRuntimeLatchAndCopiesTheDriverCounters() throws {
        let provider = try readPacketTunnelProviderSource()
        let body = try sourceBlock(
            in: provider,
            startingAt: "func mirrorChainedHealthCountersIfChanged() {",
            endingBefore: "private func resolveBootstrapAddressesThroughTunnel(")
        XCTAssertTrue(
            body.contains(
                "tunnelLifecycleIsActive && currentTunnelDataPathMode().isChainedUpstream"),
            "the active flag tracks the runtime latch AND lifecycle-active, so a flush racing a "
                + "stop cannot re-set it (the latch stays chained through teardown)")
        XCTAssertTrue(body.contains("health.isChainedUpstreamActive = chained"))
        XCTAssertTrue(body.contains("chainedRuntime?.driver.snapshotCounters()"))
        XCTAssertTrue(
            body.contains("applyChainedDriverCounters(counters)"),
            "the mirror copies the counters through the shared helper")

        // The shared copy maps each field and — decisively — sources "link outages" from the
        // path-offline count, NOT the driver's total outageCount (which the driver documents as
        // INCLUDING DNS outages), so link liveness is not conflated with a quiet resolver.
        let apply = try sourceBlock(
            in: provider,
            startingAt: "func applyChainedDriverCounters(_ counters: ChainedDriverCounters) {",
            endingBefore: "func mirrorChainedHealthCountersIfChanged(")
        XCTAssertTrue(
            apply.contains(
                "health.chainedTunnelDNSAnsweredCount = counters.tunnelDNSAnsweredObservationCount"),
            "the answered counter must come from the driver, not be left at its physical default")
        XCTAssertTrue(
            apply.contains("health.chainedLinkOutageCount = counters.offlinePathCount"),
            "link outages come from offlinePathCount, not the DNS-inclusive outageCount")
        XCTAssertFalse(
            apply.contains("counters.outageCount"),
            "outageCount includes DNS outages — do not use it for link liveness")
        // Persist ONLY on change — the mirror rides the 60 s focus tick, and re-persisting the
        // health file every tick for a quiet chained session is needless I/O the tick's own
        // footprint budget cannot afford (ios-internal#526). A regression dropping this guard
        // would reintroduce that churn silently (Slice 3 review).
        XCTAssertTrue(
            body.contains("if before != chainedMirrorFingerprint() {"),
            "the mirror must persist only when a counter changed, not on every tick")

        // The fingerprint replaced a five-element tuple when the per-destination reachability pair
        // landed (`INV-CHAIN-6`): the standard library only synthesises `==` for tuples up to six
        // elements, so the tuple could not have grown. Every field `applyChainedDriverCounters`
        // writes must appear in it — one left out is a change that never persists, which fails
        // silently rather than loudly, so the two lists are compared here.
        let fingerprint = try sourceBlock(
            in: provider,
            startingAt: "private func chainedMirrorFingerprint() -> [Int] {",
            endingBefore: "func currentChainedHandshakeState()")
        for field in [
            "chainedTunnelDNSAnsweredCount", "chainedTunnelDNSUnansweredCount",
            "chainedTunnelDNSOutageCount", "chainedLinkOutageCount",
            "chainedUnansweredDestinationCount", "chainedLongestUnansweredDestinationSeconds",
        ] {
            XCTAssertTrue(
                apply.contains("health.\(field) ="),
                "\(field) is in the change fingerprint but the mirror never writes it")
            XCTAssertTrue(
                fingerprint.contains("health.\(field)"),
                "\(field) is mirrored but missing from the change fingerprint, so a session where "
                    + "only it moved would never persist")
        }
        XCTAssertTrue(
            fingerprint.contains("health.isChainedUpstreamActive ? 1 : 0"),
            "the active flag is written by the mirror and must be in the fingerprint too")
    }

    /// The mirror must not wait for the first 60 s focus tick (which fires no leading edge), or
    /// the surface shows the DNS-only branch over a LIVE chained session for that whole window;
    /// a manual refresh must re-mirror so it can be forced; and a stop must clear the flag or the
    /// disconnected screen asserts "Chained (VPN)". All three were CONFIRMED review findings.
    func testTheMirrorRunsAtStartAndRefreshAndIsClearedOnStop() throws {
        let provider = try readPacketTunnelProviderSource()

        // Start: kicked right after the chained runtime is built, before the path monitor.
        let build = try XCTUnwrap(
            provider.range(
                of: "buildChainedRuntimeIfLatched(lifecycleGeneration: lifecycleGeneration)\n"))
        let startMonitor = try XCTUnwrap(
            provider.range(
                of: "startPathMonitor(lifecycleGeneration: lifecycleGeneration)",
                range: build.upperBound..<provider.endIndex))
        XCTAssertTrue(
            String(provider[build.upperBound..<startMonitor.lowerBound])
                .contains("mirrorChainedHealthCountersIfChanged()"),
            "the mirror must run at start, not only on the 60 s tick")

        // Refresh: the health-flush message handler re-mirrors before persisting.
        let flush = try sourceBlock(
            in: provider,
            startingAt: "case LavaSecAppGroup.flushTunnelHealthMessage:",
            endingBefore: "completion.complete(Data(\"ok\".utf8))")
        XCTAssertTrue(
            flush.contains("self.mirrorChainedHealthCountersIfChanged()"),
            "a manual health flush must re-mirror so Refresh reflects live chained health")

        // Stop: sample the FINAL counters (a short session may have stopped before any tick), THEN
        // clear the flag, THEN clear the data-path window + drop its baseline (Slice C inserted that
        // between the flag-clear and persist), before the final forced persist.
        let stopHead = try XCTUnwrap(
            provider.range(of:
                "self.applyChainedDriverCounters(counters)\n"
                + "            }\n"
                + "            self.health.isChainedUpstreamActive = false\n"),
            "stop must sample the final counters then clear the chained flag")
        let afterFlag = provider[stopHead.upperBound...]
        let clearWindow = try XCTUnwrap(
            afterFlag.range(of: "self.lastChainedDataPathStatsSample = nil"),
            "stop must drop the data-path baseline after clearing the flag")
        XCTAssertTrue(
            afterFlag[clearWindow.upperBound...].contains("self.persistHealthIfNeeded(force: true)"),
            "stop must persist after clearing the flag and the data-path window")
    }

    /// The Nerd Stats "Tunnel Health" section swaps the physical DNS rows for the chained rows
    /// when `isChainedUpstreamActive` — otherwise it would show the stale physical counters (all
    /// zero) over a working chained session.
    func testNerdStatsBranchesOnTheChainedFlag() throws {
        let view = try readSource(.legalVersionSettingsView)
        XCTAssertTrue(
            view.contains("if h.isChainedUpstreamActive {"),
            "the tunnel-health rows must branch on the chained runtime flag")
        XCTAssertTrue(view.contains("\"Chained DNS answered\""))
        XCTAssertTrue(view.contains("h.chainedTunnelDNSUnansweredCount"))
    }

    /// Slice C: the data-path byte window is sampled on the FOCUS TICK — not in the shared mirror
    /// that also runs at start/flush/stop — because a ~60 s delta is only meaningful at that fixed
    /// cadence. It reads the engine's statistics via the driver (engine-queue-confined) and never
    /// reports a negative (session-reset) delta.
    func testTheDataPathWindowIsSampledOnTheFocusTickAfterTheMirror() throws {
        let provider = try readPacketTunnelProviderSource()
        let tick = try sourceBlock(
            in: provider,
            startingAt: "private func reloadSnapshotIfConfigurationGenerationAdvanced() {",
            endingBefore: "ios-internal#526 attribution brackets")
        let mirror = try XCTUnwrap(
            tick.range(of: "mirrorChainedHealthCountersIfChanged()"),
            "the counter mirror still runs on the tick")
        XCTAssertTrue(
            tick[mirror.upperBound...].contains("sampleChainedDataPathWindowOnTick()"),
            "the data-path window sampler runs on the focus tick, after the mirror")

        let sampler = try sourceBlock(
            in: provider,
            startingAt: "func sampleChainedDataPathWindowOnTick() {",
            endingBefore: "/// A + AAAA for `hostname`")
        XCTAssertTrue(
            sampler.contains("chainedRuntime?.driver.snapshotStatistics()"),
            "the window is read from the engine via the driver, not recomputed off the packet path")
        XCTAssertTrue(
            sampler.contains("lastChainedDataPathStatsSample = nil"),
            "DNS-only / no session drops the baseline so a stale window cannot linger")
        XCTAssertTrue(
            sampler.contains("prior.sessionGeneration == current.sessionGeneration"),
            "the delta is gated on the driver's session identity, not just byte monotonicity (Codex #554)")
        XCTAssertTrue(
            sampler.contains("current.transmittedByteCount >= prior.transmittedByteCount"),
            "byte monotonicity stays as defense in depth alongside the generation gate")
    }

    func testTheDataPathWindowIsClearedOnStop() throws {
        XCTAssertTrue(try Self.stopClearsDataPathWindow(readPacketTunnelProviderSource()))
    }

    func testStopWindowPinRejectsEachMissingOrCommentedReset() throws {
        let source = try readPacketTunnelProviderSource()
        for statement in Self.dataPathResetStatements {
            for replacement in ["", "// " + statement] {
                let mutated = source.replacingOccurrences(of: statement, with: replacement)
                XCTAssertFalse(try Self.stopClearsDataPathWindow(mutated), statement)
            }
        }
    }

    private static let dataPathResetStatements = [
        "self.health.chainedDataPathTransmitWindowBytes = 0",
        "self.health.chainedDataPathReceiveWindowBytes = 0",
        "self.health.chainedDataPathHasHandshake = false",
        "self.lastChainedDataPathStatsSample = nil",
    ]

    private static func stopClearsDataPathWindow(_ source: String) throws -> Bool {
        let cleanup = try sourceBlock(in: source,
            startingAt: "private func cleanUpTunnelRuntimeAfterStop(",
            endingBefore: "private func finalizeChainedTerminationEvidence(")
        let statements = Set(sourceCodeOnly(cleanup).split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) })
        return dataPathResetStatements.allSatisfy { statements.contains($0) }
    }

    /// Slice C: Nerd Stats surfaces the data-path window while chained.
    func testNerdStatsShowsTheDataPathWindow() throws {
        let view = try readSource(.legalVersionSettingsView)
        XCTAssertTrue(view.contains("\"Data-path sent (last min)\""))
        XCTAssertTrue(view.contains("h.chainedDataPathReceiveWindowBytes"))
    }

    /// Pure interpretation is executable-tested in ChainedConnectivityPresentationTests.
    /// This pin covers only app wiring: live connection and prompt reply enter the shared presenter.
    func testNerdStatsUsesSharedPresentationWithLiveLifecycleEvidence() throws {
        let view = try readSource(.legalVersionSettingsView)
        XCTAssertTrue(view.contains("\"Connectivity health\""))
        XCTAssertTrue(view.contains("handshake: handshake,"))
        XCTAssertTrue(view.contains("isConnected: m.vpnStatus == .connected"))
        XCTAssertTrue(view.contains("ChainedConnectivityPresentation.summary(health, handshake: handshake, isConnected: isConnected)"))
        XCTAssertTrue((try readSource(.reactNativeAppQueries)).contains("model.sampleTunnelStats()"))
        XCTAssertFalse(view.contains("?? health.chainedDataPathHasHandshake"))
    }

    /// Slice 1: the app CLEARS the cached handshake on a nil reply, so a lost round-trip can't retain a
    /// prior session's "connected" and re-surface a false "Healthy" (Codex #556).
    func testNerdStatsClearsCachedHandshakeOnUnknownReply() throws {
        let source = try readSource(.reactNativeAppQueries)
        XCTAssertTrue(source.contains("let sample = await model.sampleTunnelStats()"))
        XCTAssertTrue(source.contains("handshake: sample.handshake"))
    }

    /// The tunnel answers the prompt message via the per-generation latch helper and keeps it
    /// lightweight for immediate establishment sampling plus lower-cadence lifecycle monitoring.
    func testProviderAnswersChainedHandshakeStatusLightweight() throws {
        let provider = try readPacketTunnelProviderSource()
        let block = try sourceBlock(
            in: provider,
            startingAt: "case LavaSecAppGroup.chainedHandshakeStatusMessage:",
            endingBefore: "default:")
        XCTAssertTrue(
            block.contains("currentChainedHandshakeState()"),
            "the reply reads the live handshake + everHandshaked latch via the shared helper")
        XCTAssertTrue(block.contains("ChainedHandshakeStatus("))
        XCTAssertTrue(block.contains("transportGeneration: state.transportGeneration"),
            "the prompt wire reply must carry the forwarding tally's channel identity")
        XCTAssertTrue(
            block.contains("lifecycleIsActive: self.tunnelLifecycleIsActive"),
            "the reply carries the authoritative lifecycle bit read on dnsStateQueue")
        XCTAssertFalse(
            block.contains("persistHealthIfNeeded"),
            "the prompt read must not persist the health file — it is polled, unlike the flush")
        XCTAssertFalse(
            block.contains("mirrorChainedHealthCountersIfChanged"),
            "no mirror either — this is a prompt handshake read, not the health flush")
    }

    /// Slice 1: the everHandshaked latch reads the engine handshake and RESETS on a session-generation
    /// change, so a prior session's success can't mask a fresh establishing one as connected (Kilo #556).
    func testProviderLatchesEverHandshakedPerGeneration() throws {
        let provider = try readPacketTunnelProviderSource()
        let block = try sourceBlock(
            in: provider,
            startingAt: "func currentChainedHandshakeState()",
            endingBefore: "func sampleChainedDataPathWindowOnTick(")
        XCTAssertTrue(block.contains("snapshotStatusEvidence()"))
        XCTAssertTrue(
            block.contains("stats.sessionGeneration != chainedHandshakeLatchGeneration"),
            "the latch resets when the driver's session generation changes")
        XCTAssertTrue(block.contains("chainedSessionEverHandshaked = false"))
        XCTAssertTrue(block.contains("if stats.hasHandshake { chainedSessionEverHandshaked = true }"))
        // The connect gate's real "connected" signal: bytes the chain forwarded EXCLUDING its own DNS
        // replies (`forwardedNonDNSByteCount`), with the session generation for the baseline reset —
        // NOT a DNS answer and NOT the raw liveness/received count. Gating on DNS (resolution OR raw
        // received bytes, which include DNS replies) showed "Protected" over a chain whose exit was
        // still the ISP / that only relayed DNS (founder dogfood + Codex; PR #558).
        XCTAssertTrue(
            block.contains("stats.forwardedNonDNSByteCount"),
            "the gate reads NON-DNS bytes actually forwarded back by the peer, not DNS-inclusive rx")
        XCTAssertTrue(
            block.contains("stats.sessionGeneration"),
            "the generation travels with the byte count so the gate can reset its baseline on reconnect")
        XCTAssertTrue(block.contains("stats.transportGeneration"),
            "a rebind resets the tally without replacing the WG session")
        XCTAssertFalse(
            block.contains("tunnelDNSResolvedAcceptedObservationCount")
                || block.contains("tunnelDNSAnsweredObservationCount"),
            "the gate must NOT read any DNS signal — DNS working does not prove forwarding")
    }

    /// A chained lifecycle keeps its identity while the outage driver is between runners. Folding
    /// the optional statistics read into the mode guard reports `isChained == false` in that gap,
    /// which the connect policy reserves for genuine DNS-only mode and therefore confirms without
    /// any forwarding evidence. The nil-statistics reply must instead stay chained and carry only
    /// conservative false/zero evidence and generation 0 as the explicit no-current-session marker,
    /// without erasing the internal latch before a replacement generation can reset it.
    func testProviderKeepsChainedIdentityWhileRunnerStatisticsAreUnavailable() throws {
        let provider = try readPacketTunnelProviderSource()
        let block = try sourceBlock(
            in: provider,
            startingAt: "func currentChainedHandshakeState()",
            endingBefore: "func sampleChainedDataPathWindowOnTick(")

        let modeGuard = try XCTUnwrap(
            block.range(of: "guard isChained else {"),
            "runtime mode must be decided independently from optional runner statistics")
        let statisticsGuard = try XCTUnwrap(
            block.range(
                of: "guard let stats = evidence?.statistics else {",
                range: modeGuard.upperBound..<block.endIndex),
            "a latched chained lifecycle needs its own conservative no-statistics branch")
        XCTAssertLessThan(
            modeGuard.lowerBound, statisticsGuard.lowerBound,
            "only genuine non-chained mode may take the `isChained == false` exit")

        let nonChained = String(block[modeGuard.lowerBound..<statisticsGuard.lowerBound])
        XCTAssertTrue(nonChained.contains("chainedSessionEverHandshaked = false"))
        XCTAssertTrue(nonChained.contains("chainedHandshakeLatchGeneration = 0"))
        XCTAssertTrue(nonChained.contains("return (false, false, false, 0, 0, 0, false, nil, nil, 0,"))

        let noStatistics = String(block[statisticsGuard.lowerBound...])
        XCTAssertTrue(
            noStatistics.contains("return (true, false, false, 0, 0, 0, false,"),
            "runner absence must remain chained, identify no current session, and claim no evidence")
        let noStatisticsExit = noStatistics.components(
            separatedBy: "// A new session (generation bump)")[0]
        XCTAssertFalse(
            noStatisticsExit.contains("chainedSessionEverHandshaked = false")
                || noStatisticsExit.contains("chainedHandshakeLatchGeneration = 0"),
            "a temporary runner gap must not erase the internal per-session latch")
    }

    /// Slice 1: the app's query sends the lightweight message, decodes the reply, and is bounded by a
    /// timeout with single-resume so a jetsammed NE cannot freeze the poll loop (Kilo #556).
    func testAppSendsTheChainedHandshakeStatusMessageWithTimeout() throws {
        let viewModel = try readAppViewModelSource()
        XCTAssertTrue(viewModel.contains("func queryChainedHandshakeStatus() async"))
        XCTAssertTrue(viewModel.contains("LavaSecAppGroup.chainedHandshakeStatusMessage"))
        XCTAssertTrue(viewModel.contains("LavaSecAppGroup.ChainedHandshakeStatus.decode("))
        XCTAssertTrue(
            viewModel.contains("chainedHandshakeQueryTimeout"),
            "the query is bounded by a timeout so a lost reply cannot freeze the poll loop")
        XCTAssertTrue(
            viewModel.contains("HandshakeReplyBox"),
            "a single-resume guard prevents the timeout + reply from double-resuming the continuation")
    }

    /// The behavioral codec tests exercise both compatibility defaults. This pin keeps their real
    /// implementation in the package-owned wire model and ensures the three original fields remain
    /// required, rather than silently accepting a genuinely malformed provider reply.
    func testChainedHandshakeStatusOwnsItsBackwardCompatibleDecode() throws {
        let payload = try readSource(.chainedHandshakeStatus)
        let decoder = try sourceBlock(
            in: payload,
            startingAt: "init(from decoder: any Decoder) throws {",
            endingBefore: "func encoded() -> Data")
        for tolerant in [
            "decodeIfPresent(UInt64.self, forKey: .receivedByteCount) ?? 0",
            "decodeIfPresent(UInt64.self, forKey: .sessionGeneration) ?? 0",
            "decodeIfPresent(UInt64.self, forKey: .transportGeneration) ?? 0",
        ] {
            XCTAssertTrue(
                decoder.contains(tolerant),
                "new wire fields must tolerate an older reply, not throw and drop the whole status")
        }
        XCTAssertTrue(
            decoder.contains("decodeIfPresent(Bool.self, forKey: .lifecycleIsActive)"))
        XCTAssertTrue(decoder.contains("lifecycleIsActiveWasExplicit = true"))
        XCTAssertTrue(decoder.contains("lifecycleIsActiveWasExplicit = false"))
        for required in [".isChained", ".hasHandshake", ".everHandshaked"] {
            XCTAssertTrue(
                decoder.contains("decode(Bool.self, forKey: \(required))"),
                "\(required) stays a required decode — a reply missing it is genuinely malformed")
        }
    }
}
