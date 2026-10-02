import XCTest

/// S8.8b provider wiring pins: WHERE the chained runtime is built, WHO decides the branch,
/// and the queue/ordering obligations the compiler cannot see. The behaviour itself is
/// executable-tested in the package — the driver, factory, credential-reader and stash
/// suites — so these pin the provider's thin orchestration to those tested seams, per the
/// repo's pins-are-for-wiring rule.
final class ChainedProviderConstructionSourceTests: XCTestCase {
    /// A profile update can race an on-demand start. Transport selection must use the
    /// same runtime that owns reply demultiplexing, even when includeAllNetworks changes.
    func testFullTunnelDirectDNSDoesNotDependOnMutableProfileFlags() throws {
        let provider = try readPacketTunnelProviderSource()
        let construction = try sourceBlock(in: provider,
            startingAt: "let directDNS =", endingBefore: "let baseWriter =")
        XCTAssertTrue(construction.contains("upstream.effectiveRoutingPolicy == .fullTunnel"))
        XCTAssertFalse(construction.contains("protocolConfiguration"))
        let selection = try sourceBlock(in: provider,
            startingAt: "private func resolverSocketBinding(",
            endingBefore: "func resolveTunnelledPlainDNS(")
        XCTAssertTrue(sourceContainsInOrder([
            "if let runtime = self.chainedRuntime, let resolver = runtime.directDNS",
            "return .direct(resolver, runtime.driver)",
            "guard !self.protocolConfiguration.includeAllNetworks else { return .latchReplaced }",
            "return .permitted(self.currentResolverSocketBinding())"
        ], in: selection))
    }

    /// C2 at the construction gate: the runtime exists exactly when the LATCHED mode is
    /// chained, decided through the dual-entry accessor — never the build flag, whose
    /// flip must not be what turns the data path on for a session that latched DNS-only.
    func testTheConstructionGateIsTheLatchedModeNeverTheBuildFlag() throws {
        let provider = try readPacketTunnelProviderSource()
        let block = try sourceBlock(
            in: provider,
            startingAt: "func buildChainedRuntimeIfLatched(lifecycleGeneration:",
            endingBefore: "static func eligibleChainedInterface(")
        XCTAssertTrue(
            block.contains(
                "guard case .chainedUpstream(let upstream) = currentTunnelDataPathMode()"),
            "the construction gate must destructure the LATCHED mode")
        XCTAssertFalse(
            block.contains("buildSupportsChainedDataPath"),
            "the construction gate must never consult the build flag (C2)")
    }

    /// The claim-lapse seam: the factory receives the provider's PROCESS-LIFETIME port
    /// registry, never a fresh one — the driver rebuilds runners per attempt, and a
    /// registry that died with a runner would forget an in-flight retry's port at exactly
    /// the reconnect that parks it, after which the resumed query re-classifies as
    /// unfilterable DNS (the lapse-while-parked walk `ChainedSessionRunnerTests` proves).
    func testTheFactoryReceivesTheProcessLifetimePortRegistry() throws {
        let provider = try readPacketTunnelProviderSource()
        let block = try sourceBlock(
            in: provider,
            startingAt: "func buildChainedRuntimeIfLatched(lifecycleGeneration:",
            endingBefore: "static func eligibleChainedInterface(")
        XCTAssertTrue(
            block.contains("ownResolverPorts: ownResolverPorts"),
            "the factory must receive the provider's own registry")
        XCTAssertFalse(
            block.contains("ChainedResolverPortRegistry("),
            "construction must never build a second registry")
    }

    /// The gate excludes DNS (resolver-sourced) bytes from its forwarding evidence ONLY in full tunnel.
    /// In split tunnel, general traffic bypasses the NE, so DNS is often the only captured traffic —
    /// excluding it would starve the gate and false-close a healthy split tunnel (Codex, PR #558). So
    /// the resolver-source set is populated for `.fullTunnel` and EMPTY otherwise. The runner's
    /// exclusion behaviour is executable-tested in `ChainedSessionRunnerTests`; this pins the provider
    /// only builds the exclusion set for full tunnel.
    func testTheResolverExclusionSetIsPopulatedOnlyForFullTunnel() throws {
        let provider = try readPacketTunnelProviderSource()
        let block = try sourceBlock(
            in: provider,
            startingAt: "func buildChainedRuntimeIfLatched(lifecycleGeneration:",
            endingBefore: "static func eligibleChainedInterface(")
        XCTAssertTrue(
            block.contains("upstream.effectiveRoutingPolicy == .fullTunnel"),
            "the resolver-exclusion set must be gated on full tunnel")
        // The selection is now read ONCE and hoisted above both derived sets (the exclusion set
        // and the carried-fallback set), so the ordering asserted here is selection-then-gate
        // rather than gate-then-selection. What the pin protects is unchanged: the populated
        // branch comes from the selection, and the split-tunnel branch is the empty set.
        let selected = try XCTUnwrap(block.range(of: "ChainedTunnelResolverSelection.selection("))
        let build = try XCTUnwrap(block.range(of: "let resolverSourceAddresses = upstream.effectiveRoutingPolicy == .fullTunnel"))
        let populated = try XCTUnwrap(block.range(of: "latchedSelection.resolvers"))
        let empty = try XCTUnwrap(block.range(of: ": ChainedAllowedIPs([])"))
        XCTAssertLessThan(selected.lowerBound, build.lowerBound, "the selection is read before the gate")
        XCTAssertLessThan(build.lowerBound, populated.lowerBound, "full tunnel populates the set")
        XCTAssertLessThan(populated.lowerBound, empty.lowerBound, "split tunnel excludes nothing (empty set)")
        // T0 ONLY, in both this set and the per-query route. It used to append the latched
        // T1 addresses; nothing carries T1 through the tunnel any more, so appending it
        // here excluded addresses that produce no replies (the plan's S3).
        XCTAssertFalse(
            block.contains("appending:"),
            "the exclusion set is the conf's own resolvers — there is no tunnelled T1 to append")
    }

