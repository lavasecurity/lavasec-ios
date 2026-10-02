import Network
import XCTest

@testable import LavaSecChainedUpstream

/// The one mechanism preventing the encapsulation loop under `0.0.0.0/0`.
///
/// Under `INV-CHAIN-1` the tunnel claims the peer's address too, so an unbound upstream socket
/// routes its own encapsulated datagrams back into the tunnel that produced them — read,
/// re-encapsulated, sent again. Immediate, and inside a ~50 MB jetsam ceiling.
final class ChainedUpstreamChannelParametersTests: XCTestCase {

    func testTheInterfaceRequirementIsSetRatherThanLeftDefault() throws {
        // `ChainedUpstreamEgress.bind` warns the socket must be REQUIRED to use the interface,
        // "not merely prefer it — a preference is satisfied by the tunnel". `NWParameters` has
        // no preference spelling to pick by mistake; the preference it warns about IS the
        // default. So the assertion that matters is that the requirement differs from a fresh
        // parameter set, not that some other field was avoided.
        let parameters = try XCTUnwrap(
            ChainedUpstreamChannelParameters.typeConstrained(for: Self.binding(kind: .wifi)))

        XCTAssertEqual(parameters.requiredInterfaceType, .wifi)
        XCTAssertNotEqual(
            parameters.requiredInterfaceType, NWParameters.udp.requiredInterfaceType,
            "the requirement is indistinguishable from an unconstrained parameter set")
    }

    func testTheDefaultRequirementIsOtherSoItCannotMeanUnsatisfiable() {
        // The trap this file exists around, pinned as a fact about the framework rather than a
        // claim in a comment. A fresh parameter set already reports `.other`, so `.other` in
        // the REQUIRED slot is Network's "unconstrained" — while in the PROHIBITED list the
        // same case names the type `utun` reports.
        //
        // The first version of this file mapped non-physical kinds to `.other` on the
        // reasoning that a prohibited type would make the parameters unusable. It would have
        // produced parameters with no interface requirement at all: the permissive answer,
        // silently, inside the function written to prevent it. If a future SDK changes this
        // default, this test fails and that reasoning gets revisited deliberately.
        XCTAssertEqual(
            NWParameters.udp.requiredInterfaceType, .other,
            "`.other` is no longer the unconstrained default — re-examine the nil mapping")
    }

    func testTheTunnelsOwnInterfaceTypeIsProhibited() {
        // `utun` reports as `.other`, which is the same reasoning `ChainedUpstreamLinkKind`
        // records for refusing that kind outright.
        for kind in [ChainedUpstreamLinkKind.wifi, .cellular, .wiredEthernet] {
            let parameters = ChainedUpstreamChannelParameters.typeConstrained(for: Self.binding(kind: kind))
            XCTAssertTrue(
                parameters?.prohibitedInterfaceTypes?.contains(.other) == true,
                "\(kind) parameters would accept a virtual interface")
        }
    }

    func testEachPhysicalKindRequiresItsOwnInterfaceType() {
        // A binding to Wi-Fi that opens on cellular is metered usage the user did not ask for;
        // the reverse is a failure under cellular restrictions. The policy already chose the
        // interface — this asserts the choice survives into the socket.
        let expected: [ChainedUpstreamLinkKind: NWInterface.InterfaceType] = [
            .wifi: .wifi, .cellular: .cellular, .wiredEthernet: .wiredEthernet,
        ]
        for (kind, type) in expected {
            XCTAssertEqual(
                ChainedUpstreamChannelParameters.typeConstrained(for: Self.binding(kind: kind))?.requiredInterfaceType,
                type, "\(kind) mapped to the wrong interface type")
        }
    }

    func testANonPhysicalKindRefusesToProduceParametersAtAll() {
        // Unreachable through `ChainedBindableInterface`, which refuses these kinds — so
        // reaching it means something bypassed that initialiser. Refusing beats producing
        // loose parameters: the caller must decline to open a socket rather than open an
        // unconstrained one, which is the loop.
        for kind in [ChainedUpstreamLinkKind.loopback, .other] {
            XCTAssertNil(
                ChainedUpstreamChannelParameters.interfaceType(for: kind),
                "\(kind) produced a type that would constrain nothing")
        }
    }

    func testTheParametersAreUDPRatherThanInheritingADefault() {
        // WireGuard is UDP. A TCP parameter set would connect, carry nothing, and look healthy.
        let parameters = ChainedUpstreamChannelParameters.typeConstrained(for: Self.binding(kind: .wifi))
        XCTAssertTrue(
            parameters?.defaultProtocolStack.transportProtocol is NWProtocolUDP.Options,
            "the parameters are not a UDP stack")
    }

    func testEveryBindableKindIsMappedRatherThanDefaulted() {
        // `CaseIterable` so a new link kind fails here rather than silently taking the
        // permissive branch — the recurring defect class in this feature is absent data
        // reaching a default.
        for kind in ChainedUpstreamLinkKind.allCases {
            let type = ChainedUpstreamChannelParameters.interfaceType(for: kind)
            if ChainedUpstreamEgressPolicy.physicalLinkKinds.contains(kind) {
                XCTAssertNotNil(type, "\(kind) is physical but constrains nothing")
                XCTAssertNotEqual(type, .other, "\(kind) mapped to Network's unconstrained value")
            } else {
                XCTAssertNil(type, "\(kind) is not physical and must refuse rather than loosen")
            }
        }
    }

