import Foundation
import XCTest
@testable import LavaSecFilterPipeline
@testable import LavaSecKit
@testable import LavaSecNetworking

/// The fail-closed bootstrap ladder.
///
/// With no adoptable artifact the tunnel serves `FailClosedRuntimeSnapshot`, which answers every
/// query with the block-all address. The app's repair — download the sources, publish a new
/// artifact — then cannot resolve those sources, so the outage never ends on its own. These pin
/// the narrow retry that breaks it, and (more importantly) the cases that must NOT retry.
final class BootstrapAwareDataFetcherTests: XCTestCase {

    private func fixedResolver(
        _ literals: [String],
        host: String = "example.com"
    ) -> HostAddressResolver? {
        HostAddressResolverFactory.fixed(
            host: host,
            ipv4: literals.filter { !$0.contains(":") },
            ipv6: literals.filter { $0.contains(":") })
    }

    // MARK: - The resolver factory the ladder installs

    func testAFixedResolverAnswersWithTheSuppliedAddressesForItsOwnHost() throws {
        let resolver = try XCTUnwrap(
            fixedResolver(["93.184.216.34", "2606:2800:220:1::1"], host: "lists.example.com"))
        let answered = try resolver("lists.example.com")
        XCTAssertEqual(answered.count, 2)
        XCTAssertTrue(answered.allSatisfy { $0.isPublic })

        // Case-insensitively, because a redirect's Location header may differ in case from the
        // host we brokered.
        XCTAssertEqual(try resolver("LISTS.EXAMPLE.COM").count, 2)
    }

    /// 🔴 An IDN host must be brokered and scoped in the SAME form.
    ///
    /// `url.host` yields the PERCENT-ENCODED host for a percent-encoded IDN URL
    /// (`b%C3%BCcher.example`), while `pinnedAddresses` normalizes to IDNA-ASCII
    /// (`xn--bcher-kva.example`) before querying the resolver. Brokering under one form and
    /// scoping the resolver to it refuses the very host the broker was consulted for — the
    /// scoping fix introducing a new failure for IDN sources. Both sides now use `asciiHost`.
    func testAnIDNHostBrokersAndScopesInTheSameASCIIForm() throws {
        let url = try XCTUnwrap(URL(string: "https://b%C3%BCcher.example/list.txt"))
        let brokeredHost = try XCTUnwrap(PinnedPublicHTTPSFetcher.asciiHost(from: url))
        XCTAssertEqual(brokeredHost, "xn--bcher-kva.example")

        let resolver = try XCTUnwrap(fixedResolver(["93.184.216.34"], host: brokeredHost))
        // The form the fetcher actually queries with.
        XCTAssertEqual(try resolver("xn--bcher-kva.example").count, 1)
    }

    /// 🔴 A brokered resolver must NOT answer for a host it was not brokered for.
    ///
    /// `fetch` follows redirects and re-resolves each hop. An unscoped resolver therefore hands
    /// the ORIGINAL host's addresses to the redirect target — connecting to one server while
    /// presenting another's SNI and Host header. `cannotFindHost` rather than a fall-through to
    /// the system resolver, because this is only installed while the tunnel is fail-closed,
    /// where the system resolver returns the block-all sinkhole and a fall-through would look
    /// like a successful resolution.
    func testAFixedResolverRefusesAHostItWasNotBrokeredFor() throws {
        let resolver = try XCTUnwrap(
            fixedResolver(["93.184.216.34"], host: "lists.example.com"))
        XCTAssertThrowsError(try resolver("cdn.elsewhere.example")) { error in
            XCTAssertEqual((error as? URLError)?.code, .cannotFindHost)
        }
    }

    func testAFixedResolverRefusesToExistWhenNothingParses() {
        // nil rather than an empty resolver: an empty answer would reach `pinnedAddresses` and
        // be refused as an SSRF signal, reporting a rebinding-shaped failure for what is really
        // "the broker had nothing to offer".
        XCTAssertNil(fixedResolver([]))
        XCTAssertNil(fixedResolver(["not-an-address", ""]))
    }

    func testBrokeredAddressesAreStillSubjectToThePublicScopeGate() {
        // 🔴 THE SAFETY PROPERTY. The broker is not trusted. A tunnel that answered with a
        // private address must not get the app to connect there — the addresses go through the
        // SAME gate as any system-resolved answer, so the broker can help or fail to help, and
        // cannot widen what is reachable.
        guard let resolver = fixedResolver(["10.0.0.5"], host: "lists.example.com") else {
            return XCTFail("fixture should parse")
        }
        XCTAssertThrowsError(
            try PinnedPublicHTTPSFetcher.pinnedAddresses(
                forHost: "lists.example.com", resolver: resolver)
        ) { error in
            XCTAssertEqual(
                error as? NetworkEndpointValidationError, .privateNetworkNotAllowed,
                "a brokered private address must be refused exactly like a resolved one")
        }
    }

    // MARK: - When the ladder engages

