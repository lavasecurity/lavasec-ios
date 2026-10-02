import XCTest
@testable import LavaSecCore
@testable import LavaSecKit

final class ResolverBackoffPolicyTests: XCTestCase {
    func testEncryptedRecoveryIsSharedBoundedAndKeepsHealthyPreference() {
        let clock = FakeResolverBackoffClock(now: Date(timeIntervalSince1970: 1_000))
        var policy = ResolverBackoffPolicy(interval: 30, encryptedRecoveryInterval: 2, clock: clock)
        let addresses = ["doh:one", "dot:two", "doq:three"]
        policy.record(addresses.map { .init(address: $0, outcome: .timeout) })
        XCTAssertEqual(policy.claimEncryptedRecovery(from: addresses), "doh:one")
        let expiration = policy.backoffExpiration(for: "doh:one")
        for _ in 0..<100 {
            XCTAssertNil(policy.claimEncryptedRecovery(from: addresses))
        }
        clock.advance(seconds: 1)
        XCTAssertNil(policy.claimEncryptedRecovery(from: ["doq:three"]))
        clock.advance(seconds: 1)
        XCTAssertEqual(policy.claimEncryptedRecovery(from: ["doq:three"]), "doq:three")
        XCTAssertEqual(policy.backoffExpiration(for: "doh:one"), expiration)
        policy.record([.init(address: "doh:one", outcome: .success)])
        XCTAssertNil(policy.claimEncryptedRecovery(from: addresses))
        XCTAssertEqual(policy.availableAddresses(from: addresses), ["doh:one"])
        policy.reset()
        XCTAssertNil(policy.claimEncryptedRecovery(from: addresses))
        policy.record(addresses.map { .init(address: $0, outcome: .timeout) })
        XCTAssertEqual(policy.claimEncryptedRecovery(from: addresses), "doh:one",
            "reset must clear the still-open recovery cooldown as well as endpoint penalties")
        XCTAssertNil(policy.claimEncryptedRecovery(from: []))
    }

    func testBackwardClockJumpRebasesEncryptedRecoveryCooldown() {
        let clock = FakeResolverBackoffClock(now: Date(timeIntervalSince1970: 10_000))
        var policy = ResolverBackoffPolicy(interval: 30, clock: clock)
        policy.record([.init(address: "doh:one", outcome: .timeout)])
        XCTAssertEqual(policy.claimEncryptedRecovery(from: ["doh:one"]), "doh:one")
        clock.advance(seconds: -3_600)
        XCTAssertEqual(policy.claimEncryptedRecovery(from: ["doh:one"]), "doh:one")
        XCTAssertNil(policy.claimEncryptedRecovery(from: ["doh:one"]))
        clock.advance(seconds: 1)
        XCTAssertEqual(policy.claimEncryptedRecovery(from: ["doh:one"]), "doh:one")
    }

    func testFailureBacksOffAddressUntilIntervalExpires() {
        let clock = FakeResolverBackoffClock(now: Date(timeIntervalSince1970: 1_000))
        var policy = ResolverBackoffPolicy(interval: 30, clock: clock)

        policy.record([.init(address: "8.8.8.8", outcome: .timeout)])

        XCTAssertTrue(policy.isBackedOff("8.8.8.8"))
        XCTAssertEqual(policy.availableAddresses(from: ["8.8.8.8", "8.8.4.4"]), ["8.8.4.4"])

        clock.advance(seconds: 30)

        XCTAssertFalse(policy.isBackedOff("8.8.8.8"))
        XCTAssertEqual(policy.availableAddresses(from: ["8.8.8.8", "8.8.4.4"]), ["8.8.8.8", "8.8.4.4"])
    }

    func testSuccessClearsExistingBackoff() {
        let clock = FakeResolverBackoffClock(now: Date(timeIntervalSince1970: 2_000))
        var policy = ResolverBackoffPolicy(interval: 30, clock: clock)
        policy.record([.init(address: "1.1.1.1", outcome: .receiveFailed)])

        policy.record([.init(address: "1.1.1.1", outcome: .success)])

        XCTAssertFalse(policy.isBackedOff("1.1.1.1"))
        XCTAssertNil(policy.backoffExpiration(for: "1.1.1.1"))
    }