    func testParametersAreRefusedWhenNoLiveInterfaceMatchesTheSelection() {
        // The finding this test exists for. `requiredInterfaceType` narrows to a CATEGORY, and a
        // device with two interfaces of one category — or one whose selected interface vanished
        // while a sibling of its kind survived — satisfies that requirement with the interface
        // nobody chose. Under `0.0.0.0/0` the interface it settles for can be the tunnel, so the
        // degraded binding IS the encapsulation loop.
        //
        // Refusing is therefore the assertion, not an error-handling detail: if this ever
        // returns parameters, the socket opens type-only and the loop is reachable.
        XCTAssertNil(
            ChainedUpstreamChannelParameters.make(for: Self.binding(kind: .wifi), among: []),
            "parameters were produced with no interface identity to pin the socket to")
    }

    func testTheIdentitySlotHasAnHonestUnsetDefault() {
        // The mirror of the `.other` trap above, and the reason the refusal can be written as a
        // plain optional check. The TYPE slot is non-optional and its default `.other` doubles
        // as "unconstrained", which is what made a sentinel there dangerous. The IDENTITY slot
        // is a true optional defaulting to nil, so "no identity" cannot be spelled as a value.
        // If a future SDK gives it a non-nil default, that reasoning needs revisiting.
        XCTAssertNil(
            NWParameters.udp.requiredInterface,
            "`requiredInterface` is no longer unset by default — re-examine the refusal check")
    }

    func testAMatchingLiveInterfaceBecomesTheSocketsRequiredInterface() throws {
        // The positive half, and it cannot be made deterministic: `NWInterface` has no
        // initialiser, so the only real ones come from a live path. It SKIPS rather than passes
        // on a host with no physical interface — a test that quietly passed there would assert
        // nothing at all, which is the failure mode this suite keeps refusing elsewhere.
        guard let live = Self.livePhysicalInterface() else {
            throw XCTSkip("no physical interface on this host")
        }
        let binding = try XCTUnwrap(
            ChainedBindableInterface(
                ChainedUpstreamInterface(name: live.name, kind: Self.kind(of: live.type))))

        let parameters = try XCTUnwrap(
            ChainedUpstreamChannelParameters.make(for: binding, among: [live]))
        XCTAssertEqual(
            parameters.requiredInterface, live,
            "the socket is constrained to the interface's kind but not to the interface")
    }

    func testALiveInterfaceWhoseTypeContradictsTheSelectionIsRefused() throws {
        // Both constraints land in one parameter set, so accepting a name match against a
        // contradicting type would build parameters no interface can satisfy. Those fail the way
        // this file least wants — silently, as a connection that never establishes and sends
        // that never complete, which the outage driver reads as an unresponsive peer for the
        // whole budget.
        guard let live = Self.livePhysicalInterface() else {
            throw XCTSkip("no physical interface on this host")
        }
        let contradicting: NWInterface.InterfaceType = live.type == .wifi ? .wiredEthernet : .wifi

        XCTAssertNil(
            ChainedUpstreamChannelParameters.liveInterface(
                named: live.name, of: contradicting, among: [live]),
            "\(live.name) was accepted for \(contradicting), which it does not report")
    }

    // MARK: - Live-path support

    /// The PRIMING read, not the per-attempt one, and the distinction is the whole point of
    /// `ChainedUpstreamLivePath`. `availableInterfaces()` never waits, so the first call in a
    /// process returns the empty cache — which here would silently turn the two positive tests
    /// below into skips, and a test that skips asserts nothing.
    ///
    /// The module-internal wait rather than `primed(offEngineQueue:)`: this file wants the
    /// interfaces, not the proof value, and there is no engine queue in a parameters test to name.
    private static func liveInterfaces() -> [NWInterface] {
        ChainedUpstreamLivePath.shared.startedAndWaitingForFirstReport()
    }

    private static func livePhysicalInterface() -> NWInterface? {
        liveInterfaces().first {
            [.wifi, .cellular, .wiredEthernet].contains($0.type)
                && !ChainedBindableInterface.virtualNamePrefixes.contains(
                    where: $0.name.lowercased().hasPrefix)
        }
    }

    private static func kind(of type: NWInterface.InterfaceType) -> ChainedUpstreamLinkKind {
        switch type {
        case .wifi: return .wifi
        case .cellular: return .cellular
        case .wiredEthernet: return .wiredEthernet
        default: return .other
        }
    }

    private static func binding(kind: ChainedUpstreamLinkKind) -> ChainedBindableInterface {
        let name: String
        switch kind {
        case .wifi: name = "en0"
        case .cellular: name = "pdp_ip0"
        case .wiredEthernet: name = "en5"
        case .loopback, .other: name = "en9"
        }
        return ChainedBindableInterface(ChainedUpstreamInterface(name: name, kind: kind))!
    }
}
