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
    // MARK: - Tunnel lifecycle (start / stop / wake)

    override func startTunnel(options: [String: NSObject]?, completionHandler: @escaping (Error?) -> Void) {
        let startedWithProtectedDataUnavailable = !sharedProtectedContentIsReadable()
        let operationID = Self.latencyOperationID(from: options)
        LavaSecDeviceDebugLog.append(component: "tunnel", event: "route-enforcement-started", details: [
            "enforceRoutes": "\(protocolConfiguration.enforceRoutes)",
            "includeAllNetworks": "\(protocolConfiguration.includeAllNetworks)",
            "excludeLocalNetworks": "\(protocolConfiguration.excludeLocalNetworks)"
        ])
        #if DEBUG || LAVA_QA_TOOLS
        let trace = Self.makeLatencyTrace(operationID: operationID, operationKind: "tunnelStart")
        let startSpan = trace.beginSpan("tunnel.start", details: [
            "status": "begin",
            "hasOptions": "\(options != nil)",
            "hasOperationID": "\(operationID != nil)"
        ])
        #endif

        // Stamp the build onto each tunnel session start so every captured event
        // is attributable to an exact app version / build / source commit — a
        // single local-log export can span an app update. The extension reads its
        // own Info.plist (MARKETING_VERSION / CURRENT_PROJECT_VERSION, and
        // LavaSourceRevision injected at release time; empty for local builds).
        LavaSecDeviceDebugLog.append(component: "tunnel", event: "startTunnel-begin", details: [
            "hasOptions": "\(options != nil)",
            "hasOperationID": "\(operationID != nil)",
            "appVersion": (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "",
            "appBuild": (Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String) ?? "",
            "sourceRevision": (Bundle.main.object(forInfoDictionaryKey: "LavaSourceRevision") as? String) ?? ""
        ])

        let completion = SendableCompletion(completionHandler)
        // A surrendered chained tunnel may be relaunched by Connect-On-Demand while the
        // containing app is suspended. The marker is the provider-side gate for that
        // relaunch: do not rebuild the same chain, and never clear the marker from a
        // successful path that belongs to an older lifecycle. The app's explicit Guard
        // start advances the marker revision and clears it before it calls NetworkExtension.
        // 🔴 SCOPE. An ABSENT or UNREADABLE marker must never fail this start. This runs before
        // `loadInitialSharedState`, so the provider does not yet know whether chaining is even
        // enabled — refusing here took DNS-only users, who never turned chaining on, off the
        // internet's filtered path because a chaining control file was momentarily unreadable or
        // its 0.25s `flock` was busy. It bought them nothing: a chained user is already held
        // closed WITHOUT this marker, by `TunnelDataPathLatch.resolve` (which refuses to latch
        // chained under a persisted surrender, and refuses outright on `deviceStateUnavailable`)
        // and `ChainedStartupContract.decide` (which fails the start when the saved setting asks
        // for chaining and the latch did not deliver it — except for a surrender a network change
        // can lift, which starts DNS-only so the auto-recovery can observe that change). The
        // marker's own job is narrower and
        // additive: tell the CONTAINING APP, cross-process, that the refusal is terminal so it can
        // disarm Connect-On-Demand instead of letting iOS relaunch forever (PR #636's incident).
        // Only a CONFIRMED reason below is therefore terminal; an unreadable marker degrades to
        // "ungated", leaving the pre-existing keychain-backed refusals in charge.
        let startupFailureMarkerURL = LavaSecAppGroup.chainedStartupFailureMarkerURL
        // Generation 0 is the clean/fresh-install revision. Carrying it after a failed read means a
        // later `record`/`clear` compare-and-set simply loses and logs `-stale`, which is the safe
        // direction: the keychain suppression still carries the terminal state for the next start.
        var startupFailureMarkerState = ChainedStartupFailureMarker.State(
            reason: nil, generation: 0)
        if let markerURL = startupFailureMarkerURL {
            var readState: ChainedStartupFailureMarker.State?
            do {
                readState = try ChainedStartupFailureMarker.state(
                    from: markerURL,
                    lockURL: LavaSecAppGroup.chainedStartupFailureMarkerLockURL)
            } catch {
                LavaSecDeviceDebugLog.append(
                    component: "tunnel", event: "startTunnel-chaining-marker-read-failed",
                    details: ["error": Self.errorSummary(error)])
            }
            if let readState {
                // The app and Live Activity intent can advance the marker without the tunnel's
                // Keychain entitlement. If that explicit-retry handoff is pending, the provider
                // clears the persisted chained surrender before latching the data path; otherwise
                // a restart would merely clear the file marker and immediately re-enter DNS-only.
                //
                // 🔴 ONLY a superseded start is fatal here. `beginExplicitRetry` sets the handoff
                // bit on EVERY explicit Guard on / reconnect / Live Activity restart, including
                // one from a user who has never enabled chaining — it cannot know, it runs in the
                // app. So failing this start when the chained Keychain is unreachable would take
                // DNS-only users off protection on the ordinary happy path, and unsigned/local
                // builds every single time, since `chainedDeviceEligibilityStore()` is nil without
                // a shared access group. Carrying on costs a chained user nothing: an uncleared
                // suppression means `TunnelDataPathLatch.resolve` refuses to latch chained, and the
                // start then either fails or comes up DNS-only under
                // `ChainedStartupContract.decide` — either way chaining stays off, decided by the
                // owners of that question rather than here (Codex, PR #636).
                do {
                    startupFailureMarkerState = try consumeExplicitChainedRetryIfRequested(
                        readState,
                        markerURL: markerURL)
                } catch is ChainedExplicitRetrySuperseded {
                    let markerError = NSError(
                        domain: "com.lavasec.tunnel.chained-startup",
                        code: 2,
                        userInfo: [
                            NSLocalizedDescriptionKey:
                                "A newer VPN chaining retry replaced this one. Guard stayed off."
                        ])
                    LavaSecDeviceDebugLog.append(
                        component: "tunnel", event: "startTunnel-chaining-retry-superseded")
                    #if DEBUG || LAVA_QA_TOOLS
                    startSpan.end(details: ["status": "chaining-retry-superseded"])
                    #endif
                    completion(markerError)
                    return
                } catch {
                    // The retry request stays unconsumed, so the next explicit attempt can still
                    // repair the suppression. The pre-consume snapshot carries this start: its
                    // reason still gates below, and its generation is the one this start owns.
                    LavaSecDeviceDebugLog.append(
                        component: "tunnel", event: "startTunnel-chaining-retry-consume-unavailable",
                        details: ["error": Self.errorSummary(error)])
                    startupFailureMarkerState = readState
                }
            }
        } else {
            LavaSecDeviceDebugLog.append(
                component: "tunnel", event: "startTunnel-chaining-marker-url-missing")
        }
        // A standing marker never refuses the start. The latched DNS-only path keeps filtering,
        // and the marker only informs the app for disclosure and explicit recovery. Refusing
        // here left the device unfiltered: on 2026-09-17 a terminal marker from a locked-device
        // read stopped every automatic start and the app persisted OFF
        // (plans/2026-09-18-fail-closed-protection-startup-failures-plan.md).
        // pinned: TunnelDataPathLatchSourceTests.testAStandingChainedFailureMarkerNeverRefusesTheStart
        if let reason = startupFailureMarkerState.reason {
            LavaSecDeviceDebugLog.append(
                component: "tunnel", event: "startTunnel-chaining-marker-standing",
                details: [
                    "reason": reason,
                    "generation": "\(startupFailureMarkerState.generation)",
                ])
        }
        chainedStartupFailureMarkerGeneration = startupFailureMarkerState.generation
        let lifecycleGeneration = beginTunnelLifecycle(reason: "startTunnel")
        beginFreshProtectionVPNSession(reason: "startTunnel")
        let shouldBeginTransientBootstrapDNSWaitAfterNetworkSettings = loadInitialSharedState()
        scheduleProtectionPauseResumeIfNeeded(reason: "startTunnel")
        refreshDeviceDNSResolverAddresses(reason: "startTunnel")
        resetHealth()
        resetResolverRuntimeForTunnelLifecycle(reason: "startTunnel")
        // AFTER the latch (loadInitialSharedState), BEFORE the monitor and the settings:
        // a construction failure downgrades the latch, and the settings below must read
        // the downgraded value or the tunnel claims routes it has no session to serve.
        let chainedDriver = buildChainedRuntimeIfLatched(lifecycleGeneration: lifecycleGeneration)
        let startupDecision = ChainedStartupContract.decide(
            chainedUpstreamEnabled: currentAppConfiguration().chainedUpstreamEnabled,
            latchedMode: currentTunnelDataPathMode(),
            refusal: currentLatchedDataPathRefusal(),
            includeAllNetworks: protocolConfiguration.includeAllNetworks)
        let startupRefusal: TunnelDataPathLatch.Refusal?
        switch startupDecision {
        case .start: startupRefusal = nil
        case .startDegraded(let refusal), .rejectStrictProfile(let refusal): startupRefusal = refusal
        }
        if let refusal = startupRefusal {
            // Record the refusal for disclosure. Ordinary profiles keep the latched DNS-only
            // path; strict profiles are rejected below because they require full forwarding.
            // Refusing an ordinary start previously left the device unfiltered
            // (plans/2026-09-18-fail-closed-protection-startup-failures-plan.md); the marker is
            // now a disclosure channel, never a gate. A successful chained start clears it below.
            let reason = refusal.logValue
            if let markerURL = startupFailureMarkerURL {
                do {
                    let recorded = try ChainedStartupFailureMarker.record(
                        reason: reason,
                        generation: self.chainedStartupFailureMarkerGeneration,
                        storageURL: markerURL,
                        lockURL: LavaSecAppGroup.chainedStartupFailureMarkerLockURL)
                    if !recorded {
                        LavaSecDeviceDebugLog.append(
                            component: "tunnel", event: "startTunnel-chaining-marker-stale",
                            details: ["refusal": reason])
                    }
                } catch {
                    LavaSecDeviceDebugLog.append(
                        component: "tunnel", event: "startTunnel-chaining-marker-write-failed",
                        details: ["refusal": reason, "error": Self.errorSummary(error)])
                }
            }
            LavaSecDeviceDebugLog.append(
                component: "tunnel", event: "startTunnel-chaining-degraded",
                details: ["refusal": reason])
            #if DEBUG || LAVA_QA_TOOLS
            startSpan.end(details: ["status": "chaining-degraded", "refusal": reason])
            #endif
        }
        if case .rejectStrictProfile = startupDecision {
            let error = NSError(domain: "com.lavasec.tunnel.strict-startup", code: 1,
                userInfo: [NSLocalizedDescriptionKey:
                    "Full-tunnel protection could not start. Retry Guard or turn it off to restore connectivity."])
            LavaSecDeviceDebugLog.append(component: "tunnel", event: "startTunnel-strict-profile-refused")
            cleanUpTunnelRuntimeAfterFailedStart(reason: "strict-profile-refused") { completion(error) }
            return
        }
        // Populate the chained health flag + counters IMMEDIATELY at start, not only on the
        // first 60 s focus tick. The tick timer has no leading-edge fire, so without this the
        // Nerd Stats surface would show the DNS-only branch (idle physical counters) for the
        // first ~60 s of every chained session — the exact confusion Slice 3 removes. Enqueued
        // on dnsStateQueue AFTER `resetHealth()` above (also async there), so it wins the flag
        // over the reset; the latch and `chainedRuntime` are both settled by this point.
        dnsStateQueue.async { [weak self] in self?.mirrorChainedHealthCountersIfChanged() }
        // Discover early so a physical NAT64 observation can enter the initial routes.
        // INV-QUEUE-1: capture the settings and policy baseline atomically; callbacks
        // retain later changes until the startup installation is settled below. Initialize
        // the policy before the main path monitor can request an ordinary settings reapply.
        // pinned: DNSPatchRouteDiscoverySourceTests.testDiscoveryStartsBeforeTheAtomicInitialSettingsCapture
        startDNSPatchDiscovery(lifecycleGeneration: lifecycleGeneration)
        startPathMonitor(lifecycleGeneration: lifecycleGeneration)
        // Wait for the actual interface-bound endpoints before the first settings snapshot.
        // The Oct 1 reboot spent 18.5 s on a second cold settings post for a NAT64 address
        // already discoverable on the physical path. Discovery has its own 5 s deadline;
        // no installed route or packet-loop callback is needed to complete it (INV-DNS-7).
        // pinned: DNSPatchRouteDiscoverySourceTests.testInitialSettingsWaitForPhysicalDiscoveryBeforeCapturingRoutes
        prepareDNSPatchInitialSettings(lifecycleGeneration: lifecycleGeneration) { [weak self] discoveryError in
            guard let self else { completion(CocoaError(.userCancelled)); return }
            guard self.isCurrentTunnelLifecycle(lifecycleGeneration) else {
                completion(CocoaError(.userCancelled))
                return
            }
            if let discoveryError {
                #if DEBUG || LAVA_QA_TOOLS
                startSpan.end(details: ["status": "dns-patch-discovery-error", "errorKind": "\(type(of: discoveryError))"])
                #endif
                self.cleanUpTunnelRuntimeAfterFailedStart(reason: "dns-patch-initial-discovery-error") {
                    completion(discoveryError)
                }
                return
            }
            let makeInitialSettings: () -> TunnelNetworkSettingsBundle? = {
                guard self.tunnelLifecycleIsActive, self.isCurrentTunnelLifecycle(lifecycleGeneration) else { return nil }
                // The classifier and routes must claim the same patch destinations, including
                // translations discovered after runtime construction (INV-DNS-7).
                // pinned: DNSPatchRouteDiscoverySourceTests.testStartupSettingsKeepClassifierAndRouteClaimsTogether
                self.chainedClaimedResolverDestinations?.update(
                    self.makeClaimedResolverDestinations(for: self.currentTunnelDataPathMode()))
                let settingsBundle = self.makeTunnelNetworkSettingsForLatchedDataPath()
                if self.dnsPatchStartupInstallPolicy != nil {
                    guard self.dnsPatchStartupInstallPolicy?.beginInitialInstall(lifecycleGeneration: lifecycleGeneration) == true else { return nil }
                }
                return settingsBundle
            }
            guard let settingsBundle = DispatchQueue.getSpecific(key: dnsStateQueueSpecificKey) == true
                ? makeInitialSettings() : dnsStateQueue.sync(execute: makeInitialSettings) else {
                completion(CocoaError(.userCancelled))
                return
            }

            let settingsStartedAt = Date()
            LavaSecDeviceDebugLog.append(component: "tunnel", event: "setTunnelNetworkSettings-begin", details: [
                "tunnelAddress": settingsBundle.tunnelAddress,
                "dnsServerAddress": settingsBundle.dnsServerAddress,
                "route": settingsBundle.routeDescription,
                "dataPath": settingsBundle.mode.logValue,
                // The claimed route says what is FORWARDED; this says what is FILTERED, and the
                // two stop agreeing the moment a split tunnel is in play (`INV-DNS-7`). Without
                // it a capture-coverage question can only be answered by re-deriving the scope
                // from `route` by hand, which is the drift the derived scope exists to close.
                "dnsCapture": settingsBundle.dnsCaptureScope.logValue
            ])
            #if DEBUG || LAVA_QA_TOOLS
            let networkSettingsSpan = trace.beginSpan("tunnel.setNetworkSettings", parent: startSpan, details: [
                "status": "begin"
            ])
            #endif

            setTunnelNetworkSettings(settingsBundle.settings) { [weak self] error in
                guard let self else {
                    #if DEBUG || LAVA_QA_TOOLS
                    networkSettingsSpan.end(details: ["status": "missing-provider"])
                    startSpan.end(details: ["status": "missing-provider"])
                    #endif
                    completion(error)
                    return
                }

                // Both success and error callbacks belong to the lifecycle that posted settings.
                // Reject an old error before cleanup can invalidate a replacement session.
                // pinned: DNSPatchRouteDiscoverySourceTests.testInitialSettingsCallbackRejectsStaleErrorsBeforeRuntimeCleanup
                guard self.isCurrentTunnelLifecycle(lifecycleGeneration) else {
                    #if DEBUG || LAVA_QA_TOOLS
                    LavaSecDeviceDebugLog.append(component: "tunnel", event: "setTunnelNetworkSettings-stale", details: [
                        "generation": "\(lifecycleGeneration)"
                    ])
                    #endif
                    #if DEBUG || LAVA_QA_TOOLS
                    networkSettingsSpan.end(details: ["status": "stale"])
                    startSpan.end(details: ["status": "stale"])
                    #endif
                    completion(CocoaError(.userCancelled))
                    return
                }

                if let error {
                    LavaSecDeviceDebugLog.append(component: "tunnel", event: "setTunnelNetworkSettings-error", details: Self.errorDebugDetails(error))
                    #if DEBUG || LAVA_QA_TOOLS
                    networkSettingsSpan.end(details: ["status": "error", "errorKind": "\(type(of: error))"])
                    startSpan.end(details: ["status": "error", "errorKind": "\(type(of: error))"])
                    #endif
                    self.cleanUpTunnelRuntimeAfterFailedStart(reason: "setTunnelNetworkSettings-error") {
                        completion(error)
                    }
                    return
                }

                let duration = Date().timeIntervalSince(settingsStartedAt)
                LavaSecDeviceDebugLog.append(component: "tunnel", event: "setTunnelNetworkSettings-success", details: [
                    "durationMs": "\(Int((duration * 1_000).rounded()))"
                ])
                #if DEBUG || LAVA_QA_TOOLS
                networkSettingsSpan.end(details: ["status": "ok"])
                #endif

                self.markLocalProtectionUptimeStarted()
                self.dnsStateQueue.async { [weak self] in
                    self?.hasRecordedFirstDNSDecision = false
                    self?.firstDNSDecisionReferenceAt = Date()
                    self?.tunnelStartLatencyOperationID = operationID
                }
                // Reclaim scratch a jetsam-killed prior compile orphaned — ONCE, here, before
                // any snapshot reload spawns a streaming compile. Overlapping reloads run their
                // compiles concurrently (each in its own UUID scratch dir) and only the final
                // commit is generation-gated, so a per-compile "remove every scratch dir" sweep
                // could delete a sibling's in-flight blob/output. A hard kill (the only way a
                // scratch dir is orphaned) always restarts the extension and re-runs startTunnel,
                // and a live process removes each compile's own dir via `defer`, so startup is
                // both the only place orphans appear and the only race-free place to sweep them.
                if let catalogCacheURL = self.catalogCacheURL {
                    CachedFilterSnapshotCompiler.sweepStaleScratch(cacheDirectoryURL: catalogCacheURL)
                }
                if shouldBeginTransientBootstrapDNSWaitAfterNetworkSettings {
                    self.beginTransientBootstrapDNSWait(reason: "setTunnelNetworkSettings-success")
                }
                self.loadSnapshotInBackground(reason: "startTunnel", operationID: operationID)
                // Lazy vars are not thread-safe: force the resolver seams here,
                // single-threaded, before any packet or probe can race their
                // first touch.
                //
                _ = self.resolverOrchestrator
                self.prewarmResolverBootstrapIfNeeded(admittedAtEpoch: lifecycleGeneration)
                #if DEBUG || LAVA_QA_TOOLS
                EnergyCounters.shared.activate()   // NRG: activate (synchronously) BEFORE the first "startTunnel" probe so its wire bump counts
                #endif
                self.scheduleResolverSmokeProbeIfNeeded(reason: "startTunnel")
                self.startPeriodicResolverSmokeProbe()
                self.startFocusConfigurationPoll()
                self.readPackets(chainedDriver: chainedDriver, lifecycleGeneration: lifecycleGeneration)
                // ONLY a successful CHAINED start clears a prior refusal. A degraded DNS-only start
                // records its refusal earlier in this method, and clearing it here would erase the
                // disclosure that same start just produced
                // (plans/2026-09-18-fail-closed-protection-startup-failures-plan.md). A stale/failed
                // start returns before this point.
                if self.currentTunnelDataPathMode().isChainedUpstream, let markerURL = startupFailureMarkerURL {
                    do {
                        let cleared = try ChainedStartupFailureMarker.clear(
                            generation: self.chainedStartupFailureMarkerGeneration,
                            storageURL: markerURL,
                            lockURL: LavaSecAppGroup.chainedStartupFailureMarkerLockURL)
                        if !cleared {
                            LavaSecDeviceDebugLog.append(
                                component: "tunnel", event: "startTunnel-chaining-marker-clear-stale")
                        }
                    } catch {
                        LavaSecDeviceDebugLog.append(
                            component: "tunnel", event: "startTunnel-chaining-marker-clear-failed",
                            details: ["error": Self.errorSummary(error)])
                    }
                }
                // Drain known translations before readiness, without running the large runtime
                // setup body on dnsStateQueue. The success closure executes inline with the
                // policy's ready transition: discovery cannot post between that transition and
                // NetworkExtension's startup completion (INV-QUEUE-1, INV-DNS-1).
                // pinned: DNSPatchRouteDiscoverySourceTests.testStartupDrainsKnownRoutesBeforeReadinessAndCancelsOnInvalidation
                self.finishDNSPatchStartupSettings(lifecycleGeneration: lifecycleGeneration) { [weak self] error in
                    guard let self else {
                        completion(error ?? CocoaError(.userCancelled))
                        return
                    }
                    if let error {
                        guard self.isCurrentTunnelLifecycle(lifecycleGeneration) else {
                            completion(CocoaError(.userCancelled))
                            return
                        }
                        #if DEBUG || LAVA_QA_TOOLS
                        startSpan.end(details: ["status": "dns-patch-settings-error", "errorKind": "\(type(of: error))"])
                        #endif
                        // Failed/stale delivery runs off dnsStateQueue; the existing teardown
                        // funnel cancels discovery and pending startup policy before returning.
                        self.cleanUpTunnelRuntimeAfterFailedStart(reason: "dns-patch-startup-settings-error") {
                            completion(error)
                        }
                        return
                    }
                    self.tunnelStartupDidComplete = true
                    // The gap a committed self-reconnect opened closes HERE — every known
                    // startup route installed, packets flowing — never at startTunnel entry.
                    Self.closeDanglingSelfReconnectGapIfNeeded()
                    LavaSecDeviceDebugLog.append(component: "tunnel", event: "startTunnel-ready")
                    #if DEBUG || LAVA_QA_TOOLS
                    LavaSecDeviceDebugLog.append(component: "tunnel", event: "dns-block-address-mode", details: [
                        "mode": self.blockedAddressModeForQA.rawValue,
                    ])
                    startSpan.end(details: ["status": "ready"])
                    #endif
                    completion(nil)
                    // An immediate first-unlock poll can finish before this callback returns.
                    // Report startup success before admitting any recovery cancellation.
                    // pinned: ChainedBootRecoverySourceTests.testSuccessfulStartupArmsUnlockRecoveryAndTeardownCancelsIt
                    self.startChainedBootRecoveryIfNeeded(generation: lifecycleGeneration,
                        startedWithProtectedDataUnavailable: startedWithProtectedDataUnavailable)
                }
            }
        }
    }

    override func stopTunnel(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
        #if DEBUG || LAVA_QA_TOOLS
        let stopStartedAt = DispatchTime.now().uptimeNanoseconds
        // Capture the OS stop reason (raw + readable) so an unexpected,
        // system-initiated teardown — e.g. .internalError(17), which stops the
        // tunnel with no app involvement and no auto-restart — is diagnosable
        // from the log instead of appearing as a "silent" disconnect.
        LavaSecDeviceDebugLog.append(component: "tunnel", event: "stopTunnel", details: [
            "reason": "\(reason.rawValue)",
            "reasonName": Self.stopReasonName(reason)
        ])
        #endif

        let completion = TunnelCompletion(handler: completionHandler)
        invalidateTunnelLifecycle(reason: "stopTunnel")
        cleanUpTunnelRuntimeAfterStop(reason: "stopTunnel", endedByCleanStop: true) {
            #if DEBUG || LAVA_QA_TOOLS
            LavaSecDeviceDebugLog.append(component: "tunnel", event: "stopTunnel-completing", details: [
                "reasonName": Self.stopReasonName(reason),
                "durationMs": String((DispatchTime.now().uptimeNanoseconds - stopStartedAt) / 1_000_000),
                "processID": String(ProcessInfo.processInfo.processIdentifier),
            ])
            #endif
            completion.complete()
        }
    }

    // Stamp when the suspension began so the next wake() can tell a micro-sleep from a
    // real one. The stamp is dnsStateQueue-confined (INV-QUEUE-1); the completion is
    // signalled only after the stamp lands so iOS cannot suspend us between the two.
    override func sleep(completionHandler: @escaping () -> Void) {
        LavaSecDeviceDebugLog.append(component: "tunnel", event: "sleep")
        // Hand back the unanswered-query suppressor's tail BEFORE the process can freeze: a
        // jetsam while suspended takes the held counts with it, and this seam is the last
        // guaranteed line of execution the extension gets (PR #620). Synchronous and
        // lock-guarded rather than queued, so it lands ahead of the completion below —
        // dnsStateQueue work is not guaranteed to run once iOS has suspended us.
        flushSuppressedUnansweredDNSQueries()
        let completion = TunnelCompletion(handler: completionHandler)
        dnsStateQueue.async { [weak self] in
            // The chained driver quiesces at the same boundary, BEFORE the completion at
            // this block's tail — its one-shots are due-or-delivered timers that could
            // only surrender into the suspension (the driver's own sleep doc). The hop
            // onto the engine queue is one-directional: nothing on the engine queue ever
            // waits on dnsStateQueue (INV-QUEUE-1), so this cannot deadlock.
            self?.chainedRuntime?.driver.sleep()
            self?.resolverSleepBeganAt = Date()
            // Drain the event log's buffered best-effort appends before iOS can suspend the
            // process: batched appends (UR-53 follow-up) hold up to a flush window in memory,
            // and a jetsam while suspended would silently drop that tail from Domain History.
            // One bounded transaction, mirroring the stop-path drain (PR #327 review).
            // Same drain-and-prune primitive as stop, but RETAIN on failure — sleep is a
            // SUSPENSION, not termination: iOS resumes the process in the common case, and
            // dropping a contended batch here would permanently lose up to a flush window of
            // legitimate history on every ordinary resume (OCR P1, lavasec-ios#54 sync
            // review, correcting PR #351 round 7's over-extension of the stop-path drop).
            // Retention is privacy-safe in every leg: post-wake, the retained batch's retry
            // commits and the controller's self-re-armed pass prunes below the persisted
            // floor even on an idle tunnel (PR #351 round 8); a jetsam while suspended kills
            // the uncommitted in-memory batch outright; and the pre-suspension-retry leg is
            // improbable (queues freeze at suspension, the retry sits a full flush interval
            // out) and even then bounded by the floor + the next session's first pass. Only
            // STOP keeps the drop — there the process exit is certain and no later pass
            // exists.
            // Worst-case latency bound (OCR, lavasec-ios#54 sync review): each half can wait
            // at most one 2s busy_timeout, and only when a cross-process writer contends that
            // half independently — ~4s needs two just-in-time lock grabs in succession. The
            // pre-#351 sleep drain already accepted the first 2s; NEProvider sleep completion
            // has no hard watchdog (iOS holds suspension until it's signalled), and trading a
            // rare bounded delay for the clear-local-logs promise is the right side to err on.
            self?.drainAndPruneDNSEventLog(discardOnFailure: false)
            // THE BOUNDARY, signalled after the drain and before the completion. Until this
            // point the process is still executing legitimately, and the driver's unpaired-sleep
            // self-heal must not read a packet-flow callback as proof of a resume — doing so
            // cleared the suspension latch and re-armed the timers moments before iOS actually
            // suspended (Codex P1, PR #581).
            self?.chainedRuntime?.driver.confirmSuspensionBoundary()
            completion.complete()
        }
    }

    // iOS can suspend the extension while the device sleeps (e.g. in a pocket
    // while walking out the door) and then call wake() when it resumes. After a
    // REAL sleep the upstream resolver connections and bootstrapped endpoint IPs
    // are likely stale, so drop them and re-probe: refresh device DNS, force-drop
    // cached responses and tear down stale UDP sockets / DoH/DoT/DoQ connections,
    // invalidate the bootstrap cache, then schedule the resolver re-handshake once
    // the path settles. The forced reset is what keeps a query arriving before the
    // coalesced settle probe from reusing a pre-sleep connection.
    //
    // BRIEF sleeps are the exception (UR-48 Phase 2a): a thrashing device (rc9 log:
    // 303 wakes/9.7 h) paid a fresh DoH TLS handshake + SERVFAIL'd pending queries
    // on every micro-sleep, tearing down the very sessions carrying DNS. When the
    // observed suspension is within DeviceDNSFallbackPolicy's preserve threshold,
    // wake keeps the live runtime. Safety nets for the skip: the settle probe
    // scheduled below re-checks the resolver (wedge recovery tears down a dead
    // socket), and a genuine network change still gets a force reset from
    // handleNetworkPathUpdate independently of wake.
    // pinned: PacketTunnelDNSRuntimeSourceTests.testWakePreservesResolverRuntimeAcrossBriefSleeps
    //
    // We deliberately do NOT clear the device-DNS fallback decision here. wake()
    // also fires on ordinary sleep with no network change; clearing fallback would
    // drop a fallback that is keeping DNS working (configured resolver failing on
    // this network) and force a failing-primary retry — a fresh stall every wake.
    // Real network changes are handled by handleNetworkPathUpdate (which does clear
    // fallback). Computing the reset identifier with the current mode keeps the
    // post-reset runtime consistent with what queries use; the settle probe still
    // re-checks the primary in the background and recovers if it now works.
    override func wake() {
        // Device-log appends stay un-gated so Release/TestFlight feedback reports
        // capture VPN wake events (privacy-audited: no event records a queried
        // domain). #21 shipped this in Release; do not re-wrap in #if DEBUG.
        LavaSecDeviceDebugLog.append(component: "tunnel", event: "wake")
        dnsStateQueue.async { [weak self] in
            guard let self else {
                return
            }

            // AT THE BLOCK'S HEAD, deliberately: the brief-sleep preserve branch below
            // returns early, and the driver's paired wake — budget refund, liveness
            // reset, outage end — must run on EVERY wake, micro-sleep included (303
            // wakes in 9.7 h in the rc9 field data; the preserve branch is the common
            // case, not the exception).
            self.chainedRuntime?.driver.wake()

            let sleepBeganAt = self.resolverSleepBeganAt
            self.resolverSleepBeganAt = nil

            // Invalidate any smoke probe already in flight (regular or
            // fallback-recovery) so a result computed before sleep can't apply
            // after resume and flip the fallback decision on stale, pre-sleep
            // network conditions — without itself clearing fallback.
            self.invalidateInFlightSmokeProbes()
            let preWakeResolverIdentifier = self.currentResolverRuntimeConfiguration().cacheIdentifier
            self.refreshDeviceDNSResolverAddressesOnDNSQueue(reason: "wake")
            let resolverIdentifier = self.currentResolverRuntimeConfiguration().cacheIdentifier

            // Preserve only when the wake capture kept the SAME effective resolver identity:
            // a brief Wi-Fi/cellular handoff can adopt a different device-DNS set during the
            // refresh above, and preserving then would leave in-flight completions from the
            // old runtime valid against a runtime whose queries now use different resolvers
            // (PR #330 review). An identity change takes the full reset below with the fresh
            // identifier, exactly like a long sleep.
            if resolverIdentifier == preWakeResolverIdentifier,
               DeviceDNSFallbackPolicy.shouldPreserveResolverRuntimeAcrossWake(
                   sleepBeganAt: sleepBeganAt,
                   now: Date()
               ) {
                // Brief suspension: keep the live sessions and in-flight queries — anything
                // the (possibly swapped) network actually killed fails fast and rides the
                // existing failure-evidence → wedge-recovery reset within seconds, which is
                // the probe-confirm this skip leans on (the settle probe below re-checks).
                // The response CACHE is the one channel with no such self-heal: if the sleep
                // spanned a SAME-IDENTITY network swap (Wi-Fi→Wi-Fi where both LANs hand out
                // 192.168.1.1, invisible to the identity guard above AND to
                // handleNetworkPathUpdate's kind/satisfied meaningful-change test), stale
                // answers would keep serving silently. Drop it — a cache clear costs no
                // radio, so the energy win (no TLS re-handshake) is untouched (PR #330 review).
                self.dnsResponseCache.removeAll()
                // Same reasoning for the bootstrap hostname→IP cache: prewarm suppresses
                // refresh while an entry is cached, so a stale bootstrap IP after a
                // same-identity swap would persist even through a later wedge reset — with
                // no failure-driven self-heal of its own. Invalidation is metadata-only
                // (live sessions untouched; the next re-dial just re-resolves the
                // hostname), so the energy win is unaffected (PR #330 review).
                self.resolverBootstrapService.invalidateAll()
                if let sleepBeganAt {
                    LavaSecDeviceDebugLog.append(component: "tunnel", event: "wake-resolver-reset-skipped", details: [
                        "sleptSeconds": String(format: "%.1f", Date().timeIntervalSince(sleepBeganAt))
                    ])
                }
                self.resolverProbeCoalescer.noteUnsettled()
                self.scheduleDeviceDNSCaptureRetryIfNeeded(reason: "wake")
                return
            }

            let pendingResponses = self.collectPendingResponsesAndResetResolverRuntime(
                identifier: resolverIdentifier,
                reason: "wake",
                force: true
            )
            self.resolverBootstrapService.invalidateAll()
            // The lifecycle is what decides whether a drained request is still serviceable,
            // and an INACTIVE lifecycle shares the current generation number (invalidate bumps
            // it, and nothing begins a new one until the next startTunnel), so a generation
            // compare alone would wave a retired tunnel through. Capture nil instead and let
            // the replay fail those closed.
            // Annotated: a ternary whose other arm is a bare `nil` has no contextual type.
            let replayLifecycleGeneration: UInt64? = self.tunnelLifecycleIsActive
                ? self.tunnelLifecycleGeneration
                : nil
            self.replayPendingDNSRequestsAfterWake(
                pendingResponses,
                expectedLifecycleGeneration: replayLifecycleGeneration
            )
            self.resolverProbeCoalescer.noteUnsettled()
            // The pre-sleep capture is likely stale (the device may have changed
            // networks while suspended); retry the read so a device-DNS user adopts
            // the current network's resolvers without waiting on a restart.
            self.scheduleDeviceDNSCaptureRetryIfNeeded(reason: "wake")
        }
    }

    #if DEBUG || LAVA_QA_TOOLS
    private static func stopReasonName(_ reason: NEProviderStopReason) -> String {
        switch reason {
        case .none: return "none"
        case .userInitiated: return "userInitiated"
        case .providerFailed: return "providerFailed"
        case .noNetworkAvailable: return "noNetworkAvailable"
        case .unrecoverableNetworkChange: return "unrecoverableNetworkChange"
        case .providerDisabled: return "providerDisabled"
        case .authenticationCanceled: return "authenticationCanceled"
        case .configurationFailed: return "configurationFailed"
        case .idleTimeout: return "idleTimeout"
        case .configurationDisabled: return "configurationDisabled"
        case .configurationRemoved: return "configurationRemoved"
        case .superceded: return "superceded"
        case .userLogout: return "userLogout"
        case .userSwitch: return "userSwitch"
        case .connectionFailed: return "connectionFailed"
        case .sleep: return "sleep"
        case .appUpdate: return "appUpdate"
        default:
            // .internalError = 17 (iOS 18.1+, "an internal error occurred in the
            // NetworkExtension framework"). Matched by raw value to stay
            // build-safe below the availability floor.
            return reason.rawValue == 17 ? "internalError" : "unknown(\(reason.rawValue))"
        }
    }
    #endif

    private func beginTunnelLifecycle(reason: String) -> UInt64 {
        let begin: () -> UInt64 = {
            // A same-instance start without prior teardown must not inherit a policy
            // from a patch-enabled session when this profile has the patch disabled.
            // pinned: DNSPatchRouteDiscoverySourceTests.testFreshLifecycleDiscardsThePriorStartupPolicy
            self.dnsPatchStartupInstallPolicy?.cancel()
            self.dnsPatchStartupInstallPolicy = nil
            self.cancelDNSPatchStartupInstallCompletion()
            self.tunnelLifecycleGeneration += 1
            self.tunnelLifecycleIsActive = true
            self.resetResolverTierEvidence()
            #if DEBUG || LAVA_QA_TOOLS
            LavaSecDeviceDebugLog.append(component: "tunnel", event: "lifecycle-begin", details: [
                "reason": reason,
                "generation": "\(self.tunnelLifecycleGeneration)"
            ])
            #endif
            return self.tunnelLifecycleGeneration
        }

        if DispatchQueue.getSpecific(key: dnsStateQueueSpecificKey) == true {
            return begin()
        }

        return dnsStateQueue.sync(execute: begin)
    }

    private func invalidateTunnelLifecycle(reason: String) {
        let invalidate = {
            self.tunnelLifecycleGeneration += 1
            self.tunnelLifecycleIsActive = false
            self.resetResolverTierEvidence()
            self.dnsPatchStartupInstallPolicy?.cancel()
            self.cancelDNSPatchStartupInstallCompletion()
            self.cancelChainedBootRecovery()
            self.cancelPendingProtectionNotification()
            self.scheduleProtectionNotificationIfNeeded()
            self.invalidateResolverSmokeProbeToken()
            self.cancelTransientBootstrapDNSWait(reason: "lifecycle-invalidated-\(reason)")
            #if DEBUG || LAVA_QA_TOOLS
            LavaSecDeviceDebugLog.append(component: "tunnel", event: "lifecycle-invalidated", details: [
                "reason": reason,
                "generation": "\(self.tunnelLifecycleGeneration)"
            ])
            #endif
        }

        if DispatchQueue.getSpecific(key: dnsStateQueueSpecificKey) == true {
            invalidate()
            return
        }

        dnsStateQueue.sync(execute: invalidate)
    }

    /// Whether a tunnel session is running right now, read on `dnsStateQueue` through the
    /// usual dual-entry pattern (`INV-QUEUE-1`).
    ///
    /// The activity BIT, not the generation: callers here are asking "is there a session at
    /// all", and between `invalidateTunnelLifecycle` and the async cleanup the generation
    /// still holds the number the session ended on — the same distinction
    /// `currentTunnelledPlainDNSRoute` draws.
    private func currentTunnelLifecycleIsActive() -> Bool {
        if DispatchQueue.getSpecific(key: dnsStateQueueSpecificKey) == true {
            return tunnelLifecycleIsActive
        }

        return dnsStateQueue.sync { tunnelLifecycleIsActive }
    }

    func isCurrentTunnelLifecycle(_ generation: UInt64) -> Bool {
        if DispatchQueue.getSpecific(key: dnsStateQueueSpecificKey) == true {
            return generation == tunnelLifecycleGeneration
        }

        return dnsStateQueue.sync {
            generation == tunnelLifecycleGeneration
        }
    }

    private func cleanUpTunnelRuntimeAfterFailedStart(reason: String, completion: @escaping @Sendable () -> Void) {
        invalidateTunnelLifecycle(reason: reason)
        cleanUpTunnelRuntimeAfterStop(reason: reason, endedByCleanStop: false, completion: completion)
    }

    // `endedByCleanStop` distinguishes the two shapes that reach this one funnel: a session
    // that ran and is stopping through its own teardown, and a start that failed before
    // running. The chained termination evidence needs the difference — see
    // `finalizeChainedTerminationEvidence`.
    private func cleanUpTunnelRuntimeAfterStop(reason: String, endedByCleanStop: Bool, completion: @escaping @Sendable () -> Void) {
        pathMonitor.cancel()
        dohResolver.cancel()
        // Quiesces too, for the same reasons as the DoQ line below and with the same resume
        // in resetResolverRuntimeForTunnelLifecycle. DoT pools and REUSES its lanes, so a
        // straggler rebuilding the pool after teardown does not just waste one handshake —
        // it leaves the next session serving from connections the previous session's dying
        // work opened.
        //
        // The resume pairing matters MORE here than for DoQ: `availableTransports` offers
        // DoT for any first-party preset with a DoT variant, where DoQ needs a custom
        // `doq://` resolver — so a transport left refusing is an ordinary-user outage.
        // pinned: PacketTunnelDNSRuntimeSourceTests.testOnlyStartTunnelBeginsALifecycle
        dotResolver.cancel()
        // Quiesces as well as cancels: active resolver I/O can complete after stop,
        // so cancelling alone left the failover ladder free to rebuild a pool and open
        // a fresh QUIC connection AFTER teardown. The transport stays refusing until
        // resetResolverRuntimeForTunnelLifecycle resumes it at the next startTunnel.
        //
        // A transport left refusing with no resume would SERVFAIL every DoQ query. A lifecycle
        // begins only in startTunnel, where the resolver reset resumes it. The initial settings
        // callback checks its lifecycle before the error cleanup branch, so a stale settings
        // error cannot enter this funnel and quiesce a successor session's resolver runtime.
        // pinned: PacketTunnelDNSRuntimeSourceTests.testOnlyStartTunnelBeginsALifecycle
        doqResolver.cancel()
        stopPeriodicResolverSmokeProbe()
        stopFocusConfigurationPoll()
        cancelProtectionPauseResumeTimer()
        endProtectionVPNSession(reason: reason)
        cancelFallbackRecoverySmokeProbe()
        cancelResolverWedgeRecoveryProbe()
        cancelDeviceDNSCaptureRetry()

        dnsStateQueue.async { [weak self] in
            guard let self else {
                completion()
                return
            }

            // Cancel the pending coalesced settle probe here, on dnsStateQueue: the
            // coalescer is queue-confined (not Sendable), so it can't be cancelled
            // with the off-queue cancels above. A stop/failed-start within the
            // ~1.5s settle window would otherwise leave one live timer that runs
            // resolver work after teardown.
            self.dnsPatchDiscovery?.cancel()
            self.dnsPatchDiscovery = nil
            self.dnsPatchObservedEndpoints = []
            self.dnsPatchStartupInstallPolicy = nil
            self.cancelDNSPatchStartupInstallCompletion()
            self.resolverProbeCoalescer.cancel()
            // The synchronous lifecycle gate blocks new probe admission after
            // invalidation. Keep a second token fence after every queued source
            // cancellation as defense in depth: a source already executing at the
            // boundary, or a future admission path, still cannot project resolver
            // evidence into a stopped provider.
            self.invalidateResolverSmokeProbeToken()
            self.invalidateSnapshotReloadGeneration(reason: reason)
            self.diagnostics.stopLocalProtectionUptime()
            self.markDiagnosticsUpdated()
            // Capture the session's FINAL chained counters before `chainedRuntime` is nilled
            // below — a short session that stopped before any 60 s focus tick would otherwise
            // persist zeros (Codex, PR #551) — THEN clear the flag so the persisted snapshot does
            // not assert "Chained (VPN)" on the disconnected Nerd Stats screen. On dnsStateQueue,
            // before the final forced flush; no focus tick runs after stop to do either.
            if let counters = self.chainedRuntime?.driver.snapshotCounters() {
                self.applyChainedDriverCounters(counters)
            }
            self.health.isChainedUpstreamActive = false
            // AND THE ROTATION IDENTITY, for the same reason and in the same breath. The mirror is
            // its only other writer and no focus tick runs after stop, so without this the forced
            // flush below persists the stopped session's rotation — and the freshness policy keys
            // on the generation alone, so changing or removing the stored configuration afterwards
            // made the settings panel demand a restart for a session that no longer exists
            // (Codex P2, PR #613). `0` is the field's "none", which the policy reads as silence.
            // pinned: TunnelDataPathLatchSourceTests.testStopClearsTheRunningRotationBeforePersisting
            self.health.runningChainedUpstreamGeneration = 0
            // Clear partial window evidence and its baseline before publishing the stopped session.
            // pinned: ChainedTelemetrySurfaceSourceTests.testTheDataPathWindowIsClearedOnStop
            self.health.chainedDataPathTransmitWindowBytes = 0
            self.health.chainedDataPathReceiveWindowBytes = 0
            self.health.chainedDataPathHasHandshake = false
            self.lastChainedDataPathStatsSample = nil
            self.persistHealthIfNeeded(force: true)
            self.persistDiagnosticsIfNeeded(force: true)
            // A locked-boot stop can never persist diagnostics: the write closure refuses
            // the boot-empty stores (INV-PERSIST-1) and each refusal re-arms its own retry,
            // but loadDiagnosticsAndEventLogStores never runs again in a stopped lifecycle,
            // so the flag cannot clear and the stopped process would wake every interval
            // forever without a write ever succeeding (Codex P2 round 10 on #377).
            // Abandoning loses nothing — the resident store is the boot placeholder the
            // gate exists to bury; the user's real data is still on disk, untouched.
            // Health is abandoned with it: post-INV-PERSIST-2 its write closure is ungated
            // (Class-None file, writes land pre-unlock), so this abandon is defense in depth
            // for a transiently-failed stop flush — a dead session's health that the next
            // start's resetHealth overwrites is never worth a stopped process's retry wake.
            if self.diagnosticsStoresReflectLockedBoot {
                self.diagnosticsPersistence.abandonUnpersistedState()
                self.healthPersistence.abandonUnpersistedState()
            }
            // Drain any fire-and-forget SQLite appends still queued on the log before we signal
            // stop completion. The JSON diagnostics were just force-flushed, but the app reads
            // Domain History from SQLite — so if the NE process is suspended with appends still
            // queued, the newest decisions would vanish from the list (PR #327 review).
            //
            // Drain-AND-prune, not a bare flush: if the force-flushed diagnostics pass above
            // skipped ITS prune because an app-side clear held the SQLite lock, a bare drain
            // here that then succeeds would commit the retained pre-clear batch with no later
            // pass ever running — the process is exiting and the debounced controller's dirty
            // retention can't help a dead process (Codex P1, PR #351 round 4). The helper
            // couples the prune to the successful drain; a drain that STILL fails is
            // privacy-fail-safe (the uncommitted batch dies with the process).
            //
            // The chained termination evidence settles here, on dnsStateQueue where the
            // latched mode is readable, before the completion that lets iOS suspend the
            // process. A DNS-only session must not touch it: its clean stop is not evidence
            // about a chained session, and the marker it would clear belongs to the chained
            // session that died to put this device in DNS-only.
            // pinned: TunnelDataPathLatchSourceTests.testTheTeardownFunnelSettlesChainedTerminationEvidence
            // The chained runtime is retired BEFORE the termination evidence settles:
            // retire shuts the session down and breaks the driver↔runner cycle (the only
            // place it breaks — `INV-MEM-1`), and the settle below then records a stop the
            // data path has genuinely finished. The engine-queue hop inside retire is
            // one-directional (nothing on the engine queue waits on dnsStateQueue), so it
            // cannot deadlock this block. Nilled HERE, on dnsStateQueue, where every
            // reader of `chainedRuntime` is confined.
            // pinned: ChainedProviderConstructionSourceTests.testTheTeardownFunnelRetiresTheChainedRuntime
            if let runtime = self.chainedRuntime {
                runtime.directDNS?.retire()
                runtime.driver.retire()
                LavaSecDeviceDebugLog.append(
                    component: "tunnel", event: "chained-runtime-retired",
                    details: [
                        "droppedDNSQueries": "\(runtime.dnsServingAdapter.droppedQueryCount())"
                    ])
                self.chainedRuntime = nil
                self.chainedClaimedResolverDestinations = nil
            }
            // A clean stop only counts as one if the session it is stopping actually
            // STARTED: a stopTunnel that lands while setTunnelNetworkSettings is still
            // pending cancels a start, and a cancelled start is no more evidence the
            // device coped than a failed one (Codex, PR #499).
            if self.latchedDataPathMode.isChainedUpstream,
                let lifecycleEvidenceID = self.latchedChainedLifecycleEvidenceID
            {
                self.finalizeChainedTerminationEvidence(
                    owningLifecycleID: lifecycleEvidenceID,
                    endedByCleanStop: endedByCleanStop && self.tunnelStartupDidComplete)
            }
            self.drainAndPruneDNSEventLog(discardOnFailure: true)
            // Teardown drains and traces waiters before iOS can terminate the process.
            // Drop old-flow replies; startTunnel retains a backstop drain for starts without
            // a preceding teardown (PR #508, #620).
            let abandonedAtTeardown = self.drainPendingDNSResponses()
            self.recordUnansweredDNSBatch(
                reason: "teardown-abandoned-\(reason)", pendingResponses: abandonedAtTeardown)
            // LAST, and in the funnel rather than in `stopTunnel`. Termination is certain from
            // here, so the suppressor's tail has no later flush to reach — but placing it at the
            // top of `stopTunnel` could not capture the failures the teardown ITSELF produces:
            // `invalidateTunnelLifecycle` runs immediately after, and the transient-bootstrap
            // wait it cancels SERVFAILs its batch through `writeServerFailures`, which is a
            // traced seam. A reason/shape already emitted in the previous 30 s would then stay
            // suppressed forever (Codex P2, PR #620).
            //
            // The funnel also covers the shape `stopTunnel` never sees: a failed
            // `setTunnelNetworkSettings` reaches teardown through
            // `cleanUpTunnelRuntimeAfterFailedStart`, which is exactly a session whose DNS never
            // worked — the one a capture most wants to explain.
            self.flushSuppressedUnansweredDNSQueries()
            completion()
        }
    }

    /// Settles the chained session's termination evidence at teardown.
    ///
    /// The marker clears on BOTH teardown shapes: a failed start reaches this funnel too and
    /// must not look like a missing lifecycle callback. The streak reset is conditional on a
    /// clean stop; a failed start is not a healthy lifecycle boundary.
    private func finalizeChainedTerminationEvidence(
        owningLifecycleID: String, endedByCleanStop: Bool
    ) {
        guard let store = chainedDeviceEligibilityStore() else { return }
        do {
            // ONE write settles both halves — the marker clear and the conditional streak
            // reset — so neither a kill nor a failed write can leave a cleared marker whose
            // reset never landed, compounding non-consecutive crashes into a premature
            // exclusion (Codex, PR #499).
            let didSettle = try store.settleTermination(
                owningLifecycleID: owningLifecycleID,
                sessionRanAndStoppedCleanly: endedByCleanStop)
            if !didSettle {
                LavaSecDeviceDebugLog.append(
                    component: "tunnel", event: "chained-settle-lifecycle-moved", details: [:])
            }
        } catch {
            // An unsettled record leaves the marker set and the next start counts a death
            // that did not happen. Logged loudly because nothing else will notice; the
            // single-write shape means nothing can be HALF-done.
            LavaSecDeviceDebugLog.append(
                component: "tunnel", event: "chained-settle-failed",
                details: ["error": Self.errorSummary(error)])
        }
    }

    static func errorDebugDetails(_ error: Error) -> [String: String] {
        let nsError = error as NSError
        return [
            "errorDescription": nsError.localizedDescription,
            "errorDomain": nsError.domain,
            "errorCode": "\(nsError.code)",
            "underlyingError": "\(nsError.userInfo[NSUnderlyingErrorKey] ?? "nil")"
        ]
    }

    // phys_footprint is the dirty + compressed memory iOS charges against the
    // packet-tunnel jetsam limit (mapped/clean file pages are excluded), so it
    // is the right gauge for the snapshot memory budget and for verifying the
    // zero-copy mmap of the domain table.
    static func currentMemoryFootprintMB() -> String {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else {
            return "unknown"
        }
        return String(format: "%.1f", Double(info.phys_footprint) / 1_048_576)
    }

    static func errorSummary(_ error: Error) -> String {
        let nsError = error as NSError
        return "\(nsError.localizedDescription) (\(nsError.domain) \(nsError.code))"
    }

    // Builds settings for the LATCHED data path. The previous name for this seam was
    // `…ForCurrentConfiguration`, which described precisely the thing it must not do: all
    // installs (initial, startup patch drain and flap/IPC reapply) claim the routes this session
    // started with, not the ones the configuration happens to ask for now. The rename is the
    // cheap half of that guarantee; latchedDataPathMode is the load-bearing half.
    func makeTunnelNetworkSettingsForLatchedDataPath() -> TunnelNetworkSettingsBundle {
        let mode = currentTunnelDataPathMode()
        // The ordinary capture floor is claimed only by a chained path. The separate
        // opt-in DNS patch adds only its designated profile endpoints below. This is the conservative,
        // owner-safe scope (Kilo, PR #752). F1's curated public-resolver set
        // (`DNSCaptureFloor.curatedPublicResolverAddresses`) is merged beside F3b's captured device
        // resolvers, but only when `mode.isChainedUpstream`. DNS-only passes `[]` and its route
        // array is byte-for-byte the pre-chaining shape (`INV-DNS-1`), because claiming a resolver
        // there does not serve it: the DNS-only packet loop handles only port-53 datagrams and has
        // no forwarding rung, so every other packet the claim draws in — TCP/QUIC `:443` (a client
        // fetching `https://1.1.1.1`), ICMP — is silently dropped. In chained split the packet
        // enters the classifier, which can knowingly drop and count non-DNS to a claimed resolver,
        // which is what makes the claim safe there instead of a silent black hole.
        //
        // F3b: the CAPTURED device resolvers merge as `/32` + `/128` host routes with the curated
        // set. Full tunnel ignores the floor by construction: its default routes already claim
        // every destination, so the classifier's `dropsUnfilterableEncryptedDNS` owns `:853` there.
        //
        // MEMBERSHIP EXCLUDES THE ON-LINK GATEWAY for the captured set (plan Open decision 1,
        // resolved to "exclude"; ``DNSCaptureFloorMembership``). The capture routinely contains
        // the LAN gateway, and claiming it would draw the router's non-DNS traffic into a tunnel
        // whose peer does not carry it; `NWPath` exposes no gateway identity, so the exclusion is
        // by private/link-local/ULA range and a non-gateway private resolver is the accepted
        // coverage loss. The curated public set needs no such filter — its entries are all public.
        //
        // RESIDUAL, stated rather than hidden: a clear-text resolver an app hardcodes that is NOT
        // a curated entry (or the network's captured resolver) still escapes in DNS-only, exactly
        // as it did before the floor existed. DNS-only has no forwarding rung to serve a hardcoded
        // destination, so it cannot be closed by widening the claim without the silent drop above;
        // the sign-off is disclosure (F5, still copy-pending), not a DNS-only claim.
        var dnsCaptureResolverAddresses = mode.isChainedUpstream
            ? DNSCaptureFloor.curatedPublicResolverAddresses
                + DNSCaptureFloorMembership.claimableResolverAddresses(
                    currentDeviceDNSResolverAddresses())
            : []
        dnsCaptureResolverAddresses += currentDNSPatchCaptureAddresses()
        #if DEBUG || LAVA_QA_TOOLS
        if (protocolConfiguration as? NETunnelProviderProtocol)?
            .providerConfiguration?["qaDNSOnlyDefaultRoutes"] as? Bool == true,
           !mode.isChainedUpstream, !protocolConfiguration.includeAllNetworks {
            return Self.makeTunnelNetworkSettings(
                for: mode, dnsCaptureResolverAddresses: [], declaresDefaultRoutesInDNSOnly: true)
        }
        if (protocolConfiguration as? NETunnelProviderProtocol)?
            .providerConfiguration?["qaDNSOnlyIPv6"] as? Bool == true, !mode.isChainedUpstream {
            return Self.makeTunnelNetworkSettings(
                for: mode, dnsCaptureResolverAddresses: [], advertisesIPv6DNSInDNSOnly: true)
        }
        if let qaResolvers = (protocolConfiguration as? NETunnelProviderProtocol)?
            .providerConfiguration?["qaCapturedDNSResolvers"] as? [String], !qaResolvers.isEmpty {
            return Self.makeTunnelNetworkSettings(
                for: mode, dnsCaptureResolverAddresses: dnsCaptureResolverAddresses + qaResolvers,
                capturesIPv6InDNSOnly: true)
        }
        #endif
        return Self.makeTunnelNetworkSettings(
            for: mode, dnsCaptureResolverAddresses: dnsCaptureResolverAddresses,
            capturesIPv6InDNSOnly: isDNSPatchEnabled)
    }

    /// The profile and capture setting are latched together at provider start. A UI
    /// toggle cannot silently change routes while the saved NE profile still disagrees.
    var isDNSPatchEnabled: Bool {
        (protocolConfiguration as? NETunnelProviderProtocol)?.providerConfiguration?["dnsPatchVersion"] as? Int == 1
            && dnsPatchContract != nil
    }

    func currentDNSPatchCaptureAddresses() -> [String] {
        guard isDNSPatchEnabled, let contract = dnsPatchContract else { return [] }
        if DispatchQueue.getSpecific(key: dnsStateQueueSpecificKey) == true {
            return contract.captureAddresses(observedEndpoints: dnsPatchObservedEndpoints)
        }
        return dnsStateQueue.sync { contract.captureAddresses(observedEndpoints: dnsPatchObservedEndpoints) }
    }

    func startDNSPatchDiscovery(lifecycleGeneration: UInt64) {
        // Initialize before the atomic initial snapshot, including an on-queue entry.
        // pinned: DNSPatchRouteDiscoverySourceTests.testDiscoveryStartsBeforeTheAtomicInitialSettingsCapture
        let start: @Sendable () -> Void = { [weak self] in
            guard let self, self.tunnelLifecycleIsActive, self.isCurrentTunnelLifecycle(lifecycleGeneration),
                  self.isDNSPatchEnabled, let contract = self.dnsPatchContract else { return }
            self.dnsPatchDiscovery?.cancel()
            self.dnsPatchObservedEndpoints = []
            self.dnsPatchStartupInstallPolicy = DNSPatchStartupInstallPolicy(
                contract: contract, lifecycleGeneration: lifecycleGeneration)
            self.dnsPatchDiscovery = DNSPatchRouteDiscovery(contract: contract, initialCompletion: { [weak self] result in
                self?.completeDNSPatchInitialDiscovery(result, lifecycleGeneration: lifecycleGeneration)
            }) { [weak self] addresses in
                guard let self else { return }
                self.dnsStateQueue.async { [weak self] in
                    guard let self, self.tunnelLifecycleIsActive, self.isCurrentTunnelLifecycle(lifecycleGeneration),
                          self.dnsPatchObservedEndpoints != addresses else { return }
                    let action = self.dnsPatchStartupInstallPolicy?.observeEndpoints(
                        addresses, lifecycleGeneration: lifecycleGeneration) ?? .ignore
                    self.dnsPatchObservedEndpoints = addresses
                    LavaSecDeviceDebugLog.append(component: "tunnel", event: "dns-patch-route-observation",
                        details: ["dnsPatchObservedAddresses": addresses.joined(separator: ",")])
                    // Retain startup observations for the serialized install drain. Once
                    // ready, literals, interface duplicates and aliases still need no post;
                    // new translated destinations use the ordinary unthrottled reapply.
                    // pinned: DNSPatchRouteDiscoverySourceTests.testDiscoveryPreservesObservationsButPostsOnlyForChangedCaptureDestinations
                    guard action == .reapply else { return }
                    self.reapplyTunnelNetworkSettings(reason: "dns-patch-physical-path", enforceThrottle: false)
                }
            }
        }
        if DispatchQueue.getSpecific(key: dnsStateQueueSpecificKey) == true {
            start()
        } else {
            dnsStateQueue.async(execute: start)
        }
    }

    /// Records the independent initial result even when no destination array changed.
    private func completeDNSPatchInitialDiscovery(
        _ result: DNSPatchInitialDiscoveryPolicy.Completion, lifecycleGeneration: UInt64
    ) {
        dnsStateQueue.async { [weak self] in
            guard let self, self.tunnelLifecycleIsActive, self.isCurrentTunnelLifecycle(lifecycleGeneration),
                  self.dnsPatchStartupInstallPolicy?.initialDiscoveryDidComplete(
                    result, lifecycleGeneration: lifecycleGeneration) == true else { return }
            switch result {
            case .succeeded:
                LavaSecDeviceDebugLog.append(component: "tunnel", event: "dns-patch-initial-discovery-settled",
                    details: ["generation": "\(lifecycleGeneration)"])
            case .failed(let failure):
                LavaSecDeviceDebugLog.append(component: "tunnel", event: "dns-patch-initial-discovery-failed",
                    details: ["generation": "\(lifecycleGeneration)", "reason": failure.rawValue])
            }
            // Only initial preparation retains a discovery wait completion. Consume before
            // resuming it so a reentrant stop cannot deliver twice.
            // pinned: DNSPatchRouteDiscoverySourceTests.testInitialSettlementResumesOrCancelsTheRetainedCompletionExactlyOnce
            guard let completion = self.dnsPatchStartupInstallCompletion else { return }
            self.dnsPatchStartupInstallCompletion = nil
            self.prepareDNSPatchInitialSettings(lifecycleGeneration: lifecycleGeneration, completion: completion)
        }
    }

    private func cancelDNSPatchStartupInstallCompletion() {
        dispatchPrecondition(condition: .onQueue(dnsStateQueue))
        guard let completion = dnsPatchStartupInstallCompletion else { return }
        dnsPatchStartupInstallCompletion = nil
        DispatchQueue.global(qos: .utility).async { completion(CocoaError(.userCancelled)) }
    }

    /// Discovery runs independently on physical interfaces. Keep one cancellable wait before
    /// capturing initial routes; deliver off the DNS queue for the existing runtime setup body.
    // pinned: DNSPatchRouteDiscoverySourceTests.testInitialPreparationWaitUsesTheOwnedCompletionAndRevalidatesLifecycle
    private func prepareDNSPatchInitialSettings(
        lifecycleGeneration: UInt64, completion: @escaping @Sendable (Error?) -> Void
    ) {
        dnsStateQueue.async { [weak self] in
            guard let self, self.tunnelLifecycleIsActive,
                  self.isCurrentTunnelLifecycle(lifecycleGeneration) else {
                DispatchQueue.global(qos: .utility).async { completion(CocoaError(.userCancelled)) }
                return
            }
            let action = self.dnsPatchStartupInstallPolicy?.initialSettingsAction(
                lifecycleGeneration: lifecycleGeneration) ?? .ready
            switch action {
            case .waitForDiscovery:
                self.dnsPatchStartupInstallCompletion = completion
                LavaSecDeviceDebugLog.append(component: "tunnel", event: "dns-patch-initial-settings-waiting-for-discovery",
                    details: ["generation": "\(lifecycleGeneration)"])
            case .discoveryFailed(let failure):
                DispatchQueue.global(qos: .utility).async { completion(failure) }
            case .ready:
                DispatchQueue.global(qos: .utility).async { completion(nil) }
            case .ignore:
                DispatchQueue.global(qos: .utility).async { completion(CocoaError(.userCancelled)) }
            }
        }
    }

    /// Settles DNS-patch startup routes on their owning queue, then reports success
    /// inline. Only failures hop off queue for the existing failed-start teardown body.
    private func finishDNSPatchStartupSettings(
        lifecycleGeneration: UInt64,
        completion: @escaping @Sendable (Error?) -> Void
    ) {
        dnsStateQueue.async { [weak self] in
            guard let self, self.tunnelLifecycleIsActive,
                  self.isCurrentTunnelLifecycle(lifecycleGeneration) else {
                DispatchQueue.global(qos: .utility).async { completion(CocoaError(.userCancelled)) }
                return
            }
            let action = self.dnsPatchStartupInstallPolicy?.settingsInstallDidComplete(
                lifecycleGeneration: lifecycleGeneration) ?? .ready
            switch action {
            case .ignore:
                DispatchQueue.global(qos: .utility).async { completion(CocoaError(.userCancelled)) }
            case .ready: completion(nil)
            case .installLatest:
                // INV-DNS-7: republish the classifier from the same live destination set
                // used to build this post, as the normal reapply path does.
                // pinned: DNSPatchRouteDiscoverySourceTests.testStartupSettingsKeepClassifierAndRouteClaimsTogether
                self.chainedClaimedResolverDestinations?.update(
                    self.makeClaimedResolverDestinations(for: self.currentTunnelDataPathMode()))
                let settingsBundle = self.makeTunnelNetworkSettingsForLatchedDataPath()
                let startedAt = DispatchTime.now()
                LavaSecDeviceDebugLog.append(component: "tunnel", event: "dns-patch-startup-settings-begin", details: [
                    "generation": "\(lifecycleGeneration)",
                    "route": settingsBundle.routeDescription,
                    "dnsCapture": settingsBundle.dnsCaptureScope.logValue,
                    "dataPath": settingsBundle.mode.logValue
                ])
                self.setTunnelNetworkSettings(settingsBundle.settings) { [weak self] error in
                    guard let self else {
                        DispatchQueue.global(qos: .utility).async { completion(error ?? CocoaError(.userCancelled)) }
                        return
                    }
                    if let error {
                        self.dnsStateQueue.async { [weak self] in
                            guard let self, self.tunnelLifecycleIsActive,
                                  self.isCurrentTunnelLifecycle(lifecycleGeneration) else {
                                DispatchQueue.global(qos: .utility).async { completion(CocoaError(.userCancelled)) }
                                return
                            }
                            self.dnsPatchStartupInstallPolicy?.cancel()
                            LavaSecDeviceDebugLog.append(component: "tunnel", event: "dns-patch-startup-settings-error",
                                details: Self.errorDebugDetails(error))
                            DispatchQueue.global(qos: .utility).async { completion(error) }
                        }
                        return
                    }
                    LavaSecDeviceDebugLog.append(component: "tunnel", event: "dns-patch-startup-settings-success", details: [
                        "generation": "\(lifecycleGeneration)",
                        "durationMs": "\((DispatchTime.now().uptimeNanoseconds - startedAt.uptimeNanoseconds) / 1_000_000)"
                    ])
                    // A changed path during this post remains pending. Re-enter the gate
                    // after success, so no two startup patch installs can be in flight.
                    self.finishDNSPatchStartupSettings(lifecycleGeneration: lifecycleGeneration, completion: completion)
                }
            }
        }
    }

    /// A recoverable outage under a strict profile must retry the full path. Letting its
    /// suppression select DNS-only would hold all traffic without a forwarding engine.
    private func strictProfileMayRetrySurrender(_ snapshot: ChainedDeviceEligibilityStore.Snapshot) -> Bool {
        guard protocolConfiguration.includeAllNetworks,
              let reason = snapshot.surrenderReasonLogValue else { return false }
        return ChainedReconnectPolicy.Surrender(rawValue: reason)?.isResolvableByNetworkChange ?? false
    }

    // Resolves the data path for this session and stores it. Called from
    // loadInitialSharedState — off dnsStateQueue, at startTunnel, before any network
    // settings exist — so the .sync write cannot deadlock, and no reader can observe the
    // previous session's value: all settings call sites use the resolved latch, and
    // startTunnel's runs after this returns.
    //
    // `configurationIsUnreadable` is forwarded rather than folded into the placeholder: on a
    // pre-first-unlock boot start (INV-PERSIST-1) `configuration` is the empty placeholder,
    // whose chaining flag is false because the file could not be read — not because the user
    // turned it off. The latch has to be able to tell those apart, or a device that wants
    // chaining would report the one refusal the app never reconciles.
    //
    // THE EXPENSIVE READS ARE GATED BEHIND THE CHEAP TERMS, in exactly the order `resolve`
    // consults them. `resolve` takes plain Bools, so Swift's eager argument evaluation would
    // otherwise make every tunnel start — every DNS-only user who never enabled chaining —
    // pay a Keychain round-trip plus a JSON decode in a ~50 MB NE process (`INV-MEM-1`).
    // The gate may include `hasLavaSecurityPlus` because entitlement precedes the memory and
    // exclusion terms inside `ChainedAvailability.ineligibilityReason`; it must NOT include
    // the memory floor, because the floor's own answer depends on the override this gate is
    // deciding whether to read. When the gate refuses, the gated arguments are placeholders
    // an earlier `resolve` guard is guaranteed to shadow.
    // pinned: TunnelDataPathLatchSourceTests.testFlippingTheBuildFlagCannotShipWithPlaceholderInputs
    // pinned: TunnelDataPathLatchSourceTests.testTheEligibilityReadsAreGatedInTheLatchsOwnOrder
    /// The ONE writer of the latch, and the epoch bump is why it must stay the one:
    /// a latch install that skips the bump leaves outstanding tunnelled routes
    /// validating against a latch they were not derived from — the exact
    /// same-generation transition the epoch exists to make visible. Both install
    /// sites (the prologue's resolve and the construction downgrade) funnel here.
    /// pinned: TunnelDataPathLatchSourceTests.testTheLatchHasExactlyOneWriterAndItBumpsTheEpoch
    func installLatchedDataPathMode(
        _ mode: TunnelDataPathMode, refusal: TunnelDataPathLatch.Refusal?,
        chainedTierOneResolverConfiguration: AppConfiguration? = nil,
        chainedLifecycleEvidenceID: String? = nil,
        surrenderIsRecoverable: Bool = false
    ) {
        // Dual-entry per INV-QUEUE-1's helper contract. Today's callers are both
        // off-queue prologue paths, but a bare `sync` here is a deadlock waiting for
        // the first on-queue caller — the exact trap the contract exists to remove
        // (Kilo, PR #518).
        // THE TUNNEL NO LONGER CLAIMS THE T1 RESOLVER'S ROUTE, and must not.
        //
        // A now-deleted `ChainedUpstreamConfiguration` method widened `AllowedIPs` so the tunnel ROUTED
        // the chosen alternative DNS — which made T1 depend on the peer forwarding it, i.e. on
        // the peer being an exit node. rc9 (build 1787723354) measured the consequence: three
        // attempts to 1.1.1.1 through a Tailscale node with no route for it, three drops, nothing
        // back.
        //
        // The rung now leaves on the PHYSICAL interface: its socket is `.systemChosen` (unbound)
        // for an ordinary destination, or pinned to the live physical interface when the DNS
        // capture floor claims the destination (F2,
        // `ChainedResolverEgressPolicy.tierOneSocketBinding`). Either way the datagram leaves the
        // physical path. Claiming the address here would put that route back INSIDE the tunnel and
        // the datagram would re-enter it regardless of the binding — the two halves only work
        // together (Codex, PR #590).
        // The INTENT the widening served survives and is better met: the user loaded a profile,
        // turned the fallback on, and expects both to work without hand-editing the profile. They
        // now do — the resolver is reached on the path their own traffic already takes, with no
        // change to the profile and no dependency on the peer. What is gone is the mechanism, not
        // the promise (PR #584 wrote the promise; it is kept here differently).
        // pinned: TunnelDataPathLatchSourceTests.testTheTunnelDoesNotClaimTheTierOneResolversRoute
        let routedMode = mode

        let install = {
            self.latchedDataPathMode = routedMode
            self.latchedDataPathRefusal = refusal
            // Latched WITH the refusal, from the same snapshot that produced it. The classification
            // lives in `LavaSecChainedUpstream`, which `ChainedStartupContract` cannot import
            // (`docs/architecture/module-boundaries.md`), so the tunnel makes the judgement once
            // here rather than letting the contract re-derive it from a second read that could
            // disagree with the latch it is validating.
            self.latchedSurrenderIsRecoverable = surrenderIsRecoverable
            self.latchedChainedLifecycleEvidenceID = chainedLifecycleEvidenceID
            // The rung's resolver, latched ATOMICALLY with the mode and the epoch bump, so the
            // T1 plan and the settings surface's latched selection can never describe two
            // different resolvers within one session (Codex PR #575 P1). Non-chained modes carry
            // the nil default — every T1 consumer only reads it while chained.
            self.latchedChainedTierOneResolverConfiguration = chainedTierOneResolverConfiguration
            // Stamp the refusal with the lifecycle it belongs to (already bumped by
            // beginTunnelLifecycle before loadInitialSharedState reaches here), so a consumer can tell
            // a ready lifecycle's own refusal from a stale one carried across a lifecycle boundary
            // (Codex, PR #569 round 16).
            self.latchedDataPathRefusalGeneration = self.tunnelLifecycleGeneration
            self.tunnelDataPathLatchEpoch &+= 1
            // NOT PUBLISHED HERE, deliberately. Writing `health` in this closure would be erased
            // by the `resetHealth()` that follows this call in `startTunnel`, and READING the
            // published value here would mean an engineQueue hop from inside this critical
            // section — which no install site needs, since `chainedRuntime` cannot exist yet at
            // either of them (the start latch runs before construction, and the downgrade only
            // runs because construction failed). `mirrorChainedHealthCountersIfChanged` is the
            // single publisher, and `startTunnel` already orders it after the reset.
        }
        if DispatchQueue.getSpecific(key: dnsStateQueueSpecificKey) == true {
            install()
            return
        }

        dnsStateQueue.sync(execute: install)
    }

    func latchDataPathMode(for configuration: AppConfiguration, configurationIsUnreadable: Bool) {
        var deviceStateUnavailable = false
        var deviceSnapshot: ChainedDeviceEligibilityStore.Snapshot?
        var upstreamReadinessLog = ""
        var readyUpstreamConfiguration: ChainedUpstreamConfiguration?
        // The rotation the readiness verdict was decided against, kept beside the configuration
        // it belongs to. A non-secret opaque identifier, which is exactly why it may leave the `Ready`
        // scope below when the two keys beside it may not.
        var readyUpstreamGeneration: UInt64 = 0
        if !configurationIsUnreadable,
            configuration.chainedUpstreamEnabled,
            Self.buildSupportsChainedDataPath,
            configuration.hasLavaSecurityPlus
        {
            if let store = chainedDeviceEligibilityStore() {
                switch store.read() {
                case .snapshot(let snapshot):
                    guard let currentBuildIdentity = Self.chainedBuildIdentity else {
                        LavaSecDeviceDebugLog.append(
                            component: "tunnel", event: "chained-build-identity-unavailable")
                        deviceStateUnavailable = true
                        break
                    }
                    // A stale marker is the previous chained session's death, consumed
                    // (cleared first, then counted — see the store's rationale for that
                    // order) so THIS start's latch sees the post-strike state: the third
                    // strike must refuse the very start that discovers it.
                    if let consumed = try? store.consumeUncleanTerminationEvidence(
                        from: snapshot, currentBuildIdentity: currentBuildIdentity)
                    {
                        // Consumption returns the complete live record that won the lifecycle
                        // transaction. Reusing any field from the earlier read can restore a
                        // surrender that an overlapping explicit Guard start just cleared.
                        deviceSnapshot = consumed
                    } else {
                        deviceStateUnavailable = true
                    }
                case .unavailable(let reason):
                    LavaSecDeviceDebugLog.append(
                        component: "tunnel", event: "device-eligibility-unreadable",
                        details: ["reason": reason])
                    deviceStateUnavailable = true
                }
            } else {
                // No resolvable access group (an unsigned or misconfigured build): the
                // store cannot exist, which is unavailability, never "override off" —
                // `ChainedUpstreamSecretStoreFailure.accessGroupUnavailable` makes the same
                // call for the credential store.
                deviceStateUnavailable = true
            }

            // Readiness is the LAST resolve guard, so it is read only when the terms ahead
            // of it can pass — the same predicate, evaluated through the same policy type
            // rather than a copy of it. The surrender term sits between eligibility and
            // readiness in `resolve`'s own order, so it gates here too: a surrendered
            // device resolves DNS-only whatever the store holds, and should not pay the
            // Keychain round-trip to learn something the latch will not consult.
            if let snapshot = deviceSnapshot,
                ChainedAvailability.isEligible(
                    hasLavaSecurityPlus: configuration.hasLavaSecurityPlus,
                    physicalMemoryBytes: ProcessInfo.processInfo.physicalMemory,
                    experimentalOverrideEnabled: snapshot.experimentalOverrideEnabled,
                    hasStartupCrashLoopTripped: snapshot.backoffState.hasTripped
                ),
                (!snapshot.isSurrenderSuppressed || strictProfileMayRetrySurrender(snapshot))
            {
                let readiness = evaluateChainedUpstreamReadiness()
                // Only the CONFIGURATION leaves this scope. `Ready` also carries the
                // private key, and the latch payload is stored for the whole session and
                // read from logs-adjacent code — the session build re-reads the secret
                // through its own fresh snapshot instead (the readiness type's own rule:
                // build the session and drop the `Ready`).
                if case .ready(let ready) = readiness {
                    readyUpstreamConfiguration = ready.configuration
                    readyUpstreamGeneration = ready.generation.value
                }
                // The six-way refusal split is the signal the app's re-enter-key flow
                // needs; collapsing it to the latch's single `upstreamUnavailable` here
                // would discard the one place it is observable.
                upstreamReadinessLog = readiness?.logValue ?? "store-unbuildable"
            }
        }

        var resolution = TunnelDataPathLatch.resolve(
            configurationIsUnreadable: configurationIsUnreadable,
            chainedUpstreamEnabled: configuration.chainedUpstreamEnabled,
            buildSupportsChainedDataPath: Self.buildSupportsChainedDataPath,
            hasLavaSecurityPlus: configuration.hasLavaSecurityPlus,
            physicalMemoryBytes: ProcessInfo.processInfo.physicalMemory,
            deviceLocalStateIsUnavailable: deviceStateUnavailable,
            experimentalOverrideEnabled: deviceSnapshot?.experimentalOverrideEnabled ?? false,
            hasStartupCrashLoopTripped: deviceSnapshot?.backoffState.hasTripped ?? false,
            isSurrenderSuppressed: (deviceSnapshot?.isSurrenderSuppressed ?? false)
                && !(deviceSnapshot.map(strictProfileMayRetrySurrender) ?? false),
            readyUpstream: readyUpstreamConfiguration
        )
        // Whether a standing surrender is one a network change can lift. Read from the SAME
        // snapshot the latch resolved from: a second store read could return a reason the latch
        // never saw, and the contract would then permit a DNS-only start for a suppression that
        // is not the one standing.
        let latchedSurrenderIsRecoverable = deviceSnapshot?.surrenderReasonLogValue.map {
            ChainedReconnectPolicy.Surrender(rawValue: $0)?.isResolvableByNetworkChange ?? false
        } ?? false

        // A chained lifecycle that cannot write its marker cannot participate in the startup-loop
        // breaker. Downgrade with the store's transient refusal, never a device diagnosis.
        // pinned: TunnelDataPathLatchSourceTests.testAChainedResolutionMarksTheSessionOrDowngrades
        var chainedLifecycleEvidenceID: String?
        if resolution.mode.isChainedUpstream {
            var marked = false
            if let snapshot = deviceSnapshot, let store = chainedDeviceEligibilityStore(),
                let buildIdentity = Self.chainedBuildIdentity
            {
                let lifecycleID = UUID().uuidString
                marked = (try? store.markChainedSessionStarted(
                    from: snapshot,
                    buildIdentity: buildIdentity,
                    lifecycleID: lifecycleID)) == true
                if marked { chainedLifecycleEvidenceID = lifecycleID }
            }
            if !marked {
                resolution = TunnelDataPathLatch.Resolution(
                    mode: .dnsOnly, refusal: .deviceStateUnavailable)
            }
        }

        // Latch the T1 rung's resolver with the mode, so the whole session reads one
        // selection (Codex PR #575 P1). Only for a chained latch — `.dnsOnly` has no T0
        // through a tunnel for a T1 to be second to — and `nil` when the user's selection is
        // Device DNS, the one selection that may never be the rung.
        // pinned: TunnelDataPathLatchSourceTests.testTheTierOneResolverIsLatchedFromTheUsersOwnSelection
        installLatchedDataPathMode(
            resolution.mode, refusal: resolution.refusal,
            chainedTierOneResolverConfiguration: resolution.mode.isChainedUpstream
                ? configuration.chainedTierOneResolverConfiguration : nil,
            chainedLifecycleEvidenceID: resolution.mode.isChainedUpstream
                ? chainedLifecycleEvidenceID : nil,
            surrenderIsRecoverable: latchedSurrenderIsRecoverable)

        LavaSecDeviceDebugLog.append(component: "tunnel", event: "data-path-latched", details: [
            "dataPath": resolution.mode.logValue,
            "refusal": resolution.refusal?.logValue ?? "",
            "upstreamReadiness": upstreamReadinessLog,
            // DIAGNOSTICS, not the published identity — that is derived from the live runner,
            // because readiness approving a rotation is not the same as a session running it.
            // This names what the latch APPROVED, which a field capture cannot otherwise
            // recover: `data-path-latched` logged two valid upstreams identically. Gated on the
            // RESOLUTION so a downgraded latch logs none. Non-secret, so it is safe in a capture.
            // pinned: TunnelDataPathLatchSourceTests.testADowngradedLatchLogsNoUpstreamGeneration
            "upstreamGeneration": resolution.mode.isChainedUpstream
                ? String(readyUpstreamGeneration) : ""
        ])
    }

    /// The device-local eligibility store, or `nil` when no shared access group resolves
    /// (an unsigned or misconfigured build — see `LavaSecAppGroup`).
    func chainedDeviceEligibilityStore() -> ChainedDeviceEligibilityStore? {
        guard let group = LavaSecAppGroup.chainedUpstreamKeychainAccessGroup,
            let lockURL = LavaSecAppGroup.chainedLifecycleEvidenceLockURL
        else { return nil }
        return ChainedDeviceEligibilityStore(
            items: ChainedDeviceStateKeychainItemStore(
                accessGroup: group, lifecycleEvidenceLockURL: lockURL))
    }

    /// Completes the cross-process half of an explicit retry requested by the app/widget. The
    /// widget can advance the marker but cannot touch the shared Keychain access group, so the
    /// provider owns this reset at the only safe point: after reading the marker and before
    /// `loadInitialSharedState` latches the chained data path. The marker bit is consumed only
    /// after the suppression reset succeeds; a transient Keychain failure therefore fails this
    /// start closed and leaves the retry request available for the next explicit attempt.
    private func consumeExplicitChainedRetryIfRequested(
        _ markerState: ChainedStartupFailureMarker.State,
        markerURL: URL
    ) throws -> ChainedStartupFailureMarker.State {
        guard markerState.explicitRetryRequested else {
            return markerState
        }
        guard let store = chainedDeviceEligibilityStore() else {
            throw ChainedExplicitRetryUnavailable()
        }
        try store.prepareForExplicitGuardStart()
        let consumed = try ChainedStartupFailureMarker.consumeExplicitRetryRequest(
            generation: markerState.generation,
            storageURL: markerURL,
            lockURL: LavaSecAppGroup.chainedStartupFailureMarkerLockURL)
        guard consumed else {
            // Losing the compare-and-set means the revision moved while `prepareForExplicitGuardStart`
            // was in the Keychain: a NEWER explicit retry owns the marker now, and iOS is starting a
            // provider for it. Re-reading here and adopting that newer generation is exactly what the
            // fence exists to stop — two providers would both claim to own it, and whichever finished
            // last could clear or republish terminal state for the user's newest attempt. Fail this
            // superseded start closed instead; the newer provider carries the retry.
            throw ChainedExplicitRetrySuperseded()
        }
        // Re-read after the compare-and-set. A concurrent lifecycle may have installed a
        // terminal reason while the Keychain reset was in flight; that reason must still gate
        // this start rather than being hidden by the stale pre-reset snapshot.
        let reread = try ChainedStartupFailureMarker.state(
            from: markerURL,
            lockURL: LavaSecAppGroup.chainedStartupFailureMarkerLockURL)
        // The re-read takes the marker lock AGAIN, so it is a second transaction: winning the CAS
        // above does not freeze the revision across this gap. If the dispatching app/intent exited
        // and a newer explicit retry advanced the marker in between, this read returns the newer
        // generation — and adopting it would hand a retired provider ownership of an attempt whose
        // retry request it never consumed, which is the same fence break as a lost CAS one step
        // later. Only the revision this start actually consumed may be adopted.
        guard reread.generation == markerState.generation else {
            throw ChainedExplicitRetrySuperseded()
        }
        return reread
    }

    /// Evaluates upstream readiness against the shared credential store, or `nil` when the
    /// store cannot be built at all.
    func evaluateChainedUpstreamReadiness() -> ChainedUpstreamReadiness.Readiness? {
        guard let container = LavaSecAppGroup.containerURL,
            let group = LavaSecAppGroup.chainedUpstreamKeychainAccessGroup
        else { return nil }
        let store = ChainedUpstreamKeychainStore(
            containerURL: container,
            identity: LavaSecAppGroup.chainedUpstreamStoreIdentity,
            keyItems: ChainedUpstreamKeychainKeyItemStore(accessGroup: group))
        return ChainedUpstreamReadiness.evaluate(store: store)
    }

    // Dual-entry read (INV-QUEUE-1). This is not stylistic: startTunnel builds settings OFF
    // dnsStateQueue, while the callers of reapplyTunnelNetworkSettings are already INSIDE
    // it (the path monitor delivers on dnsStateQueue; the reload-configuration handler opens
    // with dnsStateQueue.async). A bare .sync would therefore deadlock on every reapply, not
    // intermittently. Same shape as currentNetworkKind(), which the reapply path already
    // calls for exactly this reason.
    // pinned: TunnelDataPathLatchSourceTests.testTheLatchAccessorIsDualEntry
    /// The interface every resolver socket this process opens must be pinned to.
    ///
    /// ONE SEAM, deliberately. Sprinkling the decision across the three socket call sites is how
    /// one of them ends up unpinned while chained, which is silent and is the whole leak — so a
    /// reviewer has exactly one place to check and every call site has to handle the refusal.
    ///
    /// `virtualInterface` is what makes this work at all: a socket pinned to it has its packets
    /// delivered to this provider's own `packetFlow` with the tunnel's address as their source
    /// (measured on device 2026-07-29, TCP and UDP, with the unpinned control legs producing
    /// nothing). Reading it here is safe from any queue — it is a readonly provider property —
    /// and `currentTunnelDataPathMode()` is the established dual-entry accessor the orchestrator's
    /// `egressAllowance` already calls from off the DNS state queue.
    /// That device evidence covers ordinary routing. With `includeAllNetworks=true`, the
    /// September 23 comparison observed provider DNS on physical Wi-Fi instead. This binding
    /// decision does not prove strict-mode containment; see the connectivity-assist validation plan.
    /// pinned: TunnelDataPathLatchSourceTests.testTheResolverSocketBindingUsesOnlyTheVirtualInterface
    func currentResolverSocketBinding() -> ChainedResolverSocketBinding {
        let chainedIsLatched = currentTunnelDataPathMode().isChainedUpstream
        // `virtualInterface` is iOS's authoritative "this is OUR utun": a socket pinned to it has its
        // packets delivered to this provider's own `packetFlow` with the tunnel's address as their
        // source (measured on device 2026-07-29). While chained it is populated at tunnel-up (device
        // log chimmy 2026-08-15: index present at +0 s), so binding works from query #1; when it is nil
        // the binding refuses and DNS fails closed (`INV-DNS-1`). There is deliberately NO
        // address-matched getifaddrs fallback: a tunnel's assigned IPv4 is not device-unique, so even a
        // SOLE utun match could be another VPN's (or a stale) interface, with no way to establish
        // ownership from an interface list — and binding the resolver socket to the wrong tunnel is
        // itself a leak (Codex, PR #558). `virtualInterface` is the only sound ownership signal, so it
        // is the only one used.
        return ChainedResolverEgressPolicy.socketBinding(
            chainedIsLatched: chainedIsLatched,
            tunnelInterfaceIndex: virtualInterface.map { UInt32($0.index) }
        )
    }

    /// The socket binding for a specific resolver DESTINATION, F2-aware.
    ///
    /// The no-argument seam above answers only "is chained latched", which is correct for the
    /// tunnelled route: while chained, the physical path is the leak. But F3b claims the
    /// network's captured resolver addresses as host routes in a chained SPLIT plan, so an
    /// unbound socket to one of those addresses would be drawn back into the tunnel by the
    /// plan's own claim and refused by a peer that does not carry it — Lava stranding its own
    /// upstream. This seam scopes the answer to the destination: a floor-claimed destination
    /// the profile does NOT already carry is pinned to the live physical interface, everything
    /// else stays exactly as it was.
    ///
    /// The chained branch is deliberately the unchanged seam: device DNS while chained is
    /// redirected through the tunnel, so it must not acquire a physical escape here.
    ///
    /// SCOPE: ordinary DNS-only does NOT claim the floor. The opt-in DNS patch claims
    /// its designated endpoints and uses this physical binding too. Without that opt-in,
    /// the destination-aware physical branch here is
    /// unreachable. `makeTunnelNetworkSettingsForLatchedDataPath` passes the floor set for
    /// `isChainedUpstream` only, and `deviceResolverIsFloorClaimed` returns false outside a latched
    /// chained split — while the chained physical path does not come through this seam at all (its
    /// guard returns the mode-only binding). A DNS-only caller therefore gets the floor-claim
    /// answer `false` and the ordinary system-chosen binding. The chained physical path is served
    /// by the `.physical` rung seam (`tierOneSocketBinding`, which calls the same policy) instead.
    /// F1 deliberately keeps the claim out of DNS-only: a claim there would draw a resolver's
    /// non-53 traffic into a path with no forwarding rung, silently dropping it. Do not read this
    /// comment as evidence that a DNS-only session claims the floor.
    /// pinned: TunnelDataPathLatchSourceTests.testTheDeviceDNSEgressBindsTheFloorClaimedDestinationPhysically
    func currentResolverSocketBinding(for endpoint: ResolverEndpoint) -> ChainedResolverSocketBinding {
        guard !currentTunnelDataPathMode().isChainedUpstream else {
            return currentResolverSocketBinding()
        }
        return ChainedResolverEgressPolicy.destinationSocketBinding(
            destinationIsFloorClaimed: deviceResolverIsFloorClaimed(endpoint.addressLiteral),
            destinationIsProfileCovered: false,
            physicalInterfaceIndex: currentPhysicalInterfaceIndex())
    }

    /// QA-only evidence that the chained AAAA→NODATA suppression fired on device (PR: chained
    /// IPv6 DNS consistency). Throttled to one line / 2 s with a running count, so the founder's
    /// dogfood log shows the path ran without per-query spam. No-op in Release; gates nothing.
    func recordChainedAAAANoDataIfQA(domain: String) {
        #if DEBUG || LAVA_QA_TOOLS
        chainedAAAANoDataLock.lock()
        chainedAAAANoDataCount += 1
        let count = chainedAAAANoDataCount
        let now = Date()
        let shouldLog: Bool
        if let last = lastChainedAAAANoDataLogAt, now.timeIntervalSince(last) < 2 {
            shouldLog = false
        } else {
            lastChainedAAAANoDataLogAt = now
            shouldLog = true
        }
        chainedAAAANoDataLock.unlock()
        guard shouldLog else { return }
        LavaSecDeviceDebugLog.append(
            component: "tunnel", event: "chained-aaaa-nodata",
            details: ["domain": domain, "count": "\(count)"])
        #endif
    }

    /// QA-only evidence that the chained HTTPS/SVCB `ipv6hint` strip actually removed a hint on
    /// device (companion to `recordChainedAAAANoDataIfQA`), so the founder's dogfood log confirms the
    /// path fired on real dual-stack sites just as `chained-aaaa-nodata` did. Only called when the
    /// rewrite changed the response. Throttled to one line / 2 s with a running count. No-op in
    /// Release; gates nothing.
    func recordChainedIPv6HintStrippedIfQA(domain: String) {
        #if DEBUG || LAVA_QA_TOOLS
        chainedIPv6HintStripLock.lock()
        chainedIPv6HintStripCount += 1
        let count = chainedIPv6HintStripCount
        let now = Date()
        let shouldLog: Bool
        if let last = lastChainedIPv6HintStripLogAt, now.timeIntervalSince(last) < 2 {
            shouldLog = false
        } else {
            lastChainedIPv6HintStripLogAt = now
            shouldLog = true
        }
        chainedIPv6HintStripLock.unlock()
        guard shouldLog else { return }
        LavaSecDeviceDebugLog.append(
            component: "tunnel", event: "chained-ipv6hint-stripped",
            details: ["domain": domain, "count": "\(count)"])
        #endif
    }

    /// QA positive control (leak rig #8): emit the planted DNS leak canary on the PHYSICAL path so an
    /// off-device capture can SEE it. SELF-LATCHING on the driver's `sessionGeneration`, so it fires
    /// exactly once per established chained session and can be driven from a TUNNEL-OWNED lifecycle
    /// tick (the Focus poll) that runs regardless of whether the app is foregrounded — an
    /// app-poll-only trigger would miss a Connect-On-Demand / outage-driver establishment during a
    /// capture (Codex, PR #563). A no-op unless armed, chained, and handshaked. Sends
    /// `<nonce>.leak-canary.lavasec.invalid` through a `.systemChosen` `UDPResolverSocket` — UNBOUND
    /// while chained, i.e. the exact physical-path egress `ChainedResolverEgressPolicy` exists to
    /// close — so it is a REAL leak the analyzer must catch, not a mock. No-op in Release; gates nothing.
    /// pinned: DNSLeakCanaryEmitterSourceTests.testTheEmitterSendsOnTheSystemChosenPhysicalPath
    func fireChainedDNSLeakCanaryIfArmed() {
        #if DEBUG || LAVA_QA_TOOLS
        // dnsStateQueue-confined: the latch + driver-stats read run on that queue (both callers hold
        // it); only the socket send hops to resolverQueue below.
        guard currentTunnelDataPathMode().isChainedUpstream,
              let stats = chainedRuntime?.driver.snapshotStatistics(),
              stats.hasHandshake,
              chainedLeakCanaryFiredForGeneration != stats.sessionGeneration
        else { return }
        let defaults = LavaSecAppGroup.sharedDefaults
        guard let nonce = defaults.string(forKey: LavaSecAppGroup.leakCanaryArmedNonceKey),
              !nonce.isEmpty,
              // Only the nonce armed at THIS launch fires — a mid-session arm waits for a reconnect
              // (a post-arm startTunnel), so the canary never fires before the capture (Codex #563).
              nonce == leakCanaryEligibleNonce,
              let resolverIP = defaults.string(forKey: LavaSecAppGroup.leakCanaryResolverIPKey),
              let endpoint = ResolverEndpoint(address: resolverIP)
        else { return }
        // Latch OPTIMISTICALLY before the send so two dnsStateQueue ticks can't both dispatch. If the
        // send proves NO datagram left the interface (socket unbuildable, or sendto failed on a
        // changing route), the send path UN-latches so a later tick retries — only a real send counts
        // as fired, so the positive control can't report a blind capture as fired (Codex, PR #563). A
        // full rebuild bumps sessionGeneration and re-arms; a rebind keeps it (no re-fire).
        let firedGeneration = stats.sessionGeneration
        let firedLifecycle = tunnelLifecycleGeneration
        chainedLeakCanaryFiredForGeneration = firedGeneration
        let query = DNSLeakCanary.query(nonce: nonce)
        let domain = DNSLeakCanary.domain(nonce: nonce)
        let ports = ownResolverPorts
        // Off dnsStateQueue — the socket send blocks on a receive timeout (INV-QUEUE-1). `.systemChosen`
        // is the leak: an unbound-while-chained socket egresses on the physical interface.
        resolverQueue.async {
            let releaseForRetry: (String) -> Void = { reason in
                // No datagram left → drop the latch (on dnsStateQueue) so the next tick retries. Scope
                // to BOTH the tunnel lifecycle AND the session generation: sessionGeneration restarts at
                // 1 per lifecycle, and active resolver I/O can finish after stop, so an outstanding
                // attempt from a PRIOR lifecycle must not clear THIS lifecycle's latch and cause a
                // double-fire (Codex, PR #563).
                self.dnsStateQueue.async {
                    if self.tunnelLifecycleGeneration == firedLifecycle,
                        self.chainedLeakCanaryFiredForGeneration == firedGeneration {
                        self.chainedLeakCanaryFiredForGeneration = 0
                    }
                }
                LavaSecDeviceDebugLog.append(
                    component: "tunnel", event: "chained-dns-leak-canary-retry",
                    details: ["reason": reason, "resolver": resolverIP])
            }
            guard let socket = UDPResolverSocket(
                endpoint: endpoint, timeoutSeconds: Self.udpDNSTimeoutSeconds,
                binding: .systemChosen, ownResolverPorts: ports)
            else { releaseForRetry("socket-unavailable"); return }
            let outcome = socket.resolve(query).outcome
            // Did a datagram actually reach the wire? Exhaustive so a new outcome forces a decision
            // here rather than silently logging a blind capture as fired.
            let datagramSent: Bool
            switch outcome {
            case .success, .timeout, .receiveFailed, .mismatchedResponse,
                .unexpectedSourceResponse, .truncatedAnswer, .httpStatusFailure:
                // Off-source junk still means our datagram left: the send succeeded and the
                // receive loop ran (PR #577).
                datagramSent = true
            case .sendFailed, .socketUnavailable, .resolverPortUnavailable, .invalidAddress,
                .backedOff, .unsupported,
                .deviceDNSUnavailable, .refusedByEgressPolicy, .refusedAfterLifecycleEnded,
                // No query left: its path was replaced or its deadline elapsed before send.
                .refusedAfterLatchReplaced, .expiredBeforeSend,
                .tunnelInterfaceUnavailable, .physicalInterfaceUnavailable:
                datagramSent = false
            }
            guard datagramSent else { releaseForRetry(outcome.rawValue); return }
            LavaSecDeviceDebugLog.append(
                component: "tunnel", event: "chained-dns-leak-canary-fired",
                details: ["nonce": nonce, "resolver": resolverIP, "domain": domain, "outcome": outcome.rawValue])
        }
        #endif
    }

    /// The TCP fallback, with its socket pinned per ``currentResolverSocketBinding()``.
    ///
    /// A refusal is `.socketUnavailable` rather than a retry: there is no interface this query
    /// may legally leave on, and that does not become true by trying again. INV-DNS-1 is
    /// satisfied by the fail-closed answer the caller builds from this outcome.
    func resolveOverTCP(
        _ query: Data, endpoint: ResolverEndpoint, admittedAtEpoch: UInt64,
        admittedAtLatchEpoch: UInt64? = nil,
        egressInterface: ResolverOrchestrator.EgressInterface = .providerDefault,
        lifetime: DNSResolutionLifetime? = nil
    ) -> DNSUpstreamResponse {
        // Chained TCP fallback is unsupported. Strict profiles must not create provider
        // sockets that the OS may route around the VPN (the UDP path uses direct carry).
        guard !protocolConfiguration.includeAllNetworks else {
            return DNSUpstreamResponse(response: nil, outcome: .refusedByEgressPolicy)
        }
        // Admission first, exactly as in `resolveUDP` — the TCP rung follows a UDP rung
        // that legitimately spends the full UDP timeout, which is precisely how a stale
        // resolution gets late enough to matter (Codex P1, PR #524).
        guard lifetime?.isAdmitted ?? true, ResolverOrchestrator.workIsAdmitted(
            snapshot: admittedAtEpoch, live: currentResolverAdmissionEpoch()
        ) else {
            return DNSUpstreamResponse(response: nil, outcome: .refusedAfterLifecycleEnded)
        }

        // And the latch, for the same reason again one step further out: the TCP rung follows a
        // UDP rung that legitimately spends the full UDP timeout, which is exactly how a rung gets
        // late enough for the latch to have moved under it (PR #610).
        guard resolverLatchIsCurrent(admittedAtLatchEpoch) else {
            return DNSUpstreamResponse(response: nil, outcome: .refusedAfterLatchReplaced)
        }

        // Same override as the UDP rung, and needed for the same reason: a truncated T1 answer
        // must not retry INTO the tunnel it was routed around (Codex, PR #590).
        let bindingDecision: ChainedResolverSocketBinding
        switch egressInterface {
        case .providerDefault:
            bindingDecision = currentResolverSocketBinding(for: endpoint)
        case .physical:
            bindingDecision = ChainedResolverEgressPolicy.tierOneSocketBinding(
                destinationIsFloorClaimed: deviceResolverIsFloorClaimed(endpoint.addressLiteral),
                destinationIsProfileCovered: latchedChainedAllowedIPsCover(endpoint.addressLiteral),
                physicalInterfaceIndex: currentPhysicalInterfaceIndex())
        }
        let binding: ResolverInterfaceBinding
        switch bindingDecision {
        case .permitted(let permitted):
            binding = permitted
        case .refusedNoTunnelInterface:
            // Binding refused = the tunnel interface (`virtualInterface`) is not ready yet, NOT a socket
            // failure — distinct outcome so the resolver backoff does not penalise the upstream for a
            // transient startup interface-lag (Codex, PR #570).
            return DNSUpstreamResponse(response: nil, outcome: .tunnelInterfaceUnavailable)
        case .refusedNoPhysicalInterface:
            // F2's missing physical pin: the tunnel interface is known, but a floor-claimed,
            // profile-uncovered destination has no live underlay index. Its own outcome, not the
            // tunnel-interface one, so a device log does not name the wrong condition.
            return DNSUpstreamResponse(response: nil, outcome: .physicalInterfaceUnavailable)
        }

        return TCPResolver.resolve(
            query, endpoint: endpoint, timeoutSeconds: Self.tcpDNSTimeoutSeconds,
            binding: binding, ownResolverPorts: ownResolverPorts, lifetime: lifetime)
    }

    func currentTunnelDataPathMode() -> TunnelDataPathMode {
        if DispatchQueue.getSpecific(key: dnsStateQueueSpecificKey) == true {
            return latchedDataPathMode
        }

        return dnsStateQueue.sync {
            latchedDataPathMode
        }
    }

    private func currentLatchedDataPathRefusal() -> TunnelDataPathLatch.Refusal? {
        if DispatchQueue.getSpecific(key: dnsStateQueueSpecificKey) == true {
            return latchedDataPathRefusal
        }
        return dnsStateQueue.sync { latchedDataPathRefusal }
    }

    func currentChainedLifecycleEvidenceID() -> String? {
        if DispatchQueue.getSpecific(key: dnsStateQueueSpecificKey) == true {
            return latchedChainedLifecycleEvidenceID
        }
        return dnsStateQueue.sync { latchedChainedLifecycleEvidenceID }
    }

    // Holds the chained MTU under the engine's own per-packet ceiling.
    //
    // An INDEPENDENT check, not a restatement of how the plan picked its MTU. That
    // derivation has changed once already — it was `dnsOnlyMTU - encapsulationOverhead`
    // until that was found to violate IPv6's 1280 floor, and the plan now assigns
    // `minimumIPv6LinkMTU` directly (see TunnelRoutePlan for why). Tying this clamp's
    // rationale to whatever the plan currently computes is what made the previous version
    // of this comment false the moment the plan moved.
    //
    // What holds regardless of that derivation: LavaSecKit cannot import
    // LavaSecChainedUpstream (the dependency runs the other way), so no plan value can be
    // checked against the engine's limits where it is chosen. The provider is the only
    // place the two meet. An inner packet larger than the engine accepts is rejected
    // per-packet as `.packetTooLarge`, which would present as silent unidirectional loss
    // for exactly the full-size packets a path-MTU probe uses.
    //
    // DNS-only is deliberately excluded rather than clamped alongside it. Its 1280 has no
    // relationship to the engine, and routing it through an engine constant would make the
    // comment above it false and put a chained-mode dependency on the path `INV-DNS-1`
    // protects for users who never enable chaining.
    // pinned: TunnelRoutePlanSourceTests.testTheChainedMTUIsHeldUnderTheEnginePacketCeiling
    static func engineSafeMTU(for mode: TunnelDataPathMode, planMTU: Int) -> Int {
        switch mode {
        case .dnsOnly:
            return planMTU
        case .chainedUpstream(let configuration):
            let ceiling = !configuration.usesNestedTransport ? WireGuardSession.maximumIPPacketByteCount
                : ((WireGuardSession.maximumIPPacketByteCount - 60) / 16) * 16
            return min(planMTU, ceiling)
        }
    }

    private static func makeTunnelNetworkSettings(
        for mode: TunnelDataPathMode,
        dnsCaptureResolverAddresses: [String],
        capturesIPv6InDNSOnly: Bool = false,
        advertisesIPv6DNSInDNSOnly: Bool = false,
        declaresDefaultRoutesInDNSOnly: Bool = false
    ) -> TunnelNetworkSettingsBundle {
        // Every routing value comes from the plan. Spelling any of them inline here would
        // restore the two-descriptions-of-one-routing split the plan type exists to close,
        // and the DNS-only branch is the path INV-DNS-1 protects for every user who never
        // enables chaining — so the routes are MAPPED, never enumerated per mode.
        //
        // F1/F3b: the curated public resolvers and the captured device resolvers ride into the
        // plan as host routes for a CHAINED path only; the plan owns both the merge rule and the
        // "full tunnel ignores them" decision, so the provider only forwards what the latched
        // path requires (see the caller). DNS-only receives `[]`.
        let plan = TunnelRoutePlan.make(
            for: mode, dnsCaptureResolverAddresses: dnsCaptureResolverAddresses,
            capturesIPv6InDNSOnly: capturesIPv6InDNSOnly,
            advertisesIPv6DNSInDNSOnly: advertisesIPv6DNSInDNSOnly,
            declaresDefaultRoutesInDNSOnly: declaresDefaultRoutesInDNSOnly)
        let tunnelAddress = plan.tunnelAddress
        let dnsServerAddress = plan.dnsServerAddress
        let routeDescription = plan.routeDescription
        let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: dnsServerAddress)
        // `mtu` is `NSNumber?`; the previous integer literal bridged implicitly, a plain Int
        // does not. The plan stays free of Foundation bridging types — translation is this
        // function's job.
        settings.mtu = NSNumber(value: Self.engineSafeMTU(for: mode, planMTU: plan.mtu))

        let ipv4 = NEIPv4Settings(addresses: [tunnelAddress], subnetMasks: [plan.tunnelSubnetMask])
        ipv4.includedRoutes = plan.includedIPv4Routes.map {
            NEIPv4Route(destinationAddress: $0.destinationAddress, subnetMask: $0.subnetMask)
        }
        if !plan.excludedIPv4Routes.isEmpty {
            ipv4.excludedRoutes = plan.excludedIPv4Routes.map {
                NEIPv4Route(destinationAddress: $0.destinationAddress, subnetMask: $0.subnetMask)
            }
        }
        settings.ipv4Settings = ipv4

        // Only installed when the plan claims IPv6. Leaving `ipv6Settings` nil is what the
        // DNS-only path has always done and must keep doing; a mode that carries traffic
        // must NOT, or IPv6 stays on the physical interface and leaves the device outside
        // the tunnel the user turned on.
        if let ipv6Address = plan.tunnelIPv6Address,
           let ipv6PrefixLength = plan.tunnelIPv6PrefixLength,
           !plan.includedIPv6Routes.isEmpty {
            let ipv6 = NEIPv6Settings(
                addresses: [ipv6Address],
                networkPrefixLengths: [NSNumber(value: ipv6PrefixLength)]
            )
            ipv6.includedRoutes = plan.includedIPv6Routes.map {
                NEIPv6Route(
                    destinationAddress: $0.destinationAddress,
                    networkPrefixLength: NSNumber(value: $0.prefixLength)
                )
            }
            if !plan.excludedIPv6Routes.isEmpty {
                ipv6.excludedRoutes = plan.excludedIPv6Routes.map {
                    NEIPv6Route(
                        destinationAddress: $0.destinationAddress,
                        networkPrefixLength: NSNumber(value: $0.prefixLength))
                }
            }
            settings.ipv6Settings = ipv6
        }

        // Advertise the in-tunnel proxy over both families when the plan carries IPv6, so the
        // system resolver stays filtered over v6 as well as v4 without claiming `::/0` (F3c).
        let dnsServers = plan.dnsServerIPv6Address.map { [dnsServerAddress, $0] } ?? [dnsServerAddress]
        let dns = NEDNSSettings(servers: dnsServers)
        dns.matchDomains = [""]
        #if compiler(>=6.2)
        if #available(iOS 26.0, *) {
            // Keep DNS inside Lava's packet tunnel; Lava performs resolver fallback after local filtering.
            dns.allowFailover = false
        }
        #endif
        settings.dnsSettings = dns

        return TunnelNetworkSettingsBundle(
            settings: settings,
            mode: mode,
            tunnelAddress: tunnelAddress,
            dnsServerAddress: dnsServerAddress,
            routeDescription: routeDescription,
            dnsCaptureScope: plan.dnsCaptureScope
        )
    }
}
