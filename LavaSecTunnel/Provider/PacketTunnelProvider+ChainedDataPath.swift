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
    // MARK: - Chained data path construction (S8.8b)

    /// Builds the chained runtime when — and only when — this lifecycle latched chained.
    ///
    /// Runs in `startTunnel`'s prologue, AFTER the latch resolves and BEFORE the path
    /// monitor starts or any network settings are built. The ordering is C4's fail-safe:
    /// every construction failure downgrades the latch to DNS-only HERE, before
    /// `makeTunnelNetworkSettingsForLatchedDataPath` reads it, so the tunnel never claims
    /// the default route with no session to serve it. The gate is the LATCHED mode read
    /// through the dual-entry accessor — never `Self.buildSupportsChainedDataPath` (C2).
    /// pinned: ChainedProviderConstructionSourceTests.testTheConstructionGateIsTheLatchedModeNeverTheBuildFlag
    /// pinned: ChainedProviderConstructionSourceTests.testConstructionFailureDowngradesBeforeAnySettingsAreBuilt
    func buildChainedRuntimeIfLatched(lifecycleGeneration: UInt64) -> ChainedOutageDriver? {
        guard case .chainedUpstream(let upstream) = currentTunnelDataPathMode() else {
            return nil
        }

        // The endpoint must be an IP literal: the S1 hostname executor does not exist in
        // production yet, and mapping a hostname into the transient no-interface lane
        // would walk the outage ladder to a surrender — with a persisted suppression —
        // on every start. Refusing HERE is a downgrade for this lifecycle only.
        guard
            let endpoint = ChainedEndpointAddress(
                literal: upstream.endpointHost, port: upstream.endpointPort)
        else {
            downgradeChainedConstruction(reason: "endpoint-not-a-literal")
            return nil
        }
        // The configuration validator already refused malformed AllowedIPs, so a prefix
        // failing to parse here means the parsers drifted — fail the whole construction
        // closed rather than run with a silently narrower set.
        let prefixes = upstream.allowedIPs.compactMap(ChainedIPPrefix.init)
        guard prefixes.count == upstream.allowedIPs.count else {
            downgradeChainedConstruction(reason: "allowed-ips-unparsable")
            return nil
        }
        // The connect gate's forwarding evidence excludes DNS replies (source = the upstream resolver)
        // ONLY in FULL tunnel — there, all traffic rides the NE, so a chain that answers its resolver
        // but forwards nothing else is the degenerate "Protected over dead web" case to catch. In SPLIT
        // tunnel, non-`AllowedIPs` traffic BYPASSES the NE by design, so DNS is often the only captured
        // traffic; excluding it would starve the gate and false-close an otherwise healthy split tunnel
        // (Codex, PR #558). So for split, exclude nothing (empty set) — DNS-through-chain is legitimate
        // evidence the tunnel carries traffic.
        //
        // T0 ONLY, in both the full-tunnel exclusion set here and the per-query route.
        //
        // This used to append the latched T1 addresses. PR #590 stopped the per-query route
        // appending them — the rung egresses on the physical interface, so sending them through a
        // peer that will not forward them is the failure that PR fixed — and left the append
        // standing here, documented as harmless: this branch is FULL TUNNEL, full tunnel has no
        // T1 rung at all, so excluding addresses that produce no replies excluded nothing.
        //
        // It is deleted with the rest of the tunnelled-T1 machinery (the plan's S3). Harmless
        // dead weight in the connect gate's evidence set is still dead weight in the connect
        // gate's evidence set, and the next person to read it would have to re-derive that whole
        // paragraph to learn it means nothing.
        //
        // What the set still does, unchanged: in FULL tunnel all traffic rides the NE, so a chain
        // that answers its resolver but forwards nothing else is the degenerate "Protected over
        // dead web" case, and DNS replies are excluded from the forwarding evidence to catch it.
        // In SPLIT tunnel non-`AllowedIPs` traffic bypasses the NE by design, so DNS is often the
        // only captured traffic and excluding it would starve the gate and false-close a healthy
        // split tunnel (Codex, PR #558) — hence the empty set there.
        // pinned: ChainedProviderConstructionSourceTests.testTheResolverExclusionSetIsPopulatedOnlyForFullTunnel
        let latchedSelection = ChainedTunnelResolverSelection.selection(from: upstream)
        let resolverSourceAddresses = upstream.effectiveRoutingPolicy == .fullTunnel
            ? ChainedAllowedIPs(latchedSelection.resolvers.compactMap(ChainedIPPrefix.init))
            : ChainedAllowedIPs([])

        // THE SAME MTU THE SETTINGS CARRY, through the same seam: the route plan's value
        // clamped by `engineSafeMTU`. Deriving the factory's copy any other way lets the
        // engine's queue sizing and the utun's MTU disagree (S8.8b task d).
        // pinned: ChainedProviderConstructionSourceTests.testTheFactoryMTUIsTheSettingsMTU
        let mode = TunnelDataPathMode.chainedUpstream(upstream)
        let plan = TunnelRoutePlan.make(for: mode)
        let mtu = Self.engineSafeMTU(for: mode, planMTU: plan.mtu)

        let engineQueue = ChainedEngineQueue()
        // The ONE bounded wait in this prologue (~250 ms cap): the path cache must be
        // primed off the engine queue, and the FIRST build's interface comes from it —
        // the path monitor has not delivered yet, so an unprimed stash would refuse the
        // first session for want of an interface the system is happy to report.
        let livePath = ChainedUpstreamLivePath.shared.primed(offEngineQueue: engineQueue)
        let interfaceStash = ChainedEligibleInterfaceStash()
        interfaceStash.update(
            Self.eligibleChainedInterface(primedFrom: livePath.availableInterfaces()))

        // Weak-host adapters, never a direct conformance handed to the factory: the
        // factory holds writer/dnsServer strongly and this provider owns the runtime that
        // owns the driver that owns the factory (INV-MEM-1; the seam adapters' doc).
        // Build from the latched forwarding mode, not the mutable NE profile. iOS can
        // apply includeAllNetworks while an on-demand replacement is already starting.
        // Every full tunnel must already have the direct transport when that happens.
        let directDNS = upstream.effectiveRoutingPolicy == .fullTunnel
            ? TunnelUDPResolver(sourceAddress: plan.tunnelAddress) : nil
        if directDNS != nil {
            LavaSecDeviceDebugLog.append(component: "tunnel", event: "chained-direct-dns-ready")
        }
        let baseWriter = ChainedTunnelWriterAdapter(host: self)
        let writerAdapter: ChainedTunnelWriter
        if let directDNS { writerAdapter = ChainedDNSReplyWriter(resolver: directDNS, downstream: baseWriter) }
        else { writerAdapter = baseWriter }
        let dnsServingAdapter = ChainedDNSServingAdapter(
            host: self, queue: ChainedDNSServingAdapter.makeServingQueue(),
            lifecycleToken: lifecycleGeneration)

        // Brief-stall observability (2026-08-24): the recorder decides which transport and
        // pressure observations become device-log lines (rate-bounded) and keeps the tallies
        // the 60 s liveness line differences. The sinks below capture IT, never `self`, per
        // the factory-closure rule — they fire on the engine queue and on producer threads.
        let transportDiagnostics = ChainedTransportDiagnosticsRecorder()

        // Every factory closure captures VALUES, never `self`: they run inline on the
        // engine queue (no `dnsStateQueue` access, INV-QUEUE-1 — the teardown funnel
        // waits on that queue while retiring the driver waits on this one), and the
        // factory outlives any single attempt.
        // THE LATCHED VALUE ITSELF, which is now the authored one. This is compared against a
        // fresh STORE read to catch a mid-session rotation, and the store only ever holds what the
        // user saved — so it used to be `upstream.asAuthored`, stripping the routes this app
        // opened for the chosen fallback resolver. Comparing the widened form against the store
        // refused EVERY build as `configurationRotated` and downgraded the lifecycle to DNS-only,
        // turning "open a route for the chosen resolver" into "chaining stops the moment a
        // fallback is chosen" (Codex P1, PR #584). Nothing widens the latch any more (the plan's
        // S3), so the latched configuration IS the authored one and the strip has nothing to do.
        // pinned: ChainedProviderConstructionSourceTests.testCredentialRotationComparesTheLatchedConfiguration
        let latchedConfiguration = upstream

        // F4: the DNS capture-floor destinations this SPLIT plan claims. The classifier refuses
        // `:853` (DoT/DoQ) to one of them even without the full-tunnel flag, because the claim is
        // what drew the flow into the NE — where the filter cannot read it and the IPv4-only peer
        // will not carry it. FULL tunnel passes the empty set: its `dropsUnfilterableEncryptedDNS`
        // already refuses every `:853`, and its plan ignores the floor. This mirrors the plan's
        // own "full tunnel ignores the capture floor" rule, so the classifier's claimed set and
        // the routes the plan installs come from one decision.
        //
        // A BOX, not a value: the route plan's floor routes are re-derived on every settings
        // apply (`reapplyTunnelNetworkSettings` -> `makeTunnelNetworkSettingsForLatchedDataPath`)
        // from the live `currentDeviceDNSResolverAddresses()`, so the classifier's set must track
        // the same source or a roam would leave it matching the previous network's resolvers.
        // The provider republishes the box beside that rebuild; the runner reads it per packet.
        // The derivation itself (including the gateway-class exclusion and the full-tunnel
        // `.empty`) lives in `makeClaimedResolverDestinations(for:)`, shared with the reapply so
        // the two cannot disagree.
        let claimedResolverDestinations = ChainedClaimedResolverDestinationsStore(
            makeClaimedResolverDestinations(for: mode))

        let qaChannelFactory: (@Sendable (ChainedEndpointAddress, ChainedBindableInterface)
            -> ChainedUpstreamDatagramChannel?)?
        #if DEBUG || LAVA_QA_TOOLS
        let blackout = qaPeerBlackout
        qaChannelFactory = { endpoint, binding in
            guard let channel = ChainedUpstreamChannel(
                endpoint: endpoint, binding: binding, queue: engineQueue.queue,
                liveInterfaces: livePath.availableInterfaces(),
                telemetry: { sequence, event in
                    let observation = DeviceLogObservationClock.capture()
                    guard let emission = transportDiagnostics.recordTransport(
                        channelSequence: sequence, event: event) else { return }
                    Self.transportDiagnosticsLogQueue.async {
                        LavaSecDeviceDebugLog.append(
                            component: "tunnel", event: emission.event, details: emission.details,
                            observation: observation)
                    }
                }) else { return nil }
            return ChainedQABlackoutChannel(base: channel, blackout: blackout)
        }
        #else
        qaChannelFactory = nil
        #endif

        let readEntry: (@Sendable () throws -> ChainedSessionCredentials)? = upstream.precedingHops.isEmpty ? nil : { @Sendable in
            try ChainedBoundedCredentialRead.perform {
                guard let container = LavaSecAppGroup.containerURL,
                      let group = LavaSecAppGroup.chainedUpstreamKeychainAccessGroup else {
                    throw ChainedSessionBuildFailure.credentialsUnavailable
                }
                let store = ChainedUpstreamKeychainStore(containerURL: container,
                    identity: LavaSecAppGroup.chainedUpstreamStoreIdentity,
                    keyItems: ChainedUpstreamKeychainKeyItemStore(accessGroup: group))
                return try ChainedSessionCredentialReader.readEntry(store: store, latchedConfiguration: latchedConfiguration)
            }
        }

        let factory = ChainedUpstreamSessionFactory(
            readCredentials: {
                // BOUNDED: this closure runs on the engine queue with the attempt
                // watchdog — whose deadline is the outage deadline — queued behind it,
                // so the Keychain read happens off-queue and the engine queue waits at
                // most the bound, never on securityd's health (Codex, PR #508).
                try ChainedBoundedCredentialRead.perform {
                    guard let container = LavaSecAppGroup.containerURL,
                        let group = LavaSecAppGroup.chainedUpstreamKeychainAccessGroup
                    else {
                        // The latch read this same store moments ago, so an unbuildable
                        // store now is environmental and transient — never a lifecycle
                        // surrender.
                        throw ChainedSessionBuildFailure.credentialsUnavailable
                    }
                    let store = ChainedUpstreamKeychainStore(
                        containerURL: container,
                        identity: LavaSecAppGroup.chainedUpstreamStoreIdentity,
                        keyItems: ChainedUpstreamKeychainKeyItemStore(accessGroup: group))
                    // The generation this read accepted travels ON the credentials and is
                    // stamped onto the runner the factory builds from them, so nothing has to be
                    // recorded here — and nothing can be recorded for a build that then fails
                    // (Codex P2, PR #613).
                    // pinned: ChainedProviderConstructionSourceTests.testTheReadClosureRecordsNothingItselfForRotation
                    return try ChainedSessionCredentialReader.read(
                        store: store, latchedConfiguration: latchedConfiguration)
                }
            },
            allowedIPs: ChainedAllowedIPs(prefixes),
            resolverSourceAddresses: resolverSourceAddresses,
            writer: writerAdapter,
            dnsServer: dnsServingAdapter,
            mtu: mtu,
            currentInterface: { interfaceStash.latest() },
            currentEndpoint: { endpoint },
            livePath: livePath,
            ownResolverPorts: ownResolverPorts,
            // DoT/DoQ (853) is unfilterable and, in a FULL tunnel, no legitimate rung needs it:
            // every destination is claimed and the encrypted resolver rung is unavailable while
            // chained. In a SPLIT tunnel the user's own DoT resolver may egress physically, so
            // dropping its port would break resolution — the plan's F4 scoping, decided on the
            // anchors plan. Keyed on the latched routing policy, like the egress rules beside it.
            dropsUnfilterableEncryptedDNS: upstream.effectiveRoutingPolicy == .fullTunnel,
            // F4: the claimed capture-floor destinations, empty for full tunnel (above).
            claimedResolverDestinations: claimedResolverDestinations,
            makeChannel: qaChannelFactory,
            // TELEMETRY ONLY, both sinks — the channel doc's "no separate remedy signal"
            // design is untouched: nothing here feeds the driver, these name mechanisms in
            // the log a 60 s counter cannot (the brief stall's whole problem).
            // The RECORDING stays inline — it is integer arithmetic behind one lock, and the
            // rate limit has to see every event to work. Only the APPEND hops off, because that
            // is the part that touches the filesystem (Codex P2, PR #581). The recorder was
            // already built for this split: it returns a prepared `Emission` rather than logging
            // itself, "so this type never needs a logger".
            transportTelemetry: { sequence, event in
                // FIRST EXECUTABLE WORK at callback entry, in both sinks: preserve producer
                // chronology before the recorder's shared lock can delay an older callback.
                // Suppressed events intentionally pay capture's two clock reads; the domain is
                // cached, and that bounded cost is what keeps their callback order honest.
                let observation = DeviceLogObservationClock.capture()
                guard let emission = transportDiagnostics.recordTransport(
                    channelSequence: sequence, event: event) else { return }
                Self.transportDiagnosticsLogQueue.async {
                    LavaSecDeviceDebugLog.append(
                        component: "tunnel", event: emission.event, details: emission.details,
                        observation: observation)
                }
            },
            dataPathDiagnostics: { event in
                let observation = DeviceLogObservationClock.capture()
                guard let emission = transportDiagnostics.recordPressure(event) else { return }
                Self.transportDiagnosticsLogQueue.async {
                    LavaSecDeviceDebugLog.append(
                        component: "tunnel", event: emission.event, details: emission.details,
                        observation: observation)
                }
            }, entryConfiguration: upstream.precedingHops.first, readEntryCredentials: readEntry, exitConfiguration: upstream)

        // The tick handler holds the driver WEAKLY — the timers' repeating source retains
        // its handler, and a strong capture here would keep the engine alive past
        // retirement (the wiring obligation `ChainedEngineQueueTimers` documents).
        let timerDriverBox = ChainedWeakDriverBox()
        let timers = ChainedEngineQueueTimers(engineQueue: engineQueue) {
            timerDriverBox.driver?.tick()
        }
        let lifecycleEvidenceID = currentChainedLifecycleEvidenceID()
        let deviceStateAccessGroup = LavaSecAppGroup.chainedUpstreamKeychainAccessGroup
        let deviceStateLifecycleLockURL = LavaSecAppGroup.chainedLifecycleEvidenceLockURL
        let driver = ChainedOutageDriver(
            engineQueue: engineQueue,
            clock: ChainedUptimeClock(),
            timers: timers,
            source: factory,
            // The egress-dead cause is FULL-TUNNEL ONLY: in split tunnel a flat forwarding counter
            // under `AllowedIPs` demand is not proof of dead egress (a cached/literal silent host on
            // a healthy chain looks identical), so surrendering on it would false-drop a working
            // split tunnel (Codex, PR #567). Same `routingPolicy` the resolver-exclusion set reads.
            routingPolicy: upstream.effectiveRoutingPolicy,
            onSurrender: { [weak self] surrender, counters in
                self?.performChainedSurrenderRecovery(
                    surrender, counters: counters,
                    owningLifecycleID: lifecycleEvidenceID)
            },
            // A delivered inbound packet is the point where this lifecycle stops being a
            // startup-crash candidate. The driver calls on its engine queue, so the Keychain write
            // hops to a dedicated utility queue and is itself bounded: a securityd call that never
            // returns must still complete the driver's attempt as transient so its independent
            // retry can run. The store writes generation-addressed proof instead of rewriting the
            // shared marker, serializes it with lifecycle transitions, and checks the bound's
            // abandonment fence immediately before saving so work abandoned during an earlier
            // lock/read cannot proceed to the mutation.
            onHealthyForwarding: { completion in
                guard let lifecycleEvidenceID, let deviceStateAccessGroup,
                    let buildIdentity = Self.chainedBuildIdentity,
                    let deviceStateLifecycleLockURL
                else {
                    completion(true)
                    return
                }
                Self.chainedLifecycleEvidenceQueue.async {
                    let store = ChainedDeviceEligibilityStore(
                        items: ChainedDeviceStateKeychainItemStore(
                            accessGroup: deviceStateAccessGroup,
                            lifecycleEvidenceLockURL: deviceStateLifecycleLockURL))
                    do {
                        try ChainedBoundedKeychainWork.perform { isStillWanted in
                            guard isStillWanted() else { return }
                            let didMark = try store.markChainedSessionProvenHealthy(
                                buildIdentity: buildIdentity,
                                lifecycleID: lifecycleEvidenceID,
                                isStillWanted: isStillWanted)
                            if didMark {
                                LavaSecDeviceDebugLog.append(
                                    component: "tunnel", event: "chained-session-proven-healthy")
                            }
                        }
                        // `false` means the proof already existed or this lifecycle was superseded;
                        // neither should retry. A thrown refusal or timeout remains transient.
                        completion(true)
                    } catch {
                        LavaSecDeviceDebugLog.append(
                            component: "tunnel", event: "chained-session-proof-write-failed",
                            details: Self.errorDebugDetails(error))
                        completion(false)
                    }
                }
            },
            // THE ROTATION IDENTITY FOLLOWS THE RUNNER, so it has to be republished when the
            // runner changes rather than at the next poll. The mirror otherwise runs at start,
            // at stop, on an explicit flush and on the ~60 s focus tick, so between a rebuild and
            // the next mirror the snapshot still names the previous rotation — a restart demanded
            // for a rotation already adopted (Codex P2, PR #613).
            //
            // ASYNC, and that is the whole safety argument. This fires on the ENGINE queue, and
            // `INV-QUEUE-1`'s hazard is a SYNC wait in this direction — the teardown funnel waits
            // on `dnsStateQueue` while retiring the driver waits on the engine queue. An async
            // hop never blocks the engine queue, and it is the same shape `startTunnel` already
            // uses to kick this mirror.
            // pinned: ChainedProviderConstructionSourceTests.testARunnerChangeRepublishesTheRotation
            onRunnerChanged: { [weak self] in
                guard let self else { return }
                self.dnsStateQueue.async { [weak self] in
                    self?.mirrorChainedHealthCountersIfChanged()
                }
            })
        timerDriverBox.driver = driver

        // The first session is the wiring's to build (the driver builds only ladder
        // replacements), on the engine queue like every later build. ANY failure here —
        // transient or permanent — downgrades: the alternative is claiming the default
        // route and waiting for the ladder, which is a blackhole at first connect for a
        // fault DNS-only serves through unharmed.
        let firstBuild: Result<any ChainedSessionDriving, Error> = engineQueue.run {
            Result { try factory.makeSession(engineQueue: engineQueue, events: driver) }
        }
        let firstRunner: any ChainedSessionDriving
        switch firstBuild {
        case .success(let runner):
            firstRunner = runner
        case .failure(let error):
            driver.retire()
            downgradeChainedConstruction(
                reason: "first-session-build-failed: \(String(describing: error))")
            return nil
        }
        driver.adopt(firstRunner)
        // Come up without waiting for traffic — the same call the driver makes for its
        // own ladder builds.
        engineQueue.run { firstRunner.forceHandshake() }

        let runtime = ChainedTunnelRuntime(
            engineQueue: engineQueue,
            driver: driver,
            dnsServingAdapter: dnsServingAdapter,
            interfaceStash: interfaceStash,
            transportDiagnostics: transportDiagnostics,
            directDNS: directDNS)
        dnsStateQueue.sync {
            chainedRuntime = runtime
            // The F4 claimed set's provider-side handle, published beside the runtime it
            // classifies for. `reapplyTunnelNetworkSettings` updates it in place when the route
            // plan is rebuilt, so the runner's per-packet read tracks the live resolver capture.
            chainedClaimedResolverDestinations = claimedResolverDestinations
            // PUBLISH THE LATCH NOW, not on the first resolution. The session has latched its
            // T1 selection by this point (this function only runs `IfLatched`), and leaving
            // publication to the per-query derive left the app blind on an idle device — a user
            // who switched Alternative DNS off before any lookup saw `.off` while the session
            // was still holding the resolver (Codex, PR #575).
            // ONE PUBLISHER, so the two sites cannot derive it differently. This used to build
            // its own selection and hand it in, and when that selection appended the T1
            // addresses `fallbackOutcomes` read membership as "this is already the conf's own
            // resolver" — so a fallback the profile's own `AllowedIPs` happen to cover was
            // published `.alreadyPrimary` at startup, and the panel called a working resolver a
            // duplicate until the first DNS lookup re-published it correctly (Codex, PR #590).
            // The publisher derives the selection itself now, so there is no second derivation to
            // disagree with, for exactly as long as the device is idle — which is precisely the
            // window this startup publish was added to cover.
            // pinned: ChainedProviderConstructionSourceTests.testTheStartupPublishSharesTheOnePublisher
            publishChainedFallbackOutcomesOnQueue(configuration: upstream)
            #if DEBUG || LAVA_QA_TOOLS
            // The forced handshake above (11755) has just been queued; from HERE the QA
            // recovery window measures how long until the first tunnel-DNS answer lands, so a
            // cold-start "connected but no sites for 20 s" gap is legible in the log.
            openChainedRecoveryWindow(reason: "cold-start")
            #endif
        }
        LavaSecDeviceDebugLog.append(component: "tunnel", event: "chained-runtime-built", details: [
            "mtu": "\(mtu)",
            "endpoint": endpoint.isIPv6 ? "v6-literal" : "v4-literal"
        ])
        return driver
    }

    /// F4's claimed capture-floor destinations for `mode`, derived from the SAME live device
    /// resolver capture the route plan's floor routes use.
    ///
    /// FULL tunnel passes ``ChainedClaimedResolverDestinations/empty``: its
    /// `dropsUnfilterableEncryptedDNS` already refuses every `:853`, and its plan ignores the
    /// floor. Every non-chained mode passes empty too — there is no chained session to classify
    /// for. Only a SPLIT chained path claims resolvers, and it must claim exactly the ones the
    /// plan installs as host routes: F1's curated public set (the split plan carries it; DNS-only
    /// does not) plus the captured device resolvers. The gateway-class exclusion and the
    /// listener/unusable/mapped-literal exclusions live inside
    /// ``ChainedClaimedResolverDestinations``, so handing it the curated set followed by the RAW
    /// `currentDeviceDNSResolverAddresses()` is what keeps the `:853` drop and the routes in
    /// agreement.
    /// pinned: ChainedProviderConstructionSourceTests.testTheClaimedResolverSetIsSplitOnlyAndTracksReapply
    func makeClaimedResolverDestinations(
        for mode: TunnelDataPathMode
    ) -> ChainedClaimedResolverDestinations {
        guard case .chainedUpstream(let upstream) = mode,
            upstream.effectiveRoutingPolicy != .fullTunnel
        else {
            return .empty
        }
        return ChainedClaimedResolverDestinations(
            resolverAddresses: DNSCaptureFloor.curatedPublicResolverAddresses
                + currentDeviceDNSResolverAddresses() + currentDNSPatchCaptureAddresses(),
            httpsResolverAddresses: dnsPatchContract?.serverURL == nil ? [] : currentDNSPatchCaptureAddresses())
    }

    /// The egress policy's answer for the interface the path actually ROUTES OVER — never
    /// merely the first available one. With Wi-Fi and cellular both up,
    /// `availableInterfaces.first` can be cellular while the system routes Wi-Fi, and the
    /// package's own socket-lifecycle doc records exactly that binding going wrong in the
    /// field: chained would start on metered egress and rebuild onto it after every path
    /// change (Codex, PR #508). `usesInterfaceType` is route truth for the kind.
    ///
    /// RESIDUAL, stated rather than implied: `usesInterfaceType` answers about a CATEGORY,
    /// so where two interfaces share a type — the multi-same-category case
    /// `ChainedUpstreamChannelParameters` records for iPhone — this picks the first of
    /// that type in `availableInterfaces` order rather than an identity the path names.
    /// `NWPath` exposes no selected-interface identity to do better with, and inventing
    /// one would be a guess wearing a fact's clothing. What bounds the residual: the
    /// binding is by NAME and type, so a wrong pick is a live interface that simply does
    /// not carry the route, which presents as an ordinary unresponsive upstream — the
    /// silence detector opens an outage, the ladder rebuilds against a re-read path, and
    /// the budget bounds it. Narrowing it needs an identity signal this API does not have
    /// (Codex, PR #508 round 5).
    /// pinned: ChainedProviderConstructionSourceTests.testTheBindingDerivesFromTheRoutedInterface
    static func eligibleChainedInterface(on path: Network.NWPath) -> ChainedBindableInterface? {
        eligibleChainedInterface(first: routedInterface(on: path))
    }

    /// The interface `path` actually ROUTES OVER — `availableInterfaces` is the set the path
    /// CAN use, not the one it selects, and its `.first` can be a foreign `utun` (or cellular
    /// while Wi-Fi carries the route). One derivation shared by the chained interface pick here
    /// and F2's physical interface-index stamp in `startPathMonitor`
    /// (`PacketTunnelProvider+NetworkPath.swift`), so the two can never disagree about which
    /// interface is the physical path.
    static func routedInterface(on path: Network.NWPath) -> NWInterface? {
        path.availableInterfaces.first { path.usesInterfaceType($0.type) }
    }

    /// The priming variant, for the one moment no `NWPath` exists yet: the live-path
    /// cache's production observation orders its list USED-FIRST (it partitions by
    /// `usesInterfaceType`), so the head carries the same route truth the per-callback
    /// overload derives from the path itself.
    static func eligibleChainedInterface(primedFrom interfaces: [NWInterface]) -> ChainedBindableInterface? {
        eligibleChainedInterface(first: interfaces.first)
    }

    static func eligibleChainedInterface(first interface: NWInterface?) -> ChainedBindableInterface? {
        let used = interface.map {
            ChainedUpstreamInterface(name: $0.name, kind: ChainedUpstreamLinkKind(mirroring: $0.type))
        }
        switch ChainedUpstreamEgressPolicy.egress(usedInterface: used) {
        case .bind(let interface):
            return interface
        case .refuse:
            return nil
        }
    }

    /// C4's fail-safe at construction: a chained latch whose runtime cannot be built is
    /// re-latched DNS-only BEFORE any settings read it. The session marker is settled with
    /// `sessionRanAndStoppedCleanly: false` — the session never ran, so the marker clears,
    /// the streak is untouched, and no strike is counted. Nothing is persisted beyond
    /// that: a construction failure is this lifecycle's fact, never a suppression.
    private func downgradeChainedConstruction(reason: String) {
        // THE RELATCH GOES FIRST, and the Keychain settle is BOUNDED behind it. Both halves
        // answer the same hazard: this runs in `startTunnel`'s prologue, so a wedged
        // security daemon reached through `store.read()`/`settleTermination` would block
        // startup before the DNS-only relatch — never installing the fail-safe settings
        // this whole path exists to install, and defeating the bound on the credential
        // read that sent us here (Codex, PR #508). The relatch is a local queue write and
        // cannot block; the settle is best-effort evidence hygiene and may be late.
        let owningLifecycleID = currentChainedLifecycleEvidenceID()
        installLatchedDataPathMode(.dnsOnly, refusal: .upstreamUnavailable)
        if let store = chainedDeviceEligibilityStore(), let owningLifecycleID {
            do {
                try ChainedBoundedKeychainWork.perform { isStillWanted in
                    // A settle that lost its race must NOT land: the caller has moved
                    // on, and a late clear would wipe a marker the NEXT lifecycle wrote
                    // (Codex, PR #508).
                    // Threaded INTO the transition, not merely checked before it: the
                    // preserving write performs its own Keychain read, so a timeout can
                    // land inside `settleTermination` and this outer check alone would
                    // still let the write proceed (Codex, PR #508).
                    guard isStillWanted() else { return }
                    _ = try store.settleTermination(
                        owningLifecycleID: owningLifecycleID,
                        sessionRanAndStoppedCleanly: false, isStillWanted: isStillWanted)
                }
            } catch {
                LavaSecDeviceDebugLog.append(
                    component: "tunnel", event: "chained-downgrade-settle-failed",
                    details: [:])
            }
        }
        LavaSecDeviceDebugLog.append(
            component: "tunnel", event: "chained-construction-downgraded",
            details: ["reason": reason])
    }

    /// Persists suppression, writes the app-visible marker, then cancels the surrendered tunnel.
    /// Runs on the engine queue without waiting on dnsStateQueue (INV-QUEUE-1).
    /// Cancellation remains unconditional: a surrendered runner holds routes without forwarding.
    /// Confirmed recoverable suppression preserves DNS-only recovery; a failed persistence or an
    /// unresolvable fault writes a terminal refusal so On-Demand cannot loop through chained starts.
    /// pinned: ChainedProviderConstructionSourceTests.testTheSurrenderPersistsBeforeItRestartsAndNeverTouchesTheDNSQueue
    private func performChainedSurrenderRecovery(
        _ surrender: ChainedReconnectPolicy.Surrender, counters: ChainedDriverCounters,
        owningLifecycleID: String?
    ) {
        var suppressionPersisted = false
        ChainedSurrenderRecovery.perform(
            persistSuppression: {
                guard let store = chainedDeviceEligibilityStore() else {
                    throw ChainedSurrenderPersistUnavailable()
                }
                // BOUNDED: a blocked `SecItem*` never throws, so an unbounded persist
                // would hold the restart forever — leaving the surrendered tunnel
                // claiming the default route with no runner, blackholing everything past
                // the advertised maximum outage, which is the state this whole path
                // exists to end (Codex, PR #508). A timeout throws, and a throw already
                // means "restart anyway, log loudly": the driver's own `hasSurrendered`
                // latch honours the suppression for this lifecycle either way.
                try ChainedBoundedKeychainWork.perform { isStillWanted in
                    guard let owningLifecycleID else {
                        throw ChainedSurrenderPersistUnavailable()
                    }
                    // A suppression that lost its race must NOT land: the user may have
                    // Reset in the meantime, and a late write would restore the very
                    // suppression they just cleared (Codex, PR #508). Threaded INTO the
                    // transition too, because it now performs its own Keychain read (the
                    // auto-recovery window) that a timeout can land inside (Codex, PR #569).
                    guard isStillWanted() else { return }
                    guard try store.recordChainedSurrender(
                        owningLifecycleID: owningLifecycleID,
                        reasonLogValue: surrender.rawValue, isStillWanted: isStillWanted)
                    else {
                        throw ChainedSurrenderPersistUnavailable()
                    }
                }
                // Only a RETURN means persisted: the bound throws on a refusal and on a
                // non-answering store alike, and the flag is set here rather than inside
                // the closure because that closure is `@Sendable` and runs off-queue.
                suppressionPersisted = true
            },
            restartIntoDNSOnly: {
                // Logged BEFORE the cancel, which kills this process: an async hop would
                // not survive it (the self-reconnect path's CON-1 reasoning).
                // Only confirmed durable suppression authorizes the next DNS-only lifecycle.
                // The generation fence prevents an older surrender overwriting an explicit start.
                if let markerURL = LavaSecAppGroup.chainedStartupFailureMarkerURL {
                    do {
                        let recorded = try ChainedStartupFailureMarker.record(
                            reason: surrender.markerReason(suppressionPersisted: suppressionPersisted),
                            generation: chainedStartupFailureMarkerGeneration,
                            storageURL: markerURL,
                            lockURL: LavaSecAppGroup.chainedStartupFailureMarkerLockURL)
                        if !recorded {
                            LavaSecDeviceDebugLog.append(
                                component: "tunnel", event: "chained-surrender-marker-stale",
                                details: ["reason": surrender.rawValue])
                        }
                    } catch {
                        // The provider still cancels below: the driver has already latched this
                        // lifecycle as surrendered, and staying up would leave the default
                        // route blackholed. A later automatic start fails closed whenever this
                        // durable marker write succeeds; if the lock itself is unavailable, the
                        // app's existing keychain suppression remains the second line of defence.
                        LavaSecDeviceDebugLog.append(
                            component: "tunnel", event: "chained-surrender-marker-write-failed",
                            details: ["reason": surrender.rawValue, "error": Self.errorSummary(error)])
                    }
                } else {
                    LavaSecDeviceDebugLog.append(
                        component: "tunnel", event: "chained-surrender-marker-url-missing",
                        details: ["reason": surrender.rawValue])
                }
                connectivitySignalNotifier.postNotification(
                    named: TunnelHealthSignal.darwinNotificationName)
                LavaSecDeviceDebugLog.append(component: "tunnel", event: "chained-surrendered", details: [
                    "reason": surrender.rawValue,
                    "suppressionPersisted": "\(suppressionPersisted)",
                    // WHICH arm surrendered — the reason is the generic `budgetExhausted` for both the
                    // link-silence and egress-dead causes, so these attribute it in the one event that
                    // is guaranteed to be logged (the 60 s liveness poll can miss the ~36 s window).
                    "outageCount": "\(counters.outageCount)",
                    "egressDeadOutageCount": "\(counters.egressDeadOutageCount)",
                    "tunnelDNSOutageCount": "\(counters.tunnelDNSOutageCount)",
                ])
                cancelTunnelWithError(nil)
            })
    }
}
