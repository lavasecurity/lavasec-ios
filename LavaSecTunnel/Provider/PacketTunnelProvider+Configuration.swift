@preconcurrency import ActivityKit
import Foundation
import Darwin
import os
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
    // MARK: - Configuration & device-DNS state accessors

    func currentNetworkKind() -> TunnelNetworkKind {
        if DispatchQueue.getSpecific(key: dnsStateQueueSpecificKey) == true {
            return networkKind
        }

        return dnsStateQueue.sync {
            networkKind
        }
    }

    func currentDeviceDNSResolverAddresses() -> [String] {
        if DispatchQueue.getSpecific(key: dnsStateQueueSpecificKey) == true {
            return deviceDNSResolverAddresses
        }

        return dnsStateQueue.sync {
            deviceDNSResolverAddresses
        }
    }

    /// The live primary physical interface index, or `nil` before the first path update.
    ///
    /// Dual-entry for the same reason as ``currentDeviceDNSResolverAddresses()``: the
    /// `pathUpdateHandler` stamps it while already ON dnsStateQueue, and the resolver egress
    /// seams may ask from either side (INV-QUEUE-1).
    func currentPhysicalInterfaceIndex() -> UInt32? {
        if DispatchQueue.getSpecific(key: dnsStateQueueSpecificKey) == true {
            return latestPhysicalInterfaceIndex
        }

        return dnsStateQueue.sync {
            latestPhysicalInterfaceIndex
        }
    }

    /// Whether `address` is a resolver destination the latched data path claims on the DNS
    /// capture floor, and so must egress on the physical interface.
    ///
    /// The floor is claimed by a CHAINED SPLIT plan ONLY, and both membership sources ride into
    /// that one plan: F1's curated public resolvers and F3b's captured device resolvers
    /// (`makeTunnelNetworkSettingsForLatchedDataPath` passes them for `isChainedUpstream`, and
    /// `TunnelRoutePlan.make` merges the host routes only into the split branch). DNS-only claims
    /// NOTHING by default. The explicit DNS patch is a separate, narrow opt-in below.
    /// `makeTunnelNetworkSettingsForLatchedDataPath` otherwise passes `[]`, because a DNS-only
    /// claim would draw a resolver's non-53 traffic (HTTPS/QUIC `:443`, ICMP) into a path with no
    /// forwarding rung and silently drop it (the `https://1.1.1.1` breakage Kilo caught on
    /// PR #752). A full chained tunnel claims every destination with its default routes and
    /// ignores the floor, so it is not a floor claim either. Reading the curated set without the
    /// mode guard, or reading only the captured set, would pin (or refuse) a destination the
    /// routing table is actually free to choose.
    ///
    /// The tunnel's own listeners are never floor claims, in any mode, matching
    /// ``DNSCaptureFloor/hostRoutes(forResolverAddresses:)``.
    ///
    /// The on-link-gateway-class exclusion is applied to the CAPTURED arm through the SAME
    /// ``DNSCaptureFloorMembership`` the plan wiring uses: an address the membership rule removed
    /// from the floor is NOT claimed by the tunnel, so reporting it as claimed would make the F2
    /// seam pin (or, with no physical index, refuse) a destination the routing table is actually
    /// free to choose. The curated set needs no such filter — its entries are all public.
    ///
    /// Compared through ``ResolverAddressIdentity`` rather than string equality: the captured
    /// address and the endpoint's validated literal can spell the same IPv6 address differently,
    /// and a missed match strands Lava's own query in a claimed route.
    /// pinned: TunnelDataPathLatchSourceTests.testTheFloorClaimRequiresALatchedChainedSplitAndCoversCuratedAddresses
    func deviceResolverIsFloorClaimed(_ address: String) -> Bool {
        // The tunnel's own listeners are never floor claims, in any mode.
        guard !ResolverAddressIdentity.denotesSameAddress(address, TunnelRoutePlan.dnsServerAddress),
              !ResolverAddressIdentity.denotesSameAddress(
                  address, TunnelRoutePlan.chainedDNSServerIPv6Address) else {
            return false
        }
        // Opt-in profile destinations are claimed in DNS-only as well. Use this same
        // membership for physical egress so a user's T1/T2 cannot loop into our route.
        if currentDNSPatchCaptureAddresses().contains(where: {
            ResolverAddressIdentity.denotesSameAddress($0, address)
        }) {
            switch currentTunnelDataPathMode() {
            case .dnsOnly: return true
            case .chainedUpstream(let configuration): return configuration.effectiveRoutingPolicy == .splitTunnel
            }
        }
        #if DEBUG || LAVA_QA_TOOLS
        // The bounded comparison can claim a resolver in DNS-only too. Its upstream socket
        // must use the same physical-binding protection as a claimed split resolver.
        if let qaResolvers = (protocolConfiguration as? NETunnelProviderProtocol)?
            .providerConfiguration?["qaCapturedDNSResolvers"] as? [String],
           qaResolvers.contains(where: { ResolverAddressIdentity.denotesSameAddress($0, address) }) {
            switch currentTunnelDataPathMode() {
            case .dnsOnly: return true
            case .chainedUpstream(let configuration): return configuration.effectiveRoutingPolicy == .splitTunnel
            }
        }
        #endif
        // THE MODE GUARD COMES FIRST, and it is what makes this answer honest. The floor is
        // claimed by a chained split plan only: DNS-only passes `[]` (its loop cannot forward
        // non-DNS to a claimed resolver), and full tunnel already claims every destination and
        // ignores the floor. Return false before evaluating either membership source.
        guard case .chainedUpstream(let configuration) = currentTunnelDataPathMode(),
              configuration.effectiveRoutingPolicy == .splitTunnel else {
            return false
        }
        // F1: the curated public set is claimed by the chained split plan, in both families.
        if DNSCaptureFloor.isCuratedPublicResolverAddress(address) {
            return true
        }
        // F3b: the CAPTURED device resolvers, under the plan's own on-link-gateway exclusion.
        guard !DNSCaptureFloorMembership.excludesAsOnLinkGatewayClass(address) else {
            return false
        }
        return currentDeviceDNSResolverAddresses().contains { candidate in
            ResolverAddressIdentity.denotesSameAddress(candidate, address)
        }
    }

    /// Whether the latched chained profile's `AllowedIPs` already carry `address`.
    ///
    /// The "do not override the user's routes" term of
    /// ``ChainedResolverEgressPolicy/destinationSocketBinding(destinationIsFloorClaimed:destinationIsProfileCovered:physicalInterfaceIndex:)``.
    /// `false` outside a chained latch — there is no profile to be covered by, which is exactly
    /// the DNS-only case where a floor claim (when wired) is Lava's alone.
    func latchedChainedAllowedIPsCover(_ address: String) -> Bool {
        guard case .chainedUpstream(let configuration) = currentTunnelDataPathMode() else {
            return false
        }
        return ChainedResolverEgressPolicy.allowedIPsCover(
            destination: address, allowedIPs: configuration.capturedAllowedIPs)
    }

    @discardableResult
    private func setDeviceDNSResolverAddresses(
        _ addresses: [String],
        preserveOnEmptyCapture: Bool = true
    ) -> [String] {
        if DispatchQueue.getSpecific(key: dnsStateQueueSpecificKey) == true {
            deviceDNSResolverAddresses = DeviceDNSFallbackPolicy.refreshedResolverAddresses(
                current: deviceDNSResolverAddresses,
                captured: addresses,
                preserveOnEmptyCapture: preserveOnEmptyCapture
            )
            return deviceDNSResolverAddresses
        }

        return dnsStateQueue.sync {
            deviceDNSResolverAddresses = DeviceDNSFallbackPolicy.refreshedResolverAddresses(
                current: deviceDNSResolverAddresses,
                captured: addresses,
                preserveOnEmptyCapture: preserveOnEmptyCapture
            )
            return deviceDNSResolverAddresses
        }
    }

    func currentDeviceDNSFallbackModeActive() -> Bool {
        currentResolverHealthSchedulingView().deviceDNSFallbackModeActive
    }

    func refreshDeviceDNSResolverAddresses(
        reason: String,
        preserveOnEmptyCapture: Bool = true
    ) {
        let addresses = Self.currentSystemDNSServerAddresses()
        let activeAddresses = setDeviceDNSResolverAddresses(
            addresses,
            preserveOnEmptyCapture: preserveOnEmptyCapture
        )

        LavaSecDeviceDebugLog.append(component: "tunnel", event: "device-dns-captured", details: [
            "reason": reason,
            "count": "\(addresses.count)",
            "activeCount": "\(activeAddresses.count)"
        ])
    }

    func refreshDeviceDNSResolverAddressesOnDNSQueue(
        reason: String,
        preserveOnEmptyCapture: Bool = true
    ) {
        let read = Self.readSystemDNSServerAddresses()
        let addresses = read.usable
        deviceDNSResolverAddresses = DeviceDNSFallbackPolicy.refreshedResolverAddresses(
            current: deviceDNSResolverAddresses,
            captured: addresses,
            preserveOnEmptyCapture: preserveOnEmptyCapture
        )

        // Log only episode transitions (UR-48 Phase 2a): on a masked network this read runs
        // on every wake/retry and `count=0` was the log's dominant line (832 of 858 reads in
        // the rc9 bundle) — pure noise in a capped diagnostic log. Non-empty captures always
        // log; a suppressed-repeat tally rides on the next allowed line so the episode's
        // volume stays reconstructable. A masked read under a NEW `reason` (e.g. a
        // `network-path-changed` handoff between two masked networks) also logs — that's a
        // distinct recapture the log is meant to show, not a same-reason repeat. This
        // queue-confined gate covers only THIS variant — the storm path; the rare off-queue
        // refresh keeps unconditional logging.
        if DeviceDNSFallbackPolicy.shouldLogDeviceDNSCapture(
            capturedCount: addresses.count,
            reason: reason,
            lastLoggedCount: lastLoggedDeviceDNSCaptureCount,
            lastLoggedReason: lastLoggedDeviceDNSCaptureReason
        ) {
            var details = [
                "reason": reason,
                "count": "\(addresses.count)",
                "activeCount": "\(deviceDNSResolverAddresses.count)"
            ]
            // ONLY ON AN EMPTY CAPTURE, and only the two facts that tell the two empties apart.
            // `masked` means the read saw our own listener and nothing else — the design working,
            // not a network fault — which is what every post-`startTunnel` capture looks like.
            // A `count: 0` with `masked: false` and `raw: 0` is the real fault: the link handed
            // out no usable resolver at all. Suppressed on a NON-empty capture because there the
            // addresses already say everything (UR-48 Phase 2a keeps this log small).
            if addresses.isEmpty {
                details["raw"] = "\(read.rawCount)"
                details["masked"] = "\(read.isMaskedBySelf)"
            }
            if suppressedDeviceDNSCaptureLogCount > 0 {
                details["suppressedRepeats"] = "\(suppressedDeviceDNSCaptureLogCount)"
            }
            LavaSecDeviceDebugLog.append(component: "tunnel", event: "device-dns-captured", details: details)
            lastLoggedDeviceDNSCaptureCount = addresses.count
            lastLoggedDeviceDNSCaptureReason = reason
            suppressedDeviceDNSCaptureLogCount = 0
        } else {
            suppressedDeviceDNSCaptureLogCount += 1
        }
    }

    /// How many resolvers the system read returned BEFORE usability filtering, and how many of
    /// those were our own tunnel listener.
    ///
    /// `count: 0` on its own cannot distinguish the two states that produce it, and the
    /// difference decides whether anything is wrong:
    ///
    /// - **Masked, as designed.** `res_ninit` reflects the resolver config the tunnel itself
    ///   installed, so while our DNS settings are up the read returns `TunnelRoutePlan.dnsServerAddress`
    ///   and `isUsableDeviceDNSServer` rejects it. Every capture after `startTunnel` looks like
    ///   this — a stable network and a network that changed under us are indistinguishable.
    /// - **Genuinely nothing.** The read returned no servers at all, or only unusable ones
    ///   (link-local, NAT64, loopback) — a half-configured link, which IS a fault.
    ///
    /// The 2026-08-27 train captures were read as the second and were almost certainly the first:
    /// 115 retries, 23 exhaustions, and the eligible interface never changed for 40 minutes
    /// (`chained-path-identity-changed` last fired 2h earlier). Recording the raw count and the
    /// self-rejection is what makes the next capture decide it instead of inviting the guess
    /// again — see `plans/2026-08-27-chained-resolver-adaptation-and-tier-three.md` (lavasec-infra).
    struct DeviceDNSCaptureRead {
        let usable: [String]
        let rawCount: Int
        let selfRejectedCount: Int

        /// Masked by our own settings: EVERY resolver the read returned was the tunnel's own
        /// listener. Distinct from an empty read (a link fault) and, just as importantly, from a
        /// MIXED read.
        ///
        /// `usable.isEmpty && selfRejectedCount > 0` was the obvious spelling and it is wrong:
        /// a half-configured link returning the listener ALONGSIDE a link-local or NAT64 address
        /// leaves `usable` empty (the second is dropped by `isUsableDeviceDNSServer`) and
        /// `selfRejectedCount` at one, so the genuine fault would report as healthy masking —
        /// the exact misdiagnosis this type exists to prevent (Kilo + Codex, PR #597, found
        /// independently). Comparing against `rawCount` is what makes "only" mean only; a mixed
        /// read now logs `masked: false` with a `raw` above one, which reads as the fault it is.
        var isMaskedBySelf: Bool { rawCount == selfRejectedCount && selfRejectedCount > 0 }
    }

    private static func currentSystemDNSServerAddresses() -> [String] {
        readSystemDNSServerAddresses().usable
    }

    static func readSystemDNSServerAddresses() -> DeviceDNSCaptureRead {
        var buffer = [CChar](repeating: 0, count: deviceDNSCaptureBufferLength)
        let count = buffer.withUnsafeMutableBufferPointer { pointer -> Int32 in
            guard let baseAddress = pointer.baseAddress else {
                return 0
            }

            return LavaSecCopySystemDNSServers(baseAddress, Int32(pointer.count))
        }

        guard count > 0 else {
            return DeviceDNSCaptureRead(usable: [], rawCount: 0, selfRejectedCount: 0)
        }

        let capturedBytes = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        let captured = String(decoding: capturedBytes, as: UTF8.self)
        var uniqueAddresses: [String] = []
        var seenAddresses: Set<String> = []
        var rawCount = 0
        var selfRejectedCount = 0

        for address in captured.split(separator: "\n").map(String.init) {
            rawCount += 1
            // Counted BEFORE the usability filter and separately from it, because "we read our
            // own listener back" is the signature of the mask and nothing else produces it.
            if address == tunnelDNSServerAddress || address == tunnelDNSServerIPv6Address {
                selfRejectedCount += 1
                continue
            }
            guard isUsableDeviceDNSServer(address), seenAddresses.insert(address).inserted else {
                continue
            }

            uniqueAddresses.append(address)
        }

        return DeviceDNSCaptureRead(
            usable: uniqueAddresses, rawCount: rawCount, selfRejectedCount: selfRejectedCount)
    }

    private static func isUsableDeviceDNSServer(_ address: String) -> Bool {
        // Reject the tunnel's own listener (config-specific), then defer the structural
        // reserved/unroutable-range rejection (unspecified/loopback/link-local/NAT64) to
        // the pure, unit-tested policy predicate. Phase 0 hygiene (lavasec-infra#57):
        // a half-configured post-handoff link can surface a link-local/NAT64 address
        // before the real resolver settles; adopting one wedges DNS on a dead address.
        guard address != tunnelDNSServerAddress, address != tunnelDNSServerIPv6Address else {
            return false
        }

        return DeviceDNSFallbackPolicy.isUsableResolverAddress(address)
    }

    func currentAppConfiguration() -> AppConfiguration {
        if DispatchQueue.getSpecific(key: dnsStateQueueSpecificKey) == true {
            return appConfiguration
        }

        return dnsStateQueue.sync {
            appConfiguration
        }
    }


    /// The plan the T1 RUNG resolves against, or `nil` when there is no rung.
    ///
    /// `nil` in three cases, and each is the closed answer: the session is not chained; the latch
    /// was cleared by a downgrade to DNS-only; or the selection is an ADDRESS-ROUTED one
    /// (`.plainDNS`, or `.deviceDNS` since PR #592) whose every address is already the conf's own
    /// resolver or refused by a usability gate. The orchestrator treats nil as "no T1", so
    /// T0's own answer stands.
    ///
    /// "The selection is Device DNS" USED TO BE A FOURTH CASE and is not one any more. A user
    /// whose one resolver selection is the network's own resolver is asking for exactly the shape
    /// native Tailscale gives them — tailnet names from the conf's `DNS =`, everything else from
    /// the system's resolvers — and refusing it left them worse off than not chaining at all
    /// (founder, 2026-08-27). A device-DNS selection can still land on nil, but by the ADDRESS
    /// question above rather than by its transport: a device with no captured resolver, or whose
    /// only resolver IS the conf's own, has no second opinion to ask.
    ///
    /// THE ADMISSION GATE IS PLAIN-ONLY, and that is not an omission. It answers one question —
    /// "is this IPv4 literal a second opinion, and can it answer at all" — and neither half is
    /// askable of a DoH URL or a DoT hostname: there is no literal to dedupe against the conf's
    /// `DNS =`, and reachability on the physical path is not ours to predict. An encrypted
    /// selection is therefore a rung by construction, which is also the honest answer: the user
    /// picked a resolver the tunnel's own `DNS =` cannot be confused with.
    ///
    /// THE SELECTION IS LATCHED, THE PLAN IS NOT. `latchedChainedTierOneResolverConfiguration`
    /// fixes WHICH resolver for the session; everything else the plan needs — the network kind,
    /// the device's own resolvers, the health scheduler's fallback mode — moves during a session
    /// and is read live here, exactly as `currentResolverRuntimeConfiguration()` does for the
    /// primary. Building the plan at latch time instead would freeze a wifi-ordered address list
    /// across a roam to cellular.
    ///
    /// Dual-entry per INV-QUEUE-1: the orchestrator's closure calls this from resolver work that
    /// may already hold `dnsStateQueue`, so a bare `sync` would deadlock.
    /// pinned: TunnelDataPathLatchSourceTests.testTheTierOnePlanComesFromTheLatchedAlternativeSelection
    /// pinned: TunnelDataPathLatchSourceTests.testAnEncryptedTierOneSelectionIsNotNarrowedToPlainAddresses
    func currentTierOneFallbackPlan() -> DNSResolverRuntimePlan? {
        // BOTH LATCHED FACTS IN ONE CRITICAL SECTION. The rung's resolver and the set of addresses
        // it is allowed to ask are derived from the same latch, so they cannot describe two
        // different sessions — the same reason the route and its tokens are read together.
        let derive: () -> (AppConfiguration, [String], [String], [String])? = {
            guard let configuration = self.latchedChainedTierOneResolverConfiguration,
                case .chainedUpstream(let upstream) = self.latchedDataPathMode
            else { return nil }
            // PUBLISHED HERE, IN THE CRITICAL SECTION THE PLAN IS DERIVED IN, and that placement
            // is the whole point of the line.
            //
            // The per-resolution publish also runs from the route derive — but that happens
            // BEFORE the synchronous T0 attempt, while this plan is built AFTER it. For every
            // selection but one the gap is harmless, because the endpoints are fixed at latch. A
            // DEVICE-DNS selection reads the live capture, and
            // `refreshDeviceDNSResolverAddressesOnDNSQueue` can land inside T0's window (wake,
            // network-settled, wedge-recovery). The rung would then query the NEW resolver while
            // the published effective set still named the OLD one, and
            // `recordChainedTierOneRungEvidence` — which does not republish — would credit the
            // new resolver's result to the old set until some later query happened to republish.
            // On an idle device that is a long time (Codex P2, PR #592).
            //
            // Publishing from inside `derive` closes it: this runs on `dnsStateQueue` (inline via
            // getSpecific, or through the `sync` below), the refresh runs on that same serial
            // queue, so nothing can interleave between the publish, the `admitted` derivation and
            // the capture read beside them.
            //
            // THE CAPTURE IS RETURNED, NOT RE-READ, and the first cut of this fix got that wrong.
            // It published here and then let `DNSResolverRuntimePlan.make` take its own
            // `currentDeviceDNSResolverAddresses()` after the closure had returned — a SECOND
            // live read, outside the critical section this comment claimed to cover. A refresh
            // landing between the two gave the plan a different address list from the one the
            // panel had just been told about: a partial change built a plan disagreeing with the
            // published effective set, and a COMPLETE change emptied
            // `restrictingPlainAddresses`'s intersection and returned nil — silently skipping
            // T1 for a query T0 had already declined, which the user sees as a name that
            // simply does not resolve (Codex P2, PR #592).
            //
            // Change-gated like every other call, so a resolution whose capture did not move
            // costs one comparison.
            // pinned: TunnelDataPathLatchSourceTests.testTheRungPlanPublishesInTheSameCriticalSection
            self.publishChainedFallbackOutcomesOnQueue(configuration: upstream)
            // ORDER PRESERVED: publish, then the admitted set, then the capture — the sequence
            // `testTheRungPlanPublishesInTheSameCriticalSection` pins, because the publish must
            // precede a set derived from a read it cannot otherwise prove came first.
            let admitted = self.admittedTierOneAddressesOnQueue(upstream: upstream)
            // BOUND TO A LOCAL because two consumers now need the SAME read: the plan below and
            // the device-leg admission beside it. A second call would be the very race the
            // carried-capture rule exists to stop.
            let capture = self.currentDeviceDNSResolverAddresses()
            return (
                configuration,
                admitted,
                capture,
                // DERIVED FROM THE SAME CAPTURE, IN THE SAME CRITICAL SECTION, for exactly the
                // reason the capture itself is returned rather than re-read — see above. A second
                // live read here would gate one address list and hand the plan another.
                Self.admittedDeviceFallbackAddresses(capture: capture, upstream: upstream))
        }
        let latched: (AppConfiguration, [String], [String], [String])?
        if DispatchQueue.getSpecific(key: dnsStateQueueSpecificKey) == true {
            latched = derive()
        } else {
            latched = dnsStateQueue.sync(execute: derive)
        }
        guard let (configuration, admitted, deviceResolvers, admittedDeviceFallback) = latched
        else { return nil }
        // DEVICE DNS IS ADDRESS-GATED LIKE PLAIN, because it IS plain: `DNSResolverRuntimePlan.make`
        // puts the captured device resolvers straight into `plainAddresses` for this transport.
        // So the dedupe-against-T0 and usability questions are both askable, and the
        // no-admitted-address guard is exactly right — a device with no captured resolver, or one
        // whose only resolver is the conf's own, has no second opinion to ask.
        let transport = configuration.resolverPreset.transport
        let resolvesOverPlainDNS = transport == .plainDNS || transport == .deviceDNS
        // NO ADMITTED ADDRESS, NO RUNG — for a plain selection only. Every address deduped into
        // T0 or refused by a usability gate means there is no second opinion to ask, and
        // asking the conf's own resolver again is exactly what the rung exists to avoid.
        if resolvesOverPlainDNS, admitted.isEmpty { return nil }
        let schedulingView = currentResolverHealthSchedulingView()
        let plan = DNSResolverRuntimePlan.make(
            configuration: configuration,
            // THE CAPTURE FROM `derive`, never a fresh read — see the note there. This is the
            // list the publish and the admitted set were both derived from, so the plan the rung
            // resolves cannot describe a different resolver from the one the panel names.
            deviceDNSAddresses: deviceResolvers,
            networkKind: currentNetworkKind(),
            deviceDNSFallbackModeActive: schedulingView.deviceDNSFallbackModeActive,
            // THE RUNG IS THE RESOLVER THE USER PICKED, AND NOTHING ELSE — which is a claim
            // about PROVENANCE, not about transport. Since PR #592 the rung's allowance permits
            // `.deviceDNS`, because a user may PICK it; what stays forbidden is device DNS being
            // IMPOSED on the rung by a fallback episode the user never asked for.
            //
            // THIS IS NOW THE ONLY GATE, and it is the one that was always doing the work.
            // `chainedTierOneResolverConfiguration` used to also force `fallbackToDeviceDNS` off;
            // it now carries the user's own value, because the rung runs the full ladder and that
            // per-query flag is the user's setting rather than an imposition. The MODE is the
            // imposition: a device-wide fallback episode arises from the PRIMARY's health, and
            // letting it rewrite a rung the user set to 1.1.1.1 into one that asks their café's
            // resolver is exactly `LAV-87`. Ignoring it here is what stops that, and it does not
            // depend on the flag beside it.
            ignoresDeviceDNSFallbackMode: true,
            deviceResolverWedged: schedulingView.reconnectEpisodeIsActive
        )
        // NARROWED TO WHAT THE PANEL CALLS ADMITTED, and ONLY for a plain selection.
        // `resolvePlainDNS` returns on the FIRST address that yields any packet, SERVFAIL
        // included — so a preset partially overlapping the conf's own `DNS =` (Cloudflare against
        // `DNS = 1.1.1.1`) would re-ask the resolver that just declined the name, stop on its
        // second refusal, and never reach the admitted address. The wire, the counters and the
        // panel then describe the same set (Codex, PR #590).
        //
        // An encrypted plan is returned WHOLE. `restrictingPlainAddresses` only filters a
        // `.plainDNS` plan, so passing an empty `admitted` through it would be a no-op today —
        // but a no-op that reads as "narrowed to nothing", and the next person to widen that
        // method would silently delete the rung. Saying which plans are narrowed is the point.
        //
        // THE DEVICE LEG IS GATED TOO, and it is a SEPARATE list from the one narrowed below.
        // `deviceDNSFallbackAddresses` is the raw capture — `make` puts it there with no chained
        // admission — so before PR #603 the rung's device leg egressed unadmitted addresses on
        // `.physical`: an IPv6 resolver into the chained `::/0` blackhole, and a resolver equal to
        // the conf's own `DNS =` re-asked the name T0 had just declined, ending the leg on its
        // second refusal. That leg only became reachable when PR #596 gave the rung the full
        // ladder, so the gap arrived with it (Codex P2, PR #596).
        //
        // APPLIED TO EVERY SELECTION, not just the plain ones. The narrowing below is skipped for
        // an encrypted selection because there is no address list to narrow — but an encrypted
        // selection still HAS a device leg, and its addresses are just as unadmitted.
        let admittedPlan = plan.restrictingDeviceDNSFallbackAddresses(to: admittedDeviceFallback)
        guard resolvesOverPlainDNS else { return admittedPlan }
        return admittedPlan.restrictingPlainAddresses(to: admitted)
    }

    /// The captured device resolvers the RUNG's fallback leg may ask, under the chained gates.
    ///
    /// The same derivation `admittedTierOneAddressesOnQueue` runs, over a different list: that one
    /// asks which of the SELECTED resolvers are a second opinion, this one asks it of the
    /// capture that backs the ladder's device leg. They coincide for a device-DNS selection and
    /// differ for every other one, which is exactly the case the leg was unguarded for.
    ///
    /// `resolvesOverPlainDNS: true` unconditionally — these are IP literals whoever handed them
    /// over, so the dedupe-against-T0 and usability questions are both askable.
    ///
    /// Static and total, taking the capture rather than reading it, so the caller passes the same
    /// value it already holds on `dnsStateQueue`.
    private static func admittedDeviceFallbackAddresses(
        capture: [String], upstream: ChainedUpstreamConfiguration
    ) -> [String] {
        // IPv6 entries are already `.unusableIPv6` (not `.admitted`) in `fallbackOutcomes`, so
        // `.admitted`-only already excludes them; no extra filter, which would drop the panel's
        // `.unusableIPv6` naming (Kilo, PR #738).
        ChainedTunnelResolverSelection.fallbackOutcomes(
            latched: capture,
            resolvesOverPlainDNS: true,
            selection: ChainedTunnelResolverSelection.selection(from: upstream),
            configuration: upstream)
            .filter { $0.disposition == .admitted }
            .map(\.address)
    }

    /// The T1 addresses this session may actually ask, derived exactly as the settings panel
    /// derives them so the wire and the surface cannot disagree. Empty — meaning "no address
    /// question to ask" rather than "refused" — for an encrypted selection.
    ///
    /// `dnsStateQueue`-confined: the caller establishes it. Shares
    /// `ChainedTunnelResolverSelection.fallbackOutcomes` with `publishChainedFallbackOutcomesOnQueue`
    /// rather than re-deriving the rules, because a second copy of "which addresses count" is the
    /// drift that put a routing verdict in the provider once already (Kilo, PR #575).
    private func admittedTierOneAddressesOnQueue(
        upstream: ChainedUpstreamConfiguration
    ) -> [String] {
        dispatchPrecondition(condition: .onQueue(dnsStateQueue))
        return Self.tierOneOutcomes(
            latched: latchedChainedTierOneResolverConfiguration,
            deviceResolvers: currentDeviceDNSResolverAddresses(),
            upstream: upstream)
            .filter { $0.disposition == .admitted }
            .map(\.address)
    }

    /// What became of each entry in the latched T1 selection — the ONE derivation the wire
    /// gate and the settings panel both read.
    ///
    /// Static and total: it takes the latch rather than reading it, so both callers pass the same
    /// value they already hold on `dnsStateQueue` and neither can take a second, differently-timed
    /// read of it.
    static func tierOneOutcomes(
        latched: AppConfiguration?,
        deviceResolvers: [String],
        upstream: ChainedUpstreamConfiguration
    ) -> [ChainedFallbackAddressOutcome] {
        guard let latched else { return [] }
        let transport = latched.resolverPreset.transport
        // THE LIVE CAPTURE IS THE DEVICE SELECTION'S ADDRESS LIST. A device-DNS selection names
        // nothing in the configuration — the resolvers are whatever the network handed this
        // device — so the endpoints come from the capture the plan itself resolves through
        // (`DNSResolverRuntimePlan.make` puts `deviceDNSAddresses` straight into
        // `plainAddresses` for this transport). Reading them from anywhere else would let the
        // panel and the wire describe different resolvers, which is the drift this one shared
        // derivation exists to prevent.
        //
        // They are PLAIN IP LITERALS, so the ordinary gates apply and should: a device resolver
        // that IS the conf's own `DNS =` is `.alreadyPrimary` and asking it again buys nothing,
        // and an unusable literal is unusable whoever handed it over.
        // AN IPv6 PLAIN/DEVICE ADDRESS IS ALREADY `.unusableIPv6`, NOT `.admitted`
        // (`ChainedTunnelResolverSelection.fallbackOutcomes`), and that is the reason no extra
        // filter belongs here. `.admitted`-only is what the wire consumes, so a v6 resolver was
        // never dialed; and the PANEL consumes the full outcome list to NAME the refusal, so
        // dropping the `.unusableIPv6` outcomes would replace a specific remedy with the generic
        // one (Kilo, PR #738). F2 now pins a floor-claimed plain/device destination to the
        // physical interface (`ChainedResolverEgressPolicy.tierOneSocketBinding`), but an
        // ENCRYPTED selection's `allBootstrapServers` connect leg is not in this address list and
        // does not pass through that socket seam, so a v6-only encrypted endpoint remains the
        // recorded residual.
        return ChainedTunnelResolverSelection.fallbackOutcomes(
            latched: Self.tierOneEndpoints(latched: latched, deviceResolvers: deviceResolvers),
            resolvesOverPlainDNS: transport == .plainDNS || transport == .deviceDNS,
            selection: ChainedTunnelResolverSelection.selection(from: upstream),
            configuration: upstream)
    }

    /// The addresses or endpoints the latched T1 selection names — the ONE list both the
    /// outcome derivation and the snapshot's `chainedFallbackLatchedAddresses` read.
    ///
    /// It exists because DEVICE DNS names nothing in the configuration. Every other transport
    /// carries its endpoints in the preset, so `chainedTierOneResolverEndpoints` is the whole
    /// answer; a device-DNS selection's resolvers are whatever the network handed this device,
    /// and they live only in the tunnel's live capture — the same capture
    /// `DNSResolverRuntimePlan.make` puts straight into `plainAddresses` for this transport.
    ///
    /// Both callers going through here is the point. Deriving the outcomes from the capture while
    /// the snapshot's latched list stayed empty would publish a panel that enumerates resolvers
    /// against a "latched" set naming none of them — the panel-versus-wire drift the shared
    /// `tierOneOutcomes` derivation exists to prevent, reintroduced one field over.
    /// pinned: TunnelDataPathLatchSourceTests.testTheLatchedTierOneListIsTheDeviceCaptureForADeviceSelection
    static func tierOneEndpoints(
        latched: AppConfiguration, deviceResolvers: [String]
    ) -> [String] {
        latched.resolverPreset.transport == .deviceDNS
            ? deviceResolvers : latched.chainedTierOneResolverEndpoints
    }

    func setAppConfiguration(_ configuration: AppConfiguration) {
        if DispatchQueue.getSpecific(key: dnsStateQueueSpecificKey) == true {
            adoptAppConfiguration(configuration)
            return
        }

        dnsStateQueue.sync {
            adoptAppConfiguration(configuration)
        }
    }

    /// Assigns the live configuration and refreshes the values derived from it.
    ///
    /// `setAppConfiguration` is the ONLY writer of `appConfiguration`, so this is the one place the
    /// manual-rule caches can go stale. The two normalized rule sets are rebuilt together into ONE
    /// immutable `ManualDomainRuleSnapshot` and published under the `manualRuleDiagnosticState`
    /// lock, so the off-queue diagnostic read (`recordManualRuleDecisionIfNeeded`) is ordered
    /// against it and can never observe a torn pair. Normalizing once per configuration instead
    /// of once per DNS query (the paid limits allow 1000 blocked + 1000 allowed rules) — Kilo
    /// review, PR #745. dnsStateQueue-confined by both callers.
    /// pinned: ManualDomainRuleDiagnosticSourceTests.testTheManualRuleSnapshotIsPublishedUnderTheGuardedState
    private func adoptAppConfiguration(_ configuration: AppConfiguration) {
        revalidateChainedBootRecoveryIfNeeded()
        appConfiguration = configuration
        let snapshot = ManualDomainRuleSnapshot(
            blocked: ManualDomainRuleSet(rawRules: configuration.blockedDomains),
            allowed: ManualDomainRuleSet(rawRules: configuration.allowedDomains)
        )
        manualRuleDiagnosticState.withLock { $0.snapshot = snapshot }
    }

    static func tunnelNetworkKind(for path: Network.NWPath) -> TunnelNetworkKind {
        if path.usesInterfaceType(.cellular) {
            return .cellular
        }

        if path.usesInterfaceType(.wifi) {
            return .wifi
        }

        if path.usesInterfaceType(.wiredEthernet) {
            return .wired
        }

        return path.status == .satisfied ? .other : .unknown
    }

    static func pathStatusDescription(_ status: Network.NWPath.Status) -> String {
        switch status {
        case .satisfied:
            "satisfied"
        case .unsatisfied:
            "unsatisfied"
        case .requiresConnection:
            "requires-connection"
        @unknown default:
            "unknown"
        }
    }

    // Runs on dnsStateQueue (the DNS handling path); the elapsed time is
    // measured from setTunnelNetworkSettings success per the plan's
    // "first DNS after tunnel start" latency target.
    func recordFirstDNSDecisionIfNeeded(_ decision: String) {
        guard !hasRecordedFirstDNSDecision else {
            return
        }

        hasRecordedFirstDNSDecision = true

        #if DEBUG || LAVA_QA_TOOLS
        let elapsedMs = firstDNSDecisionReferenceAt.map { Int((Date().timeIntervalSince($0) * 1_000).rounded()) }
        let trace = Self.makeLatencyTrace(operationID: tunnelStartLatencyOperationID, operationKind: "tunnelStart")
        trace.record("tunnel.firstDNSDecision", details: [
            "decision": decision,
            "elapsedMs": elapsedMs.map(String.init) ?? "unknown"
        ])
        #endif
    }

    // Pause flips deliberately do NOT reset the DNS runtime or reload the
    // snapshot: the policy snapshot stays loaded during pause, pause-era cached
    // answers carry TTLs capped to the pause window, and pending forwards
    // re-check policy at completion. Refreshing pause state and the expiry
    // timer is sufficient (plan F2 / Track 5).
    func refreshProtectionPauseStateOnly(reason: String) {
        guard DispatchQueue.getSpecific(key: dnsStateQueueSpecificKey) == true else {
            dnsStateQueue.async { [weak self] in
                self?.refreshProtectionPauseStateOnly(reason: reason)
            }
            return
        }

        let pauseUntil = refreshTemporaryProtectionPauseState(synchronizesDefaults: true)
        let pauseIsActive = pauseUntil.map { $0 > Date() } ?? false
        let didChangePauseActivity = pauseIsActive != lastAppliedTemporaryProtectionPauseIsActive
        lastAppliedTemporaryProtectionPauseIsActive = pauseIsActive
        scheduleProtectionPauseResumeIfNeeded(reason: reason)
        if didChangePauseActivity { scheduleProtectionNotificationIfNeeded() }

        #if DEBUG || LAVA_QA_TOOLS
        LavaSecDeviceDebugLog.append(component: "tunnel", event: "pause-state-refreshed", details: [
            "reason": reason,
            "pauseActive": "\(pauseIsActive)",
            "changed": "\(didChangePauseActivity)"
        ])
        #endif
    }
}
