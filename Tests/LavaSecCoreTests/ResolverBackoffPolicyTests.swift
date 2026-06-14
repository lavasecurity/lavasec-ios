import XCTest
@testable import LavaSecCore

final class ResolverBackoffPolicyTests: XCTestCase {
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
        ])

        XCTAssertEqual(policy.backoffExpiration(for: "9.9.9.9"), expiration)
        XCTAssertNil(policy.backoffExpiration(for: "149.112.112.112"))
        XCTAssertNil(policy.backoffExpiration(for: DNSResolverPreset.device.id))
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
            .init(address: "8.8.4.4", outcome: .socketUnavailable),
        ])

        XCTAssertEqual(policy.availableAddresses(from: ["8.8.8.8", "8.8.4.4"]), [])

        clock.advance(seconds: 10)

        XCTAssertEqual(policy.availableAddresses(from: ["8.8.8.8", "8.8.4.4"]), ["8.8.8.8", "8.8.4.4"])
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
