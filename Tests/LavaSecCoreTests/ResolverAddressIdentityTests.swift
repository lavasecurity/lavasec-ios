import XCTest
@testable import LavaSecKit

/// `ResolverAddressIdentity` exists for one reason: F2 decides a socket's binding by whether an
/// endpoint's address is one the DNS capture floor claims, and the two sides can spell the same
/// IPv6 address differently. A missed match strands Lava's own query in a claimed route, so the
/// comparison is over parsed bytes and these tests pin that.
final class ResolverAddressIdentityTests: XCTestCase {
    func testAnAddressMatchesItself() {
        XCTAssertTrue(ResolverAddressIdentity.denotesSameAddress("1.1.1.1", "1.1.1.1"))
        XCTAssertTrue(
            ResolverAddressIdentity.denotesSameAddress(
                "2606:4700:4700::1111", "2606:4700:4700::1111"))
    }

    func testEquivalentIPv6SpellingsMatch() {
        XCTAssertTrue(
            ResolverAddressIdentity.denotesSameAddress(
                "2606:4700:4700::1111", "2606:4700:4700:0:0:0:0:1111"),
            "the two spellings name the same address; a string compare would strand the query")
        XCTAssertTrue(
            ResolverAddressIdentity.denotesSameAddress(
                "fd00:1a7a::1", "fd00:1a7a:0000:0000:0000:0000:0000:0001"))
    }

    func testDifferentAddressesDoNotMatch() {
        XCTAssertFalse(ResolverAddressIdentity.denotesSameAddress("1.1.1.1", "8.8.8.8"))
        XCTAssertFalse(
            ResolverAddressIdentity.denotesSameAddress(
                "2606:4700:4700::1111", "2606:4700:4700::1001"))
    }

    func testFamiliesNeverCross() {
        // An IPv4-mapped literal is a DIFFERENT family from the bare IPv4 address, and treating
        // it as equal would let a mapped form inherit the v4 destination's claim.
        XCTAssertFalse(
            ResolverAddressIdentity.denotesSameAddress("127.0.0.1", "::ffff:127.0.0.1"))
        XCTAssertFalse(
            ResolverAddressIdentity.denotesSameAddress("1.1.1.1", "2606:4700:4700::1111"))
    }

    func testAnUnparseableLiteralNeverMatches() {
        XCTAssertFalse(ResolverAddressIdentity.denotesSameAddress("not-an-address", "1.1.1.1"))
        XCTAssertFalse(ResolverAddressIdentity.denotesSameAddress("1.1.1.1", "not-an-address"))
        XCTAssertFalse(ResolverAddressIdentity.denotesSameAddress("", ""))
    }
}