    /// Codex PR #575 P1, in its surviving form: NOTHING in the resolver-route derivation or the
    /// connect gate's exclusion set may read the LIVE app config.
    ///
    /// The P1 was that the per-query route read the live configuration while the exclusion set was
    /// built once at session start, so changing Alternative DNS mid-session routed DNS to a
    /// resolver absent from the exclusion set, whose replies then counted as
    /// `forwardedNonDNSByteCount` — falsely confirming forwarding and suppressing the egress-dead
    /// surrender.
    ///
    /// The two sets can no longer disagree about T1 because NEITHER carries it: the rung
    /// egresses on the physical interface (PR #590) and both appends are deleted (the plan's S3).
    /// What is still worth pinning is the live-config half — a mid-session read is a
    /// session-consistency defect whatever it is read for — plus the ONE surviving latch, which
    /// must be written in the same critical section as the mode and the epoch bump.
    func testTheTierOneResolverIsLatchedAndNothingReadsTheLiveConfig() throws {
        let provider = try readPacketTunnelProviderSource()
        // The latch write is atomic with the mode + epoch bump.
        let install = try sourceBlock(
            in: provider,
            startingAt: "let install = {",
            endingBefore: "if DispatchQueue.getSpecific(key: dnsStateQueueSpecificKey) == true {")
        XCTAssertTrue(
            install.contains(
                "self.latchedChainedTierOneResolverConfiguration = chainedTierOneResolverConfiguration"),
            "the rung's resolver must be latched in the same critical section as the mode")
        let route = try sourceBlock(
            in: provider,
            startingAt: "func currentTunnelledPlainDNSRoute()",
            endingBefore: "func chainedTunnelledDNSSurvivesPhysicalPathChange()")
        XCTAssertFalse(
            route.contains("appending:"),
            "there is no tunnelled T1; appending it re-enters the peer's path")
        XCTAssertFalse(
            route.contains("currentAppConfiguration()"),
            "the route must NOT read the live app config (the P1)")
        let construction = try sourceBlock(
            in: provider,
            startingAt: "let latchedSelection = ChainedTunnelResolverSelection.selection(",
            endingBefore: "let resolverSourceAddresses")
        XCTAssertFalse(
            construction.contains("currentAppConfiguration()"),
            "the exclusion set must NOT read the live app config either (the P1)")
    }

    /// The egress-dead cause is confined to FULL tunnels, and the confinement is wired HERE: the
    /// driver is a pure health state machine that cannot see the route shape on its own, so the
    /// provider must hand it the latched `routingPolicy`. In split tunnel the runner still carries
    /// the configured `AllowedIPs` traffic, so a flat forwarding counter under demand is not proof
    /// of dead egress and an unconditional predicate would false-surrender a healthy split tunnel
    /// (Codex, PR #567). The gating BEHAVIOUR is executable-tested in `ChainedOutageDriverTests`
    /// (`testASplitTunnelNeverDeclaresAnEgressDeadOutage`); this pins that the provider passes the
    /// SAME policy the resolver-exclusion set reads, never a hardcoded `.fullTunnel`.
    func testTheDriverReceivesTheLatchedRoutingPolicy() throws {
        let provider = try readPacketTunnelProviderSource()
        let block = try sourceBlock(
            in: provider,
            startingAt: "func buildChainedRuntimeIfLatched(lifecycleGeneration:",
            endingBefore: "static func eligibleChainedInterface(")
        let driverInit = try XCTUnwrap(
            block.range(of: "let driver = ChainedOutageDriver("),
            "the driver construction must be in this block")
        let policyArg = try XCTUnwrap(
            block.range(of: "routingPolicy: upstream.effectiveRoutingPolicy"),
            "the driver must receive the latched routing policy, not a hardcoded value")
        XCTAssertLessThan(
            driverInit.lowerBound, policyArg.lowerBound,
            "the routingPolicy argument must belong to the driver construction")
    }