    func testNonMutatingOutcomesDoNotChangeBackoffState() {
        let clock = FakeResolverBackoffClock(now: Date(timeIntervalSince1970: 3_000))
        var policy = ResolverBackoffPolicy(interval: 30, clock: clock)
        policy.record([.init(address: "9.9.9.9", outcome: .sendFailed)])
        let expiration = policy.backoffExpiration(for: "9.9.9.9")

        policy.record([
            .init(address: "9.9.9.9", outcome: .backedOff),
            .init(address: "149.112.112.112", outcome: .unsupported),
            .init(address: DNSResolverPreset.device.id, outcome: .deviceDNSUnavailable),
            // `.tunnelInterfaceUnavailable` is a LOCAL "the tunnel interface isn't bound yet" condition,
            // not an upstream failure, so it must not touch the ledger (2026-08-23 startup-blackout fix,
            // narrowed from `.socketUnavailable` per Codex #570 so genuine socket failures still throttle).
            .init(address: "203.0.113.9", outcome: .tunnelInterfaceUnavailable),
            // `.physicalInterfaceUnavailable` is its opposite-hand sibling — the tunnel IS bound, but
            // F2's live physical pin for a floor-claimed destination is missing. Also local, also no
            // wire attempt, so also no ledger entry (Kilo, PR #747).
            .init(address: "203.0.113.10", outcome: .physicalInterfaceUnavailable),
        ])

        XCTAssertEqual(policy.backoffExpiration(for: "9.9.9.9"), expiration)
        XCTAssertNil(policy.backoffExpiration(for: "149.112.112.112"))
        XCTAssertNil(policy.backoffExpiration(for: DNSResolverPreset.device.id))
        XCTAssertNil(policy.backoffExpiration(for: "203.0.113.9"))
        XCTAssertNil(policy.backoffExpiration(for: "203.0.113.10"))
    }

    func testTunnelInterfaceUnavailableDoesNotBackOffTheEndpoint() {
        // The chained-tunnel startup blackout (device-confirmed 2026-08-23): `virtualInterface` lags a
        // few seconds after connect, so the resolver socket has no interface to pin to and the binding
        // refuses with `.tunnelInterfaceUnavailable`. Penalising the upstream endpoint for that local
        // condition backed it off for the full interval, suppressing every query as `.backedOff` long
        // after the interface was ready → a ~30-45 s DNS blackout. It is a transient local
        // send-capability condition, not an upstream failure, so it must NOT back off the endpoint —
        // the query the moment the interface is ready must go straight out. (Genuine socket failures use
        // `.socketUnavailable`, which DOES back off — see testAllMutatingFailureOutcomesBackOffAddress.)
        let clock = FakeResolverBackoffClock(now: Date(timeIntervalSince1970: 6_000))
        var policy = ResolverBackoffPolicy(interval: 30, clock: clock)

        policy.record([.init(address: "8.8.8.8", outcome: .tunnelInterfaceUnavailable)])

        XCTAssertFalse(
            policy.isBackedOff("8.8.8.8"),
            "tunnel-interface-unavailable is a local interface-not-ready condition, not an upstream failure")
        XCTAssertNil(policy.backoffExpiration(for: "8.8.8.8"))
        XCTAssertEqual(policy.availableAddresses(from: ["8.8.8.8"]), ["8.8.8.8"])
    }

    /// F2's missing PHYSICAL pin is not an upstream failure either, and it must not be folded into
    /// the tunnel-interface case's ledger behaviour by accident: it is a distinct outcome now, so it
    /// gets its own proof that a destination refused for it stays available (Kilo, PR #747).
    func testPhysicalInterfaceUnavailableDoesNotBackOffTheEndpoint() {
        let clock = FakeResolverBackoffClock(now: Date(timeIntervalSince1970: 6_200))
        var policy = ResolverBackoffPolicy(interval: 30, clock: clock)

        policy.record([.init(address: "8.8.4.4", outcome: .physicalInterfaceUnavailable)])

        XCTAssertFalse(
            policy.isBackedOff("8.8.4.4"),
            "physical-interface-unavailable is a local missing-pin condition, not an upstream failure")
        XCTAssertNil(policy.backoffExpiration(for: "8.8.4.4"))
        XCTAssertEqual(policy.availableAddresses(from: ["8.8.4.4"]), ["8.8.4.4"])
    }

