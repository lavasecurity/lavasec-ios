import XCTest

@testable import LavaSecChainedUpstream
@testable import LavaSecKit

/// Endpoint resolution for the chained upstream.
///
/// The failure this guards is not a wrong answer, it is a HANG. Chained mode sets
/// `matchDomains [""]`, so the tunnel's own name lookups are directed into the tunnel — which,
/// at the moment the endpoint needs resolving, is the thing not yet up. A `getaddrinfo` here
/// does not fail fast; it waits, and the user watches a VPN connect forever.
final class ChainedEndpointResolutionTests: XCTestCase {
    private typealias Policy = ChainedEndpointResolutionPolicy

    private static let deviceResolvers = ["192.168.1.1", "1.1.1.1"]

    // MARK: - The deadlock is unrepresentable, not merely avoided

    func testNoPlanCanAskForTheSystemResolver() {
        // The structural claim. Every reachable plan either needs no lookup, or carries the
        // numeric resolvers to dial, or refuses. There is no fourth case, so a caller cannot
        // route this through `getaddrinfo` by choosing the wrong one — it would have to ignore
        // the plan entirely.
        let plans: [ChainedEndpointResolutionPlan] = [
            Policy.plan(host: "203.0.113.9", port: 51820, capturedDeviceResolvers: []),
            Policy.plan(host: "vpn.example.com", port: 51820, capturedDeviceResolvers: Self.deviceResolvers),
            Policy.plan(host: "vpn.example.com", port: 51820, capturedDeviceResolvers: []),
        ]
        for plan in plans {
            switch plan.outcome {
            case .useLiteral, .queryDirectly, .unresolvable:
                continue
            }
        }

        // And every resolver a plan hands over is numeric, so dialing it cannot itself need a
        // lookup. This is the property that makes the bootstrap terminate.
        guard case .queryDirectly(_, _, let resolvers) = plans[1].outcome else {
            return XCTFail("a hostname with usable resolvers must produce a direct query")
        }
        XCTAssertFalse(resolvers.isEmpty)
        for resolver in resolvers {
            // Numeric by TYPE now, not by convention: the case cannot hold anything else.
            XCTAssertEqual(resolver.port, ChainedEndpointResolutionPolicy.dnsPort)
            XCTAssertNotNil(ChainedResolverAddress(literal: resolver.literal))
        }
    }

    func testTheTunnelsOwnDNSListenerIsNeverQueried() {
        // The circular wait, reachable through the ONE address the structural predicate has no
        // reason to refuse. `10.255.0.1` is an ordinary private address, and the capture can
        // legitimately surface it: while the tunnel owns device DNS the in-process read is
        // masked (INV-DNS-5) and can report the tunnel's own resolver straight back.
        //
        // Querying it to bootstrap the tunnel is exactly the deadlock this type exists to make
        // impossible — the borrowed predicate leaves this config-specific rejection to its
        // caller, and this caller has to make it rather than assume it inherited it.
        XCTAssertTrue(
            DeviceDNSFallbackPolicy.isUsableResolverAddress(TunnelRoutePlan.dnsServerAddress),
            "the structural predicate does not refuse it, which is why this test exists"
        )
        XCTAssertEqual(
            Policy.plan(
                host: "vpn.example.com", port: 51820,
                capturedDeviceResolvers: [TunnelRoutePlan.dnsServerAddress]).outcome,
            .unresolvable(.onlyTheTunnelsOwnResolverCaptured)
)

        // And it is filtered out rather than refusing the whole plan when a real resolver is
        // also present — one masked read must not cost the user a working endpoint.
        guard case .queryDirectly(_, _, let resolvers) = Policy.plan(
            host: "vpn.example.com", port: 51820,
            capturedDeviceResolvers: [TunnelRoutePlan.dnsServerAddress, "9.9.9.9"]).outcome
        else { return XCTFail("a real resolver alongside the tunnel's own must still query") }
        XCTAssertEqual(resolvers.map(\.literal), ["9.9.9.9"])
    }

