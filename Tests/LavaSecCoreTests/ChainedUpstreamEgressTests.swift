import XCTest

@testable import LavaSecChainedUpstream

/// Where the chained upstream socket is allowed to send.
///
/// The failure guarded here is a LOOP, not a leak. Chained mode claims `0.0.0.0/0`, so an
/// unbound socket matches the tunnel's own default route and a datagram the engine just
/// encapsulated is handed straight back to be encapsulated again. That is unbounded recursion
/// between the packet loop and the socket, and it burns CPU and the bounded queues until the
/// extension is killed.
final class ChainedUpstreamEgressTests: XCTestCase {
    private typealias Policy = ChainedUpstreamEgressPolicy

    private func iface(_ name: String, _ kind: ChainedUpstreamLinkKind) -> ChainedUpstreamInterface {
        ChainedUpstreamInterface(name: name, kind: kind)
    }

    /// The validated form, for asserting against `.bind`. Force-unwrapped deliberately: a
    /// caller of this helper is claiming the interface IS bindable, and a nil here means the
    /// test's own premise is wrong rather than the policy.
    private func bindable(
        _ name: String, _ kind: ChainedUpstreamLinkKind,
        file: StaticString = #filePath, line: UInt = #line
    ) -> ChainedBindableInterface {
        guard let value = ChainedBindableInterface(iface(name, kind)) else {
            XCTFail("\(name)/\(kind) should be bindable", file: file, line: line)
            return ChainedBindableInterface(iface("en0", .wifi))!
        }
        return value
    }

    // MARK: - The loop

    func testAVirtualInterfaceRefusesRatherThanBindingToTheTunnel() {
        // The state a naive implementation loops in: the tunnel is what the system reports as
        // carrying the path, because it claimed everything. Binding there sends the engine's
        // output back into the engine.
        XCTAssertEqual(
            Policy.egress(usedInterface: iface("utun4", .other)),
            .refuse(.onlyVirtualInterfaceAvailable))
        XCTAssertFalse(Policy.egress(usedInterface: iface("utun4", .other)).permitsSocket)
    }

    func testOnlyPhysicalLinksAreEverBoundTo() {
        // An allowlist, checked exhaustively so a future link kind cannot be admitted by
        // omission. A new platform interface lands in `other`, and the costs are asymmetric:
        // wrongly refusing an exotic-but-real link gives DNS-only, which works, while wrongly
        // accepting a virtual one is the loop.
        // The oracle is written out here rather than read from `physicalLinkKinds`. Deriving
        // it from the production set makes the test agree with whatever that set says,
        // including a future kind wrongly admitted to it — which is precisely the mistake the
        // test exists to catch.
        let physicalByHand: Set<ChainedUpstreamLinkKind> = [.wifi, .cellular, .wiredEthernet]
        XCTAssertEqual(Policy.physicalLinkKinds, physicalByHand, "the allowlist changed")
        for kind in ChainedUpstreamLinkKind.allCases {
            let expectPhysical = physicalByHand.contains(kind)
            let egress = Policy.egress(usedInterface: iface("if0", kind))
            XCTAssertEqual(
                egress, expectPhysical
                    ? .bind(bindable("if0", kind))
                    : .refuse(kind == .other ? .onlyVirtualInterfaceAvailable : .onlyLoopbackAvailable),
                "\(kind)")
            // `permitsSocket` is the gate that decides whether a socket opens at all, and it
            // was asserted for one of its four inputs — in the false direction only. Inverting
            // it therefore blackholed chained mode with a green suite. Driven from the same
            // exhaustive loop, in both directions, for one added line.
            XCTAssertEqual(egress.permitsSocket, expectPhysical, "permitsSocket for \(kind)")
        }
    }

    func testLoopbackCannotReachAPeer() {
        XCTAssertEqual(
            Policy.egress(usedInterface: iface("lo0", .loopback)),
            .refuse(.onlyLoopbackAvailable))
    }

