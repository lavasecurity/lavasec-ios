import Foundation
import XCTest
@testable import LavaSecCore

final class DNSOnlyDefaultRouteTests: XCTestCase {
    func testExclusionsPartitionBothAddressSpacesExceptTheLocalDNSHosts() throws {
        let plan = TunnelRoutePlan.make(
            for: .dnsOnly, dnsCaptureResolverAddresses: [], declaresDefaultRoutesInDNSOnly: true)
        XCTAssertEqual(plan.excludedIPv4Routes.count, 32)
        XCTAssertEqual(plan.excludedIPv6Routes.count, 128)
        let v4 = try plan.excludedIPv4Routes.map { route -> (String, Int) in
            let mask = try bits(route.subnetMask, family: AF_INET)
            let prefix = mask.prefix(while: { $0 == "1" }).count
            XCTAssertEqual(mask, String(repeating: "1", count: prefix) + String(repeating: "0", count: 32 - prefix))
            return (try bits(route.destinationAddress, family: AF_INET), prefix)
        }
        let v6 = try plan.excludedIPv6Routes.map {
            (try bits($0.destinationAddress, family: AF_INET6), $0.prefixLength)
        }
        try assertCompletePartition(v4, retaining: bits(plan.dnsServerAddress, family: AF_INET))
        try assertCompletePartition(v6, retaining: bits(XCTUnwrap(plan.dnsServerIPv6Address), family: AF_INET6))
        XCTAssertEqual(plan.includedIPv4Routes, [.init(destinationAddress: "0.0.0.0", subnetMask: "0.0.0.0")])
        XCTAssertEqual(plan.includedIPv6Routes, [.init(destinationAddress: "::", prefixLength: 0)])
        XCTAssertTrue(plan.installsIPv6Settings)
        XCTAssertTrue(plan.mtuIsLegalForClaimedFamilies)
        XCTAssertFalse(plan.claimsDefaultRoute)
        XCTAssertFalse(plan.claimsIPv6DefaultRoute)
        XCTAssertEqual(plan.dnsCaptureScope, .systemResolverAndClaimedRoutes)
    }

    func testCarrierOverridesCannotContaminateThisComparison() {
        let baseline = TunnelRoutePlan.make(
            for: .dnsOnly, dnsCaptureResolverAddresses: [], declaresDefaultRoutesInDNSOnly: true)
        XCTAssertEqual(baseline, TunnelRoutePlan.make(
            for: .dnsOnly, dnsCaptureResolverAddresses: ["9.9.9.9", "2001:db8::53"],
            capturesIPv6InDNSOnly: true, advertisesIPv6DNSInDNSOnly: true,
            declaresDefaultRoutesInDNSOnly: true))
        let ordinary = TunnelRoutePlan.make(for: .dnsOnly)
        XCTAssertTrue(ordinary.excludedIPv4Routes.isEmpty)
        XCTAssertTrue(ordinary.excludedIPv6Routes.isEmpty)
        XCTAssertFalse(ordinary.installsIPv6Settings)
    }

    // Decode routes as integer intervals, insert the one retained host, then require that
    // the intervals touch end-to-end across the entire space with no overlap or gaps.
    // This checks every address, independently of the sibling-prefix construction.
    private func assertCompletePartition(_ routes: [(String, Int)], retaining host: String) throws {
        var intervals = [(host, host)]
        for (address, prefix) in routes {
            XCTAssertTrue((1...host.count).contains(prefix))
            let network = String(address.prefix(prefix))
            XCTAssertEqual(address, network + String(repeating: "0", count: host.count - prefix))
            intervals.append((address, network + String(repeating: "1", count: host.count - prefix)))
        }
        intervals.sort { $0.0 < $1.0 }
        XCTAssertEqual(intervals.first?.0, String(repeating: "0", count: host.count))
        XCTAssertEqual(intervals.last?.1, String(repeating: "1", count: host.count))
        for index in 1..<intervals.count {
            var successor = Array(intervals[index - 1].1)
            var bit = successor.count - 1
            while bit >= 0, successor[bit] == "1" {
                successor[bit] = "0"
                bit -= 1
            }
            XCTAssertGreaterThanOrEqual(bit, 0)
            if bit >= 0 { successor[bit] = "1" }
            XCTAssertEqual(String(successor), intervals[index].0)
        }
    }

    private func bits(_ address: String, family: Int32) throws -> String {
        var bytes = [UInt8](repeating: 0, count: family == AF_INET ? 4 : 16)
        let parsed = bytes.withUnsafeMutableBytes { inet_pton(family, address, $0.baseAddress) }
        XCTAssertEqual(parsed, 1)
        return bytes.map {
            let value = String($0, radix: 2)
            return String(repeating: "0", count: 8 - value.count) + value
        }.joined()
    }
}
