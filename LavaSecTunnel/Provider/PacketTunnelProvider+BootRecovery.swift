import Foundation
@preconcurrency import NetworkExtension
import LavaSecChainedUpstream
import LavaSecKit

extension PacketTunnelProvider {
    private enum ChainedBootUpstreamReadiness: Equatable, Sendable {
        case ready, notReady, ineligible
    }

    // MARK: - VPN recovery after first unlock (LAV-124)

    /// A stationary network supplies no new path callback at first unlock. Poll only the
    /// protected boot refusal, keeping the DNS-only latch until fresh credentials are usable.
    /// INV-DNS-1 / INV-QUEUE-1 / INV-MEM-1: no packet-path Keychain work or resident secret.
    /// pinned: ChainedBootRecoverySourceTests.testSuccessfulStartupArmsUnlockRecoveryAndTeardownCancelsIt
    func startChainedBootRecoveryIfNeeded(
        generation: UInt64, startedWithProtectedDataUnavailable: Bool
    ) {
        dnsStateQueue.async { [weak self] in
            guard let self, self.tunnelLifecycleIsActive,
                  self.tunnelStartupDidComplete,
                  self.tunnelLifecycleGeneration == generation,
                  self.latchedDataPathRefusalGeneration == generation,
                  self.chainedBootRecoveryArmedGeneration != generation else { return }
            self.cancelChainedBootRecovery()
            guard !self.protocolConfiguration.includeAllNetworks,
                  let policy = ChainedBootRecoveryPolicy(generation: generation,
                    startedWithProtectedDataUnavailable: startedWithProtectedDataUnavailable,
                    refusal: self.latchedDataPathRefusal) else { return }
            self.chainedBootRecoveryArmedGeneration = generation
            self.chainedBootRecoveryPolicy = policy
            self.pollChainedBootRecovery()
        }
    }

    /// Cancels logical work on lifecycle invalidation. An uncancellable SecItem call keeps
    /// the physical slot until its completion, including across same-instance restarts.
    func cancelChainedBootRecovery() {
        dispatchPrecondition(condition: .onQueue(dnsStateQueue))
        stopChainedBootRecoveryTimer()
        chainedBootRecoveryPolicy = nil
    }

    private func stopChainedBootRecoveryTimer() {
        chainedBootRecoveryTimer?.cancel()
        chainedBootRecoveryTimer = nil
    }

