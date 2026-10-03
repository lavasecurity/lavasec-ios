import Foundation
import LavaSecCore
@testable import LavaSecKit
import XCTest

final class IPv4AnswerAddressClassesTests: XCTestCase {
    /// The three ranges the chained route treats differently must not blur into each other.
    ///
    /// `100.64.0.0/10` is the one that motivates the whole diagnostic — chained mode pulls it
    /// into the tunnel and sends everything else direct — and its boundaries are the easy thing
    /// to get wrong: the block is 100.64–100.127, so `100.63.x` and `100.128.x` are ORDINARY
    /// public space. A classifier that took all of `100/8` would report a routing fact that
    /// isn't one and send the next investigation into the tunnel for no reason.
    func testTheChainedRouteRangesAreClassifiedApart() {
        let cases: [(String, IPv4AddressClass)] = [
            // CGNAT, and its exact edges.
            ("100.64.0.0", .carrierGradeNAT),
            ("100.127.255.255", .carrierGradeNAT),
            ("100.63.255.255", .publicRoutable),
            ("100.128.0.0", .publicRoutable),
            // RFC 1918, and the edges of the 172 block, which is the other easy miss.
            ("10.0.0.1", .privateUse),
            ("172.16.0.1", .privateUse),
            ("172.31.255.255", .privateUse),
            ("172.15.255.255", .publicRoutable),
            ("172.32.0.1", .publicRoutable),
            ("192.168.1.1", .privateUse),
            // Ordinary public space, including a real answer address.
            ("93.184.216.34", .publicRoutable),
            ("8.8.8.8", .publicRoutable),
            ("223.255.255.255", .publicRoutable),
        ]

        for (address, expected) in cases {
            XCTAssertEqual(
                IPv4AddressClass(dottedQuad: address), expected,
                "\(address) must classify as \(expected)")
        }
    }

    /// This codebase already has an address-scope map — `NetworkEndpointValidator`'s, which
    /// decides what `PinnedPublicHTTPSFetcher` may connect to. Two classifiers in one codebase
    /// disagreeing about what "public" means is a trap: the SSRF gate would refuse an address
    /// this diagnostic had just counted as a healthy public answer. `192.88.99.0/24` (6to4
    /// relay anycast) was exactly that gap when this type was first written.
    ///
    /// So the agreement is pinned rather than assumed, over a structured sweep that hits every
    /// boundary in BOTH tables: all 256 first octets against the second and third octets where
    /// either map changes behaviour. The one deliberate difference is CGNAT — the validator
    /// folds `100.64.0.0/10` into `reserved`, this type reports it separately — and it is still
    /// non-public on both sides, so the equivalence below holds for it too.
    func testPublicAgreesWithTheEndpointValidatorScopeMap() {
        let seconds: [UInt8] = [0, 15, 16, 31, 32, 63, 64, 88, 99, 100, 127, 128, 168, 18, 19, 51, 254, 255]
        let thirds: [UInt8] = [0, 1, 2, 99, 100, 113, 255]
        var compared = 0

        for first in UInt8.min...UInt8.max {
            for second in seconds {
                for third in thirds {
                    let octets = [first, second, third, 7]
                    let address = octets.map(String.init).joined(separator: ".")
                    guard let classified = IPv4AddressClass(dottedQuad: address) else {
                        return XCTFail("\(address) must parse")
                    }
                    compared += 1
                    XCTAssertEqual(
                        classified == .publicRoutable,
                        NetworkEndpointValidator.isPublicResolvedIPv4(octets: octets),
                        "\(address): classified \(classified) but the validator disagrees")
                }
            }
        }

        XCTAssertEqual(compared, 256 * seconds.count * thirds.count, "the sweep ran in full")
    }

    /// Special-use space is one bucket on purpose, but everything in it must actually land
    /// there — `0.0.0.0` especially, which is the classic "answered, unreachable" reply.
    func testSpecialUseSpaceIsRecognizedRatherThanReadAsPublic() {
        for address in [
            "0.0.0.0", "127.0.0.1", "169.254.1.1", "192.0.0.1", "192.0.2.1",
            "198.18.0.1", "198.19.255.255", "198.51.100.5", "203.0.113.5",
            // 6to4 relay anycast, RFC 7526 — the range the validator's map already listed and
            // this type missed on its first pass (Codex P2, PR #619).
            "192.88.99.1",
            "224.0.0.1", "240.0.0.1", "255.255.255.255",
        ] {
            XCTAssertEqual(
                IPv4AddressClass(dottedQuad: address), .specialUse,
                "\(address) is special-use, not a destination a public name should resolve to")
        }
    }

    /// Parsed with `inet_pton`, so shorthand and octal forms are REJECTED rather than
    /// reinterpreted. `10.1` means 10.0.0.1 to `inet_aton` — accepting it would let a
    /// non-literal decide a routing class.
    func testOnlyFullDottedQuadsAreAccepted() {
        for address in ["", "10.1", "10.0.0", "10.0.0.1.2", "0x0a000001", "example.com", "::1", "10.0.0.256"] {
            XCTAssertNil(
                IPv4AddressClass(dottedQuad: address),
                "\(address) is not a dotted quad and must not be classified")
        }
    }

    /// Membership, not counts: one resolution answered with several classes sets one flag each,
    /// so a reader adding the four counters can never mistake them for an address total.
    func testMembershipIsPerClassNotPerAddress() {
        let classes = IPv4AnswerAddressClasses(
            classifying: ["93.184.216.34", "8.8.8.8", "100.64.0.5", "100.64.0.6"])

        XCTAssertTrue(classes.containsPublicRoutable)
        XCTAssertTrue(classes.containsCarrierGradeNAT)
        XCTAssertFalse(classes.containsPrivateUse)
        XCTAssertFalse(classes.containsSpecialUse)
        XCTAssertFalse(classes.isEmpty)
    }

    /// The shape the field capture is expected to show if the hypothesis is right: a public
    /// name answered with tunnel-routed space and nothing else.
    func testAnAnswerEntirelyInsideTheTunnelRangeReportsOnlyThatClass() {
        let classes = IPv4AnswerAddressClasses(classifying: ["100.64.0.5"])

        XCTAssertTrue(classes.containsCarrierGradeNAT)
        XCTAssertFalse(classes.containsPublicRoutable)
        XCTAssertFalse(classes.isEmpty, "an answer WAS classified — this is not the empty case")
    }

    /// No addresses and unparseable addresses both report EMPTY rather than inventing a class.
    ///
    /// The distinction carries weight downstream: `isEmpty` is what the resolution uses to keep
    /// the FIRST answered set, and what separates "not an A query / no answer" from "an answer
    /// arrived and every address was public". A skipped junk entry that silently became
    /// `specialUse` would report a routing fact nobody observed.
    func testNothingClassifiableReportsEmptyRatherThanAClass() {
        XCTAssertTrue(IPv4AnswerAddressClasses(classifying: []).isEmpty)
        XCTAssertEqual(IPv4AnswerAddressClasses(classifying: []), .none)
        XCTAssertTrue(IPv4AnswerAddressClasses(classifying: ["not-an-address", "::1"]).isEmpty)

        // A junk entry alongside a real one keeps the real one and adds nothing of its own.
        let mixed = IPv4AnswerAddressClasses(classifying: ["nonsense", "10.0.0.1"])
        XCTAssertTrue(mixed.containsPrivateUse)
        XCTAssertFalse(mixed.containsSpecialUse)
        XCTAssertFalse(mixed.containsPublicRoutable)
    }
}