    /// The credential read is BOUNDED: it runs on the engine queue with the attempt
    /// watchdog — whose deadline is the outage deadline — queued behind it, so an
    /// unwrapped `SecItemCopyMatching` would let a wedged securityd hold the claimed
    /// default route blackholed past the budget (Codex, PR #508). The bound's behaviour
    /// is executable-tested in the package; this pins that the provider's closure
    /// actually goes through it.
    func testTheCredentialReadIsBoundedOnTheEngineQueue() throws {
        let provider = try readPacketTunnelProviderSource()
        let block = try sourceBlock(
            in: provider,
            startingAt: "func buildChainedRuntimeIfLatched(lifecycleGeneration:",
            endingBefore: "static func eligibleChainedInterface(")
        XCTAssertTrue(
            block.contains("try ChainedBoundedCredentialRead.perform {"),
            "the readCredentials closure must wrap its store read in the bound — the "
                + "watchdog defers by at most the timeout, never by securityd")
    }

    /// C4's fail-safe ordering: construction runs before the settings are built, and a
    /// construction failure re-latches DNS-only — so the tunnel can never claim the
    /// default route with no session to serve it.
    func testConstructionFailureDowngradesBeforeAnySettingsAreBuilt() throws {
        let provider = try readPacketTunnelProviderSource()
        let startBlock = try sourceBlock(
            in: provider,
            startingAt: "override func startTunnel",
            endingBefore: "override func stopTunnel")
        let build = try XCTUnwrap(
            startBlock.range(of: "let chainedDriver = buildChainedRuntimeIfLatched(lifecycleGeneration: lifecycleGeneration)"))
        let settings = try XCTUnwrap(
            startBlock.range(of: "let settingsBundle = self.makeTunnelNetworkSettingsForLatchedDataPath()"))
        XCTAssertTrue(
            build.lowerBound < settings.lowerBound,
            "the settings must be built AFTER construction can downgrade the latch")

        let downgrade = try sourceBlock(
            in: provider,
            startingAt: "private func downgradeChainedConstruction(reason: String)",
            endingBefore: "private func performChainedSurrenderRecovery(")
        // Through the one latch installer, which publishes both fields and bumps the
        // latch epoch — the epoch is what retires outstanding tunnelled routes on this
        // same-generation relatch (PR #518 round 3); the installer's own shape is
        // pinned by testTheLatchHasExactlyOneWriterAndItBumpsTheEpoch.
        XCTAssertTrue(
            downgrade.contains(
                "installLatchedDataPathMode(.dnsOnly, refusal: .upstreamUnavailable)"))
        XCTAssertTrue(
            downgrade.contains("sessionRanAndStoppedCleanly: false"),
            "a session that never ran settles its marker without a strike and without a "
                + "streak reset")
        XCTAssertTrue(
            sourceContainsInOrder(
                [
                    "let owningLifecycleID = currentChainedLifecycleEvidenceID()",
                    "installLatchedDataPathMode(.dnsOnly, refusal: .upstreamUnavailable)",
                    "owningLifecycleID: owningLifecycleID",
                ], in: downgrade),
            "the downgrade must capture its own marker before the DNS-only relatch clears the latch")
        // The RELATCH precedes the store, and the store work is BOUNDED. Both answer the
        // same hazard: this runs in startTunnel's prologue, so a wedged security daemon
        // reached through the settle would block startup before the relatch — never
        // installing the fail-safe settings, and defeating the bound on the credential
        // read that sent us here (Codex, PR #508).
        let relatch = try XCTUnwrap(
            downgrade.range(of: "installLatchedDataPathMode(.dnsOnly, refusal: .upstreamUnavailable)"))
        let storeTouch = try XCTUnwrap(downgrade.range(of: "chainedDeviceEligibilityStore()"))
        XCTAssertTrue(
            relatch.lowerBound < storeTouch.lowerBound,
            "the DNS-only relatch must land before any Keychain work, or a wedged store "
                + "stops startTunnel from installing fail-safe settings")
        XCTAssertTrue(
            downgrade.contains("try ChainedBoundedKeychainWork.perform {"),
            "the settle must be bounded — an unbounded sibling defeats the credential "
                + "read's own bound")
    }

    /// S8.8b task (d): the factory's MTU is the SAME value the settings carry, through
    /// the same seam — the route plan clamped by `engineSafeMTU` — so the engine's queue
    /// sizing and the utun's MTU cannot disagree.
    func testTheFactoryMTUIsTheSettingsMTU() throws {
        let provider = try readPacketTunnelProviderSource()
        let block = try sourceBlock(
            in: provider,
            startingAt: "func buildChainedRuntimeIfLatched(lifecycleGeneration:",
            endingBefore: "static func eligibleChainedInterface(")
        XCTAssertTrue(
            block.contains("let mtu = Self.engineSafeMTU(for: mode, planMTU: plan.mtu)"),
            "the factory MTU must come from the settings' own seam")
        XCTAssertTrue(block.contains("mtu: mtu"), "and must be what the factory receives")
    }

