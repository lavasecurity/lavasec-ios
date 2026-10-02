import Network
import XCTest

@testable import LavaSecChainedUpstream

/// The two halves of the `NWInterface.InterfaceType` mirror, proven against each other so
/// neither can drift.
final class ChainedUpstreamLinkKindMappingTests: XCTestCase {
    func testEveryInterfaceTypeLandsOnItsMirroredKind() {
        XCTAssertEqual(ChainedUpstreamLinkKind(mirroring: .wifi), .wifi)
        XCTAssertEqual(ChainedUpstreamLinkKind(mirroring: .cellular), .cellular)
        XCTAssertEqual(ChainedUpstreamLinkKind(mirroring: .wiredEthernet), .wiredEthernet)
        XCTAssertEqual(ChainedUpstreamLinkKind(mirroring: .loopback), .loopback)
        XCTAssertEqual(
            ChainedUpstreamLinkKind(mirroring: .other), .other,
            "everything unrecognized must land on the kind the egress policy REFUSES — "
                + "binding a link class this module has never seen is the permissive answer")
    }

    /// The forward map must round-trip through the reverse one for every kind the reverse
    /// map constrains — a swapped arm in either switch fails here, not in the field as a
    /// socket bound to the wrong link class.
    func testTheForwardMapRoundTripsThroughTheReverseOne() {
        for kind in ChainedUpstreamLinkKind.allCases {
            guard let type = ChainedUpstreamChannelParameters.interfaceType(for: kind) else {
                continue  // .loopback and .other constrain nothing; totality is the other test.
            }
            XCTAssertEqual(
                ChainedUpstreamLinkKind(mirroring: type), kind,
                "the mirror disagrees with its reverse for \(kind) — the two switches drifted")
        }
    }
}
