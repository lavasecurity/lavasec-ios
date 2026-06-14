import XCTest
@testable import LavaSecCore

final class ResolverOrchestratorTests: XCTestCase {
    private let query = Data([0x12, 0x34, 0x01, 0x00, 0x00, 0x01])

    func testDoHSuccessRecordsAttemptWithNegotiatedProtocol() {
        let recorder = ExecutorRecorder()
        let orchestrator = Self.orchestrator(
            recorder: recorder,
            dohResults: [DNSTransportResponse(
                response: Data([0x01]),
                outcome: .success,
                negotiatedHTTPProtocolName: "h3"
            )]
        )

        let result = resolveUpstreamSync(orchestrator, plan: Self.dohPlan(endpointHosts: ["one.example"]))

        XCTAssertEqual(result?.response, Data([0x01]))
        XCTAssertEqual(result?.successfulResolverAddress, "doh:https://one.example/dns-query")
        XCTAssertEqual(result?.attempts.count, 1)
        XCTAssertEqual(result?.attempts.first?.outcome, .success)
        XCTAssertEqual(result?.attempts.first?.transport, .dnsOverHTTPS)
        XCTAssertEqual(result?.attempts.first?.negotiatedDoHProtocol, "h3")
        XCTAssertEqual(result?.negotiatedDoHProtocol, "h3")
        XCTAssertEqual(recorder.dohCallCount, 1)
        XCTAssertEqual(recorder.plainCallCount, 0)
        XCTAssertEqual(recorder.deviceCallCount, 0)
    }

    func testTimeoutFailsOverToNextEndpoint() {
        let recorder = ExecutorRecorder()
        let orchestrator = Self.orchestrator(
            recorder: recorder,
            dohResults: [
                DNSTransportResponse(response: nil, outcome: .timeout),
                DNSTransportResponse(response: Data([0x02]), outcome: .success)
            ]
        )

        let result = resolveUpstreamSync(
            orchestrator,
            plan: Self.dohPlan(endpointHosts: ["one.example", "two.example"])
        )

        XCTAssertEqual(result?.response, Data([0x02]))
        XCTAssertEqual(result?.successfulResolverAddress, "doh:https://two.example/dns-query")
        XCTAssertEqual(result?.attempts.map(\.outcome), [.timeout, .success])
        XCTAssertEqual(recorder.dohCallCount, 2)
    }

    func testAllEndpointsFailingAccumulatesAttemptsWithoutResponse() {
        let recorder = ExecutorRecorder()
        let orchestrator = Self.orchestrator(
            recorder: recorder,
            dohResults: [
                DNSTransportResponse(response: nil, outcome: .receiveFailed),
                DNSTransportResponse(response: nil, outcome: .timeout)
            ]
        )

        let result = resolveUpstreamSync(
            orchestrator,
            plan: Self.dohPlan(endpointHosts: ["one.example", "two.example"])
        )

        XCTAssertNil(result?.response)
        XCTAssertNil(result?.successfulResolverAddress)
        XCTAssertEqual(result?.attempts.map(\.outcome), [.receiveFailed, .timeout])
        XCTAssertEqual(result?.failureSummary, "timeout")
    }

    func testBackedOffEndpointSkipsWireAndAdvancesToNextEndpoint() {
        let recorder = ExecutorRecorder()
        recorder.backedOffAddresses = ["doh:https://one.example/dns-query"]
        let orchestrator = Self.orchestrator(
            recorder: recorder,
            dohResults: [DNSTransportResponse(response: Data([0x03]), outcome: .success)]
        )

        let result = resolveUpstreamSync(
            orchestrator,
            plan: Self.dohPlan(endpointHosts: ["one.example", "two.example"])
        )

        XCTAssertEqual(result?.response, Data([0x03]))
        XCTAssertEqual(result?.attempts.map(\.outcome), [.backedOff, .success])
        XCTAssertEqual(
            recorder.dohCallCount,
            1,
            "A backed-off endpoint must not touch the wire."
        )
        XCTAssertEqual(result?.attempts.first?.address, "doh:https://one.example/dns-query")
    }