    /// C4's crash-window ordering at the provider: the surrender persists through
    /// `ChainedSurrenderRecovery` (persist FIRST, restart always — executable-tested in
    /// the package), the restart is the tunnel cancel, and the whole sink body never
    /// touches `dnsStateQueue` — the engine queue must never wait on the DNS confinement.
    func testTheSurrenderPersistsBeforeItRestartsAndNeverTouchesTheDNSQueue() throws {
        let provider = try readPacketTunnelProviderSource()
        let block = try sourceBlock(
            in: provider,
            startingAt: "private func performChainedSurrenderRecovery(",
            endingBefore: "// MARK: - Chained runtime types (S8.8b)")
        XCTAssertTrue(block.contains("ChainedSurrenderRecovery.perform("))
        let persist = try XCTUnwrap(block.range(of: "recordChainedSurrender("))
        let restart = try XCTUnwrap(block.range(of: "cancelTunnelWithError(nil)"))
        XCTAssertTrue(
            persist.lowerBound < restart.lowerBound,
            "the suppression must be durable before the restart begins")
        XCTAssertTrue(
            block.contains("owningLifecycleID: owningLifecycleID"),
            "the surrender must fence on the driver's captured lifecycle, not adopt a fresh store read")
        XCTAssertTrue(
            sourceContainsInOrder(
                [
                    "recordChainedSurrender(",
                    "suppressionPersisted = true",
                    "ChainedStartupFailureMarker.record(",
                    "surrender.markerReason(suppressionPersisted: suppressionPersisted)",
                    "connectivitySignalNotifier.postNotification(",
                    "cancelTunnelWithError(nil)",
                ], in: block),
            "the app-visible terminal marker and nudge must precede the provider cancellation")
        XCTAssertFalse(
            block.contains("dnsStateQueue"),
            "the surrender sink runs on the engine queue and must never wait on the DNS "
                + "confinement (INV-QUEUE-1)")
    }

    /// The DNS seam host delegates to the ONE DNS path the DNS-only loop uses — same
    /// family-agnostic parser, same handler, the family recovered from the packet itself
    /// since the classifier routes both IPv4 and IPv6 DNS here (F3c) — so the two paths
    /// cannot drift.
    func testTheDNSSeamHostDelegatesToTheOneDNSPath() throws {
        let provider = try readPacketTunnelProviderSource()
        let block = try sourceBlock(
            in: provider,
            startingAt: "func serveClientDNSQuery(_ packet: Data, lifecycleToken:",
            endingBefore: "// MARK: - Private DNS wire, socket & factory types")
        XCTAssertTrue(block.contains("guard let request = parseDNSDatagram(packet) else"))
        XCTAssertTrue(block.contains("handleDNSRequest("))
        XCTAssertTrue(block.contains("request is IPv6UDPDNSPacket ? Int(AF_INET6) : Int(AF_INET)"))
        XCTAssertTrue(
            block.contains("expectedLifecycleGeneration: lifecycleToken"),
            "the seam must FENCE the query on its runtime's token — the fence parameter "
                + "is non-optional (PR #524), so the compiler now forbids the nil that "
                + "would have let a retired runtime's query resolve against the next "
                + "lifecycle's configuration; this pin holds the seam to passing ITS "
                + "token rather than some other session's")
    }

    /// The read loop's C2 branch, and BOTH arms' retirement tokens: provider instances
    /// are reused across starts, and a stale loop competes with the live one for every
    /// batch it can reach. The chained arm's token is the driver's refusal (a retired
    /// driver answers false — no per-batch queue hop on the hot path); the DNS-only
    /// arm's token is the lifecycle generation, or a stale DNS-only loop surviving into
    /// a CHAINED lifecycle steals batches whose non-DNS packets `handle` discards
    /// (Codex, PR #508). The DNS-only FILTERING body stays token-for-token the
    /// pre-chained loop; the chained arm hands batches over WHOLE (classification is the
    /// runner's — pre-splitting is the self-resolution defect the seam doc names).
    func testTheReadLoopBranchesWholeBatchesAndKeepsDNSOnlyByteForByte() throws {
        let provider = try readPacketTunnelProviderSource()
        let block = try sourceBlock(
            in: provider,
            startingAt: "func readPackets(chainedDriver: ChainedOutageDriver?",
            endingBefore: "private func handle(packet: Data")
        XCTAssertTrue(
            block.contains(
                "guard chainedDriver.handleOutboundBatch(packets, protocols: protocols) else {"),
            "the chained arm must forward the arrays whole AND stop on a refused batch — "
                + "a stale loop from a previous lifecycle dies here or competes forever")
        XCTAssertTrue(
            block.contains("guard isCurrentTunnelLifecycle(lifecycleGeneration) else {"),
            "the DNS-only arm must carry its own retirement token — it has no driver to "
                + "refuse for it, and a stale DNS-only loop in a chained lifecycle "
                + "discards the data packets it steals")
        XCTAssertTrue(
            block.contains(
                "for (packet, protocolNumber) in zip(packets, protocols) {\n"
                    + "                    handle(\n"
                    + "                        packet: packet,\n"
                    + "                        protocolNumber: protocolNumber,\n"
                    + "                        lifecycleGeneration: lifecycleGeneration\n"
                    + "                    )\n"
                    + "                }"),
            "the DNS-only filtering body stays the pre-chained loop, now handing each "
                + "packet the batch's OWN generation — the acceptance boundary the "
                + "admission epoch originates from (PR #524)")
        XCTAssertTrue(
            block.contains(
                "readPackets(chainedDriver: chainedDriver, lifecycleGeneration: lifecycleGeneration)"),
            "the recursion must carry the captured driver and generation")
        XCTAssertFalse(
            block.contains("IPv4UDPDNSPacket"),
            "the read loop must never pre-split a chained batch")
    }

