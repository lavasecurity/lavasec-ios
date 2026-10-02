import Foundation
import XCTest
@testable import LavaSecCore

final class DNSResolutionLifetimeTests: XCTestCase {
    func testExpiredQueuedLookupNeverInvokesAnExecutor() {
        let probe = LifetimeProbe()
        let lifetime = DNSResolutionLifetime(deadline: MonotonicDeadline(after: 0), isCurrent: { true })
        run(lifetime: lifetime, probe: probe)
        XCTAssertEqual(probe.calls, 0)
    }

    func testRuntimeChangeEndsEncryptedEndpointsAndDeviceFallback() {
        let probe = LifetimeProbe()
        let lifetime = DNSResolutionLifetime(deadline: MonotonicDeadline(after: 10), isCurrent: { probe.current })
        run(lifetime: lifetime, probe: probe)
        XCTAssertEqual(probe.calls, 1)
    }

    func testWholeDeadlineEndsTheLadderAfterTheFirstAttempt() {
        let probe = LifetimeProbe(delay: 0.08)
        let lifetime = DNSResolutionLifetime(deadline: MonotonicDeadline(after: 0.04), isCurrent: { true })
        run(lifetime: lifetime, probe: probe)
        XCTAssertEqual(probe.calls, 1)
    }

    func testRuntimeChangeDuringTierZeroCannotOpenThePhysicalRung() {
        let probe = LifetimeProbe()
        let lifetime = DNSResolutionLifetime(deadline: MonotonicDeadline(after: 10), isCurrent: { probe.current })
        run(lifetime: lifetime, probe: probe, chained: true)
        XCTAssertEqual(probe.calls, 1)
    }

    private func run(lifetime: DNSResolutionLifetime, probe: LifetimeProbe, chained: Bool = false) {
        let result: @Sendable (DNSResolverTransport) -> DNSResolutionResult = { transport in
            probe.attempt()
            return DNSResolutionResult(response: nil, successfulResolverAddress: nil,
                attempts: [ResolverAttempt(address: "1.1.1.1", outcome: .timeout, transport: transport)],
                transport: transport, udpTruncated: false, tcpFallbackAttempted: false, tcpFallbackSucceeded: false)
        }
        let executors = ResolverOrchestrator.Executors(
            isEndpointBackedOff: { _ in false },
            resolveDoH: { _, _, _, completion in
                probe.attempt(); completion(DNSTransportResponse(response: nil, outcome: .timeout))
            },
            resolveDoT: { _, _, _, _, completion in
                probe.attempt(); completion(DNSTransportResponse(response: nil, outcome: .timeout))
            },
            resolveDoQ: { _, _, _, _, completion in
                probe.attempt(); completion(DNSTransportResponse(response: nil, outcome: .timeout))
            },
            resolvePlain: { _, _, transport, _, _, _ in result(transport) },
            resolveTunnelledPlain: { _, _ in result(.plainDNS) },
            resolveDevice: { _, _, _, _, _, _ in result(.deviceDNS) })
        let plan = DNSResolverRuntimePlan(
            transport: .dnsOverHTTPS, plainAddresses: ["1.1.1.1"],
            dohEndpoints: ["one.example", "two.example"].map {
                DNSOverHTTPSEndpoint(url: URL(string: "https://\($0)/dns-query")!,
                    bootstrapIPv4Servers: [], bootstrapIPv6Servers: [])
            }, dotEndpoints: [], doqEndpoints: [], cacheIdentifier: "test",
            deviceDNSFallbackAddresses: ["192.168.1.1"], shouldFallbackToDeviceDNS: true,
            usesDeviceDNSFallbackMode: false)
        let base = ResolverOrchestrator(executors: executors,
            egressAllowance: { chained ? .chainedSplitTunnelMode : .dnsOnlyMode },
            tunnelledPlainDNSRoute: {
                chained ? .init(resolverAddresses: ["100.64.0.1"], originatingLifecycle: 1, originatingLatchEpoch: 1) : nil
            }, admissionEpoch: { 1 }, tierOneFallbackPlan: { plan })
        let done = expectation(description: "lookup finishes once")
        done.assertForOverFulfill = true
        base.scoped(to: lifetime, executors: executors).resolveUpstream(
            DNSResolverSmokeProbe.query(), plan: plan, admittedAtEpoch: 1) { response in
                XCTAssertNil(response.response)
                done.fulfill()
            }
        wait(for: [done], timeout: 2)
    }
}

private final class LifetimeProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    private let delay: TimeInterval
    init(delay: TimeInterval = 0) { self.delay = delay }
    var calls: Int { lock.lock(); defer { lock.unlock() }; return count }
    var current: Bool { calls == 0 }
    func attempt() {
        lock.lock(); count += 1; lock.unlock()
        if delay > 0 { Thread.sleep(forTimeInterval: delay) }
    }
}