    private func updateChainedBootRecoveryTimer() {
        guard chainedBootRecoveryPolicy?.pollingIsNeeded == true else {
            stopChainedBootRecoveryTimer()
            return
        }
        guard chainedBootRecoveryTimer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: dnsStateQueue)
        timer.schedule(deadline: .now() + ChainedBootRecoveryPolicy.pollInterval,
                       repeating: ChainedBootRecoveryPolicy.pollInterval, leeway: .milliseconds(500))
        timer.setEventHandler { [weak self] in self?.pollChainedBootRecovery() }
        chainedBootRecoveryTimer = timer
        timer.resume()
    }

    /// Both path-owner turns wake the same policy. The generation/observation gate rejects
    /// optimistic defaults, stale monitors and old health applied after a newer physical path.
    /// pinned: ChainedBootRecoverySourceTests.testDeliveredCombinedPathWakesDormantRecovery
    func chainedBootRecoveryPathDidChange() {
        dispatchPrecondition(condition: .onQueue(dnsStateQueue))
        pollChainedBootRecovery()
    }

    /// Existing configuration adoption/polling retires dormant work without adding a timer.
    /// The next path callback also reads durable intent/configuration again before admission.
    /// pinned: ChainedBootRecoverySourceTests.testConfigurationInvalidationUsesExistingOwners
    func revalidateChainedBootRecoveryIfNeeded() {
        dispatchPrecondition(condition: .onQueue(dnsStateQueue))
        guard var policy = chainedBootRecoveryPolicy else { return }
        // Invalidation only: work admission belongs to the path/poll owner. This avoids
        // recursively admitting credentials while configuration adoption is in progress.
        guard policy.revalidate(chainedBootRecoveryContext()) else {
            cancelChainedBootRecovery()
            return
        }
        chainedBootRecoveryPolicy = policy
        updateChainedBootRecoveryTimer()
    }

    private func chainedBootRecoveryContext() -> ChainedBootRecoveryPolicy.Context {
        dispatchPrecondition(condition: .onQueue(dnsStateQueue))
        let readable = sharedProtectedContentIsReadable()
        var configuration: AppConfiguration?
        if readable, case .loaded(let loaded) = loadConfigurationClassified() {
            configuration = loaded
        }
        let wanted: Bool
        if let container = LavaSecAppGroup.containerURL, let configuration {
            wanted = ProtectionRestoreIntentStore.read(containerURL: container)
                .resolvedIntent(fallingBackTo: configuration.protectionEnabled)
        } else {
            wanted = false
        }
        let schedulingView = currentResolverHealthSchedulingView()
        return .init(generation: tunnelLifecycleGeneration,
            lifecycleIsActive: tunnelLifecycleIsActive && tunnelStartupDidComplete
                && !protocolConfiguration.includeAllNetworks,
            refusal: latchedDataPathRefusalGeneration == tunnelLifecycleGeneration
                ? latchedDataPathRefusal : nil,
            protectedDataIsReadable: readable, protectionIsWanted: wanted,
            chainingIsEnabled: configuration?.chainedUpstreamEnabled == true
                && configuration?.hasLavaSecurityPlus == true,
            onDemandIsEnabled: Self.isOnDemandConfirmedEnabled(),
            networkIsSatisfied: chainedBootRecoveryPathGate.isSatisfied
                && latestMonitoredPathIsSatisfied && schedulingView.networkPathIsSatisfied,
            networkTransitionSerial: chainedBootRecoveryPathGate.satisfiedTransitionSerial,
            physicalReadIsInFlight: chainedBootRecoveryReadSlot.isInFlight,
            now: ProcessInfo.processInfo.systemUptime)
    }

    private func pollChainedBootRecovery() {
        dispatchPrecondition(condition: .onQueue(dnsStateQueue))
        guard var policy = chainedBootRecoveryPolicy else { return }
        let action = policy.nextAction(chainedBootRecoveryContext())
        chainedBootRecoveryPolicy = policy
        updateChainedBootRecoveryTimer()
        switch action {
        case .wait, .dormant: return
        case .stop:
            logChainedBootRecovery(policy, phase: "stopped")
            cancelChainedBootRecovery()
        case .checkReadiness(let token):
            // The cheap context read above was authoritative; this second read supplies the
            // exact fresh configuration for eligibility. A failed read never falls back to
            // the cached boot placeholder (INV-PERSIST-1).
            guard case .loaded(let configuration) = loadConfigurationClassified() else {
                _ = policy.completeReadinessCheck(chainedBootRecoveryContext(), token: token, upstreamIsReady: false)
                chainedBootRecoveryPolicy = policy
                if policy.isFinished { cancelChainedBootRecovery() }
                return
            }
            guard chainedBootRecoveryReadSlot.admit(token) else { return }
            let admittedPolicy = policy
            let markerGeneration = chainedStartupFailureMarkerGeneration
            logChainedBootRecovery(policy, phase: "checking")
            // One physical read across ALL lifecycles, not just one per generation: a wedged
            // securityd plus restart churn must not accumulate threads/NE residents.
            // pinned: ChainedBootRecoverySourceTests.testRecoveryReadsOffQueueAndRevalidatesUnderTheUserMutationFence
            DispatchQueue.global(qos: .utility).async { [weak self] in
                guard let self else { return }
                let readiness = self.chainedBootUpstreamReadiness(configuration: configuration)
                let fence: ProtectionLifecycleMutationFenceHandle?
                if readiness == .ready, let container = LavaSecAppGroup.containerURL {
                    // Acquire AFTER Keychain work so a wedged read cannot block explicit OFF.
                    // No wait: a user action holding the fence wins; a later bounded poll may retry.
                    fence = try? ProtectionLifecycleMutationFence.acquire(
                        lockFileURL: container.appendingPathComponent(
                            LavaSecAppGroup.protectionLifecycleMutationLockFilename), wait: false)
                } else {
                    fence = nil
                }
                // Eligibility is Keychain-backed, so its existing read follows credentials
                // and precedes this fence. Backoff consumption starts a new provider generation;
                // this DNS-only boot owner cannot surrender a chained runtime. A delayed prior
                // surrender/explicit retry also changes the existing non-secret marker owner.
                // No SecItem call runs while explicit OFF is excluded by the user fence.
                let durableRefusalMatches: Bool?
                if fence != nil, let markerURL = LavaSecAppGroup.chainedStartupFailureMarkerURL,
                   let marker = try? ChainedStartupFailureMarker.state(from: markerURL,
                        lockURL: LavaSecAppGroup.chainedStartupFailureMarkerLockURL) {
                    durableRefusalMatches = admittedPolicy.matchesDurableRefusal(marker,
                        expectedMarkerGeneration: markerGeneration)
                } else { durableRefusalMatches = nil }
                self.dnsStateQueue.async { [weak self] in
                    defer { fence?.release() }
                    guard let self else { return }
                    guard self.chainedBootRecoveryReadSlot.complete(token) else { return }
                    guard var current = self.chainedBootRecoveryPolicy else { return }
                    // Intent, on-demand, path and active generation are sampled AGAIN while
                    // the same mutation fence used by app/intent ON/OFF is still owned.
                    let configurationStillMatches: Bool
                    if case .loaded(let freshConfiguration) = self.loadConfigurationClassified() {
                        configurationStillMatches = freshConfiguration == configuration
                    } else { configurationStillMatches = false }
                    var context = self.chainedBootRecoveryContext()
                    // A readable excluded/surrendered eligibility snapshot is terminal for
                    // this boot refusal. An unreadable snapshot remains a bounded failed read.
                    if readiness == .ineligible { context.chainingIsEnabled = false }
                    if durableRefusalMatches == false { context.lifecycleIsActive = false }
                    let restart = current.completeReadinessCheck(context, token: token,
                        upstreamIsReady: readiness == .ready && fence != nil
                            && configurationStillMatches && durableRefusalMatches == true)
                    self.chainedBootRecoveryPolicy = current
                    if restart {
                        self.logChainedBootRecovery(current, phase: "restarting")
                        self.cancelChainedBootRecovery()
                        // The next start reads the real key and chooses a fresh latch. We do not
                        // change settings, reset surrender/crash backoff, or install strict-profile
                        // DNS-only routes. Confirmed on-demand must relaunch this cancellation.
                        self.cancelTunnelWithError(nil)
                    } else {
                        self.logChainedBootRecovery(current,
                            phase: current.isFinished ? "stopped" : "not-ready")
                        if current.isFinished { self.cancelChainedBootRecovery() }
                        else {
                            // A genuine edge may have opened a new window while the physical
                            // slot was occupied. Drain revalidates once on this queue; it never
                            // promotes the old result or needs a second stationary-Wi-Fi edge.
                            self.pollChainedBootRecovery()
                        }
                    }
                }
            }
        }
    }

    /// Only a non-secret outcome crosses the queue boundary; Ready and both keys die here.
    private func chainedBootUpstreamReadiness(configuration: AppConfiguration) -> ChainedBootUpstreamReadiness {
        guard configuration.chainedUpstreamEnabled else { return .ineligible }
        // Read credentials first; an unbounded key read must not leave an older eligibility
        // snapshot authorizing restart after settings/lifecycle evidence has moved on.
        let upstreamIsReady: Bool
        if let readiness = evaluateChainedUpstreamReadiness(), case .ready = readiness {
            upstreamIsReady = true
        } else { upstreamIsReady = false }
        guard let store = chainedDeviceEligibilityStore(),
              case .snapshot(let snapshot) = store.read() else { return .notReady }
        guard !snapshot.isSurrenderSuppressed,
              ChainedAvailability.isEligible(
                hasLavaSecurityPlus: configuration.hasLavaSecurityPlus,
                physicalMemoryBytes: ProcessInfo.processInfo.physicalMemory,
                experimentalOverrideEnabled: snapshot.experimentalOverrideEnabled,
                hasStartupCrashLoopTripped: snapshot.backoffState.hasTripped) else { return .ineligible }
        return upstreamIsReady ? .ready : .notReady
    }

    private func logChainedBootRecovery(_ policy: ChainedBootRecoveryPolicy, phase: String) {
        LavaSecDeviceDebugLog.append(component: "tunnel", event: "chained-boot-recovery", details: [
            "phase": phase, "refusal": policy.refusal.logValue,
            "generation": String(policy.generation), "count": String(policy.readinessChecks),
            "windows": String(policy.onlineWindows)
        ])
    }
}
