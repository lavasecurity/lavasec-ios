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
    // MARK: - Bootstrap host resolution broker (breaks the fail-closed deadlock)

    /// How many distinct hostnames one fail-closed window may broker.
    ///
    /// The repair needs the manifest host plus its blocklist sources — a handful. A cap keeps
    /// this from becoming a general-purpose resolver for a compromised container app, and it
    /// is per-window rather than per-hour so a genuine repair after a later outage is not
    /// starved by an earlier one.
    private static let maximumBrokeredBootstrapHostsPerFailClosedWindow = 8

    /// Resolve one hostname for the container app while the resident snapshot is fail-closed.
    ///
    /// 🔴 THIS DOES NOT SERVE DNS. `FailClosedRuntimeSnapshot` is untouched: every client on
    /// the device still receives the block-all answer for this hostname and every other. The
    /// addresses returned here travel the provider-message channel to the app process only,
    /// are never encoded by `DNSMessage`, never written to the utun, and are recorded in no
    /// Domain History entry or served-query counter. INV-DNS-1 constrains what the tunnel
    /// serves; this changes how the APP learns an address for its own HTTPS fetch, which the
    /// app then re-validates through its usual public-scope gate before connecting.
    func handleResolveBootstrapHostMessage(
        _ providerMessage: LavaSecProviderMessage,
        completion: AppMessageCompletion
    ) {
        let requestedHostname = providerMessage.payload?[LavaSecAppGroup.resolveBootstrapHostnameKey]
        dnsStateQueue.async { [weak self] in
            guard let self else {
                completion.complete(nil)
                return
            }

            func refuse(_ reason: String) {
                LavaSecDeviceDebugLog.append(
                    component: "tunnel", event: "bootstrap-broker-refused", details: ["reason": reason])
                completion.complete(nil)
            }

            // (1) ONLY while fail-closed. Outside that window the app's own resolver works,
            // so the deadlock this exists for does not exist and neither should the broker.
            guard self.isResidentFailClosedDueToUnavailableSnapshot() else {
                return refuse("not-fail-closed")
            }

            // (2) Exactly one hostname, and a real one. `DomainName.normalize` is the same
            // boundary the rest of the DNS path uses, so this cannot be handed a raw address
            // literal, an empty string, or a label that would not survive the wire.
            guard let requested = requestedHostname,
                let hostname = try? DomainName.normalize(requested)
            else {
                return refuse("invalid-hostname")
            }

            // (6) Bounded per window.
            if !self.brokeredBootstrapHostnames.contains(hostname),
                self.brokeredBootstrapHostnames.count
                    >= Self.maximumBrokeredBootstrapHostsPerFailClosedWindow
            {
                return refuse("window-cap")
            }

            // (3) WHICH WIRE. This must follow the same egress rule as every other query, and
            // the two modes take different paths:
            //
            //  - CHAINED: the query goes THROUGH the WireGuard upstream, like every other DNS
            //    while chained (S6). It must NOT go to the device resolvers — that is plain DNS
            //    on the physical interface, which is precisely the leak S6's merge bar forbids.
            //    `resolveDoQBootstrapAddresses` refuses for exactly this reason
            //    (`permitsPhysicalInterfaceDNS`), and the first version of this broker inherited
            //    that refusal and returned zero addresses on every chained device — correct, and
            //    useless.
            //  - DNS-ONLY: no tunnel to carry it, and the physical interface is where this
            //    device's DNS legitimately goes, so the device resolvers are right.
            // BRANCH ON THE LATCH, not on route availability. `currentTunnelledPlainDNSRoute()`
            // is also nil when the conf carries no usable `DNS =` line, and treating that as
            // "not chained" dropped into the device branch — whose `permitsPhysicalInterfaceDNS`
            // guard then returned ([], []). Four distinct causes all logged
            // `bootstrap-broker-resolved {ipv4Count: 0}`, which is the same undiagnosable shape
            // this whole investigation kept hitting. Each now refuses with its own reason.
            let chainedIsLatched = self.currentTunnelDataPathMode().isChainedUpstream
            let route = chainedIsLatched ? self.currentTunnelledPlainDNSRoute() : nil
            if chainedIsLatched, route == nil {
                return refuse("chained-no-route")
            }
            let deviceResolvers = chainedIsLatched
                ? []
                : self.orderedResolverAddressesForCurrentNetwork(
                    self.currentDeviceDNSResolverAddresses())
            if !chainedIsLatched, deviceResolvers.isEmpty {
                return refuse("no-device-resolvers")
            }

            // AFTER every refusal. A refused request used to burn a slot from a budget whose
            // only reset fires on the commit the broker exists to enable.
            self.brokeredBootstrapHostnames.insert(hostname)
            let windowHostCount = self.brokeredBootstrapHostnames.count
            let admittedAtEpoch = self.currentResolverAdmissionEpoch()

            // 🔴 INV-QUEUE-1: THE WIRE WORK LEAVES THIS QUEUE. Every branch below blocks in
            // `recvfrom`, and doing that while holding dnsStateQueue is the blocking coupling
            // the invariant exists to forbid (the provider says so itself at the resolveUDP
            // socket seam). It is not theoretical here: `replaceSnapshot` takes
            // `dnsStateQueue.sync` — that is the commit which ENDS fail-closed — so a broker
            // blocked on a dead peer head-of-line-blocks the very repair it was added to
            // enable, and `resolveUDP` re-enters the live-epoch read off-queue.
            // Everything queue-confined (the fail-closed gate, normalization, the cap, the
            // insert, the latch/route derivation, the epoch read) has already happened above;
            // only the syscalls move. `runBoundedResolverWork` also puts this under the same
            // concurrency bound as every other resolver query.
            let generation = self.currentResolverRuntimeGeneration()
            let lifetime = DNSResolutionLifetime(deadline: MonotonicDeadline(after: Self.resolverQueryLifetimeSeconds)) { [weak self] in
                guard let self else { return false }
                return self.resolverWorkIsCurrent(admittedAtEpoch: admittedAtEpoch, generation: generation)
            }
            self.runBoundedResolverWork(
                retainedBytes: hostname.utf8.count + 256, deadline: lifetime.deadline,
                discard: { completion.complete(LavaSecBootstrapHostResolution(ipv4: [], ipv6: []).encoded()) }
            ) { finish in
                let resolved: (ipv4: [String], ipv6: [String])
                if let route {
                    resolved = self.resolveBootstrapAddressesThroughTunnel(
                        for: hostname, route: route, lifetime: lifetime)
                } else {
                    resolved = self.resolveDoQBootstrapAddresses(
                        for: hostname,
                        resolverAddresses: deviceResolvers,
                        admittedAtEpoch: admittedAtEpoch, lifetime: lifetime)
                }

                guard lifetime.isAdmitted else {
                    completion.complete(LavaSecBootstrapHostResolution(ipv4: [], ipv6: []).encoded())
                    finish()
                    return
                }
                // (4) Addresses only.
                let reply = LavaSecBootstrapHostResolution(
                    ipv4: resolved.ipv4, ipv6: resolved.ipv6)
                // (5) The hostname is NOT logged: this path exists during a filtering outage,
                // and a blocklist source host is still a host the user asked for. Counts only.
                // `wire` distinguishes the two paths so a zero answer names which one produced
                // it — the distinction that was missing.
                LavaSecDeviceDebugLog.append(
                    component: "tunnel", event: "bootstrap-broker-resolved",
                    details: [
                        "ipv4Count": "\(reply.ipv4.count)",
                        "ipv6Count": "\(reply.ipv6.count)",
                        "windowHostCount": "\(windowHostCount)",
                        "wire": route == nil ? "device-dns" : "chained-tunnel",
                    ])
                // Client settlement is once-only; finish retires the separate underlying-work slot.
                // pinned: PacketTunnelDNSRuntimeSourceTests.testClientReplyAndWorkRetirementShareTheCompletionClaimPolicy
                completion.complete(reply.encoded())
                finish()
            }
        }
    }

    /// Emit whether the chained peer is actually ALIVE.
    ///
    /// 🔴 WHY THIS DID NOT EXIST AND HAD TO. The engine has always known — `WireGuardSession`
    /// `statistics()` carries `timeSinceLastHandshake` — but its ONLY consumer is an internal
    /// keypair-freshness guard in `ChainedSessionRunner`, and `ChainedOutageDriver`'s counters
    /// were never emitted either. So in the field a peer that never completed a handshake was
    /// INDISTINGUISHABLE from a working one: the latch reports `upstream-ready` (which means the
    /// configuration parsed and the key was readable, nothing more), the routes install, and the
    /// UI says on. A device audit found zero session/handshake/outage events over an entire
    /// session — 63 `loadSnapshot-compile-skipped-chained` and not one line about the peer.
    ///
    /// That is also why a DNS query brokered through the tunnel came back empty with no error
    /// anywhere: there was nothing to say the upstream never answered.
    ///
    /// Rides the EXISTING 60 s focus-poll tick — no new timer, and nothing on the DNS path.
    /// Counters only: no endpoint, no hostname, no peer key.
    func emitChainedSessionLivenessIfChained() {
        guard let runtime = chainedRuntime else { return }
        let counters = runtime.driver.snapshotCounters()
        let transport = runtime.transportDiagnostics.snapshotTallies()
        // QA-only diagnostic (#56): the engine's forwarding + handshake state, so a post-path-change
        // blind window can be read as either a STALLED tunnel (rx/tx flat, hasHandshake false — the
        // WG outer socket/handshake was not re-picked-up on the new interface) or a forwarding tunnel
        // whose DNS is late (rx/tx climbing, hasHandshake true — Lava's own resolver handling lags).
        let stats = runtime.driver.snapshotStatistics()
        LavaSecDeviceDebugLog.append(component: "tunnel", event: "chained-session-liveness", details: [
            // Self-heal diagnostics (field 2026-08-24): `isSuspended=true` on a liveness line means
            // the driver is dark (engine tick disarmed, detectors frozen) — pair against a `sleep`
            // with no `wake`. `selfHealResumeCount` climbing is the Focus-poll/packet self-heal
            // recovering an unpaired sleep instead of a manual re-chain.
            "isSuspended": "\(counters.isSuspended)",
            "selfHealResumeCount": "\(counters.selfHealResumeCount)",
            "outageCount": "\(counters.outageCount)",
            "startedAttemptCount": "\(counters.startedAttemptCount)",
            "sessionEndCount": "\(counters.sessionEndCount)",
            "stoodDownCount": "\(counters.stoodDownCount)",
            "offlinePathCount": "\(counters.offlinePathCount)",
            "pathRecoveryCount": "\(counters.pathRecoveryCount)",
            // Which recovery a path change actually took, so a post-roam DNS gap can be
            // attributed. `rebindCount` up with `outageCount` flat is the fast R2 socket swap
            // (keypair kept, ~one keepalive). `rebindReanchorRetryCount` up with
            // `rebindUnconfirmedCount` FLAT is the fix's win — a lost re-anchor absorbed by the
            // forced-handshake retry, no rebuild (PR #574); `rebindReanchorRetryCount` up AND
            // `rebindUnconfirmedCount`/`rebindDeclinedCount` up means even the retry missed and the
            // rebind fell back to the full rebuild (`outageCount` also climbs).
            // `coalescedPathRecoveryCount` up means a flap BURST deferred the socket recovery into
            // the settle window rather than a single clean roam recovering at once.
            "rebindCount": "\(counters.rebindCount)",
            "rebindDeclinedCount": "\(counters.rebindDeclinedCount)",
            "rebindUnconfirmedCount": "\(counters.rebindUnconfirmedCount)",
            "rebindReanchorRetryCount": "\(counters.rebindReanchorRetryCount)",
            "coalescedPathRecoveryCount": "\(counters.coalescedPathRecoveryCount)",
            // The decisive pair: DNS sent through the upstream vs DNS the upstream answered.
            // Answered == 0 with Unanswered > 0 is a peer that is not there, which is precisely
            // the state that used to be invisible.
            "tunnelDNSAnswered": "\(counters.tunnelDNSAnsweredObservationCount)",
            "tunnelDNSUnanswered": "\(counters.tunnelDNSUnansweredObservationCount)",
            "tunnelDNSOutageCount": "\(counters.tunnelDNSOutageCount)",
            // THE SPLIT-TUNNEL READING, and the line that separates two states the pair above
            // cannot: a high `tunnelDNSUnanswered` with THIS climbing is a T0 that answers only
            // its own namespace while the physical T1 rung serves the rest — the user has DNS.
            // The same shape with this at zero is a genuinely dead resolver. Before this counter
            // both read identically and the first surrendered a healthy session (field 2026-09-01).
            "tierOneRungRescues": "\(counters.tierOneRungRescueObservationCount)",
            // Attribution for the third arm: this advancing while `tunnelDNSOutageCount` stays flat,
            // with `rxBytes` climbing (keepalives) and `fwdNonDNSBytes` flat, is the egress-dead
            // signature — the surrender itself logs the generic `budgetExhausted` reason (PR #567).
            "egressDeadOutageCount": "\(counters.egressDeadOutageCount)",
            // The per-destination reading, which is the ONLY line here that can be non-zero while
            // every other one reads healthy — the 2026-08-27 split-tunnel capture exactly. Read it
            // against `fwdNonDNSBytes`: in split tunnel that figure includes DNS replies (PR #558
            // empties the resolver exclusion there), so `rxBytes == fwdNonDNSBytes` means the
            // forwarding number is DNS and proves nothing about the host the user wanted.
            "unansweredDests": "\(counters.unansweredDestinationCount)",
            "longestUnansweredSecs": "\(counters.longestUnansweredDestinationSeconds)",
            "hasHandshake": stats.map { "\($0.hasHandshake)" } ?? "nil",
            "txBytes": stats.map { "\($0.transmittedByteCount)" } ?? "nil",
            "rxBytes": stats.map { "\($0.receivedByteCount)" } ?? "nil",
            "fwdNonDNSBytes": stats.map { "\($0.forwardedNonDNSByteCount)" } ?? "nil",
            // Bounded aggregate input/admission evidence at the existing log cadence.
            // No destination or packet content; these counts never grant a protection claim.
            "outboundInputPackets": "\(counters.outboundInputPacketCount)",
            "outboundWithoutRunnerPackets": "\(counters.outboundWithoutRunnerPacketCount)",
            "dnsHandledPackets": "\(counters.dnsHandledPacketCount)",
            "malformedPackets": "\(counters.malformedPacketCount)",
            "unfilterableDNSPackets": "\(counters.unfilterableDNSPacketCount)",
            "unfilterableEncryptedDNSPackets": "\(counters.unfilterableEncryptedDNSPacketCount)",
            "droppedOutboundIPv6Packets": "\(counters.droppedIPv6Count)",
            "encapsulationAttempts": "\(counters.encapsulationAttemptCount)",
            // Brief-stall observability (2026-08-24): the data-path pressure and transport-
            // health tallies that were flat-invisible across a user-visible forwarding stall.
            // All monotonic across session rebuilds (the driver folds retired runners in), so
            // a window's delta is honest. `saturatedTicks` is duration; shed/refused are
            // volume; sendErrors is the completion Bool the runner used to discard; channel*
            // difference the transport observer's tallies.
            //
            // READ `saturatedTicks` AGAINST A CADENCE THAT IS NOT CONSTANT. It counts liveness
            // SAMPLES that found the send bound full, and the sampler runs at the established
            // 500 ms tick only OUTSIDE an outage — inside one it is `outageTickInterval`
            // (250 ms), so a window overlapping an outage converts to duration at up to 2x the
            // naive rate (and a path recovery can add or discard a sample). Multiply by 500 ms
            // for the ordinary case, check `outageCount` before trusting the number as seconds.

            "shedPackets": "\(counters.shedPacketCount)",
            "refusedOutboundBacklog": "\(counters.refusedOutboundBacklogPacketCount)",
            "refusedInboundBacklog": "\(counters.refusedInboundBacklogDatagramCount)",
            "sendErrors": "\(counters.sendCompletionErrorCount)",
            "saturatedTicks": "\(counters.saturatedTickCount)",
            "channelNotReady": "\(transport.stateNotReadyTransitionCount)",
            "channelUnviable": "\(transport.unviableTransitionCount)",
            "channelSendFailEdges": "\(transport.sendFailedEdgeCount)",
            "channelReceiveLoopEnds": "\(transport.receiveLoopEndedCount)",
            "pressureEvents": "\(transport.pressureEventCount)",
            // WHAT THE RATE BOUND HID, split by MECHANISM. The recorder tracks suppression
            // precisely so thinning is visible, and this — its only production consumer —
            // dropped the field, so a throttled storm vanished silently: recovery-side state
            // changes and `betterPathChanged` events have no tally of their own to reveal it.
            //
            // Two fields, not one: the recorder's total covers all kinds, so reporting it under
            // a channel-shaped name attributed a queue-PRESSURE storm to the NWConnection —
            // pointing a reader at the opposite mechanism (Codex P2, PR #582).
            "channelSuppressedLogs": "\(transport.suppressedTransportLogCount)",
            "pressureSuppressedLogs": "\(transport.suppressedPressureLogCount)",
        ])
    }

    /// PRODUCTION self-heal backstop for an unpaired iOS `sleep()` that left the chained driver
    /// suspended (see the call site in the Focus poll). `resumeIfSuspended()` is idempotent and
    /// self-guarding, so this is a cheap no-op whenever the driver is not suspended. The QA log line
    /// fires only when a suspended driver is actually found, so a device trace shows exactly when the
    /// backstop recovered a dark tunnel.
    func resumeChainedTunnelIfSuspended() {
        guard let runtime = chainedRuntime else { return }
        #if DEBUG || LAVA_QA_TOOLS
        if runtime.driver.snapshotCounters().isSuspended {
            LavaSecDeviceDebugLog.append(
                component: "tunnel", event: "chained-self-heal-resume",
                details: ["trigger": "focus-poll"])
        }
        #endif
        runtime.driver.resumeIfSuspended()
    }

    #if DEBUG || LAVA_QA_TOOLS
    /// Monotonic wall-independent milliseconds — immune to a wall-clock step during a roam,
    /// which is exactly when a `Date()`-based elapsed would lie.
    private func nowMonotonicMillis() -> Int {
        Int(DispatchTime.now().uptimeNanoseconds / 1_000_000)
    }

    /// Open (or re-open) the QA recovery-measurement window: stamp the start, capture the
    /// tunnel-DNS answered/unanswered baselines, and start the fast sampling cadence. A re-open
    /// (a second path change before the first settled) re-stamps onto the newer event, which is
    /// the one whose recovery we now care about. dnsStateQueue-confined.
    func openChainedRecoveryWindow(reason: String) {
        dispatchPrecondition(condition: .onQueue(dnsStateQueue))
        guard let runtime = chainedRuntime else { return }
        let counters = runtime.driver.snapshotCounters()
        // Bump the serial FIRST: any tick still pending from a previous (possibly coarse-cadence)
        // window now carries a stale serial and no-ops, so this window schedules a fresh FINE tick
        // rather than being gated by the old callback (Codex, PR #575).
        chainedRecoveryWindowSerial &+= 1
        chainedRecoveryWindowStartedAtMillis = nowMonotonicMillis()
        chainedRecoveryWindowReason = reason
        chainedRecoveryWindowBaselineAnswered = counters.tunnelDNSAnsweredObservationCount
        chainedRecoveryWindowBaselineUnanswered = counters.tunnelDNSUnansweredObservationCount
        chainedRecoveryFirstAnswerAtMillis = nil
        chainedRecoveryUnansweredBeforeFirstAnswer = nil
        // The deltas restart from this window's baselines, so the previous window's tally would
        // read as evidence that preceded THIS window's first answer.
        chainedRecoveryUnansweredAtPreviousSample = 0
        LavaSecDeviceDebugLog.append(component: "tunnel", event: "chained-recovery", details: [
            "phase": "begin",
            "reason": reason,
        ])
        scheduleChainedRecoveryFastTick()
    }

    private func scheduleChainedRecoveryFastTick() {
        dispatchPrecondition(condition: .onQueue(dnsStateQueue))
        guard let startedAt = chainedRecoveryWindowStartedAtMillis else { return }
        // Capture the serial so a window (re)opened before this fires cancels it — the fire guard
        // rejects a stale serial, which also stops a stale chain from rescheduling itself.
        let serial = chainedRecoveryWindowSerial
        // Fine while young, coarse once the sub-second edge is behind us — computed from the
        // elapsed AT SCHEDULE TIME so the cadence steps down without a second timer.
        let elapsed = nowMonotonicMillis() - startedAt
        let ms = elapsed < Self.chainedRecoveryFineUntilMillis
            ? Self.chainedRecoveryFineTickMillis : Self.chainedRecoveryCoarseTickMillis
        dnsStateQueue.asyncAfter(deadline: .now() + .milliseconds(ms)) { [weak self] in
            guard let self, serial == self.chainedRecoveryWindowSerial else { return }
            self.fireChainedRecoveryFastTickIfOpen()
        }
    }

    /// One recovery-window sample: emit the driver's liveness plus `elapsedMs`, the deltas since
    /// the window opened (`dnsAnsΔ`/`dnsUnansΔ`), and `firstAnswerMs` — and, for a session that
    /// dies before the 60 s liveness line can carry them, the ladder counters and the TRANSPORT
    /// recorder's tallies, which are not the driver's liveness and are snapshotted separately.
    /// It records the first
    /// answer's elapsed but does NOT close on it — it keeps sampling a tail window past it so a
    /// post-recovery timeout tail (queries still failing after the first success — the "patchy"
    /// shape) is visible. Closes `phase=settled` a fixed tail past the first answer, or
    /// `phase=capped` if no answer ever lands inside the cap. dnsStateQueue-confined.
    private func fireChainedRecoveryFastTickIfOpen() {
        dispatchPrecondition(condition: .onQueue(dnsStateQueue))
        guard let startedAt = chainedRecoveryWindowStartedAtMillis,
              let runtime = chainedRuntime else {
            chainedRecoveryWindowStartedAtMillis = nil
            return
        }
        let elapsed = nowMonotonicMillis() - startedAt
        let counters = runtime.driver.snapshotCounters()
        let stats = runtime.driver.snapshotStatistics()
        let transport = runtime.transportDiagnostics.snapshotTallies()
        let ansDelta = counters.tunnelDNSAnsweredObservationCount - chainedRecoveryWindowBaselineAnswered
        let unansDelta =
            counters.tunnelDNSUnansweredObservationCount - chainedRecoveryWindowBaselineUnanswered
        var justFirstAnswered = false
        if ansDelta > 0, chainedRecoveryFirstAnswerAtMillis == nil {
            chainedRecoveryFirstAnswerAtMillis = elapsed
            // WHETHER `firstAnswerMs` MEASURES RECOVERY AT ALL, stamped at the only moment it can
            // be known. Neither opening site issues a probe, so an idle window advances elapsed
            // while nothing is being asked, and the next organic query's answer books the whole
            // idle wait as recovery — a healthy tunnel reading as a multi-second stall, which is
            // precisely the shape this instrumentation exists to find (Codex, PR #575).
            //
            // A query that went unanswered BEFORE the first answer is the evidence that the
            // tunnel was actually being asked and actually failing. With none, the elapsed is
            // dominated by waiting for traffic and says nothing about the tunnel.
            //
            // 🔴 The PREVIOUS sample's tally, never THIS one's. Counters give totals, not order,
            // and both events can land inside one sampling interval: the coarse cadence is 1500 ms
            // and `udpDNSTimeoutSeconds` is 1, so a burst can answer fast and then time out a
            // DIFFERENT query before the next tick. Reading the current tally there sees
            // `unansDelta > 0` and calls the sample anchored, when the failure it counted happened
            // AFTER the answer — the idle interval smuggled back in under a trusted flag, which is
            // worse than the unqualified number this replaced (Codex, PR #575).
            //
            // Anything counted at or before the previous sample strictly precedes this interval,
            // and the answer landed inside it — so the ordering holds by construction rather than
            // by assumption. It UNDER-counts (a failure earlier in this same interval is missed),
            // and that is the direction to be wrong in: an unanchored sample is dropped from the
            // experiment, never mistaken for a stall.
            chainedRecoveryUnansweredBeforeFirstAnswer = chainedRecoveryUnansweredAtPreviousSample
            justFirstAnswered = true
        }
        let cappedByTime = elapsed >= Self.chainedRecoveryWindowCapMillis
        let settled = chainedRecoveryFirstAnswerAtMillis
            .map { elapsed - $0 >= Self.chainedRecoveryTailMillis } ?? false
        let closing = cappedByTime || settled
        let phase: String
        if closing {
            // `idle` is NOT `capped`. Capped reads as "the tunnel never came back"; with nothing
            // asked in the whole window there is no such claim to make, and reporting one would
            // manufacture an outage out of a quiet device.
            if chainedRecoveryFirstAnswerAtMillis != nil {
                phase = "settled"
            } else {
                phase = unansDelta == 0 ? "idle" : "capped"
            }
        } else {
            phase = justFirstAnswered ? "first-answer" : "sample"
        }
        LavaSecDeviceDebugLog.append(component: "tunnel", event: "chained-recovery", details: [
            "phase": phase,
            "reason": chainedRecoveryWindowReason,
            "elapsedMs": "\(elapsed)",
            "firstAnswerMs": chainedRecoveryFirstAnswerAtMillis.map { "\($0)" } ?? "nil",
            // Read `firstAnswerMs` ONLY when this is true. See the stamp above: false means the
            // window was idle and the elapsed measures the wait for traffic, not the tunnel.
            "anchored": chainedRecoveryUnansweredBeforeFirstAnswer.map { "\($0 > 0)" } ?? "nil",
            "dnsAnsD": "\(ansDelta)",
            "dnsUnansD": "\(unansDelta)",
            "hasHandshake": stats.map { "\($0.hasHandshake)" } ?? "nil",
            "rxBytes": stats.map { "\($0.receivedByteCount)" } ?? "nil",
            "txBytes": stats.map { "\($0.transmittedByteCount)" } ?? "nil",
            "fwdNonDNSBytes": stats.map { "\($0.forwardedNonDNSByteCount)" } ?? "nil",
            // Bounded aggregate input/admission evidence at the existing log cadence.
            // No destination or packet content; these counts never grant a protection claim.
            "outboundInputPackets": "\(counters.outboundInputPacketCount)",
            "outboundWithoutRunnerPackets": "\(counters.outboundWithoutRunnerPacketCount)",
            "dnsHandledPackets": "\(counters.dnsHandledPacketCount)",
            "malformedPackets": "\(counters.malformedPacketCount)",
            "unfilterableDNSPackets": "\(counters.unfilterableDNSPacketCount)",
            "unfilterableEncryptedDNSPackets": "\(counters.unfilterableEncryptedDNSPacketCount)",
            "droppedOutboundIPv6Packets": "\(counters.droppedIPv6Count)",
            "encapsulationAttempts": "\(counters.encapsulationAttemptCount)",
            "rebindCount": "\(counters.rebindCount)",
            "rebindReanchorRetryCount": "\(counters.rebindReanchorRetryCount)",
            "outageCount": "\(counters.outageCount)",
            // WHY A DARK SESSION IS DARK, at the cadence that can still see it.
            //
            // A session that never comes up reads identically at this sample whether the retry
            // ladder is rebuilding it once a rung or sitting on ONE inert session:
            // `hasHandshake=false` with `txBytes=0` for the whole window, and nothing emitted
            // here said which. A field log from 2026-08-25 carried seven such windows — ~30 s of
            // zero-tx samples each ending in `chained-surrendered budgetExhausted` — and the
            // question could not be answered from the export at all, because these counters
            // reached it ONLY on the 60 s `chained-session-liveness` line, which a session that
            // dies at ~30 s never emits.
            //
            // The branch point. A climbing `startedAttemptCount` with `sessionEndCount` behind it
            // means the ladder is building sessions that die — a build or handshake fault. Both
            // flat at one means a single session sat inert.
            //
            // `sendToPeer` is what makes the inert case READABLE, and the first version of this
            // block was wrong without it: `channelNotReady` counts transitions INTO
            // `waiting`/`failed` so a socket that reached `ready` never moves it,
            // `channelSendFailEdges` counts failure edges so successful sends never move it, and
            // `txBytes` is PLAINTEXT accepted for encapsulation — which a handshake initiation is
            // not. All three sit flat whether the engine emitted initiations nobody answered or
            // emitted nothing at all, so the sample could not tell those apart (Codex, PR #585).
            // A climbing `sendToPeer` with a flat `hasHandshake` is a peer that is not replying;
            // `sendToPeer` flat at zero is an engine that produced nothing, and the channel
            // tallies then say whether the socket was the reason.
            //
            // `saturatedTicks` closes the third case, which the other five still could not name:
            // a channel that stays `ready` and simply stops calling completions parks the runner
            // at its in-flight bound, so `sendToPeer` RISES AND THEN GOES FLAT (it is counted at
            // submission, not completion) while `channelNotReady` and `channelSendFailEdges` both
            // stay zero — a local transport wedge wearing the shape of a silent peer. The counter
            // already records exactly that, sampled at tick cadence so its delta reads as wedge
            // DURATION, and it was stranded on the same 60 s line as the rest (Codex, PR #585).
            //
            // Every key here but `sendToPeer` was already allowlisted for export (`saturatedTicks`
            // included, from the liveness line); `sendToPeer`
            // is added to `BugReportBundle`'s chained block in the same diff, and it is a COUNT
            // of datagrams — no address, no payload, no name — so it meets that block's stated
            // bar rather than widening what a shareable bundle may carry.
            // pinned: ChainedRecoveryWindowSourceTests.testASampleSaysWhetherTheLadderIsRebuildingOrSittingOnOneDeadSession
            // pinned: ChainedRecoveryWindowSourceTests.testASampleSeparatesADeadSocketFromASilentEngine
            "startedAttemptCount": "\(counters.startedAttemptCount)",
            "sessionEndCount": "\(counters.sessionEndCount)",
            "stoodDownCount": "\(counters.stoodDownCount)",
            "sendToPeer": "\(counters.sendToPeerCount)",
            "saturatedTicks": "\(counters.saturatedTickCount)",
            "channelNotReady": "\(transport.stateNotReadyTransitionCount)",
            "channelSendFailEdges": "\(transport.sendFailedEdgeCount)",
            // The window can cap before the next 60 s liveness line, so keep rate-bound storms
            // visible here too, split by mechanism rather than through the all-kinds total.
            // pinned: ChainedRecoveryWindowSourceTests.testARecoverySampleReportsWhatTheRateBoundSuppressedBeforeSixtySeconds
            "channelSuppressedLogs": "\(transport.suppressedTransportLogCount)",
            "pressureSuppressedLogs": "\(transport.suppressedPressureLogCount)",
        ])
        // AFTER the stamp above reads it, so this tick's own arrivals never count as preceding
        // this tick's first answer. This is what makes the ordering structural.
        chainedRecoveryUnansweredAtPreviousSample = unansDelta
        if closing {
            chainedRecoveryWindowStartedAtMillis = nil
        } else {
            scheduleChainedRecoveryFastTick()
        }
    }
    #endif

    /// Copies a chained driver counter snapshot into `health`. Shared by the focus-tick / start /
    /// flush mirror and the stop-time final sample, so every writer uses the SAME mapping.
    ///
    /// 🔴 `chainedLinkOutageCount` comes from `offlinePathCount` (the network path went offline),
    /// NOT `outageCount`: the driver documents `tunnelDNSOutageCount` as a subset of
    /// `outageCount`, so sourcing "link outages" from the total would make it climb for DNS-only
    /// failures while the link is healthy (Codex, PR #551). Callers hold `dnsStateQueue`.
    func applyChainedDriverCounters(_ counters: ChainedDriverCounters) {
        health.chainedTunnelDNSAnsweredCount = counters.tunnelDNSAnsweredObservationCount
        health.chainedTunnelDNSUnansweredCount = counters.tunnelDNSUnansweredObservationCount
        health.chainedTunnelDNSOutageCount = counters.tunnelDNSOutageCount
        health.chainedLinkOutageCount = counters.offlinePathCount
        // LEVELS, not tallies, and the driver already assigns rather than accumulates them from the
        // live runner — so this mirror is a plain copy. Zero and zero is the healthy reading, and it
        // is also what a DNS-only or torn-down session leaves behind, which is honest: with no chain
        // nobody is waiting on anything through one.
        health.chainedUnansweredDestinationCount = counters.unansweredDestinationCount
        health.chainedLongestUnansweredDestinationSeconds =
            counters.longestUnansweredDestinationSeconds
    }

    /// The rotation the LIVE runner is running, or `0` when nothing is running one.
    ///
    /// ONE SNAPSHOT ANSWERS BOTH QUESTIONS, and it has to. The generation is stamped onto the
    /// runner at construction, so `snapshotStatistics()` returning non-nil IS the evidence that a
    /// session adopted it — read on the engine queue, in a single hop. A two-read version was
    /// rejected: between "does a runner exist" and "what generation did the last read see", the
    /// engine queue can retire the runner and start a failing build, so a generation nothing was
    /// running could be published (Codex P2, PR #613).
    ///
    /// NO FALLBACK TO THE LATCH, and that removal is a fix rather than a simplification. Falling
    /// back republished the STARTUP latch whenever a runner was momentarily absent — so after a
    /// key-only rotation from A to B had already been adopted, any outage that retired runner B
    /// resurrected A, and the panel told the user to restart for a configuration the engine had
    /// adopted rounds ago. Runnerless publishes `0` instead, which the freshness policy reads as
    /// "no chained session" and renders as silence: while nothing is running there is no running
    /// rotation to be stale, and saying nothing is the only answer that is true in every case
    /// (Codex P2, PR #613).
    ///
    /// The hop is the one the mirror already makes for `snapshotCounters()` a few lines below.
    /// pinned: TunnelDataPathLatchSourceTests.testAFailedRebuildDoesNotPublishTheRotationItRead
    func runningChainedUpstreamGeneration() -> UInt64 {
        // Non-chained publishes none, so a rotation can never outlive the session that ran it —
        // the same rule every other chained field in the snapshot follows.
        guard tunnelLifecycleIsActive, currentTunnelDataPathMode().isChainedUpstream else {
            return 0
        }
        return chainedRuntime?.driver.acceptedUpstreamGeneration() ?? 0
    }

    func mirrorChainedHealthCountersIfChanged() {
        // Gated on the lifecycle being ACTIVE, not just the latch: `latchedDataPathMode` stays
        // chained through teardown, so a `flushTunnelHealthMessage` racing a stop would otherwise
        // re-set the flag true right after the stop cleanup cleared it (Kilo, PR #551). Once the
        // lifecycle is invalidated, the mirror reports DNS-only.
        let chained = tunnelLifecycleIsActive && currentTunnelDataPathMode().isChainedUpstream
        let before = chainedMirrorFingerprint()
        health.isChainedUpstreamActive = chained
        if chained, let counters = chainedRuntime?.driver.snapshotCounters() {
            applyChainedDriverCounters(counters)
        }
        // THE REPUBLICATION THAT BEATS `resetHealth()`. This call is already enqueued after the
        // reset for the chained flag's sake — the comment at its call site in `startTunnel` says
        // so — and the rotation identity has the same need for the same reason. It also picks up
        // a generation a REBUILD accepted, which is the only way that value ever reaches `health`.
        // Non-chained sessions publish `0`, so a stale rotation can never outlive its session.
        health.runningChainedUpstreamGeneration = runningChainedUpstreamGeneration()
        if before != chainedMirrorFingerprint() {
            markHealthCountersUpdated()
        }
    }

    /// Everything ``mirrorChainedHealthCountersIfChanged`` writes, as one comparable value.
    ///
    /// An ARRAY rather than the tuple this used to be: the standard library only synthesises `==`
    /// for tuples up to six elements, so adding the reachability pair to a five-element tuple would
    /// not have compiled. Every field this mirror writes must appear here — a field left out is a
    /// change that never persists, which is silent rather than loud. dnsStateQueue-confined, like
    /// its caller and every other `health` read.
    private func chainedMirrorFingerprint() -> [Int] {
        [
            health.isChainedUpstreamActive ? 1 : 0,
            health.chainedTunnelDNSAnsweredCount,
            health.chainedTunnelDNSUnansweredCount,
            health.chainedTunnelDNSOutageCount,
            health.chainedLinkOutageCount,
            health.chainedUnansweredDestinationCount,
            health.chainedLongestUnansweredDestinationSeconds,
            // The rotation identity, because this mirror now writes it and the rule above is
            // absolute: a field left out is a change that never persists. `truncatingIfNeeded`
            // because this is a change DETECTOR, not the value — two generations that collide
            // modulo `Int` would have to be 2^64 apart in one session.
            Int(truncatingIfNeeded: health.runningChainedUpstreamGeneration),
        ]
    }

    /// Samples the chained engine's transport byte totals ON THE FOCUS TICK and differences them
    /// against the prior sample into the health snapshot's ~60 s transmit/receive window (Slice C).
    ///
    /// The FOCUS TICK, not the shared mirror above: that mirror runs at start/flush/stop too, and a
    /// window delta is only meaningful at the poll's fixed ~60 s cadence. Surface-only telemetry —
    /// `DataPathHealth` reads this window to spot a peer that stays reachable but stops forwarding,
    /// but nothing here acts on it. dnsStateQueue-confined; persists only on change, like the mirror.
    /// The current chained handshake state for the app's prompt query — reads the live engine
    /// handshake via the driver (engine-queue-confined inside `snapshotStatistics()`) and advances
    /// the per-generation "ever handshaked" latch so the app can tell establishing from an expired
    /// session. dnsStateQueue-confined (the latch is dnsStateQueue state). `isChained` is false only
    /// in genuine DNS-only / inactive mode; a latched chained lifecycle between runners keeps its
    /// identity but reports conservative false/zero evidence. (Kilo #556)
    func currentChainedHandshakeState()
        -> (
            isChained: Bool, hasHandshake: Bool, everHandshaked: Bool, receivedByteCount: UInt64,
            sessionGeneration: UInt64, transportGeneration: UInt64, setupReady: Bool,
            providerLifecycleID: String?, verificationEpoch: UInt64?, forwardingBaseline: UInt64,
            runtimeCondition: ChainedRuntimeCondition
        ) {
        let isChained = tunnelLifecycleIsActive && currentTunnelDataPathMode().isChainedUpstream
        guard isChained else {
            chainedSessionEverHandshaked = false
            chainedHandshakeLatchGeneration = 0
            return (false, false, false, 0, 0, 0, false, nil, nil, 0,
                tunnelLifecycleIsActive ? .normal : .retired)
        }
        let evidence = chainedRuntime?.driver.snapshotStatusEvidence()
        guard let stats = evidence?.statistics else {
            // The outage ladder intentionally has gaps with no live runner. Runtime identity comes
            // from the lifecycle latch, not optional engine statistics: reporting DNS-only here
            // lets the app confirm the chain with zero forwarded bytes. Generation 0 is the wire
            // marker for "latched chained, no current session"; retain the internal per-session
            // latch until a real replacement generation arrives, but expose no session evidence.
            return (true, false, false, 0, 0, 0, false,
                latchedChainedLifecycleEvidenceID, evidence?.verificationEpoch, 0,
                evidence?.runtimeCondition ?? .recovering)
        }
        // A new session (generation bump) starts NOT-yet-handshaked, and the engine's handshake +
        // byte totals reset with it (Slice C / PR #554), so the latch must reset too — otherwise a
        // prior session's success would mask a fresh, still-establishing one as "already connected".
        if stats.sessionGeneration != chainedHandshakeLatchGeneration {
            chainedHandshakeLatchGeneration = stats.sessionGeneration
            chainedSessionEverHandshaked = false
        }
        if stats.hasHandshake { chainedSessionEverHandshaked = true }
        // Status queries never trigger the QA leak canary. Its existing Focus tick remains
        // authoritative; a prompt read must not manufacture traffic while verifying evidence.
        // The connect gate's real "connected" signal: bytes the chain forwarded from the internet
        // EXCLUDING its own DNS replies (`forwardedNonDNSByteCount`), because a chained endpoint can
        // handshake AND answer its own resolver while forwarding nothing else — which showed
        // "Protected" over a chain whose exit was still the ISP / that only relayed DNS (founder
        // dogfood + Codex, PR #558). Counting DNS-reply bytes would let such a chain confirm; counting
        // only non-resolver-sourced bytes means genuine general traffic must flow first (in full tunnel;
        // split tunnel excludes nothing — general traffic bypasses the NE there). Reported RAW
        // (cumulative-within-transport + its session generation) — the FORWARDING decision belongs to
        // the gate, which differences it since the connect began and re-anchors on a generation change.
        // Cannot be manufactured without the peer relaying real traffic, so the gate cannot claim
        // "Protected" without it — it resolves UNCONFIRMED instead, and PR #629 made that a surface
        // rather than the teardown it used to be: on a split tunnel an idle tailnet produces zero
        // here on a perfectly healthy chain, and turning the user's filtering off for it destroyed
        // working protection three times on device (2026-08-30). The
        // runner resets it to 0 on a new session AND on a channel rebind, so it is always evidence from
        // the LIVE transport. Both identities travel with it: a new transport's first positive sample
        // is already proof, even when smaller than the previous transport's cumulative total.
        return (
            true, stats.hasHandshake, chainedSessionEverHandshaked, stats.forwardedNonDNSByteCount,
            stats.sessionGeneration, stats.transportGeneration, stats.setupReady && tunnelStartupDidComplete,
            latchedChainedLifecycleEvidenceID, stats.verificationEpoch, stats.forwardingBaseline,
            stats.runtimeCondition
        )
    }

    func sampleChainedDataPathWindowOnTick() {
        let chained = tunnelLifecycleIsActive && currentTunnelDataPathMode().isChainedUpstream
        let before = (
            health.chainedDataPathTransmitWindowBytes,
            health.chainedDataPathReceiveWindowBytes,
            health.chainedDataPathHasHandshake
        )
        guard chained, let current = chainedRuntime?.driver.snapshotStatistics() else {
            // DNS-only, or no session to read: clear the window and DROP the baseline so a stale
            // window can never linger and the next chained session starts a fresh delta.
            health.chainedDataPathTransmitWindowBytes = 0
            health.chainedDataPathReceiveWindowBytes = 0
            health.chainedDataPathHasHandshake = false
            lastChainedDataPathStatsSample = nil
            if before != (0, 0, false) { markHealthCountersUpdated() }
            return
        }
        // A window is only meaningful between two samples of the SAME session. The driver's
        // `sessionGeneration` is the reliable identity: the engine's byte totals reset when a session
        // is rebuilt, and the replacement can accumulate PAST the old total within one window, so a
        // byte-monotonicity check alone would mis-difference across that boundary (Codex, PR #554).
        // The `>=` guards stay as defense in depth against a same-generation counter regression.
        if let prior = lastChainedDataPathStatsSample,
            prior.sessionGeneration == current.sessionGeneration,
            prior.hasHandshake, current.hasHandshake,
            current.transmittedByteCount >= prior.transmittedByteCount,
            current.receivedByteCount >= prior.receivedByteCount {
            health.chainedDataPathTransmitWindowBytes =
                current.transmittedByteCount - prior.transmittedByteCount
            health.chainedDataPathReceiveWindowBytes =
                current.receivedByteCount - prior.receivedByteCount
        } else {
            health.chainedDataPathTransmitWindowBytes = 0
            health.chainedDataPathReceiveWindowBytes = 0
        }
        health.chainedDataPathHasHandshake = current.hasHandshake
        lastChainedDataPathStatsSample = current
        let after = (
            health.chainedDataPathTransmitWindowBytes,
            health.chainedDataPathReceiveWindowBytes,
            health.chainedDataPathHasHandshake
        )
        if before != after { markHealthCountersUpdated() }
    }

    /// A + AAAA for `hostname` sent THROUGH the chained upstream, never on the physical
    /// interface.
    ///
    /// Same shape as `resolveDoQBootstrapAddresses`, but over `resolveTunnelledPlainDNS`, which
    /// is the route every other DNS takes while chained. That is what makes this leak-free: the
    /// packets are encapsulated to the WireGuard peer exactly like a user's query, so nothing
    /// about this lookup is observable to the local network that would not already be.
    private func resolveBootstrapAddressesThroughTunnel(
        for hostname: String,
        route: ResolverOrchestrator.TunnelledPlainDNSRoute,
        lifetime: DNSResolutionLifetime? = nil
    ) -> (ipv4: [String], ipv6: [String]) {
        func addresses(_ recordType: DNSRecordType) -> [String] {
            let query = DNSResolverSmokeProbe.query(
                transactionID: UInt16.random(in: 0...UInt16.max),
                domain: hostname,
                recordType: recordType.rawValue
            )
            let result = resolveTunnelledPlainDNS(query, route: route, lifetime: lifetime)
            return DNSBootstrapAddressExtractor.addresses(
                from: result.response, matching: query, recordType: recordType)
        }
        return (ipv4: addresses(.a), ipv6: addresses(.aaaa))
    }

    /// Forget the current window's brokered hostnames. Called when the tunnel adopts a real
    /// snapshot — the broker's whole purpose is to make this happen, so the budget resets with
    /// it rather than persisting into a healthy session.
    func resetBrokeredBootstrapHostnames() {
        dispatchPrecondition(condition: .onQueue(dnsStateQueue))
        guard !brokeredBootstrapHostnames.isEmpty else { return }
        brokeredBootstrapHostnames.removeAll()
    }

    /// The same reset, callable from a queue that is not `dnsStateQueue`.
    ///
    /// 🔴 WHY EVERY EXIT FROM THE WINDOW MUST CALL THIS. The budget is documented as
    /// PER-WINDOW, so "a genuine repair after a later outage is not starved by an earlier
    /// one". A commit that leaves fail-closed was the only reset — but it is not the only
    /// way the window ends. `startTunnel` clears
    /// `residentFailClosedDueToUnavailableSnapshot` directly on a same-instance restart, and
    /// so does `clearResidentFailClosedDueToUnavailableSnapshot`. Either path opened a
    /// SECOND window still holding the FIRST window's hostname set.
    ///
    /// That is not a cosmetic leak. The cap refuses a hostname not already in the set once
    /// the count reaches the maximum, so a configuration with more distinct source hostnames
    /// than the cap could never fetch the last of them in any later window FOR THE LIFE OF
    /// THE PROCESS — the only reset was a successful commit, which needs the very fetch the
    /// cap refuses.
    ///
    /// Scope, stated precisely because an earlier draft of this comment overstated it: the
    /// set is an INSTANCE property, so only a SAME-INSTANCE restart inherits it. A fresh
    /// extension process starts empty, which is why toggling protection off and on did break
    /// the outage in the field.
    ///
    /// `async` rather than `sync` is an ORDERING choice, not a prohibition — `startTunnel`'s
    /// own `loadInitialSharedState` does `dnsStateQueue.sync` a few lines from the call site
    /// and argues correctly that it cannot deadlock. Async is used because it is sufficient:
    /// a reset landing slightly late can only widen the new window's budget, never starve it,
    /// and no hostname can be brokered before `setTunnelNetworkSettings` completes anyway.
    func resetBrokeredBootstrapHostnamesFromAnyQueue() {
        if DispatchQueue.getSpecific(key: dnsStateQueueSpecificKey) == true {
            resetBrokeredBootstrapHostnames()
        } else {
            dnsStateQueue.async { [weak self] in
                self?.resetBrokeredBootstrapHostnames()
            }
        }
    }

    // Reattached by the file split: this contract documents the timer below, but sat under an
    // empty `// MARK: - Periodic resolver smoke probe` header on `main` with no declaration
    // beneath it, so the split carried it into a file that has no smoke probe in it at all.
    /// DESIGN / ENERGY TRADE-OFF (NRG — deferred, no behavior change here):
    /// This repeating timer is the ONE periodic that issues a real upstream DNS wire
    /// query on its cadence, so it is the most expensive steady-state probe: every
    /// 300 s it can wake the radio. It CANNOT be made purely event-driven: its entire
    /// purpose is to catch a resolver that went SILENTLY dead while there is no
    /// organic traffic to prove otherwise — an idle tunnel has no other signal. The
    /// cadence (300 s) is deliberately the "honesty budget" and stays fixed; lowering
    /// it widens blind-spot windows and raising it costs more energy for no gain.
    ///
    /// The energy cost is already mitigated by NRG-3a: `scheduleResolverSmokeProbe-
    /// IfNeeded` SKIPS the wire query when acceptance-checked primary evidence
    /// (a probe success or an organic primary answer passing the SAME acceptance
    /// check) is younger than one interval — so under live browsing the timer still
    /// fires (a CPU wake) but the radio wake is suppressed. The residual cost is one
    /// CPU wake + skip-predicate evaluation per 300 s on an idle-but-healthy tunnel;
    /// the 30 s leeway lets the kernel coalesce it. A future change must keep the
    /// cadence as the honesty budget and must NOT let skip evidence come from a
    /// merely-resolved reply (a hijacking resolver's REFUSED/SERVFAIL stamps those —
    /// the LAV-87 suppression regression), nor survive a resolver-runtime reset.
    ///
    /// (Honesty note, review 2026-07-05: two directions on the residual. SMALLER —
    /// the 30 s leeway already coalesces much of the idle radio wake into other
    /// activity, so the true marginal cost is below the naive one-wake-per-300 s.
    /// LARGER — a periodic-probe SUCCESS deliberately does NOT refresh the
    /// accepted-primary evidence stamp (only organic traffic does), so a
    /// steadily-idle-but-healthy tunnel keeps probing at full cadence and each probe
    /// pays a COLD handshake, not a warm round-trip; an always-cellular-all-day-idle
    /// phone is the only cohort where this is non-trivial. The one tweak that trims
    /// idle radio energy WITHOUT widening the dead-resolver window is widening this
    /// timer's leeway — measure the coalesced idle cost on-device before changing
    /// even that. NRG-3a already captured the main (live-traffic) win.)
    func startPeriodicResolverSmokeProbe() {
        guard DispatchQueue.getSpecific(key: dnsStateQueueSpecificKey) == true else {
            dnsStateQueue.async { [weak self] in
                self?.startPeriodicResolverSmokeProbe()
            }
            return
        }

        // Never armed while chained (C3). The latch is fixed for the session, so this timer
        // would wake the extension every 300 s for the whole session to run a handler whose
        // chained guard returns immediately — the physical-interface resolver is not the
        // path in use, and chained health is measured by the outage supervisor from tunnel
        // traffic instead. The scheduler's own guard stays as the backstop for every
        // non-periodic reason.
        // pinned: TunnelDataPathLatchSourceTests.testTheProbeTimersAreNotArmedWhileChained
        guard permitsPhysicalInterfaceDNS() else { return }

        resolverSmokeProbeTimer?.cancel()

        let timer = DispatchSource.makeTimerSource(queue: dnsStateQueue)
        // 10% leeway: nothing gates on tick phase, so let the kernel coalesce this wake
        // with other system activity instead of forcing a strict lone wake every 300 s.
        // The cadence itself is the honesty budget and stays untouched.
        timer.schedule(
            deadline: .now() + Self.resolverSmokeProbeInterval,
            repeating: Self.resolverSmokeProbeInterval,
            leeway: .seconds(30)
        )
        timer.setEventHandler { [weak self] in
            self?.scheduleResolverSmokeProbeIfNeeded(reason: "periodic-health-check")
        }
        resolverSmokeProbeTimer = timer
        timer.resume()
    }

    func stopPeriodicResolverSmokeProbe() {
        guard DispatchQueue.getSpecific(key: dnsStateQueueSpecificKey) == true else {
            dnsStateQueue.async { [weak self] in
                self?.stopPeriodicResolverSmokeProbe()
            }
            return
        }

        resolverSmokeProbeTimer?.cancel()
        resolverSmokeProbeTimer = nil
    }
}
