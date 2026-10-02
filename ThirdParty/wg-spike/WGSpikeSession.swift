// THROWAWAY SPIKE — Phase 0 de-risking for chained VPN upstream.
//
// REFERENCE FILE, NOT A COMPILED TARGET SOURCE. It lives under ThirdParty/ so it is
// outside every Xcode target and every CI scope root — CI never compiles or lints it.
// A Mac-based engineer copies it into a throwaway LavaSecTunnel branch (behind the
// internal QA-tools build flag), links LavaSecWGSpike.xcframework, and runs
// MEASUREMENT.md. It is
// deliberately not production code: no error taxonomy, no fail-safe-to-DNS-only, no
// reconnect/roaming, no config import — those are Phase 3. This exists ONLY to put a
// live Rust-WG data path next to the filter so phys_footprint can be measured.
//
// Plan: lavasec-infra plans/2026-07-22-vpn-upstream-chaining-implementation-plan.md (Phase 0).

import Foundation
import NetworkExtension
import os

// The C symbols come from LavaSecWGSpike.xcframework via the tunnel's bridging header
// (or @_silgen_name declarations mirroring include/lavasec_wg_spike.h).

/// Bounded, back-pressured packet queue. The feasibility record names unbounded
/// buffering as the wireguard-go SpeedTest-jetsam failure mode; the spike measures with
/// a hard cap and a drop-oldest policy so a throughput burst can never grow resident
/// memory without bound. Not thread-safe on its own — confined to `spikeQueue`.
final class BoundedPacketQueue {
    private var storage: [Data] = []
    private let capacity: Int
    private(set) var dropped: Int = 0

    init(capacity: Int) {
        self.capacity = capacity
    }

    /// Enqueues `packet`. When full, drops the OLDEST datagram to make room, appends the
    /// arrival, and returns false as the back-pressure signal — so the queue stays at
    /// capacity and only one packet is lost per overflow. (Dropping both the oldest and
    /// the new arrival would under-count traffic and skew the throughput/jetsam
    /// measurement this queue exists to drive.)
    @discardableResult
    func enqueue(_ packet: Data) -> Bool {
        if storage.count >= capacity {
            storage.removeFirst()
            dropped += 1
            storage.append(packet)
            return false
        }
        storage.append(packet)
        return true
    }

    func dequeueAll() -> [Data] {
        defer { storage.removeAll(keepingCapacity: true) }
        return storage
    }
}

/// phys_footprint sampler — the jetsam-counted number (matches the feasibility model's
/// 32 MB target / ~40-46 MB cliff). Log this at each MEASUREMENT.md scenario.
enum PhysFootprint {
    static func currentBytes() -> UInt64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), rebound, &count)
            }
        }
        guard result == KERN_SUCCESS else { return 0 }
        return info.phys_footprint
    }

    static func logMebibytes(_ label: String, logger: Logger) {
        let mib = Double(currentBytes()) / (1024.0 * 1024.0)
        logger.log("phys_footprint[\(label, privacy: .public)] = \(mib, privacy: .public) MiB")
    }
}

/// Hardcoded upstream for the spike — a single test peer (self-hosted or Mullvad).
/// Filled in on the throwaway branch; never committed with real keys.
struct WGSpikePeer {
    let privateKey: [UInt8]      // 32 bytes
    let peerPublicKey: [UInt8]   // 32 bytes
    let presharedKey: [UInt8]?   // 32 bytes or nil
    let endpointHost: String     // resolve via a physical-interface bootstrap, NOT 10.255.0.1
    let endpointPort: UInt16
    let keepaliveSeconds: UInt16
}

/// Minimal packetFlow <-> Tunn <-> UDP wiring. The DNS interception path is unchanged
/// (the branch keeps 10.255.0.1 + matchDomains and forwards port-53 to the filter);
/// this class handles ONLY the non-DNS full-traffic path under 0.0.0.0/0.
final class WGSpikeSession {
    private let spikeQueue = DispatchQueue(label: "spike.wg")
    private let inbound: BoundedPacketQueue
    private let outbound: BoundedPacketQueue
    private let logger = Logger(subsystem: "com.lavasec.tunnel.spike", category: "wg")
    private var session: OpaquePointer?
    private var scratch = [UInt8](repeating: 0, count: 65_536)

    init(bufferCapacity: Int) {
        self.inbound = BoundedPacketQueue(capacity: bufferCapacity)
        self.outbound = BoundedPacketQueue(capacity: bufferCapacity)
    }

    // start(peer:packetFlow:) would:
    //   1. wg_spike_session_new(...) with the peer keys
    //   2. wg_spike_force_handshake -> send the init to the UDP socket
    //   3. loop packetFlow.readPackets -> wg_spike_encapsulate -> UDP send
    //   4. loop UDP recv -> wg_spike_decapsulate (draining WRITE_TO_NETWORK) ->
    //      packetFlow.writePackets on WRITE_TO_TUNNEL_*
    //   5. a 250 ms timer calling wg_spike_tick
    //   6. PhysFootprint.logMebibytes at each MEASUREMENT.md checkpoint
    // The body is intentionally omitted here: it is written and thrown away on the
    // measurement branch, not reviewed as product code.
}
