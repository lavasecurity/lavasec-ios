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
    // MARK: - Transient bootstrap DNS wait

    // The wait's STATE machine lives in TransientBootstrapDNSWait (LavaSecDNS,
    // Phase E2), where the INV-DNS-2 transitions are executable
    // (TransientBootstrapDNSWaitTests). These wrappers keep everything that must
    // stay a provider concern: the query-shape guards, the SERVFAIL writes
    // (writeServerFailures), the replay THROUGH the filter, the device-log events
    // (names/keys unchanged), the INV-QUEUE-1 dual-entry hops, and
    // tunnelLifecycleGeneration ownership. Since actors slice 3 the machine is a
    // dispatch-backed actor whose executor IS dnsStateQueue: the dual-entry hops
    // below land on that executor, and each confined region reaches the machine
    // through synchronous assumeIsolated (which traps on the wrong queue where the
    // old dispatchPrecondition merely asserted in debug). Placement rule per
    // region: only the machine's decision runs inside isolation — the log appends
    // and SERVFAIL writes strictly follow it, nothing interleaves with wait state.

    func enqueueTransientBootstrapDNSRequestIfNeeded(
        request: any DNSDatagramRequest,
        protocolNumber: Int,
        filterDecision: FilterDecision,
        failClosedReason: String?,
        allowsTransientBootstrapDeferral: Bool,
        expectedLifecycleGeneration: UInt64,
        isReplayOfARecordedDecision: Bool
    ) -> Bool {
        guard allowsTransientBootstrapDeferral,
              filterDecision.action == .block,
              filterDecision.reason == .protectionUnavailable,
              failClosedReason == "transient-protection-unavailable"
        else {
            return false
        }

        var serverFailure: PendingDNSResponse?
        var serverFailureReason: String?
        let handledByWait = dnsStateQueue.sync {
            // Carried, not defaulted: this wait is the SECOND queue a request can sit in,
            // and its drain re-enters the handler. A wake replay re-decided as transiently
            // fail-closed parks here, so dropping the marker would record the query on the
            // way out — the duplicate the marker exists to stop (Codex P2, PR #617).
            let pending = PendingDNSResponse(
                request: request,
                protocolNumber: protocolNumber,
                maximumAnswerTTL: nil,
                temporaryPauseNormalizedDomain: nil,
                isReplayOfARecordedDecision: isReplayOfARecordedDecision
            )
            // On dnsStateQueue (the sync above), which IS the wait actor's executor —
            // synchronous assumeIsolated, zero hops (INV-QUEUE-1). Only the admission
            // decision runs inside isolation; the per-case log appends and the SERVFAIL
            // bookkeeping strictly follow the decision.
            //
            // The CALLER'S generation, not a live re-read. A stop/start landing between
            // the fence at `handleDNSRequest`'s entry and this sync would store the old
            // session's query under the NEW session's generation — the drain would then
            // replay it against a configuration it was never classified for, which is the
            // wrong-origin class this slice removes everywhere else (Codex P1, PR #524).
            // A mismatched generation makes the wait invisible (`.notHandled`) and the
            // query takes the normal fail-closed answer instead of crossing sessions.
            let decision = transientBootstrapDNSWait.assumeIsolated { wait in
                wait.enqueue(pending, generation: expectedLifecycleGeneration)
            }
            switch decision {
            case .rejectExpiredGeneration:
                serverFailure = pending
                serverFailureReason = "transient-bootstrap-dns-wait-timeout"
                return true

            case .notHandled:
                return false

            case .rejectOverflow(let logOnce, let pendingCount):
                serverFailure = pending
                serverFailureReason = "transient-bootstrap-dns-wait-overflow"
                if logOnce {
                    LavaSecDeviceDebugLog.append(component: "tunnel", event: "transient-bootstrap-dns-wait-overflow", details: [
                        "generation": "\(tunnelLifecycleGeneration)",
                        "pendingResponses": "\(pendingCount)"
                    ])
                }
                return true

            case .queued(let isFirst):
                if isFirst {
                    LavaSecDeviceDebugLog.append(component: "tunnel", event: "transient-bootstrap-dns-wait-queued", details: [
                        "generation": "\(tunnelLifecycleGeneration)"
                    ])
                }
                return true
            }
        }

        if let serverFailure {
            writeServerFailures(for: [serverFailure], reason: serverFailureReason)
        }
        return handledByWait
    }

    func drainTransientBootstrapDNSWait(reason: String) {
        let drain = { [self] () -> (pendingResponses: [PendingDNSResponse], replayGeneration: UInt64?) in
            // On dnsStateQueue via the dual-entry hop below, which IS the wait actor's
            // executor — synchronous assumeIsolated, zero hops (INV-QUEUE-1). Only the
            // drain decision runs inside isolation; the log appends and the stale-
            // lifecycle SERVFAIL write strictly follow the returned queue.
            let decision = transientBootstrapDNSWait.assumeIsolated { wait in
                wait.drain(currentGeneration: tunnelLifecycleGeneration)
            }
            switch decision {
            case .idle:
                return ([], nil)

            case .staleLifecycle(let pendingResponses):
                if !pendingResponses.isEmpty {
                    LavaSecDeviceDebugLog.append(component: "tunnel", event: "transient-bootstrap-dns-wait-stale-lifecycle", details: [
                        "generation": "\(tunnelLifecycleGeneration)",
                        "pendingResponses": "\(pendingResponses.count)",
                        "reason": reason
                    ])
                }
                writeServerFailures(
                    for: pendingResponses,
                    reason: "transient-bootstrap-dns-wait-stale-lifecycle"
                )
                return ([], nil)

            case .replay(let pendingResponses, let replayGeneration):
                if !pendingResponses.isEmpty {
                    LavaSecDeviceDebugLog.append(component: "tunnel", event: "transient-bootstrap-dns-wait-drain", details: [
                        "generation": "\(tunnelLifecycleGeneration)",
                        "pendingResponses": "\(pendingResponses.count)",
                        "reason": reason
                    ])
                }
                return (pendingResponses, replayGeneration)
            }
        }

        let result: (pendingResponses: [PendingDNSResponse], replayGeneration: UInt64?)
        if DispatchQueue.getSpecific(key: dnsStateQueueSpecificKey) == true {
            result = drain()
        } else {
            result = dnsStateQueue.sync(execute: drain)
        }

        replayTransientBootstrapDNSRequests(
            result.pendingResponses,
            expectedLifecycleGeneration: result.replayGeneration
        )
    }

    func failTransientBootstrapDNSWait(reason: String, expectedGeneration: UInt64? = nil) {
        let fail = { [self] () -> [PendingDNSResponse] in
            // Only the TIMEOUT exit stamps the expired-generation marker (same-
            // lifecycle latecomers keep receiving SERVFAIL); a snapshot-unavailable
            // fail leaves no marker, so latecomers take the normal immediate
            // fail-closed answer.
            // pinned: TransientBootstrapDNSWaitTests.testSnapshotUnavailableFailDrainsWithoutMarkingTheGenerationExpired
            let isTimeout = reason == "transient-bootstrap-dns-wait-timeout"
            // On dnsStateQueue via the dual-entry hop below (the timeout handler
            // arrives already confined — the wait's scheduleAfter delivers it there),
            // which IS the wait actor's executor — synchronous assumeIsolated, zero
            // hops (INV-QUEUE-1). The log appends strictly follow the returned queue.
            let pendingResponses = transientBootstrapDNSWait.assumeIsolated { wait in
                wait.fail(
                    expectedGeneration: expectedGeneration,
                    marksGenerationExpired: isTimeout
                )
            }
            if !pendingResponses.isEmpty {
                if isTimeout {
                    LavaSecDeviceDebugLog.append(component: "tunnel", event: "transient-bootstrap-dns-wait-timeout", details: [
                        "generation": "\(tunnelLifecycleGeneration)",
                        "pendingResponses": "\(pendingResponses.count)",
                        "reason": reason
                    ])
                } else {
                    LavaSecDeviceDebugLog.append(component: "tunnel", event: "transient-bootstrap-dns-wait-failed", details: [
                        "generation": "\(tunnelLifecycleGeneration)",
                        "pendingResponses": "\(pendingResponses.count)",
                        "reason": reason
                    ])
                }
            }
            return pendingResponses
        }

        let pendingResponses: [PendingDNSResponse]
        if DispatchQueue.getSpecific(key: dnsStateQueueSpecificKey) == true {
            pendingResponses = fail()
        } else {
            pendingResponses = dnsStateQueue.sync(execute: fail)
        }

        writeServerFailures(for: pendingResponses, reason: reason)
    }

    private func replayTransientBootstrapDNSRequests(
        _ pendingResponses: [PendingDNSResponse],
        expectedLifecycleGeneration: UInt64?
    ) {
        guard !pendingResponses.isEmpty else {
            return
        }

        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else {
                return
            }

            guard let expectedLifecycleGeneration,
                  self.isCurrentTunnelLifecycle(expectedLifecycleGeneration)
            else {
                self.writeServerFailures(
                    for: pendingResponses,
                    reason: "transient-bootstrap-dns-wait-stale-lifecycle"
                )
                return
            }

            for pending in pendingResponses {
                // The marker rides the request: a query parked here by a WAKE replay was
                // already recorded, and this drain is its second re-handling.
                self.handleDNSRequest(
                    pending.request,
                    protocolNumber: pending.protocolNumber,
                    allowsTransientBootstrapDeferral: false,
                    expectedLifecycleGeneration: expectedLifecycleGeneration,
                    isReplayOfARecordedDecision: pending.isReplayOfARecordedDecision
                )
            }
        }
    }

    /// Re-asks the DNS queries a wake-time resolver-runtime reset drained, instead of
    /// answering them SERVFAIL.
    ///
    /// The reset above swaps the RESOLVER runtime; the tunnel LIFECYCLE is untouched, so every
    /// drained request is still serviceable — the client is still waiting on it, and the fresh
    /// runtime is the one that should answer it. Failing them turned a routine resolver swap
    /// into a hard, immediately-surfaced error: in the 2026-08-28 21:32 field capture six
    /// `pending-dns-servfail reason=wake` events failed 19 queries and the page stayed dead
    /// until a manual reload. One re-ask downgrades that to a brief delay.
    ///
    /// Follows ``replayTransientBootstrapDNSRequests``' queue shape: hop OFF `dnsStateQueue`
    /// (the caller is confined and `handleDNSRequest` re-enters it — INV-QUEUE-1), then re-check
    /// the lifecycle. It parts company on the refusal: a tunnel that really did retire
    /// underneath us gets the drained requests DROPPED (count-only trace), never answered, for
    /// the reason `handleDNSRequest`'s own fence drops them — `writeDNSResponse` has no
    /// lifecycle gate, so a reply built here would enter the successor session's packet flow
    /// (Codex, PR #508). That fence also covers anything that retires between this check and
    /// the forward.
    ///
    /// Bootstrap deferral stays ENABLED here, unlike the bootstrap replay (which disables it so
    /// a request coming out of that wait cannot be re-parked in it): a wake replay never came
    /// from the wait, so an unavailable bootstrap after resume should park it exactly like a
    /// fresh query rather than fail it.
    // pinned: PacketTunnelDNSRuntimeSourceTests.testWakeReplaysDrainedRequestsInsteadOfFailingThem
    func replayPendingDNSRequestsAfterWake(
        _ pendingResponses: [PendingDNSResponse],
        expectedLifecycleGeneration: UInt64?
    ) {
        guard !pendingResponses.isEmpty else {
            return
        }

        // Un-gated like `pending-dns-servfail`, and for the same reason: this is the only
        // field-visible evidence that a wake cost a query, and it records a COUNT only —
        // no queried domain (privacy-audited, #21).
        LavaSecDeviceDebugLog.append(component: "tunnel", event: "wake-pending-dns-replay", details: [
            "pendingResponses": "\(pendingResponses.count)"
        ])

        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else {
                return
            }

            // DROPPED, not SERVFAILed, exactly like `handleDNSRequest`'s own fence: the
            // tunnel retired between the capture above and this block, so `writeDNSResponse`
            // — which has no lifecycle gate — would inject these answers into whatever packet
            // flow is live NOW, and a reused client tuple plus transaction ID can make a stale
            // SERVFAIL fail a live query in the successor session (Codex, PR #508). The client
            // re-asks under the new session on its own timeout. Count-only trace so a field
            // capture can still tell a drop from a replay.
            guard let expectedLifecycleGeneration,
                  self.isCurrentTunnelLifecycle(expectedLifecycleGeneration)
            else {
                LavaSecDeviceDebugLog.append(
                    component: "tunnel",
                    event: "wake-pending-dns-replay-dropped",
                    details: ["pendingResponses": "\(pendingResponses.count)"]
                )
                // AND through the unanswered tracer. Unlike `completeForward`'s stale-runtime
                // guard — which discards an ANSWER whose client this very function replays, so
                // tracing it would manufacture an outage on a routine wake — this arm discards
                // the CLIENT REQUESTS. Nothing else can settle them: the reset already drained
                // them out of the coalescer and cleared the cache, so every one of these ends
                // here with no reply at all. The line above carries a count and nothing else;
                // the address family is what a capture needs, and it is exactly the split that
                // would tell a wake that cost only AAAA lookups from one that cost everything.
                self.recordUnansweredDNSBatch(
                    reason: "wake-replay-stale-lifecycle", pendingResponses: pendingResponses)
                return
            }

            for pending in pendingResponses {
                // Forwarded queries record their final decision at settlement. Carry the
                // marker through replay so an unanswered request still gets one user record.
                self.handleDNSRequest(
                    pending.request,
                    protocolNumber: pending.protocolNumber,
                    allowsTransientBootstrapDeferral: true,
                    expectedLifecycleGeneration: expectedLifecycleGeneration,
                    isReplayOfARecordedDecision: pending.isReplayOfARecordedDecision
                )
            }
        }
    }

    func beginTransientBootstrapDNSWait(reason: String) {
        guard DispatchQueue.getSpecific(key: dnsStateQueueSpecificKey) == true else {
            dnsStateQueue.sync {
                self.beginTransientBootstrapDNSWait(reason: reason)
            }
            return
        }

        let generation = tunnelLifecycleGeneration
        // Already on dnsStateQueue (the specific-key guard above), which IS the wait
        // actor's executor — synchronous assumeIsolated, zero hops (INV-QUEUE-1).
        // Only the arm runs inside isolation; the replaced queue's SERVFAIL write and
        // the begin log strictly follow it. The @Sendable timeout handler re-enters
        // through failTransientBootstrapDNSWait's own dual entry when the wait's
        // scheduleAfter delivers it on this same queue.
        let replacedPendingResponses = transientBootstrapDNSWait.assumeIsolated { wait in
            wait.beginWait(generation: generation) { [weak self] expiredGeneration in
                self?.failTransientBootstrapDNSWait(
                    reason: "transient-bootstrap-dns-wait-timeout",
                    expectedGeneration: expiredGeneration
                )
            }
        }
        writeServerFailures(
            for: replacedPendingResponses,
            reason: "transient-bootstrap-dns-wait-replaced"
        )

        LavaSecDeviceDebugLog.append(component: "tunnel", event: "transient-bootstrap-dns-wait-begin", details: [
            "generation": "\(generation)",
            "reason": reason
        ])
    }

    func cancelTransientBootstrapDNSWait(reason: String) {
        let cancel = { [self] () -> [PendingDNSResponse] in
            // On dnsStateQueue via the dual-entry hop below, which IS the wait actor's
            // executor — synchronous assumeIsolated, zero hops (INV-QUEUE-1). The
            // cancel log and the SERVFAIL write strictly follow the returned queue.
            let pendingResponses = transientBootstrapDNSWait.assumeIsolated { wait in
                wait.cancelWait()
            }
            if !pendingResponses.isEmpty {
                LavaSecDeviceDebugLog.append(component: "tunnel", event: "transient-bootstrap-dns-wait-cancel", details: [
                    "generation": "\(tunnelLifecycleGeneration)",
                    "pendingResponses": "\(pendingResponses.count)",
                    "reason": reason
                ])
            }
            return pendingResponses
        }

        let pendingResponses: [PendingDNSResponse]
        if DispatchQueue.getSpecific(key: dnsStateQueueSpecificKey) == true {
            pendingResponses = cancel()
        } else {
            pendingResponses = dnsStateQueue.sync(execute: cancel)
        }

        writeServerFailures(for: pendingResponses, reason: reason)
    }
}