    func testAQueryPlanCannotBeForgedWithAHostnameResolver() {
        // The payload is validated by TYPE, not by the factory's discipline. The first version
        // of this case carried `[String]`, so `plan`'s inet_pton filtering proved only its own
        // outputs — any caller could write `.queryDirectly(resolvers: ["dns.example.com"])`,
        // and an S3 transport turning that into an endpoint would resolve a hostname to find a
        // resolver, routing the bootstrap back through the system resolver.
        //
        // There is no string to hand in now. The only way to build a resolver entry is through
        // an initializer that refuses everything non-numeric, so the forgery does not compile.
        for hostname in ["dns.example.com", "localhost", "resolver", ""] {
            XCTAssertNil(
                ChainedResolverAddress(literal: hostname),
                "\(hostname) must not be constructible as a resolver address"
            )
        }

        // Every resolver a plan emits carries the DNS port, so the transport cannot invent one.
        guard case .queryDirectly(_, _, let resolvers) = Policy.plan(
            host: "vpn.example.com", port: 51820, capturedDeviceResolvers: Self.deviceResolvers).outcome
        else { return XCTFail("expected a query") }
        XCTAssertFalse(resolvers.isEmpty)
        XCTAssertTrue(resolvers.allSatisfy { $0.port == Policy.dnsPort })
    }

    func testTheTunnelListenerCannotBeBuiltAsAResolver() {
        // Third instance of the same shape in this stack: validating in a factory and calling
        // the TYPE safe. Both the initializer and the `queryDirectly` case are public, so
        // filtering only inside `plan` left a caller free to write
        // `ChainedResolverAddress(literal: TunnelRoutePlan.dnsServerAddress)!` and embed it in
        // a plan directly — and the transport would then query the tunnel whose upstream it is
        // bootstrapping.
        XCTAssertNil(ChainedResolverAddress(literal: TunnelRoutePlan.dnsServerAddress))

        // Still constructible as an ENDPOINT, which is correct: nothing stops a user's peer
        // living at that address, and the refusal is about what may be QUERIED.
        XCTAssertNotNil(
            ChainedEndpointAddress(literal: TunnelRoutePlan.dnsServerAddress, port: 51820))
    }

    func testTheDNSPortHasExactlyOneDefinition() {
        // The constant was introduced to retire an inline `53`, then reintroduced twice inside
        // the resolver type. One definition, re-exported where callers look for it.
        XCTAssertEqual(ChainedResolverAddress.dnsPort, 53)
        XCTAssertEqual(Policy.dnsPort, ChainedResolverAddress.dnsPort)
    }

    func testAResolverCannotBeBuiltOnANonDNSPort() {
        // Typing the payload closed the hostname forgery and left the PORT open: a caller
        // could still hand over `ChainedEndpointAddress(literal: "1.1.1.1", port: 51820)` as a
        // resolver, and the transport would send every query to a non-DNS port and time out —
        // a bootstrap that fails slowly rather than one that fails at all.
        //
        // There is no port to pass now. The property is read-only and constant, so the
        // forgery is unwritable rather than asserted against.
        let resolver = try? XCTUnwrap(ChainedResolverAddress(literal: "1.1.1.1"))
        XCTAssertEqual(resolver?.port, 53)

        guard case .queryDirectly(_, _, let resolvers) = Policy.plan(
            host: "vpn.example.com", port: 51820, capturedDeviceResolvers: Self.deviceResolvers).outcome
        else { return XCTFail("expected a query") }
        XCTAssertTrue(resolvers.allSatisfy { $0.port == 53 })

        // And the endpoint port is still free, which is the reason the two types are separate:
        // a peer is reachable on whatever port the user configured.
        XCTAssertEqual(ChainedEndpointAddress(literal: "203.0.113.9", port: 51820)?.port, 51820)
    }

    func testAMaskedCaptureIsDistinguishedFromABadNetwork() {
        // The two mean opposite things about the network, so folding them together threw away
        // the distinction the type documents. Structurally-unusable addresses CANNOT answer;
        // the tunnel's own listener CAN — which is exactly why it is refused, because
        // answering means the tunnel resolving the endpoint it needs in order to come up.
        //
        // They are also named for what they OBSERVE, not for what they imply. A masked read
        // that saw our own listener (INV-DNS-5) is the likely explanation for the collision,
        // but the input is addresses with no provenance — a physical network is free to
        // advertise 10.255.0.1 as its router resolver, and on that network this reason means
        // the user's gateway collided with ours.
        XCTAssertEqual(
            Policy.plan(
                host: "vpn.example.com", port: 51820,
                capturedDeviceResolvers: [TunnelRoutePlan.dnsServerAddress]).outcome,
            .unresolvable(.onlyTheTunnelsOwnResolverCaptured)
)
        XCTAssertEqual(
            Policy.plan(
                host: "vpn.example.com", port: 51820,
                capturedDeviceResolvers: ["127.0.0.1", "fe80::1"]).outcome,
            .unresolvable(.everyCapturedResolverUnusable)
)
        // Three distinct reasons, three distinct log values — the point of keeping them apart.
        let values = Set([
            Policy.plan(host: "h.example", port: 1, capturedDeviceResolvers: []).logValue,
            Policy.plan(host: "h.example", port: 1, capturedDeviceResolvers: ["127.0.0.1"]).logValue,
            Policy.plan(
                host: "h.example", port: 1,
                capturedDeviceResolvers: [TunnelRoutePlan.dnsServerAddress]).logValue,
        ])
        XCTAssertEqual(values.count, 3)
    }