    func testEmptyEncryptedEndpointsDegradeToPlainDNS() {
        let recorder = ExecutorRecorder()
        let orchestrator = Self.orchestrator(recorder: recorder)

        let result = resolveUpstreamSync(orchestrator, plan: Self.dohPlan(endpointHosts: []))

        XCTAssertEqual(recorder.plainCallCount, 1)
        XCTAssertEqual(recorder.lastPlainAddresses, ["9.9.9.9"])
        XCTAssertEqual(recorder.lastPlainTransport, .plainDNS)
        XCTAssertEqual(result?.response, ExecutorRecorder.plainResponse)
    }

    func testDeviceFallbackRunsOnlyWhenPrimaryFailsAndPlanAllowsIt() {
        let recorder = ExecutorRecorder()
        let orchestrator = Self.orchestrator(
            recorder: recorder,
            dohResults: [DNSTransportResponse(response: nil, outcome: .receiveFailed)]
        )

        let result = resolveUpstreamSync(
            orchestrator,
            plan: Self.dohPlan(endpointHosts: ["one.example"], shouldFallbackToDeviceDNS: true)
        )

        XCTAssertEqual(recorder.deviceCallCount, 1)
        XCTAssertEqual(recorder.lastDeviceAddresses, ["192.168.1.1"])
        XCTAssertEqual(result?.response, ExecutorRecorder.deviceResponse)
        XCTAssertEqual(result?.transport, .deviceDNS)
        XCTAssertEqual(result?.deviceDNSFallbackAttempted, true)
        XCTAssertEqual(result?.deviceDNSFallbackSucceeded, true)
        XCTAssertEqual(result?.attempts.map(\.outcome), [.receiveFailed, .success])
    }

    func testNoDeviceFallbackWhenPlanDisallowsIt() {
        let recorder = ExecutorRecorder()
        let orchestrator = Self.orchestrator(
            recorder: recorder,
            dohResults: [DNSTransportResponse(response: nil, outcome: .receiveFailed)]
        )

        let result = resolveUpstreamSync(
            orchestrator,
            plan: Self.dohPlan(endpointHosts: ["one.example"], shouldFallbackToDeviceDNS: false)
        )

        XCTAssertEqual(recorder.deviceCallCount, 0)
        XCTAssertNil(result?.response)
        XCTAssertEqual(result?.deviceDNSFallbackAttempted, false)
    }

    func testNoDeviceFallbackWhenPrimarySucceeds() {
        let recorder = ExecutorRecorder()
        let orchestrator = Self.orchestrator(
            recorder: recorder,
            dohResults: [DNSTransportResponse(response: Data([0x04]), outcome: .success)]
        )

        let result = resolveUpstreamSync(
            orchestrator,
            plan: Self.dohPlan(endpointHosts: ["one.example"], shouldFallbackToDeviceDNS: true)
        )

        XCTAssertEqual(recorder.deviceCallCount, 0)
        XCTAssertEqual(result?.response, Data([0x04]))
    }

    func testIsolatedConnectionFlagReachesDoTAndDoQExecutors() {
        let recorder = ExecutorRecorder()
        recorder.dotResults = [DNSTransportResponse(response: Data([0x05]), outcome: .success)]
        recorder.doqResults = [DNSTransportResponse(response: Data([0x06]), outcome: .success)]
        let orchestrator = Self.orchestrator(recorder: recorder)

        _ = resolveUpstreamSync(
            orchestrator,
            plan: Self.dotPlan(hostnames: ["dot.example"]),
            usesIsolatedEncryptedConnections: true
        )
        _ = resolveUpstreamSync(
            orchestrator,
            plan: Self.doqPlan(hostnames: ["doq.example"]),
            usesIsolatedEncryptedConnections: true
        )

        XCTAssertEqual(recorder.lastDoTIsolated, true)
        XCTAssertEqual(recorder.lastDoQIsolated, true)

        recorder.dotResults = [DNSTransportResponse(response: Data([0x05]), outcome: .success)]
        _ = resolveUpstreamSync(orchestrator, plan: Self.dotPlan(hostnames: ["dot.example"]))
        XCTAssertEqual(recorder.lastDoTIsolated, false)
    }

