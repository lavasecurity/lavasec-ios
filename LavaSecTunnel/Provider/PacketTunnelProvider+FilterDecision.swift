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
    // MARK: - Filter decision

    func filterDecision(for domain: String) -> FilterDecision {
        snapshotQueue.sync {
            snapshot.decision(for: domain)
        }
    }

    func filterDecision(forNormalizedDomain normalizedDomain: String) -> FilterDecision {
        snapshotQueue.sync {
            snapshot.decision(forNormalizedDomain: normalizedDomain)
        }
    }

    /// Decision + fail-closed reason read under the SAME snapshotQueue pass, so the reason
    /// can never describe a different resident snapshot than the one that made the decision:
    /// a queued reload commit can flip `residentFailClosedDueToUnavailableSnapshot` between
    /// the decision and any deferred read, mislabeling a snapshot-unavailable block as
    /// transient (or the reverse).
    func filterDecisionCapturingFailClosedReason(
        forNormalizedDomain normalizedDomain: String
    ) -> (decision: FilterDecision, failClosedReason: String?) {
        snapshotQueue.sync {
            let decision = snapshot.decision(forNormalizedDomain: normalizedDomain)
            guard decision.reason == .protectionUnavailable else {
                return (decision, nil)
            }
            return (
                decision,
                residentFailClosedDueToUnavailableSnapshot
                    ? "snapshot-unavailable"
                    : "transient-protection-unavailable"
            )
        }
    }

    /// Re-evaluates every destination under one current snapshot for this client response.
    func forwardedDecision(
        for question: DNSQuestion, pending: PendingDNSResponse, reachableAliasDomains: [String]
    ) -> (decision: FilterDecision, failClosedReason: String?, maximumAnswerTTL: UInt32?) {
        // Refresh outside snapshotQueue: the pause reader can enter dnsStateQueue.
        // Check the deadline after acquiring the snapshot so queue delay cannot extend a pause.
        let pauseUntil = isTemporaryProtectionPauseActive(synchronizesDefaults: false)
            ? protectionPauseStateQueue.sync { cachedTemporaryProtectionPauseUntil } : nil
        return snapshotQueue.sync {
            let isPaused = pauseUntil.map { $0 > Date() } ?? false
            let policy = isPaused || pending.temporaryPauseNormalizedDomain != nil
                ? protectionPolicySnapshot : snapshot
            let decision = policy.decision(forNormalizedDomain: question.normalizedDomain,
                                           reachableAliasDomains: reachableAliasDomains)
            let outcome = dnsQueryDispatcher.decideForwardedResponse(
                filterDecision: decision, isProtectionPaused: isPaused,
                maximumAnswerTTL: pending.maximumAnswerTTL, pausedWouldBlockTTL: pausedWouldBlockForwardTTL)
            let reason = outcome.decision.reason == .protectionUnavailable
                ? (residentFailClosedDueToUnavailableSnapshot ? "snapshot-unavailable" : "transient-protection-unavailable")
                : nil
            return (outcome.decision, reason, outcome.maximumAnswerTTL)
        }
    }

    func protectionPolicyDecision(forNormalizedDomain normalizedDomain: String) -> FilterDecision {
        snapshotQueue.sync {
            protectionPolicySnapshot.decision(forNormalizedDomain: normalizedDomain)
        }
    }

    func temporaryPauseMaximumAnswerTTL(forNormalizedDomain normalizedDomain: String) -> UInt32? {
        let decision = protectionPolicyDecision(forNormalizedDomain: normalizedDomain)
        return decision.action == .block ? pausedWouldBlockForwardTTL : nil
    }

    private func currentResolverPreset() -> DNSResolverPreset {
        snapshotQueue.sync {
            snapshot.resolver
        }
    }

    // Tri-state classification of the shared configuration read (INV-PERSIST-1). The
    // bootstrap and reload paths must distinguish existing-but-UNREADABLE — Data Protection
    // between reboot and first unlock on a Connect-On-Demand boot start, when the user's
    // filtering config is intact behind the lock — from absent/corrupt: collapsing them
    // turned a locked config into the EMPTY pass-through, i.e. unfiltered serving while
    // filtering is configured, in violation of INV-DNS-1 (2026-07-14 incident plan,
    // latent-1). File metadata stays readable while content is locked, which is what makes
    // the distinction reliable (see SharedStateFileReader).
    enum SharedConfigurationLoad {
        case loaded(AppConfiguration)
        case absentOrCorrupt
        case unreadable
    }

    func loadConfigurationClassified() -> SharedConfigurationLoad {
        guard let configurationURL else {
            return .absentOrCorrupt
        }
        switch SharedStateFileReader.read(AppConfiguration.self, from: configurationURL) {
        case .loaded(let configuration):
            return .loaded(configuration)
        case .absent, .corrupt:
            return .absentOrCorrupt
        case .unreadable:
            return .unreadable
        }
    }

    func loadConfiguration() -> AppConfiguration? {
        guard case .loaded(let configuration) = loadConfigurationClassified() else {
            return nil
        }

        return configuration
    }
}