    func testTheOwnListenerReasonWinsWhenBothApply() {
        // A capture holding our listener AND junk is evidence the read happened too late,
        // whatever else was in it — that is the actionable half.
        XCTAssertEqual(
            Policy.plan(
                host: "vpn.example.com", port: 51820,
                capturedDeviceResolvers: [TunnelRoutePlan.dnsServerAddress, "127.0.0.1"]).outcome,
            .unresolvable(.onlyTheTunnelsOwnResolverCaptured)
)
    }

    // MARK: - Literals need no lookup at all

    func testAnAddressEndpointResolvesToItselfWithoutAQuery() {
        guard case .useLiteral(let address) =
            Policy.plan(host: "203.0.113.9", port: 51820, capturedDeviceResolvers: []).outcome
        else { return XCTFail("an IPv4 literal must not produce a query") }

        XCTAssertEqual(address.literal, "203.0.113.9")
        XCTAssertEqual(address.port, 51820)
        XCTAssertFalse(address.isIPv6)
    }

    func testALiteralNeedsNoCapturedResolversAtAll() {
        // The case that matters at cold start: the capture may not have run yet. A literal
        // endpoint must be unaffected, or chaining would depend on DNS state it never uses.
        XCTAssertEqual(
            Policy.plan(host: "203.0.113.9", port: 51820, capturedDeviceResolvers: []),
            Policy.plan(host: "203.0.113.9", port: 51820, capturedDeviceResolvers: Self.deviceResolvers)
        )
    }

    func testAddressParsingAcceptsOnlyRealLiterals() {
        for good in ["203.0.113.9", "0.0.0.0", "255.255.255.255", "2001:db8::1", "::1", "::"] {
            XCTAssertNotNil(ChainedEndpointAddress(literal: good, port: 51820), good)
        }
        for bad in [
            "vpn.example.com", "203.0.113", "203.0.113.9.9", "203.0.113.256", "",
            " 203.0.113.9", "203.0.113.9 ", "[2001:db8::1]", "2001:db8::1:", "example",
        ] {
            XCTAssertNil(ChainedEndpointAddress(literal: bad, port: 51820), bad)
        }
    }

    func testTheFamilyIsReportedSoTheLoopCanPickASocket() {
        XCTAssertEqual(ChainedEndpointAddress(literal: "203.0.113.9", port: 1)?.isIPv6, false)
        XCTAssertEqual(ChainedEndpointAddress(literal: "2001:db8::1", port: 1)?.isIPv6, true)
    }

    // MARK: - Hostnames query the captured resolvers, filtered

    func testAHostnameQueriesTheCapturedResolversInOrder() {
        guard case .queryDirectly(let name, let port, let resolvers) =
            Policy.plan(host: "vpn.example.com", port: 51820, capturedDeviceResolvers: Self.deviceResolvers).outcome
        else { return XCTFail("a hostname with usable resolvers must produce a direct query") }

        XCTAssertEqual(name, "vpn.example.com")
        XCTAssertEqual(port, 51820)
        XCTAssertEqual(
            resolvers.map(\.literal), ["192.168.1.1", "1.1.1.1"],
            "capture order is the system's intent")
    }

    func testUnusableResolversAreDroppedRatherThanDialed() {
        // Each of these wedges a query on an address that cannot answer. The rule lives in
        // DeviceDNSFallbackPolicy; this asserts the endpoint path actually applies it, rather
        // than re-listing the addresses and drifting from it.
        let captured = ["127.0.0.1", "::1", "0.0.0.0", "::", "fe80::1", "64:ff9b::1", "9.9.9.9"]
        guard case .queryDirectly(_, _, let resolvers) =
            Policy.plan(host: "vpn.example.com", port: 51820, capturedDeviceResolvers: captured).outcome
        else { return XCTFail("one usable resolver is enough to query") }

        XCTAssertEqual(resolvers.map(\.literal), ["9.9.9.9"])
        for dropped in captured where dropped != "9.9.9.9" {
            XCTAssertFalse(
                DeviceDNSFallbackPolicy.isUsableResolverAddress(dropped),
                "\(dropped) was dropped, so the shared predicate must agree it is unusable"
            )
        }
    }