    /// The teardown funnel retires the runtime — the only place the driver↔runner cycle
    /// breaks — BEFORE the termination evidence settles, and nils the confined property
    /// on its owning queue.
    func testTheTeardownFunnelRetiresTheChainedRuntime() throws {
        let provider = try readPacketTunnelProviderSource()
        let block = try sourceBlock(
            in: provider,
            startingAt: "private func cleanUpTunnelRuntimeAfterStop(",
            endingBefore: "static func errorDebugDetails(")
        let retire = try XCTUnwrap(block.range(of: "runtime.driver.retire()"))
        let settle = try XCTUnwrap(block.range(of: "self.finalizeChainedTerminationEvidence("))
        XCTAssertTrue(
            retire.lowerBound < settle.lowerBound,
            "the evidence settle must describe a stop the data path has finished")
        XCTAssertTrue(block.contains("self.chainedRuntime = nil"))
    }

    /// Sleep and wake forward to the driver inside their `dnsStateQueue` blocks: sleep
    /// before the completion that lets iOS suspend, and wake at the block's HEAD — the
    /// brief-sleep preserve branch returns early, and the paired wake must run on every
    /// wake, micro-sleeps included.
    func testSleepAndWakeForwardToTheChainedDriverInsideTheirQueueBlocks() throws {
        let provider = try readPacketTunnelProviderSource()
        let sleepBlock = try sourceBlock(
            in: provider,
            startingAt: "override func sleep(completionHandler:",
            endingBefore: "override func wake()")
        XCTAssertTrue(sleepBlock.contains("self?.chainedRuntime?.driver.sleep()"))

        let wakeBlock = try sourceBlock(
            in: provider,
            startingAt: "override func wake()",
            endingBefore: "#if DEBUG || LAVA_QA_TOOLS")
        let driverWake = try XCTUnwrap(
            wakeBlock.range(of: "self.chainedRuntime?.driver.wake()"))
        let preserveRead = try XCTUnwrap(
            wakeBlock.range(of: "let sleepBeganAt = self.resolverSleepBeganAt"))
        XCTAssertTrue(
            driverWake.lowerBound < preserveRead.lowerBound,
            "the driver's wake must precede the brief-sleep preserve branch's early return")
    }

    /// The binding derives from the interface the path ROUTES OVER, never merely the
    /// first available: with Wi-Fi and cellular both up, `availableInterfaces.first` can
    /// be cellular while the system routes Wi-Fi (Codex, PR #508) — chained would start
    /// on metered egress and rebuild onto it after every path change.
    func testTheBindingDerivesFromTheRoutedInterface() throws {
        let provider = try readPacketTunnelProviderSource()
        let block = try sourceBlock(
            in: provider,
            startingAt: "static func eligibleChainedInterface(on path:",
            endingBefore: "private func downgradeChainedConstruction(")
        XCTAssertTrue(
            block.contains(
                "path.availableInterfaces.first { path.usesInterfaceType($0.type) }"),
            "the per-path selection must be the route-truth filter, not .first")
        XCTAssertTrue(
            provider.contains("let eligible = Self.eligibleChainedInterface(on: path)"),
            "the path handler must hand the helper the PATH, not a bare interface list")
        XCTAssertTrue(
            provider.contains("runtime.interfaceStash.update(eligible)"),
            "the stash must receive the SAME derivation the log line names — a second read "
                + "could disagree with what was logged")
    }

    /// The path handler — the one hook holding the full `NWPath` — feeds the chained
    /// runtime: the stash derives the identity-change signal, and the driver hop is
    /// `enqueue`, never a synchronous wait from `dnsStateQueue` onto the engine queue.
    func testThePathHandlerFeedsTheChainedRuntime() throws {
        let provider = try readPacketTunnelProviderSource()
        let monitorBlock = try sourceBlock(
            in: provider,
            startingAt: "func startPathMonitor(lifecycleGeneration:",
            endingBefore: "private func noteChainedPathObservation(")
        XCTAssertTrue(
            monitorBlock.contains(
                "self.noteChainedPathObservation(path, satisfied: update.isSatisfied)"))

        let feedBlock = try sourceBlock(
            in: provider,
            startingAt: "private func noteChainedPathObservation(",
            endingBefore: "func clearEncryptedFallbackLogThrottle")
        XCTAssertTrue(feedBlock.contains("runtime.interfaceStash.update("))
        XCTAssertTrue(feedBlock.contains("runtime.engineQueue.enqueue"))
        XCTAssertTrue(
            feedBlock.contains(
                "driver?.pathChanged(satisfied: satisfied, interfacesChanged: identityChanged)"))
        XCTAssertFalse(
            feedBlock.contains("engineQueue.run"),
            "the driver hop from dnsStateQueue must be asynchronous (INV-QUEUE-1)")
    }