    func testAllMutatingFailureOutcomesBackOffAddress() {
        let mutatingOutcomes: [ResolverBackoffPolicy.AttemptOutcome] = [
            .timeout,
            .httpStatusFailure,
            .sendFailed,
            .receiveFailed,
            .invalidAddress,
            .socketUnavailable,
            .mismatchedResponse,
        ]

        for (index, outcome) in mutatingOutcomes.enumerated() {
            let address = "192.0.2.\(index + 1)"
            var policy = ResolverBackoffPolicy(
                interval: 30,
                clock: FakeResolverBackoffClock(now: Date(timeIntervalSince1970: 3_500))
            )

            policy.record([.init(address: address, outcome: outcome)])

            XCTAssertTrue(policy.isBackedOff(address), "Expected \(outcome.rawValue) to back off \(address)")
        }
    }

    func testRepeatedAddressAttemptsAreAppliedInOrder() {
        let clock = FakeResolverBackoffClock(now: Date(timeIntervalSince1970: 3_750))
        var policy = ResolverBackoffPolicy(interval: 30, clock: clock)

        policy.record([
            .init(address: "8.8.8.8", outcome: .timeout),
            .init(address: "8.8.8.8", outcome: .success),
        ])

        XCTAssertFalse(policy.isBackedOff("8.8.8.8"))

        policy.record([
            .init(address: "8.8.8.8", outcome: .success),
            .init(address: "8.8.8.8", outcome: .timeout),
        ])

        XCTAssertTrue(policy.isBackedOff("8.8.8.8"))
    }

    func testAllBackedOffAddressesRecoverWhenBackoffExpires() {
        let clock = FakeResolverBackoffClock(now: Date(timeIntervalSince1970: 4_000))
        var policy = ResolverBackoffPolicy(interval: 10, clock: clock)
        policy.record([
            .init(address: "8.8.8.8", outcome: .timeout),
            .init(address: "8.8.4.4", outcome: .receiveFailed),
        ])

        // Both are suppressed, so there is no healthy address to prefer — the route is handed
        // back whole rather than emptied (`availableAddresses`' own note: suppression defers, it
        // never eliminates). This assertion used to expect `[]`; that contract is what turned ten
        // transient socket failures into 36 dead lookups on device 2026-08-29.
        XCTAssertEqual(
            policy.availableAddresses(from: ["8.8.8.8", "8.8.4.4"]), ["8.8.8.8", "8.8.4.4"])
        // THE LEDGER STILL KNOWS, which is what keeps this test about EXPIRY. Without these two
        // the fall-back above would satisfy both halves and the test would pass whether the
        // interval elapsed or not — the same assertion twice, proving nothing.
        XCTAssertTrue(policy.isBackedOff("8.8.8.8"))
        XCTAssertTrue(policy.isBackedOff("8.8.4.4"))

        clock.advance(seconds: 10)

        XCTAssertEqual(policy.availableAddresses(from: ["8.8.8.8", "8.8.4.4"]), ["8.8.8.8", "8.8.4.4"])
        XCTAssertFalse(policy.isBackedOff("8.8.8.8"))
        XCTAssertFalse(policy.isBackedOff("8.8.4.4"))
    }

    func testResetClearsAllBackoffState() {
        let clock = FakeResolverBackoffClock(now: Date(timeIntervalSince1970: 5_000))
        var policy = ResolverBackoffPolicy(interval: 30, clock: clock)
        policy.record([
            .init(address: "8.8.8.8", outcome: .timeout),
            .init(address: "1.1.1.1", outcome: .mismatchedResponse),
        ])

        policy.reset()

        XCTAssertEqual(policy.availableAddresses(from: ["8.8.8.8", "1.1.1.1"]), ["8.8.8.8", "1.1.1.1"])
        XCTAssertNil(policy.backoffExpiration(for: "8.8.8.8"))
        XCTAssertNil(policy.backoffExpiration(for: "1.1.1.1"))
    }

    /// A suppression that leaves nothing to try is an outage, not a throttle.
    ///
    /// The single-resolver route is the whole point: a chained profile that supplies one DNS
    /// server has no failover for the ledger to express, so benching it removes the only address
    /// and every uncached lookup fails closed for the interval. Device 2026-08-29: ten transient
    /// local socket failures cost 36 of 185 resolutions this way, in rolling 30 s bands.
    func testSuppressionNeverEmptiesANonEmptyRoute() {
        let clock = FakeResolverBackoffClock(now: Date(timeIntervalSince1970: 5_000))
        var policy = ResolverBackoffPolicy(interval: 30, clock: clock)
        policy.record([.init(address: "100.100.100.100", outcome: .socketUnavailable)])

        // Still recorded as backed off — the ledger's own state is unchanged...
        XCTAssertTrue(policy.isBackedOff("100.100.100.100"))
        // ...but the sole address is still offered, because refusing it resolves nothing.
        XCTAssertEqual(
            policy.availableAddresses(from: ["100.100.100.100"]), ["100.100.100.100"],
            "suppressing the only address turns a throttle into a DNS outage")
    }

