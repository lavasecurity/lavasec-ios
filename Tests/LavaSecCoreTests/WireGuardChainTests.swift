import CryptoKit
import Foundation
import XCTest
@testable import LavaSecKit

final class WireGuardChainTests: XCTestCase {
    private func profile(_ name: String, routes: [String] = ["0.0.0.0/0"], mtu: UInt16? = nil, endpoint: String = "198.51.100.2") throws -> ChainedUpstreamConfiguration {
        try ChainedUpstreamConfiguration(endpointHost: endpoint, endpointPort: 51820,
            peerPublicKey: Curve25519.KeyAgreement.PrivateKey().publicKey.rawRepresentation.base64EncodedString(),
            clientAddress: "10.0.0.2", allowedIPs: routes, interfaceMTU: mtu, dnsAddresses: ["1.1.1.1"], displayName: name)
    }

    func testOrderedChainRoundTripAndAnyFullTunnelDisablesFallback() throws {
        let entry = try profile("Entry")
        let exit = try profile("Exit", routes: ["10.0.0.0/8"])
        let chain = try exit.withEntryHop(entry)
        let decoded = try JSONDecoder().decode(ChainedUpstreamConfiguration.self, from: JSONEncoder().encode(chain))
        XCTAssertEqual(decoded.orderedHops.map(\.displayName), ["Entry", "Exit"])
        XCTAssertTrue(decoded.containsFullTunnel)
        XCTAssertEqual(decoded.routingPolicy, .splitTunnel)
        XCTAssertEqual(decoded.dnsAddresses, exit.dnsAddresses)
    }

    func testThirdHopIsRejectedAndIndependentSplitFirstDoesNotNeedExitCoverage() throws {
        let first = try profile("First")
        let second = try profile("Second").withEntryHop(first)
        XCTAssertThrowsError(try profile("Third").withEntryHop(second))
        XCTAssertNoThrow(try profile("Exit").withEntryHop(profile("Entry", routes: ["10.0.0.0/8"])))
    }

    func testEntryHostnameIsRejectedBeforeSavingAChain() throws {
        XCTAssertThrowsError(try profile("Exit").withEntryHop(profile("Entry", endpoint: "vpn.example.com"))) {
            XCTAssertEqual($0 as? WireGuardChainFailure, .entryRequiresLiteralEndpoint)
        }
        XCTAssertNoThrow(try profile("Exit").withEntryHop(profile("Entry", endpoint: "203.0.113.7")))
    }

    func testNestedMTUReservesEncapsulationAndPadding() throws {
        XCTAssertEqual(try profile("Exit", mtu: 1420).withEntryHop(profile("Entry", mtu: 1420)).effectiveInterfaceMTU, 1360)
        XCTAssertEqual(try profile("Exit", mtu: 1420).withEntryHop(profile("Entry", mtu: 1340)).effectiveInterfaceMTU, 1280)
        XCTAssertThrowsError(try profile("Exit").withEntryHop(profile("Entry", mtu: 1339)))
        XCTAssertEqual(try profile("Single", mtu: 1420).effectiveInterfaceMTU, 1420)
    }

    func testSingleProfileRemainsCompatibleAndContainsNoSecretMetadata() throws {
        let config = try profile("Personal")
        XCTAssertEqual(config.orderedHops.count, 1)
        let data = try JSONEncoder().encode(config)
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("privateKey"))
        XCTAssertEqual(try JSONDecoder().decode(ChainedUpstreamConfiguration.self, from: data), config)
    }
}