    func testDuplicateResolversAreCollapsed() {
        // The same resolver commonly appears on more than one interface. A duplicate buys
        // nothing and spends a timeout out of a 15 s budget.
        guard case .queryDirectly(_, _, let resolvers) = Policy.plan(
            host: "vpn.example.com", port: 51820,
            capturedDeviceResolvers: ["1.1.1.1", "9.9.9.9", "1.1.1.1", "9.9.9.9"]).outcome
        else { return XCTFail("expected a query") }
        XCTAssertEqual(resolvers.map(\.literal), ["1.1.1.1", "9.9.9.9"])
    }

    // MARK: - Refusing is a working outcome, not a failure to retry

    func testAHostnameWithNoCaptureRefusesRatherThanFallingBack() {
        XCTAssertEqual(
            Policy.plan(host: "vpn.example.com", port: 51820, capturedDeviceResolvers: []).outcome,
            .unresolvable(.noCapturedDeviceResolvers)
)
    }

    func testAllUnusableIsDistinctFromNothingCaptured() {
        // Two different observations. One says nothing was captured, the other says what was
        // captured is structurally undialable. Neither diagnoses a cause on its own, and the
        // log keeps them apart so the next check can differ.
        XCTAssertEqual(
            Policy.plan(
                host: "vpn.example.com", port: 51820,
                capturedDeviceResolvers: ["127.0.0.1", "fe80::1"]).outcome,
            .unresolvable(.everyCapturedResolverUnusable)
)
        XCTAssertNotEqual(
            Policy.plan(host: "vpn.example.com", port: 51820, capturedDeviceResolvers: []).logValue,
            Policy.plan(
                host: "vpn.example.com", port: 51820,
                capturedDeviceResolvers: ["127.0.0.1"]).logValue
        )
    }

    // MARK: - Roaming

    func testALiteralEndpointDoesNotReResolveOnRoam() {
        // The plan comes from the policy, because it can no longer come from anywhere else —
        // this test used to hand-build `.useLiteral(...)`, which is exactly the forgery the
        // type now refuses.
        let address = ChainedEndpointAddress(literal: "203.0.113.9", port: 51820)!
        let plan = Policy.plan(host: "203.0.113.9", port: 51820, capturedDeviceResolvers: [])
        XCTAssertEqual(
            Policy.decisionOnPathChange(for: plan, current: address), .keepCurrent)
    }

    func testAPlanCannotBeBuiltOutsideThePolicy() {
        // The structural end of a class. Four separate findings on this type were the same
        // shape — a public case with a raw payload letting a caller hand-assemble a state
        // `plan` would never emit: a hostname resolver, a resolver on a non-DNS port, the
        // tunnel's own listener, an unusable or empty resolver list, a literal filed as a
        // query. Each was closed individually and the next appeared.
        //
        // The plan's initializer is now fileprivate, so the ONLY way to obtain one is through
        // the policy, which applies every rule. An `Outcome` is still constructible and that
        // is harmless: nothing consumes a bare outcome.
        //
        // The compiler proves the negative; this asserts the positive half — that the one
        // route still works and still carries the rules.
        let forgedOutcome = ChainedEndpointResolutionPlan.Outcome.queryDirectly(
            name: "203.0.113.9", port: 51820, resolvers: [])
        if case .queryDirectly(_, _, let resolvers) = forgedOutcome {
            XCTAssertTrue(resolvers.isEmpty, "an Outcome carries no rules, which is why it is not a plan")
        }
        let real = Policy.plan(host: "203.0.113.9", port: 51820, capturedDeviceResolvers: [])
        guard case .useLiteral = real.outcome else {
            return XCTFail("the policy still classifies a literal as a literal")
        }
    }

    func testUnusableResolversCannotBeBuiltAtAll() {
        // Moved from the filter into the type, matching the listener precedent: a rule
        // enforced only in `plan` is one a hand-built value walks past.
        for unusable in ["127.0.0.1", "::1", "0.0.0.0", "::", "fe80::1", "64:ff9b::1"] {
            XCTAssertNil(ChainedResolverAddress(literal: unusable), unusable)
        }
        XCTAssertNotNil(ChainedResolverAddress(literal: "9.9.9.9"))
    }

