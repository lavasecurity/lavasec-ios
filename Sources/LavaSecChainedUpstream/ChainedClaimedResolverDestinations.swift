import Darwin
import Foundation
import LavaSecKit

/// The resolver destinations the tunnel's route plan CLAIMS as DNS capture-floor host routes,
/// normalized once into the byte form the outbound classifier compares per packet.
///
/// ## Why the classifier needs the claimed set
///
/// ``ChainedOutboundPacketClassifier`` refuses DoT (TCP/853) and DoQ (UDP/853) as encrypted DNS
/// it can neither read nor carry. In a FULL tunnel that refusal is universal — every destination
/// is claimed, so a `:853` flow can only be a resolver the filter cannot read, and the session
/// has no physical-egress rung to strand. In a SPLIT tunnel a blanket refusal would break
/// resolution: the user's own DoT/DoQ rung may egress on the physical interface.
///
/// F3b claims the network's captured resolver addresses as `/32` + `/128` host routes so a
/// client that dials one still reaches the filter (``DNSCaptureFloor``; plan
/// `plans/2026-09-17-path-independent-dns-capture-floor.md`). A destination the plan CLAIMED is
/// ours to serve or refuse: its `:853` flow enters the NE, where it is unfilterable and the
/// IPv4-only peer will not carry it, so it fails closed like the full-tunnel case. A destination
/// the plan did NOT claim never enters the NE in split, so its `:853` is left alone for the rung.
///
/// ## Why a precomputed byte set, never strings
///
/// This runs per packet inside the ~50 MB tunnel process (`INV-MEM-1`). Addresses are
/// normalized ONCE at construction (`inet_pton`, the same parse ``DNSCaptureFloor`` validated),
/// and membership is a compare over the already-parsed destination bytes — no re-normalization,
/// no string work and no per-packet allocation on the hot path. The sets are bounded by the
/// handful of resolvers a network advertises.
///
/// The construction source is ``DNSCaptureFloor/hostRoutes(forResolverAddresses:)`` on the
/// on-link-gateway-filtered list (``DNSCaptureFloorMembership/claimableResolverAddresses(_:)``),
/// so the set can never disagree with the routes F3b merges: the same listener,
/// unusable/mapped-literal and on-link-gateway exclusions apply. The membership filter is
/// applied HERE rather than left to the caller, because a `:853` drop that matches a route the
/// plan did not install — or misses one it did — is exactly the disagreement this type exists
/// to prevent. The caller's obligation is therefore only to hand in the SAME resolver list the
/// route plan is built from: F1's ``DNSCaptureFloor/curatedPublicResolverAddresses`` followed by
/// the captured device resolvers (both are claimed by a split plan; the gateway exclusion
/// leaves the curated entries untouched).
public struct ChainedClaimedResolverDestinations: Sendable {
    /// One IPv6 address as four network-order 32-bit words, so membership is a value compare
    /// with no allocation and no string work per packet.
    private struct IPv6Words: Hashable, Sendable {
        let first: UInt32
        let second: UInt32
        let third: UInt32
        let fourth: UInt32
    }

    private let httpsIPv4Addresses: Set<UInt32>
    private let ipv4Addresses: Set<UInt32>
    private let ipv6Addresses: Set<IPv6Words>

    /// No claimed destinations — the state before F3b's floor is wired, and the state a FULL
    /// tunnel passes because its own `dropsUnfilterableEncryptedDNS` already covers every `:853`.
    public static let empty = ChainedClaimedResolverDestinations(resolverAddresses: [])

