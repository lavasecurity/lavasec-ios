import XCTest
@testable import LavaSecKit

/// `ResolverInterfaceBinding` carries no policy, so what is worth testing is the one property the
/// socket layer branches on — and the fact that the cases are not interchangeable, which is the
/// entire reason the type exists rather than a `UInt32?`.
final class ResolverInterfaceBindingTests: XCTestCase {
    func testAChainedBindingIsARequirementAndNotAPreference() {
        XCTAssertTrue(
            ResolverInterfaceBinding.boundToTunnel(interfaceIndex: 42).mustBindBeforeConnect,
            "a chained socket that cannot be pinned must fail, not fall back to the physical "
                + "interface — the fallback is indistinguishable from the leak"
        )
        XCTAssertFalse(
            ResolverInterfaceBinding.systemChosen.mustBindBeforeConnect,
            "there is nothing to apply when the routing table chooses, so there is nothing to fail"
        )
    }

    /// F2's `.boundToPhysical` is a requirement too: a claimed route whose physical pin failed
    /// must not quietly follow the routing table back into the tunnel.
    func testAPhysicalBindingIsAlsoARequirementAndNotAPreference() {
        XCTAssertTrue(
            ResolverInterfaceBinding.boundToPhysical(interfaceIndex: 42).mustBindBeforeConnect)
        XCTAssertEqual(
            ResolverInterfaceBinding.boundToPhysical(interfaceIndex: 42).requiredInterfaceIndex, 42)
    }

    func testEveryPinnedBindingCarriesAnIndexAndSystemChosenDoesNot() {
        XCTAssertEqual(
            ResolverInterfaceBinding.boundToTunnel(interfaceIndex: 95).requiredInterfaceIndex, 95)
        XCTAssertEqual(
            ResolverInterfaceBinding.boundToPhysical(interfaceIndex: 95).requiredInterfaceIndex, 95)
        XCTAssertNil(ResolverInterfaceBinding.systemChosen.requiredInterfaceIndex)
    }

    /// Two sockets pinned to different interfaces are not the same binding. Obvious, and worth a
    /// line: an `Equatable` that ignored the index would let a stale binding compare equal to a
    /// fresh one across a tunnel restart, and the stale index names a dead interface. The two pin
    /// KINDS are distinct as well, even at the same index.
    func testBindingsToDifferentInterfacesAreNotEqual() {
        XCTAssertNotEqual(
            ResolverInterfaceBinding.boundToTunnel(interfaceIndex: 95),
            ResolverInterfaceBinding.boundToTunnel(interfaceIndex: 96))
        XCTAssertNotEqual(
            ResolverInterfaceBinding.boundToTunnel(interfaceIndex: 95),
            ResolverInterfaceBinding.systemChosen)
        XCTAssertNotEqual(
            ResolverInterfaceBinding.boundToTunnel(interfaceIndex: 95),
            ResolverInterfaceBinding.boundToPhysical(interfaceIndex: 95))
        XCTAssertNotEqual(
            ResolverInterfaceBinding.boundToPhysical(interfaceIndex: 95),
            ResolverInterfaceBinding.boundToPhysical(interfaceIndex: 96))
    }

    /// Log values are stable strings a field log is read by, and they must not carry the index.
    func testLogValuesAreStableAndCarryNoIndex() {
        XCTAssertEqual(ResolverInterfaceBinding.systemChosen.logValue, "resolver-socket-system-chosen")
        XCTAssertEqual(
            ResolverInterfaceBinding.boundToTunnel(interfaceIndex: 95).logValue,
            "resolver-socket-bound-to-tunnel")
        XCTAssertEqual(
            ResolverInterfaceBinding.boundToPhysical(interfaceIndex: 95).logValue,
            "resolver-socket-bound-to-physical")
    }
}