    /// Brief-stall observability (2026-08-24): the construction hands the factory BOTH
    /// telemetry sinks, routed through the recorder that rate-bounds what reaches the log —
    /// wiring the compiler cannot see because the sinks are optional and nil-defaulted, so a
    /// dropped argument would compile clean and silently un-instrument the transport.
    func testTheTransportTelemetrySinksReachTheFactory() throws {
        let provider = try readPacketTunnelProviderSource()
        let construction = try sourceBlock(
            in: provider,
            startingAt: "func buildChainedRuntimeIfLatched(",
            endingBefore: "static func eligibleChainedInterface(on path:")
        XCTAssertTrue(
            construction.contains("transportTelemetry: { sequence, event in"),
            "the channel-state observer sink must be wired at construction")
        XCTAssertTrue(
            construction.contains("transportDiagnostics.recordTransport("),
            "channel events must go through the recorder's rate bound, not straight to the log")
        XCTAssertTrue(
            construction.contains("dataPathDiagnostics: { event in"),
            "the pressure-event sink must be wired at construction")
        XCTAssertTrue(
            construction.contains("transportDiagnostics.recordPressure(event)"),
            "pressure events must go through the recorder's rate bound, not straight to the log")
        // WITHOUT THE CLOSING PAREN, and that is the point of this edit rather than an accident.
        // Anchored on `transportDiagnostics)` this asserted that the recorder is the LAST argument
        // to `ChainedTunnelRuntime.init`, which is a fact about argument order, not about the
        // recorder reaching the runtime. Adding `rotationStash:` after it broke the pin while the
        // property it guards was untouched — the same brittle-anchor species that cost PR #610
        // seven pins (a pin must be specific about WHERE and permissive about WHAT).
        XCTAssertTrue(
            construction.contains("transportDiagnostics: transportDiagnostics"),
            "the recorder must be stored on the runtime or the liveness line cannot read its tallies")
    }

    /// The 60 s liveness line carries the pressure/transport tallies — the exact keys the
    /// brief-stall capture protocol differences. A key silently dropped here would return the
    /// field to the all-counters-flat blindness the incident showed.
    func testTheLivenessLineSurfacesTheDataPathPressureTallies() throws {
        let provider = try readPacketTunnelProviderSource()
        let liveness = try sourceBlock(
            in: provider,
            startingAt: "func emitChainedSessionLivenessIfChained()",
            endingBefore: "func resumeChainedTunnelIfSuspended()")
        XCTAssertTrue(liveness.contains("transportDiagnostics.snapshotTallies()"))
        for key in [
            "shedPackets", "refusedOutboundBacklog", "refusedInboundBacklog", "sendErrors",
            "saturatedTicks", "channelNotReady", "channelUnviable", "channelSendFailEdges",
            "channelReceiveLoopEnds", "pressureEvents",
        ] {
            XCTAssertTrue(
                liveness.contains("\"\(key)\""),
                "the liveness line lost the '\(key)' tally the capture protocol differences")
        }
    }

    /// The identity-change moment logs in EVERY build (it is what arms the rebind machinery),
    /// and the per-callback observation line stays inside the QA gate.
    func testThePathObservationLogsTheIdentityChangeMoment() throws {
        let provider = try readPacketTunnelProviderSource()
        let feedBlock = try sourceBlock(
            in: provider,
            startingAt: "private func noteChainedPathObservation(",
            endingBefore: "func clearEncryptedFallbackLogThrottle")
        guard let identityRange = feedBlock.range(of: "chained-path-identity-changed") else {
            XCTFail(
                "the moment the stash reports an identity change must be a log line — it is "
                    + "the timestamped cause for any rebind that follows")
            return
        }
        guard let qaGateRange = feedBlock.range(of: "#if DEBUG || LAVA_QA_TOOLS") else {
            XCTFail("the per-callback observation line must exist under the QA gate")
            return
        }
        // ABOVE THE GATE, asserted by POSITION rather than by presence. A presence-only check
        // passes just as happily with the identity line moved INSIDE the QA gate — which would
        // silently make the production build's only path-cause evidence disappear, and a device
        // log pulled from a Release install would show rebinds with nothing naming their cause.
        XCTAssertTrue(
            identityRange.lowerBound < qaGateRange.lowerBound,
            "the identity-change line must sit ABOVE the QA gate — it logs in EVERY build, "
                + "because a rebind with no logged cause is the blindness this slice removed")
        XCTAssertTrue(
            feedBlock[qaGateRange.upperBound...].contains("chained-path-observation"),
            "the per-callback line must sit inside the QA gate — production logs transitions, "
                + "not every path callback")
    }
    /// The value handed to the credential reader is the AUTHORED configuration, not the widened
    /// one. `PacketTunnelProvider` is outside the package, so only a pin holds this.
    func testCredentialRotationComparesTheLatchedConfiguration() throws {
        let provider = try readPacketTunnelProviderSource()

        // The reader compares this against a fresh STORE read to catch a mid-session rotation,
        // and the store holds only what the user saved. Handing it a configuration carrying
        // routes this app opened refused EVERY build as `configurationRotated` and downgraded the
        // lifecycle to DNS-only — so choosing an alternative DNS stopped chaining entirely
        // (Codex P1, PR #584). Nothing widens the latch any more (the plan's S3), so the latched
        // value IS the authored one and the strip is gone with the widening.
        XCTAssertTrue(provider.contains("let latchedConfiguration = upstream"))
        XCTAssertFalse(
            provider.contains("openingRoutes("),
            "nothing may widen AllowedIPs at latch time; that is what made the strip necessary")
        // Exactly one binding, so a second one cannot quietly reintroduce the widened value.
        XCTAssertEqual(
            provider.components(separatedBy: "let latchedConfiguration = ").count - 1, 1)
    }