    /// Normalizes `resolverAddresses` once into family-separated byte sets.
    public init(resolverAddresses: [String] = [], httpsResolverAddresses: [String] = []) {
        httpsIPv4Addresses = httpsResolverAddresses.isEmpty ? [] : Self(resolverAddresses: httpsResolverAddresses).ipv4Addresses
        var ipv4 = Set<UInt32>()
        var ipv6 = Set<IPv6Words>()

        // The on-link-gateway exclusion is applied here, not asked of the caller: the routes the
        // plan installs only ever come from the filtered list, so an unfiltered input would make
        // this set claim a destination F3b left unclaimed — the disagreement the type forbids.
        let claimable = DNSCaptureFloorMembership.claimableResolverAddresses(resolverAddresses)
        for route in DNSCaptureFloor.hostRoutes(forResolverAddresses: claimable) {
            switch route.family {
            case .ipv4:
                var parsed = in_addr()
                guard inet_pton(AF_INET, route.address, &parsed) == 1 else { continue }
                ipv4.insert(withUnsafeBytes(of: parsed) { raw in
                    (UInt32(raw[0]) << 24) | (UInt32(raw[1]) << 16)
                        | (UInt32(raw[2]) << 8) | UInt32(raw[3])
                })
            case .ipv6:
                var parsed = in6_addr()
                guard inet_pton(AF_INET6, route.address, &parsed) == 1 else { continue }
                ipv6.insert(withUnsafeBytes(of: parsed) { raw in
                    IPv6Words(
                        first: (UInt32(raw[0]) << 24) | (UInt32(raw[1]) << 16)
                            | (UInt32(raw[2]) << 8) | UInt32(raw[3]),
                        second: (UInt32(raw[4]) << 24) | (UInt32(raw[5]) << 16)
                            | (UInt32(raw[6]) << 8) | UInt32(raw[7]),
                        third: (UInt32(raw[8]) << 24) | (UInt32(raw[9]) << 16)
                            | (UInt32(raw[10]) << 8) | UInt32(raw[11]),
                        fourth: (UInt32(raw[12]) << 24) | (UInt32(raw[13]) << 16)
                            | (UInt32(raw[14]) << 8) | UInt32(raw[15]))
                })
            }
        }

        self.ipv4Addresses = ipv4
        self.ipv6Addresses = ipv6
    }

    /// Whether there is anything to compare — lets the classifier skip the IPv6 destination read
    /// on the common split path with no floor claim.
    public var isEmpty: Bool { ipv4Addresses.isEmpty && ipv6Addresses.isEmpty }

    /// Only explicit DoH profile endpoints; ordinary HTTPS and device-router pages are unaffected.
    public func containsHTTPSIPv4Destination(_ destination: UInt32) -> Bool {
        httpsIPv4Addresses.contains(destination)
    }

    /// Whether an IPv4 destination, as the network-order `UInt32` an IPv4 header carries, is a
    /// claimed resolver destination.
    public func containsIPv4Destination(_ ipv4Destination: UInt32) -> Bool {
        ipv4Addresses.contains(ipv4Destination)
    }

    /// Whether the IPv6 destination whose four network-order 32-bit words are given is a claimed
    /// resolver destination.
    public func containsIPv6Destination(
        _ first: UInt32, _ second: UInt32, _ third: UInt32, _ fourth: UInt32
    ) -> Bool {
        ipv6Addresses.contains(
            IPv6Words(first: first, second: second, third: third, fourth: fourth))
    }
}

/// The live claimed-destination set, shared between the provider (writer) and the chained
/// session runner (per-packet reader).
///
/// ## Why a reference, not a value threaded once at construction
///
/// The route plan's capture-floor routes are re-derived on EVERY settings apply — initial install,
/// startup patch drain and ordinary reapply call `makeTunnelNetworkSettingsForLatchedDataPath`, which
/// reads the live `currentDeviceDNSResolverAddresses()`. A claimed set built once when the
/// runtime was constructed would keep matching the network the session
/// started on: after a roam the plan would claim the new network's resolvers as host routes
/// while the classifier still tested the old ones, so a `:853` flow to a destination the plan
/// DID claim would no longer be refused — the flow is drawn into the NE by the route and then
/// not dropped. The runner therefore reads this box per packet, and the provider republishes it
/// wherever the route plan is rebuilt.
///
/// ## Why `os_unfair_lock`
///
/// The read is on the data path, once per outbound packet, and the critical section is a
/// copy-on-write struct copy — the shape ``ChainedResolverPortRegistry`` documents for the same
/// reason. The writer runs on `dnsStateQueue` at reapply and in the construction prologue, both
/// off the hot path. `INV-MEM-1`: the sets are bounded by the handful of resolvers a network
/// advertises, and no set is constructed on read.
public final class ChainedClaimedResolverDestinationsStore: @unchecked Sendable {
    private var lock = os_unfair_lock_s()
    private var stored: ChainedClaimedResolverDestinations

    /// Creates the box around `initial`, which defaults to empty — the pre-F4 and full-tunnel
    /// state.
    public init(_ initial: ChainedClaimedResolverDestinations = .empty) {
        self.stored = initial
    }

    /// Replaces the live set. Called by the provider when the latched route plan is rebuilt, so
    /// the set tracks the same `currentDeviceDNSResolverAddresses()` capture the plan's floor
    /// routes derive from.
    public func update(_ destinations: ChainedClaimedResolverDestinations) {
        os_unfair_lock_lock(&lock)
        stored = destinations
        os_unfair_lock_unlock(&lock)
    }

    /// The current set, read per packet. One lock and a struct retain; no set is built here.
    public func latest() -> ChainedClaimedResolverDestinations {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        return stored
    }
}