    func testPlainAndDeviceTransportsRouteDirectly() {
        let recorder = ExecutorRecorder()
        let orchestrator = Self.orchestrator(recorder: recorder)

        let plainResult = resolveUpstreamSync(orchestrator, plan: Self.plainPlan())
        XCTAssertEqual(recorder.plainCallCount, 1)
        XCTAssertEqual(plainResult?.response, ExecutorRecorder.plainResponse)

        let devicePlan = DNSResolverRuntimePlan(
            transport: .deviceDNS,
            plainAddresses: ["10.0.0.1"],
            dohEndpoints: [],
            dotEndpoints: [],
            doqEndpoints: [],
            cacheIdentifier: "device",
            deviceDNSFallbackAddresses: [],
            shouldFallbackToDeviceDNS: false,
            usesDeviceDNSFallbackMode: false
        )
        let deviceResult = resolveUpstreamSync(orchestrator, plan: devicePlan)
        XCTAssertEqual(recorder.deviceCallCount, 1)
        XCTAssertEqual(recorder.lastDeviceAddresses, ["10.0.0.1"])
        XCTAssertEqual(deviceResult?.response, ExecutorRecorder.deviceResponse)
    }

    // MARK: - Fixtures

    private func resolveUpstreamSync(
        _ orchestrator: ResolverOrchestrator,
        plan: DNSResolverRuntimePlan,
        usesIsolatedEncryptedConnections: Bool = false
    ) -> DNSResolutionResult? {
        let box = ResultBox()
        orchestrator.resolveUpstream(
            query,
            plan: plan,
            usesIsolatedEncryptedConnections: usesIsolatedEncryptedConnections
        ) { result in
            box.store(result)
        }
        // Fake executors complete synchronously, so the result is already set.
        return box.value
    }

    private static func orchestrator(
        recorder: ExecutorRecorder,
        dohResults: [DNSTransportResponse] = []
    ) -> ResolverOrchestrator {
        recorder.dohResults = dohResults
        return ResolverOrchestrator(executors: ResolverOrchestrator.Executors(
            isEndpointBackedOff: { address in
                recorder.isBackedOff(address)
            },
            resolveDoH: { _, _, completion in
                completion(recorder.nextDoHResult())
            },
            resolveDoT: { _, _, isolated, completion in
                recorder.recordDoT(isolated: isolated)
                completion(recorder.nextDoTResult())
            },
            resolveDoQ: { _, _, isolated, completion in
                recorder.recordDoQ(isolated: isolated)
                completion(recorder.nextDoQResult())
            },
            resolvePlain: { _, addresses, transport in
                recorder.recordPlain(addresses: addresses, transport: transport)
                return DNSResolutionResult(
                    response: ExecutorRecorder.plainResponse,
                    successfulResolverAddress: addresses.first,
                    attempts: [ResolverAttempt(address: addresses.first ?? "none", outcome: .success, transport: transport)],
                    transport: transport,
                    udpTruncated: false,
                    tcpFallbackAttempted: false,
                    tcpFallbackSucceeded: false
                )
            },
            resolveDevice: { _, addresses in
                recorder.recordDevice(addresses: addresses)
                return DNSResolutionResult(
                    response: ExecutorRecorder.deviceResponse,
                    successfulResolverAddress: addresses.first,
                    attempts: [ResolverAttempt(address: addresses.first ?? "none", outcome: .success, transport: .deviceDNS)],
                    transport: .deviceDNS,
                    udpTruncated: false,
                    tcpFallbackAttempted: false,
                    tcpFallbackSucceeded: false
                )
            }
        ))
    }

    private static func dohPlan(
        endpointHosts: [String],
        shouldFallbackToDeviceDNS: Bool = false
    ) -> DNSResolverRuntimePlan {
        DNSResolverRuntimePlan(
            transport: .dnsOverHTTPS,
            plainAddresses: ["9.9.9.9"],
            dohEndpoints: endpointHosts.map { host in
                DNSOverHTTPSEndpoint(
                    url: URL(string: "https://\(host)/dns-query")!,
                    bootstrapIPv4Servers: [],
                    bootstrapIPv6Servers: []
                )
            },
            dotEndpoints: [],
            doqEndpoints: [],
            cacheIdentifier: "doh-test",
            deviceDNSFallbackAddresses: ["192.168.1.1"],
            shouldFallbackToDeviceDNS: shouldFallbackToDeviceDNS,
            usesDeviceDNSFallbackMode: false
        )
    }