    /// The startup publish and the per-query one go through the SAME publisher.
    ///
    /// They used to build a selection each and hand it in, and when one of them appended the
    /// T1 addresses `fallbackOutcomes` read membership in `selection.resolvers` as "already
    /// the conf's own resolver" — so a fallback the profile's own `AllowedIPs` happen to cover was
    /// published `.alreadyPrimary` at startup, and the panel called a working resolver a duplicate
    /// until the first DNS lookup re-published it correctly (Codex, PR #590).
    ///
    /// The window that mattered is exactly the one this startup publish exists to close: an idle
    /// device that has not resolved anything yet. Passing no selection at all is what makes the
    /// two derivations unable to differ.
    func testTheStartupPublishSharesTheOnePublisher() throws {
        let provider = try readPacketTunnelProviderSource()
        let publish = try sourceBlock(
            in: provider,
            // Anchored on the startup site's own comment, NOT on the call: `sourceBlock` takes the
            // FIRST match, and `publishChainedFallbackOutcomesOnQueue(` matches its definition
            // thousands of lines earlier.
            startingAt: "// ONE PUBLISHER, so the two sites cannot derive it differently.",
            endingBefore: "#if DEBUG || LAVA_QA_TOOLS")
        XCTAssertTrue(
            publish.contains("publishChainedFallbackOutcomesOnQueue(configuration: upstream)"),
            "the startup publish must hand in the configuration and nothing else")
        XCTAssertFalse(
            publish.contains("selection:"),
            "a hand-built selection is the second derivation this removed")
        // And the publisher takes no selection to be handed, so there is no way back.
        XCTAssertTrue(
            provider.contains(
                "func publishChainedFallbackOutcomesOnQueue(\n        configuration: ChainedUpstreamConfiguration\n    ) {"),
            "the publisher derives the selection itself")
    }

    // MARK: - The accepted rotation reaches the provider (task #21 / Codex P1, PR #613)

    /// The read closure records nothing of its own, and still may not reach `self`.
    ///
    /// Two things are pinned here and both are load-bearing. Nothing may be recorded at this
    /// point: the closure returns before `makeSession` constructs the session and the runner, so
    /// a value stashed here describes a build that can still fail — the generation rides on the
    /// credentials and is stamped onto the runner instead, which cannot exist unless the build
    /// succeeded. And the closure may not reach `self`: it runs inline on the ENGINE queue, and
    /// the teardown funnel waits on `dnsStateQueue` while retiring the driver waits on the engine
    /// queue, so a hop from here is the `INV-QUEUE-1` deadlock rather than a style violation. The
    /// file's own rule at this site says every factory closure captures values, never `self`.
    func testTheReadClosureRecordsNothingItselfForRotation() throws {
        let source = try readPacketTunnelProviderSource()
        let build = try sourceBlock(
            in: source,
            startingAt: "let factory = ChainedUpstreamSessionFactory(",
            endingBefore: "allowedIPs: ChainedAllowedIPs(prefixes),")
        // NOTHING IS RECORDED HERE, and that is the fix rather than an omission. This closure
        // returns before `makeSession` builds the session and the runner, and that construction
        // throws on its own paths — so anything recorded here describes a build that may never
        // have happened. The generation rides ON the credentials instead and is stamped onto the
        // runner, which cannot exist unless the build succeeded (Codex P2, PR #613).
        XCTAssertFalse(
            build.contains(".record(credentials.generation)"),
            "a value recorded before construction describes a build that may have failed")
        XCTAssertTrue(
            build.contains("ChainedSessionCredentialReader.read("),
            "the closure's whole job is the bounded read")
        // THE BOX, NOT `self`. If this ever became a `self?.` hop it would deadlock under
        // teardown, so the absence is the assertion.
        XCTAssertFalse(
            build.contains("self?.dnsStateQueue"),
            "a factory closure may not reach dnsStateQueue — INV-QUEUE-1")
        XCTAssertFalse(
            build.contains("[weak self]"),
            "a factory closure captures values, never self")
    }


