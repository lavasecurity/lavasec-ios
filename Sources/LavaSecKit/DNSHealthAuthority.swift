import Foundation

/// Who owns aggregate DNS-health judgement and recovery, selected by the chained data-path latch.
///
/// The app runs two DNS-health subsystems with overlapping jurisdiction: the physical-DNS
/// reconnect coordinator (smoke + organic evidence on the interface; recovery = reconnect /
/// recapture / encrypted fallback) and the chained outage supervisor (`ChainedOutageDriver`:
/// tunnel-observation evidence; recovery = surrender → dns-only). Exactly one may own health at
/// a time, and which one is a pure function of a single bit — whether the chained upstream is
/// latched.
///
/// That bit used to be read INLINE at every seam (`currentTunnelDataPathMode().isChainedUpstream`
/// in the reconnect actor, the smoke-probe scheduler, the organic-evidence recorder; and the
/// separate `ChainedResolverEgressPolicy.suspendsPhysicalInterfaceBehaviour` for egress). Every
/// such inline read is a place the "exactly one owner" invariant is RE-DERIVED, and a place it can
/// be missed: the false-reconnect loop (#548) was a seam that fed tunnelled outcomes to the
/// physical reconnect coordinator because its own `if chained` check did not exist yet. Deriving
/// ownership in one place and consulting it everywhere is what stops the seams from disagreeing —
/// the same move `ChainedResolverEgressPolicy` already made when it collapsed two byte-identical
/// suspension predicates into one.
///
/// This type is deliberately a pure value with no I/O: it is constructed from the latch bit at the
/// point of use and answers aggregate ownership questions. Generic physical probes and wedge
/// recovery stand down while chaining is latched. Canonical T1/T2 evidence has a separate,
/// explicitly admitted Device DNS recapture consultation under the split exception (INV-CHAIN-5);
/// it does not broaden any of these gates or make a fixed endpoint restart-worthy.
/// pinned: ResolverTierRecoverySourceTests.testRecaptureUsesTierEvidenceAndTheSharedBudget
public struct DNSHealthAuthority: Equatable, Sendable {
    /// The single owner of DNS health for the current latch.
    public enum Owner: Equatable, Sendable, CaseIterable {
        /// DNS-only: physical-interface probes plus reconnect / device-DNS recapture /
        /// encrypted fallback. This is the owner when the chained upstream is NOT latched.
        case physicalPath
        /// Chained: `ChainedOutageDriver` owns tunnel-observation evidence and the
        /// surrender → dns-only retry ladder. This is the owner when the chained upstream IS
        /// latched. Generic physical probes and wedge recovery do not run under this owner.
        case tunnelSupervisor
    }

    public let owner: Owner

    /// The whole decision, in one place: chained latched ⇒ the tunnel supervisor owns health.
    public init(chainedIsLatched: Bool) {
        owner = chainedIsLatched ? .tunnelSupervisor : .physicalPath
    }

    // MARK: - Ownership consultations
    //
    // Each answers one seam's question. They are all the SAME bit today — that is the point:
    // the seams must not be ABLE to disagree, so they read the same owner rather than each
    // re-deriving `isChainedUpstream`. When the subsystems unify (plan Slice N), the
    // evidence-source and recovery-strategy selection lives behind these names.

    /// The physical-path reconnect actor (VPN restart) may act. False while chained: chained
    /// health is the outage supervisor's, and a restart from the physical actor would reset the
    /// driver's per-lifecycle accounting while fixing nothing a session rebuild would not (#548).
    public var physicalReconnectMayAct: Bool { owner == .physicalPath }

    /// Physical-interface health machinery — the resolver smoke probe, device-DNS capture, and
    /// wedge recovery — may run. False while chained: generic probing is not the split rung's
    /// tier-scoped organic evidence, and must not open physical egress under a full profile.
    public var physicalInterfaceHealthProbesMayRun: Bool { owner == .physicalPath }

    /// The device-DNS fallback ladder may run. Shares the answer above for the same reason:
    /// a generic fallback must not open physical egress under a full profile. The orchestrator's
    /// explicitly admitted split T1/T2 ladder is governed by its own egress allowance.
    public var deviceDNSFallbackMayRun: Bool { owner == .physicalPath }

    /// Organic upstream-resolution outcomes feed the physical reconnect coordinator's evidence.
    /// False while chained: tunnelled outcomes are the outage supervisor's to judge, and letting
    /// them into the physical coordinator is exactly the false-reconnect loop #548 closed.
    public var organicEvidenceFeedsPhysicalReconnect: Bool { owner == .physicalPath }
}