    private static func dotPlan(hostnames: [String]) -> DNSResolverRuntimePlan {
        DNSResolverRuntimePlan(
            transport: .dnsOverTLS,
            plainAddresses: ["9.9.9.9"],
            dohEndpoints: [],
            dotEndpoints: hostnames.map { hostname in
                DNSOverTLSEndpoint(
                    hostname: hostname,
                    port: 853,
                    bootstrapIPv4Servers: [],
                    bootstrapIPv6Servers: []
                )
            },
            doqEndpoints: [],
            cacheIdentifier: "dot-test",
            deviceDNSFallbackAddresses: [],
            shouldFallbackToDeviceDNS: false,
            usesDeviceDNSFallbackMode: false
        )
    }

    private static func doqPlan(hostnames: [String]) -> DNSResolverRuntimePlan {
        DNSResolverRuntimePlan(
            transport: .dnsOverQUIC,
            plainAddresses: ["9.9.9.9"],
            dohEndpoints: [],
            dotEndpoints: [],
            doqEndpoints: hostnames.map { hostname in
                DNSOverQUICEndpoint(
                    hostname: hostname,
                    port: 853,
                    bootstrapIPv4Servers: [],
                    bootstrapIPv6Servers: []
                )
            },
            cacheIdentifier: "doq-test",
            deviceDNSFallbackAddresses: [],
            shouldFallbackToDeviceDNS: false,
            usesDeviceDNSFallbackMode: false
        )
    }

    private static func plainPlan() -> DNSResolverRuntimePlan {
        DNSResolverRuntimePlan(
            transport: .plainDNS,
            plainAddresses: ["9.9.9.9"],
            dohEndpoints: [],
            dotEndpoints: [],
            doqEndpoints: [],
            cacheIdentifier: "plain-test",
            deviceDNSFallbackAddresses: [],
            shouldFallbackToDeviceDNS: false,
            usesDeviceDNSFallbackMode: false
        )
    }
}

private final class ResultBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: DNSResolutionResult?

    var value: DNSResolutionResult? {
        lock.lock()
        defer {
            lock.unlock()
        }
        return stored
    }

    func store(_ result: DNSResolutionResult) {
        lock.lock()
        stored = result
        lock.unlock()
    }
}

private final class ExecutorRecorder: @unchecked Sendable {
    static let plainResponse = Data([0xAA])
    static let deviceResponse = Data([0xBB])

    private let lock = NSLock()

    var backedOffAddresses: Set<String> = []
    var dohResults: [DNSTransportResponse] = []
    var dotResults: [DNSTransportResponse] = []
    var doqResults: [DNSTransportResponse] = []

    private(set) var dohCallCount = 0
    private(set) var plainCallCount = 0
    private(set) var deviceCallCount = 0
    private(set) var lastPlainAddresses: [String]?
    private(set) var lastPlainTransport: DNSResolverTransport?
    private(set) var lastDeviceAddresses: [String]?
    private(set) var lastDoTIsolated: Bool?
    private(set) var lastDoQIsolated: Bool?

    func isBackedOff(_ address: String) -> Bool {
        lock.lock()
        defer {
            lock.unlock()
        }
        return backedOffAddresses.contains(address)
    }

    func nextDoHResult() -> DNSTransportResponse {
        lock.lock()
        defer {
            lock.unlock()
        }
        dohCallCount += 1
        return dohResults.isEmpty
            ? DNSTransportResponse(response: nil, outcome: .receiveFailed)
            : dohResults.removeFirst()
    }

    func nextDoTResult() -> DNSTransportResponse {
        lock.lock()
        defer {
            lock.unlock()
        }
        return dotResults.isEmpty
            ? DNSTransportResponse(response: nil, outcome: .receiveFailed)
            : dotResults.removeFirst()
    }

    func nextDoQResult() -> DNSTransportResponse {
        lock.lock()
        defer {
            lock.unlock()
        }
        return doqResults.isEmpty
            ? DNSTransportResponse(response: nil, outcome: .receiveFailed)
            : doqResults.removeFirst()
    }

    func recordDoT(isolated: Bool) {
        lock.lock()
        lastDoTIsolated = isolated
        lock.unlock()
    }

    func recordDoQ(isolated: Bool) {
        lock.lock()
        lastDoQIsolated = isolated
        lock.unlock()
    }

    func recordPlain(addresses: [String], transport: DNSResolverTransport) {
        lock.lock()
        plainCallCount += 1
        lastPlainAddresses = addresses
        lastPlainTransport = transport
        lock.unlock()
    }

    func recordDevice(addresses: [String]) {
        lock.lock()
        deviceCallCount += 1
        lastDeviceAddresses = addresses
        lock.unlock()
    }
}