    func testNoPathAtAllIsItsOwnRefusal() {
        XCTAssertEqual(Policy.egress(usedInterface: nil), .refuse(.noPathAvailable))
        XCTAssertFalse(Policy.egress(usedInterface: nil).permitsSocket)
        let values = Set([
            Policy.egress(usedInterface: nil).logValue,
            Policy.egress(usedInterface: iface("utun4", .other)).logValue,
            Policy.egress(usedInterface: iface("lo0", .loopback)).logValue,
        ])
        XCTAssertEqual(values.count, 3, "each refusal must be distinguishable in a device log")
    }

    func testThePathsOwnSelectionIsUsedRatherThanAnyPreferenceOfOurs() {
        // `NWPath.availableInterfaces` is NOT a preference ordering, and an earlier version
        // treated it as one — scanning for the first physical kind. On a device with both
        // radios up that could bind to cellular while the system-selected route was Wi-Fi:
        // metered usage the user did not ask for, or a failure under cellular restrictions.
        //
        // Only the interface the path actually uses is accepted, so there is no list to
        // mis-order.
        XCTAssertEqual(
            Policy.egress(usedInterface: iface("pdp_ip0", .cellular)),
            .bind(bindable("pdp_ip0", .cellular)))
        XCTAssertEqual(
            Policy.egress(usedInterface: iface("en0", .wifi)), .bind(bindable("en0", .wifi)))
    }

    func testTheBoundInterfaceIsCarriedThroughVerbatim() {
        // The caller binds to an interface, so the decision has to name which one rather than
        // its category — that is the whole reason identity is carried.
        guard case .bind(let bound) = Policy.egress(usedInterface: iface("en1", .wiredEthernet))
        else { return XCTFail("a wired link is bindable") }
        XCTAssertEqual(bound.name, "en1")
        XCTAssertEqual(bound.kind, .wiredEthernet)
    }

    func testABindableInterfaceCannotNameAVirtualOne() {
        // `.bind` used to carry a raw `ChainedUpstreamInterface`, so the loop guard lived only
        // in the factory: any caller could write `.bind(ChainedUpstreamInterface(name: "utun4",
        // kind: .other))` and hand the socket the tunnel itself. Validating in a factory
        // validates the factory, not the type — and the illegal value here IS the encapsulation
        // loop.
        //
        // Both terms are enforced because either alone is insufficient. A virtual interface
        // reported with a physical KIND still carries a virtual NAME, and the name is what the
        // caller passes to the socket.
        for prefix in ChainedBindableInterface.virtualNamePrefixes {
            XCTAssertNil(
                ChainedBindableInterface(iface("\(prefix)0", .wifi)),
                "a \(prefix)* interface claiming to be Wi-Fi is still not bindable")
        }
        for kind in ChainedUpstreamLinkKind.allCases where !Policy.physicalLinkKinds.contains(kind) {
            XCTAssertNil(
                ChainedBindableInterface(iface("en0", kind)),
                "a physical NAME does not make \(kind) bindable")
        }
        XCTAssertNotNil(ChainedBindableInterface(iface("en0", .wifi)))
        XCTAssertNotNil(ChainedBindableInterface(iface("pdp_ip0", .cellular)))
    }

    // MARK: - Lifecycle keys on identity, not category

    func testAPathChangeAlwaysRebuildsBecauseSurvivalIsNotObservable() {
        // Four attempts to decide when a socket survives a path change, each wrong: on link
        // KIND (a same-kind roam reads as unchanged), on interface NAME (iOS keeps `en0`
        // across a Wi-Fi roam), on LOCAL ADDRESS (two unrelated networks hand out
        // 192.168.1.50 just as readily), and finally by asking the transport for a Boolean —
        // which failed the same way one layer down, because for the silent same-interface
        // roam the transport cannot produce a truthful `false` either. The index is still
        // `en0`, no socket error is emitted, datagrams just stop.
        //
        // So there is no `keep`. The event carries no payload and there is nothing left for a
        // caller to answer wrongly.
        // ALWAYS, asserted as a universal rather than on the two kinds that came to mind.
        // `boundTo` is an input to this function, so a future arm could read it and the claim
        // would silently narrow to whichever kinds a test happened to name.
        for kind in ChainedUpstreamLinkKind.allCases {
            XCTAssertEqual(
                Policy.lifecycle(after: .pathChanged, boundTo: iface("if0", kind)), .rebuild,
                "\(kind)")
        }
    }