    func testAHostnameEndpointKeepsSendingWhileItReResolves() {
        // The regression this exists for: dropping the working address first turns a
        // re-resolve into a guaranteed outage, on the network change where a resolver is
        // slowest, against a 15 s budget. WireGuard is connectionless and the peer is often
        // reachable at the same address on the new path.
        let address = ChainedEndpointAddress(literal: "203.0.113.9", port: 51820)!
        let plan = Policy.plan(
            host: "vpn.example.com", port: 51820, capturedDeviceResolvers: Self.deviceResolvers)
        XCTAssertEqual(
            Policy.decisionOnPathChange(for: plan, current: address),
            .reResolveRetainingCurrent(address)
        )
    }

    func testEveryPlanHasARoamDecision() {
        let address = ChainedEndpointAddress(literal: "203.0.113.9", port: 51820)!
        for plan in [
            Policy.plan(host: "203.0.113.9", port: 51820, capturedDeviceResolvers: []),
            Policy.plan(host: "vpn.example.com", port: 51820, capturedDeviceResolvers: Self.deviceResolvers),
            Policy.plan(host: "vpn.example.com", port: 51820, capturedDeviceResolvers: []),
        ] {
            switch Policy.decisionOnPathChange(for: plan, current: address) {
            case .keepCurrent, .reResolveRetainingCurrent:
                continue
            }
        }
    }

    // MARK: - Disclosure and logging

    func testOnlyTheHostnamePathDisclosesTheEndpointName() {
        // The privacy fact the Settings copy has to state: a hostname endpoint is looked up on
        // the physical interface, so the name reaches the local network's resolver — the
        // observer the user is chaining an upstream to avoid. A literal discloses nothing.
        let literal = Policy.plan(host: "203.0.113.9", port: 51820, capturedDeviceResolvers: [])
        let hostname = Policy.plan(
            host: "vpn.example.com", port: 51820, capturedDeviceResolvers: Self.deviceResolvers)
        let refused = Policy.plan(host: "vpn.example.com", port: 51820, capturedDeviceResolvers: [])

        XCTAssertFalse(literal.disclosesEndpointNameToLocalNetwork)
        XCTAssertTrue(hostname.disclosesEndpointNameToLocalNetwork)
        XCTAssertFalse(refused.disclosesEndpointNameToLocalNetwork, "a refused plan sends nothing")
    }

    func testTheLogValueNeverCarriesTheHostname() {
        // A bug report travels. Writing the endpoint name into the log would undo the
        // disclosure boundary the type is built around.
        let plan = Policy.plan(
            host: "secret-vpn.example.com", port: 51820, capturedDeviceResolvers: Self.deviceResolvers)
        XCTAssertFalse(plan.logValue.contains("secret-vpn"))
        XCTAssertFalse(plan.logValue.contains("example.com"))
        XCTAssertEqual(plan.logValue, "endpoint-query-2-resolvers")
        XCTAssertEqual(
            Policy.plan(host: "203.0.113.9", port: 51820, capturedDeviceResolvers: []).logValue,
            "endpoint-literal-v4"
        )
    }

    func testTheLogValueDoesNotCarryResolverAddressesEither() {
        // Captured device resolvers are the user's network, not ours to record.
        let plan = Policy.plan(
            host: "vpn.example.com", port: 51820, capturedDeviceResolvers: ["192.168.7.7"])
        XCTAssertFalse(plan.logValue.contains("192.168.7.7"))
    }

    // MARK: - The configuration cannot express an IPv6 endpoint

    func testAConfiguredHostIsNeverABareIPv6Literal() throws {
        // Not a property of this policy — a property of the configuration, asserted here
        // because the policy's IPv4-only literal path depends on it. `isPlausibleEndpointHost`
        // rejects any host containing a colon, which is every spelling of an IPv6 literal
        // including the bracketed form. A user whose server is IPv6-only cannot configure it;
        // that gap belongs to config entry, and this fails if it is ever closed without
        // revisiting the literal path here.
        let key = Data(1...32).base64EncodedString()
        for host in ["2001:db8::1", "[2001:db8::1]", "::1"] {
            XCTAssertThrowsError(
                try ChainedUpstreamConfiguration(
                    endpointHost: host, endpointPort: 51820,
                    peerPublicKey: key, clientAddress: "10.64.0.5", allowedIPs: ["0.0.0.0/0"], persistentKeepaliveSeconds: 25),
                "\(host) now configures; the endpoint literal path must handle IPv6"
            )
        }
        // A hostname may still RESOLVE to IPv6, so the resolved family is unconstrained.
        XCTAssertEqual(ChainedEndpointAddress(literal: "2001:db8::1", port: 51820)?.isIPv6, true)
    }
}