    func testTheBrokerIsConsultedOnlyWhenTheHostDidNotResolve() async throws {
        let brokerCalls = Counter()
        let fetcher = BlocklistCatalogSynchronizer.bootstrapAwareDataFetcher { _ in
            await brokerCalls.increment()
            return nil
        }

        // `cannotFindHost` is the sinkhole shape PinnedPublicHTTPSFetcher now reports for an
        // all-unspecified answer, so the ladder engages...
        _ = try? await fetcher(URL(string: "https://unresolvable.invalid/list.txt")!)
        let consulted = await brokerCalls.value
        XCTAssertGreaterThan(
            consulted, 0, "an unresolvable host must reach the broker")
    }

    func testAPrivateAnswerIsNotRetriedThroughTheBroker() async {
        // 🔴 NARROW BY DESIGN. `privateNetworkNotAllowed` is an SSRF signal — a private,
        // loopback or MIXED answer. Retrying it through a second resolver is precisely how a
        // rebinding attempt would get a second chance, so the ladder must not engage.
        let brokerCalls = Counter()
        let fetcher = BlocklistCatalogSynchronizer.bootstrapAwareDataFetcher { _ in
            await brokerCalls.increment()
            return (ipv4: ["93.184.216.34"], ipv6: [])
        }
        // An IP-literal private URL is refused by the literal branch, which raises
        // privateNetworkNotAllowed and never cannotFindHost.
        _ = try? await fetcher(URL(string: "https://10.0.0.5/list.txt")!)
        let consulted = await brokerCalls.value
        XCTAssertEqual(
            consulted, 0,
            "an SSRF refusal must not be retried through the broker")
    }

    private actor Counter {
        private(set) var value = 0
        func increment() { value += 1 }
    }
}

/// Source pins for the tunnel half of the broker. The provider is not in the test target, so
/// these are text pins — the established pattern for cross-process wiring the compiler cannot see.
final class BootstrapHostBrokerSourceTests: XCTestCase {

    func testTheBrokerIsAdmittedOnlyWhileTheResidentSnapshotIsFailClosed() throws {
        let provider = try readPacketTunnelProviderSource()
        let block = try sourceBlock(
            in: provider,
            startingAt: "func handleResolveBootstrapHostMessage",
            endingBefore: "func resetBrokeredBootstrapHostnames")

        // 🔴 The whole safety argument rests on this guard: outside a fail-closed window the
        // app's own resolver works, so the deadlock does not exist and neither should the
        // broker. Without it this is a general-purpose resolver for the container process.
        XCTAssertTrue(block.contains("guard self.isResidentFailClosedDueToUnavailableSnapshot() else"))
        XCTAssertTrue(block.contains("refuse(\"not-fail-closed\")"))

        // One hostname, normalized through the same boundary the DNS path uses.
        XCTAssertTrue(block.contains("DomainName.normalize(requested)"))
        XCTAssertTrue(block.contains("refuse(\"invalid-hostname\")"))

        // Bounded per window.
        XCTAssertTrue(block.contains("maximumBrokeredBootstrapHostsPerFailClosedWindow"))
        XCTAssertTrue(block.contains("refuse(\"window-cap\")"))

        // 🔴 The hostname must never be logged: this runs during a filtering outage, and a
        // blocklist source host is still a host the user asked for.
        XCTAssertFalse(
            block.contains("\"hostname\": hostname"),
            "the brokered hostname must not be written to the device debug log")
    }

    func testTheBrokerNeverSendsPlainDNSOnThePhysicalInterfaceWhileChained() throws {
        let provider = try readPacketTunnelProviderSource()
        let block = try sourceBlock(
            in: provider,
            startingAt: "func handleResolveBootstrapHostMessage",
            endingBefore: "private func resolveBootstrapAddressesThroughTunnel")

        // 🔴 THE LEAK PROPERTY. While chained, EVERY query goes through the WireGuard upstream;
        // plain DNS to the device resolvers would egress on the physical interface, which is
        // exactly what S6's merge bar forbids. The chained branch must be taken first, and the
        // device-resolver branch may only run when there is no tunnelled route.
        // Keyed on the LATCH, not on route availability: currentTunnelledPlainDNSRoute() is
        // also nil when the conf carries no usable DNS line, and treating that as "not chained"
        // dropped into the device branch — the physical-interface leak this pin guards.
        XCTAssertTrue(
            block.contains("let chainedIsLatched = self.currentTunnelDataPathMode().isChainedUpstream"),
            "the branch must key on the latch, not on route availability")
        XCTAssertTrue(
            block.contains("refuse(\"chained-no-route\")"),
            "chained with no usable route must REFUSE, not fall through to device resolvers")
        let chainedIndex = try XCTUnwrap(
            block.range(of: "chainedIsLatched")).lowerBound
        let deviceIndex = try XCTUnwrap(
            block.range(of: "currentDeviceDNSResolverAddresses")).lowerBound
        XCTAssertLessThan(
            chainedIndex, deviceIndex,
            "the device-resolver fallback must sit BELOW the chained branch, not before it")
    }

    func testTheWindowBudgetResetsWhenTheTunnelLeavesFailClosed() throws {
        let provider = try readPacketTunnelProviderSource()
        XCTAssertTrue(
            provider.contains("if !failClosedDueToUnavailableSnapshot {\n                    resetBrokeredBootstrapHostnames()"),
            "the budget resets on the COMMIT that leaves fail-closed, not on a reload request")
    }
}
