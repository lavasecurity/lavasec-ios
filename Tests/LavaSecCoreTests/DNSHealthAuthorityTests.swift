import Foundation
import XCTest

import LavaSecChainedUpstream
import LavaSecKit

/// `DNSHealthAuthority` is the single place the "exactly one DNS-health owner" decision lives.
/// These pin the two things a divergence bug needs: the latch→owner mapping, and the fact that
/// every ownership consultation is the SAME bit — so no seam can be routed to the wrong owner.
final class DNSHealthAuthorityTests: XCTestCase {
    func testTheChainedLatchSelectsTheTunnelSupervisor() {
        XCTAssertEqual(DNSHealthAuthority(chainedIsLatched: true).owner, .tunnelSupervisor)
        XCTAssertEqual(DNSHealthAuthority(chainedIsLatched: false).owner, .physicalPath)
    }

    func testThePhysicalPathOwnsEveryPhysicalBehaviourWhenNotChained() {
        let authority = DNSHealthAuthority(chainedIsLatched: false)
        XCTAssertTrue(authority.physicalReconnectMayAct)
        XCTAssertTrue(authority.physicalInterfaceHealthProbesMayRun)
        XCTAssertTrue(authority.deviceDNSFallbackMayRun)
        XCTAssertTrue(authority.organicEvidenceFeedsPhysicalReconnect)
    }

    func testNoPhysicalBehaviourRunsWhileChained() {
        // The INV-CHAIN-1 consequence: while the tunnel owns health, the physical interface is
        // untouched. A single one of these coming back true is a leak, which is why they are one
        // decision and this test asserts the whole set, not a representative.
        let authority = DNSHealthAuthority(chainedIsLatched: true)
        XCTAssertFalse(authority.physicalReconnectMayAct)
        XCTAssertFalse(authority.physicalInterfaceHealthProbesMayRun)
        XCTAssertFalse(authority.deviceDNSFallbackMayRun)
        XCTAssertFalse(authority.organicEvidenceFeedsPhysicalReconnect)
    }

    /// The load-bearing invariant: every consultation is the SAME bit, in BOTH latch states, so
    /// the seams cannot be ABLE to disagree. This is what a future edit that gives one seam its
    /// own subtly-different rule has to break — the exhaustiveness the plan's "decided in one
    /// place" depends on.
    func testEveryConsultationAgreesWithTheOwnerInBothStates() {
        for chained in [true, false] {
            let authority = DNSHealthAuthority(chainedIsLatched: chained)
            let physicalOwns = authority.owner == .physicalPath
            XCTAssertEqual(authority.physicalReconnectMayAct, physicalOwns)
            XCTAssertEqual(authority.physicalInterfaceHealthProbesMayRun, physicalOwns)
            XCTAssertEqual(authority.deviceDNSFallbackMayRun, physicalOwns)
            XCTAssertEqual(authority.organicEvidenceFeedsPhysicalReconnect, physicalOwns)
        }
    }

    /// Ownership is total and binary: exactly two owners, so a `switch` over `Owner` needs no
    /// `default` and adding a third owner is a compile-time event that forces every seam to
    /// decide where it belongs, not a silent fall-through.
    func testOwnershipIsExactlyTwoTotalCases() {
        XCTAssertEqual(Set(DNSHealthAuthority.Owner.allCases), [.physicalPath, .tunnelSupervisor])
        XCTAssertEqual(DNSHealthAuthority.Owner.allCases.count, 2)
    }

    /// The egress-suspension seam, in the other module, must not be ABLE to disagree with the
    /// authority about who owns the physical interface. `ChainedResolverEgressPolicy` now sources
    /// its suspension from `DNSHealthAuthority`; this pins that they stay the same decision in
    /// both latch states — a leak boundary (`INV-CHAIN-1`) that a silent divergence would open.
    func testTheEgressSuspensionAgreesWithTheAuthorityInBothStates() {
        for chained in [true, false] {
            let authority = DNSHealthAuthority(chainedIsLatched: chained)
            XCTAssertEqual(
                ChainedResolverEgressPolicy.suspendsPhysicalInterfaceBehaviour(chainedIsLatched: chained),
                !authority.physicalInterfaceHealthProbesMayRun)
            XCTAssertEqual(
                ChainedResolverEgressPolicy.permitsPhysicalInterfaceHealthProbes(chainedIsLatched: chained),
                authority.physicalInterfaceHealthProbesMayRun)
            XCTAssertEqual(
                ChainedResolverEgressPolicy.permitsDeviceDNSFallback(chainedIsLatched: chained),
                authority.deviceDNSFallbackMayRun)
        }
    }

    /// Every ownership consultation the authority declares must actually be READ by a seam.
    ///
    /// The behavioural tests above prove the consultations agree today; they cannot catch a seam
    /// wired to the WRONG one, because today every answer is the same bit. `permitsDeviceDNSFallback`
    /// was exactly that: it asked `suspendsPhysicalInterfaceBehaviour` — the probes question — so
    /// `deviceDNSFallbackMayRun` had no reader at all. Identical answers made it invisible, and it
    /// would have stayed invisible until the subsystems unify (plan Slice N) and the answers
    /// diverge, at which point the device-DNS ladder would silently follow the probe owner.
    ///
    /// The authority names four consultations BECAUSE they are expected to diverge. An unread one
    /// is a seam asking a neighbour's question, so this fails the moment a consultation exists
    /// without a consumer — either wire it, or delete it and stop implying a distinction.
    func testEveryOwnershipConsultationHasAProductionConsumer() throws {
        let authority = try readSource(.dnsHealthAuthority)
        // Regex over the WHOLE file, not a per-line prefix match: a consultation declared
        // `public static var`, or with its return type wrapped to the next line, would be
        // invisible to a line filter — and `Set` equality below would still pass, because the
        // missed one is simply absent from both sides. The blind spot would silently recreate the
        // unread-consultation gap this test exists to close (Kilo, PR #637).
        let pattern = try NSRegularExpression(
            pattern: #"public\s+(?:static\s+)?var\s+(\w+)\s*:\s*Bool"#)
        let range = NSRange(authority.startIndex..., in: authority)
        let consultations = pattern.matches(in: authority, range: range).compactMap { match -> String? in
            Range(match.range(at: 1), in: authority).map { String(authority[$0]) }
        }
        XCTAssertEqual(
            consultations.count, 4,
            "a consultation was added, renamed or hidden from discovery — widen deliberately")
        XCTAssertEqual(
            Set(consultations),
            [
                "physicalReconnectMayAct",
                "physicalInterfaceHealthProbesMayRun",
                "deviceDNSFallbackMayRun",
                "organicEvidenceFeedsPhysicalReconnect",
            ],
            "a consultation was added or renamed — wire the new seam before widening this set")

        // CODE ONLY. The seams document which consultation they source from, so a raw-text search
        // is satisfied by the prose explaining the read rather than the read itself — deleting the
        // production call in `permitsDeviceDNSFallback` would leave this green while the very
        // divergence it guards went unnoticed (Codex, PR #637).
        let consumers = sourceCodeOnly(
            try readPacketTunnelProviderSource() + readSource(.chainedResolverEgress))
        for consultation in consultations {
            XCTAssertTrue(
                consumers.contains(consultation),
                "\(consultation) is declared but no seam READS it — it would diverge unnoticed")
        }
    }
}