    func testARebuildIsNotAHandshakeWhichIsWhatMakesRebuildingAlwaysAffordable() throws {
        // The load-bearing fact behind removing `keep`, asserted against the engine rather
        // than trusted: if a socket rebuild restarted the session, rebuilding on every
        // metadata-only path update would burn the outage budget and the Boolean would have
        // been worth its risk.
        //
        // It does not. `Tunn` is constructed from keys and an index alone — no socket, no
        // endpoint, no local address — so session state outlives its transport, and a new
        // source port is the ordinary WireGuard roaming case the peer resolves by
        // re-anchoring on the next authenticated datagram.
        // Pinned on the file that DEFINES `Tunn`, not on our call to it. The previous version
        // asserted the shape of `Tunn::new(...)` in our FFI shim, which catches an upstream
        // rename and MISSES the thing the claim is about: a field added to the struct. And it
        // swallowed a read failure through `try?`, so a moved file passed silently.
        let noise = try readSource(.wireGuardCoreVendoredNoise)
        let tunn = try sourceBlock(
            in: noise, startingAt: "pub struct Tunn {", endingBefore: "impl Tunn {")
        for transportState in ["endpoint", "SocketAddr", "UdpSocket", "socket"] {
            XCTAssertFalse(
                tunn.contains(transportState),
                "`Tunn` gained `\(transportState)`: the session would now be carried by its "
                    + "transport, so a socket rebuild would cost a handshake and this policy's "
                    + "rebuild-always stance needs revisiting")
        }
    }

    func testTheOnlyLifecyclesAreRebuildAndClose() {
        // Totality, and the absence of `keep` asserted directly: a future case reintroducing
        // an unconditional keep has to fail something.
        let bound = iface("en0", .wifi)
        let expectations: [(ChainedUpstreamSocketEvent, ChainedUpstreamSocketLifecycle)] = [
            (.sessionEnded, .close),
            (.peerAddressChanged, .rebuild),
            (.pathChanged, .rebuild),
        ]
        for (event, expected) in expectations {
            XCTAssertEqual(Policy.lifecycle(after: event, boundTo: bound), expected, "\(event)")
        }
        // Was `XCTAssertEqual(expectations.count, 3)` — a literal compared with itself, which
        // cannot detect the event it names. Compared against the enum instead, so adding a
        // case without a decision here fails.
        XCTAssertEqual(
            Set(expectations.map(\.0)), Set(ChainedUpstreamSocketEvent.allCases),
            "an event was added without a lifecycle decision")
    }

    func testANewPeerAddressRebuildsTheSocket() {
        // A connected datagram socket carries its destination; reusing it after a roam
        // re-resolve sends to the old peer.
        XCTAssertEqual(
            Policy.lifecycle(after: .peerAddressChanged, boundTo: iface("en0", .wifi)), .rebuild)
    }

    func testASessionEndClosesRatherThanRebuilds() {
        // The one event that must NOT rebuild: rebuilding here would reopen a socket for a
        // session that is over, which is how a torn-down tunnel keeps a live upstream.
        XCTAssertEqual(
            Policy.lifecycle(after: .sessionEnded, boundTo: iface("en0", .wifi)), .close)
        XCTAssertNotEqual(
            Policy.lifecycle(after: .sessionEnded, boundTo: iface("en0", .wifi)), .rebuild)
    }

    // MARK: - Logging

    func testLogValuesNameTheKindAndNeverTheInterfaceName() {
        // An interface name is a small fingerprint of the user's network, and a device log
        // travels in a bug report.
        let egress = Policy.egress(usedInterface: iface("en0", .wifi))
        XCTAssertEqual(egress.logValue, "egress-wifi")
        XCTAssertFalse(egress.logValue.contains("en0"))
        XCTAssertEqual(
            Policy.egress(usedInterface: iface("utun4", .other)).logValue,
            "egress-refused-onlyVirtualInterfaceAvailable")
    }
}