    /// Where there IS an alternative, suppression must still do its job.
    ///
    /// The guard above must not become "backoff never filters anything" — that would reintroduce
    /// the head-of-line latency the ledger exists to remove, on every route that has a healthy
    /// address to prefer.
    func testSuppressionStillFiltersWhenAHealthyAddressRemains() {
        let clock = FakeResolverBackoffClock(now: Date(timeIntervalSince1970: 6_000))
        var policy = ResolverBackoffPolicy(interval: 30, clock: clock)
        policy.record([.init(address: "9.9.9.9", outcome: .timeout)])

        XCTAssertEqual(
            policy.availableAddresses(from: ["9.9.9.9", "1.1.1.1"]), ["1.1.1.1"],
            "a sick address must drop out while a healthy one remains")

        // And once BOTH are sick, the route is offered whole again, in the caller's order.
        policy.record([.init(address: "1.1.1.1", outcome: .receiveFailed)])
        XCTAssertEqual(
            policy.availableAddresses(from: ["9.9.9.9", "1.1.1.1"]), ["9.9.9.9", "1.1.1.1"],
            "with nothing healthy to prefer, the ladder is handed back in its original order")
    }

    /// Every refusal WE make leaves the endpoint available — asserted for all three, not two.
    ///
    /// `.resolverPortUnavailable` was the third member of this family and the only one with no
    /// assertion behind its "MUST NOT BACK OFF" doc block: the behaviour held, through the
    /// `ResolverBackoffPolicy.AttemptOutcome` bridge mapping it to the no-penalty `.backedOff`
    /// arm, but nothing failed if a later edit to either changed it — which is precisely the
    /// regression class this split exists to make visible (Kilo, PR #623).
    ///
    /// EXECUTED, not pinned — the bridge and the policy are both in the package, so the real
    /// question ("does an address stay available after this outcome?") can simply be asked. A
    /// text pin would assert today's spelling of the mapping; this asserts its meaning, and would
    /// still fail if someone rewrote the bridge to reach the same wrong answer another way.
    ///
    /// This is the invariant the whole split exists to establish: the 30 s penalty is for
    /// endpoints that failed us, never for our own lifecycle bookkeeping. These three paragraphs
    /// sat above `testSuppressionNeverEmptiesANonEmptyRoute` — a doc block orphaned onto the
    /// neighbouring test when this one was inserted (Kilo, PR #623).
    func testTokenRefusalsDoNotThrottleTheEndpoint() {
        for outcome: ResolverAttemptOutcome in [
            .refusedAfterLifecycleEnded, .refusedAfterLatchReplaced, .resolverPortUnavailable,
        ] {
            let clock = FakeResolverBackoffClock(now: Date(timeIntervalSince1970: 4_000))
            var policy = ResolverBackoffPolicy(interval: 30, clock: clock)
            policy.record([
                .init(
                    address: "9.9.9.9",
                    outcome: ResolverBackoffPolicy.AttemptOutcome(outcome))
            ])
            XCTAssertFalse(
                policy.isBackedOff("9.9.9.9"),
                "\(outcome.rawValue) must leave the endpoint available — it never reached a socket"
            )
        }
        // The control: a genuine socket failure still throttles, so this proves a
        // DISCRIMINATION rather than a policy that has quietly stopped backing anything off.
        let clock = FakeResolverBackoffClock(now: Date(timeIntervalSince1970: 4_000))
        var policy = ResolverBackoffPolicy(interval: 30, clock: clock)
        policy.record([
            .init(
                address: "9.9.9.9",
                outcome: ResolverBackoffPolicy.AttemptOutcome(.socketUnavailable))
        ])
        XCTAssertTrue(
            policy.isBackedOff("9.9.9.9"),
            "a real socket failure must still throttle — #570's point stands"
        )
    }
}

private final class FakeResolverBackoffClock: ResolverBackoffClock, @unchecked Sendable {
    var now: Date

    init(now: Date) {
        self.now = now
    }

    func advance(seconds: TimeInterval) {
        now = now.addingTimeInterval(seconds)
    }
}