    /// A RUNNER CHANGE REPUBLISHES THE ROTATION, asynchronously.
    ///
    /// The mirror otherwise runs at start, at stop, on an explicit flush and on the ~60 s focus
    /// tick, so between a rebuild and the next mirror the health snapshot still names the
    /// previous rotation — the panel then demands a restart for a rotation already adopted, or
    /// reports a removed configuration as still running (Codex P2, PR #613).
    ///
    /// ASYNC is the safety argument, not a style choice: the callback fires on the ENGINE queue,
    /// and `INV-QUEUE-1`'s hazard is a SYNC wait in this direction — the teardown funnel waits on
    /// `dnsStateQueue` while retiring the driver waits on the engine queue.
    func testARunnerChangeRepublishesTheRotation() throws {
        let provider = try readPacketTunnelProviderSource()
        let construction = try sourceBlock(
            in: provider,
            startingAt: "onSurrender: { [weak self] surrender, counters in",
            endingBefore: "timerDriverBox.driver = driver")
        XCTAssertTrue(
            construction.contains("onRunnerChanged: { [weak self] in"),
            "the driver must tell the provider when the live runner changes")
        XCTAssertTrue(
            construction.contains("self.dnsStateQueue.async"),
            "the hop off the engine queue must be ASYNC — a sync wait here is the INV-QUEUE-1 "
                + "deadlock against the teardown funnel")
        XCTAssertTrue(
            construction.contains("mirrorChainedHealthCountersIfChanged()"),
            "the republication goes through the one publisher, not a second copy of it")
        XCTAssertFalse(
            construction.contains("dnsStateQueue.sync"),
            "a sync hop from the engine queue deadlocks against teardown")
    }

    // MARK: - F4: the claimed-destination set is split-only and live (Kilo, PR #749)

    /// The provider hands the classifier a claimed capture-floor set only for the SPLIT chained
    /// path, `.empty` for a FULL tunnel and every non-chained mode, and that set is a LIVE box
    /// the settings reapply republishes.
    ///
    /// The classifier's claimed set and the plan's floor routes must be built from the same live
    /// `currentDeviceDNSResolverAddresses()`. Latched once at construction while the plan
    /// re-derived per reapply, a roam would leave the `:853` drop matching the previous network's
    /// resolvers while the plan routed the new ones into the NE — a claimed flow the classifier
    /// no longer recognised. The package cannot observe the tunnel process's box, so this is a
    /// source pin.
    func testTheClaimedResolverSetIsSplitOnlyAndTracksReapply() throws {
        let provider = try readPacketTunnelProviderSource()

        // The shared derivation: split chained claims the capture; full tunnel and DNS-only empty.
        let derivation = try sourceBlock(
            in: provider,
            startingAt: "func makeClaimedResolverDestinations(",
            endingBefore: "static func eligibleChainedInterface(on path:")
        XCTAssertTrue(
            derivation.contains("case .chainedUpstream(let upstream) = mode"),
            "the set must be derived from the latched mode")
        XCTAssertTrue(
            derivation.contains("upstream.effectiveRoutingPolicy != .fullTunnel"),
            "full tunnel must fall through to the empty set")
        XCTAssertTrue(
            derivation.contains("return .empty"),
            "both the non-chained and full-tunnel arms must return the empty set")
        XCTAssertTrue(
            derivation.contains("currentDeviceDNSResolverAddresses()"),
            "the claimed set's source must be the same live capture the route plan uses")
        XCTAssertTrue(
            derivation.contains("ChainedClaimedResolverDestinations("),
            "the split path must claim the captured resolvers")
        XCTAssertTrue(
            derivation.contains("DNSCaptureFloor.curatedPublicResolverAddresses"),
            "F1: the classifier's claimed set must include the curated public resolvers the split "
                + "plan claims, or a curated `:853` flow would not be refused")

        // Construction hands the factory a live box and publishes it beside the runtime.
        let construction = try sourceBlock(
            in: provider,
            startingAt: "func buildChainedRuntimeIfLatched(",
            endingBefore: "func makeClaimedResolverDestinations(")
        XCTAssertTrue(
            construction.contains("ChainedClaimedResolverDestinationsStore("),
            "the provider must hand the factory a live box, not a latched value")
        XCTAssertTrue(
            construction.contains(
                "chainedClaimedResolverDestinations = claimedResolverDestinations"),
            "the box must be published beside the runtime so reapply can update it")
        XCTAssertTrue(
            construction.contains("makeClaimedResolverDestinations(for: mode)"),
            "the box must be built from the shared derivation, not a second inline copy")

        // Reapply republishes the box at the same point the route plan is rebuilt.
        let reapply = try sourceBlock(
            in: provider,
            startingAt: "func reapplyTunnelNetworkSettings(",
            endingBefore: "private func recordNetworkSettingsReapplyFailure(")
        let update = try XCTUnwrap(
            reapply.range(of: "chainedClaimedResolverDestinations?.update("),
            "reapply must republish the claimed set or the drop lags the routes")
        let rebuild = try XCTUnwrap(
            reapply.range(of: "let settingsBundle = makeTunnelNetworkSettingsForLatchedDataPath()"),
            "the route plan rebuild must be in this block")
        XCTAssertLessThan(
            update.lowerBound, rebuild.lowerBound,
            "the claimed set must be republished at the same point the route plan is rebuilt")
        XCTAssertTrue(
            reapply.contains("makeClaimedResolverDestinations(for: currentTunnelDataPathMode())"),
            "reapply must feed the live derivation into update(, or the drop lags the routes")
    }

}
