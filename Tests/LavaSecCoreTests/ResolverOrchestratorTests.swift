import XCTest
@testable import LavaSecCore
@testable import LavaSecKit

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

    func testDeviceDNSPrimaryFallsBackToEncryptedWhenWedged() {
        let dohResponse = Data([0xCC])
        let box = ResultBox()

        let orchestrator = ResolverOrchestrator(executors: ResolverOrchestrator.Executors(
            isEndpointBackedOff: { _ in false },
            resolveDoH: { _, _, completion in
                completion(DNSTransportResponse(response: dohResponse, outcome: .success))
            },
            resolveDoT: { _, _, _, completion in completion(DNSTransportResponse(response: nil, outcome: .receiveFailed)) },
            resolveDoQ: { _, _, _, completion in completion(DNSTransportResponse(response: nil, outcome: .receiveFailed)) },
            resolvePlain: { _, addresses, transport in
                DNSResolutionResult(
                    response: nil,
                    successfulResolverAddress: nil,
                    attempts: [ResolverAttempt(address: addresses.first ?? "none", outcome: .timeout, transport: transport)],
                    transport: transport,
                    udpTruncated: false,
                    tcpFallbackAttempted: false,
                    tcpFallbackSucceeded: false
                )
            },
            resolveDevice: { _, addresses in
                // Primary Device DNS is wedged (no response).
                DNSResolutionResult(
                    response: nil,
                    successfulResolverAddress: nil,
                    attempts: [ResolverAttempt(address: addresses.first ?? "none", outcome: .timeout, transport: .deviceDNS)],
                    transport: .deviceDNS,
                    udpTruncated: false,
                    tcpFallbackAttempted: false,
                    tcpFallbackSucceeded: false
                )
            }
        ))

        let endpoint = DNSResolverRuntimePlan.mullvadEncryptedFallbackEndpoint
        let plan = DNSResolverRuntimePlan(
            transport: .deviceDNS,
            plainAddresses: ["10.0.0.1"],
            dohEndpoints: [],
            dotEndpoints: [],
            doqEndpoints: [],
            cacheIdentifier: "device",
            deviceDNSFallbackAddresses: [],
            shouldFallbackToDeviceDNS: false,
            usesDeviceDNSFallbackMode: false,
            shouldFallbackToEncrypted: true,
            encryptedFallbackEndpoints: [endpoint]
        )

        orchestrator.resolveUpstream(Data([0x01, 0x02]), plan: plan) { box.store($0) }

        // Device primary wedged → encrypted (Mullvad DoH) fallback carries the query.
        // The last recorded attempt is the Mullvad endpoint, proving DoH was hit.
        XCTAssertEqual(box.value?.attempts.last?.address, endpoint.cacheIdentifier)
        XCTAssertEqual(box.value?.attempts.last?.transport, .dnsOverHTTPS)
        XCTAssertEqual(box.value?.response, dohResponse)
        XCTAssertEqual(box.value?.transport, .dnsOverHTTPS)
        // Observable for diagnostics, and preserved through recordingDuration (the
        // provider applies it before recordUpstreamResult reads the flag).
        XCTAssertTrue(box.value?.usedEncryptedFallback ?? false)
        XCTAssertTrue(box.value?.recordingDuration(since: Date()).usedEncryptedFallback ?? false)
        // Encrypted fallback must NOT masquerade as the device-DNS fallback mode.
        XCTAssertFalse(box.value?.deviceDNSFallbackAttempted ?? true)
    }

    func testEncryptedFallbackIsNotUsedWhenDeviceDNSResolves() {
        let recorder = ExecutorRecorder()
        let orchestrator = Self.orchestrator(recorder: recorder)
        let plan = DNSResolverRuntimePlan(
            transport: .deviceDNS,
            plainAddresses: ["10.0.0.1"],
            dohEndpoints: [],
            dotEndpoints: [],
            doqEndpoints: [],
            cacheIdentifier: "device",
            deviceDNSFallbackAddresses: [],
            shouldFallbackToDeviceDNS: false,
            usesDeviceDNSFallbackMode: false,
            shouldFallbackToEncrypted: true,
            encryptedFallbackEndpoints: [DNSResolverRuntimePlan.mullvadEncryptedFallbackEndpoint]
        )

        let result = resolveUpstreamSync(orchestrator, plan: plan)

        // The shared factory's device executor succeeds → no DoH fallback attempted.
        XCTAssertEqual(result?.response, ExecutorRecorder.deviceResponse)
        XCTAssertEqual(recorder.dohCallCount, 0)
        XCTAssertFalse(result?.usedEncryptedFallback ?? true)
    }

    func testEncryptedPrimaryRefusedReplyDoesNotSpillToDeviceDNS() {
        // SERVFAIL/REFUSED from a configured encrypted resolver is an authoritative
        // verdict (DNSSEC validation / policy). The device-DNS fallback contract is
        // "no response only" — retrying such a reply on the less-filtered Device DNS
        // would change/leak the answer, so it must pass straight through.
        let refusedReply = Data([0x12, 0x34, 0x80, 0x02, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00])
        let recorder = ExecutorRecorder()
        let orchestrator = Self.orchestrator(
            recorder: recorder,
            dohResults: [DNSTransportResponse(response: refusedReply, outcome: .success)]
        )

        let result = resolveUpstreamSync(
            orchestrator,
            plan: Self.dohPlan(endpointHosts: ["one.example"], shouldFallbackToDeviceDNS: true)
        )

        XCTAssertEqual(result?.response, refusedReply)
        XCTAssertEqual(result?.transport, .dnsOverHTTPS)
        XCTAssertEqual(recorder.deviceCallCount, 0, "A resolver-declared failure must not be retried on Device DNS.")
        XCTAssertFalse(result?.deviceDNSFallbackAttempted ?? true)
    }

    func testStaleDeviceDNSRefusedReplyTriggersEncryptedFallback() {
        let dohResponse = Data([0xDD])
        let box = ResultBox()

        // A reachable-but-stale Device-DNS resolver answers with REFUSED (rcode 5):
        // a non-nil wire packet with a `.success` attempt outcome. The fallback guard
        // must treat this as a failure, not hand the useless reply back to the client.
        let refusedReply = Data([0x12, 0x34, 0x80, 0x05, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00])

        let orchestrator = ResolverOrchestrator(executors: ResolverOrchestrator.Executors(
            isEndpointBackedOff: { _ in false },
            resolveDoH: { _, _, completion in
                completion(DNSTransportResponse(response: dohResponse, outcome: .success))
            },
            resolveDoT: { _, _, _, completion in completion(DNSTransportResponse(response: nil, outcome: .receiveFailed)) },
            resolveDoQ: { _, _, _, completion in completion(DNSTransportResponse(response: nil, outcome: .receiveFailed)) },
            resolvePlain: { _, addresses, transport in
                DNSResolutionResult(
                    response: nil,
                    successfulResolverAddress: nil,
                    attempts: [ResolverAttempt(address: addresses.first ?? "none", outcome: .timeout, transport: transport)],
                    transport: transport,
                    udpTruncated: false,
                    tcpFallbackAttempted: false,
                    tcpFallbackSucceeded: false
                )
            },
            resolveDevice: { _, addresses in
                // Stale resolver: reachable, returns a REFUSED packet (wire success).
                DNSResolutionResult(
                    response: refusedReply,
                    successfulResolverAddress: addresses.first,
                    attempts: [ResolverAttempt(address: addresses.first ?? "none", outcome: .success, transport: .deviceDNS)],
                    transport: .deviceDNS,
                    udpTruncated: false,
                    tcpFallbackAttempted: false,
                    tcpFallbackSucceeded: false
                )
            }
        ))

        let endpoint = DNSResolverRuntimePlan.mullvadEncryptedFallbackEndpoint
        let plan = DNSResolverRuntimePlan(
            transport: .deviceDNS,
            plainAddresses: ["10.0.0.1"],
            dohEndpoints: [],
            dotEndpoints: [],
            doqEndpoints: [],
            cacheIdentifier: "device",
            deviceDNSFallbackAddresses: [],
            shouldFallbackToDeviceDNS: false,
            usesDeviceDNSFallbackMode: false,
            shouldFallbackToEncrypted: true,
            encryptedFallbackEndpoints: [endpoint],
            // Health has confirmed the resolver is broadly wedged, so a REFUSED reply
            // is treated as wedge evidence rather than an authoritative verdict.
            treatsResolverRejectionAsFallbackTrigger: true
        )

        orchestrator.resolveUpstream(Data([0x12, 0x34, 0x01, 0x00]), plan: plan) { box.store($0) }

        // The REFUSED reply is discarded in favor of the encrypted fallback answer.
        XCTAssertEqual(box.value?.response, dohResponse)
        XCTAssertEqual(box.value?.transport, .dnsOverHTTPS)
        XCTAssertTrue(box.value?.usedEncryptedFallback ?? false)
        XCTAssertEqual(box.value?.attempts.last?.address, endpoint.cacheIdentifier)
    }

    func testHealthyDeviceDNSRefusalIsHonoredNotSentToEncryptedFallback() {
        // A REFUSED reply on a resolver that is NOT health-confirmed as wedged is an
        // authoritative per-domain verdict (a managed-network block / DNSSEC failure).
        // It must pass straight through — not be re-asked on the encrypted fallback,
        // which would bypass the verdict and leak the lookup to Mullvad.
        let refusedReply = Data([0x12, 0x34, 0x80, 0x05, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00])
        let box = ResultBox()

        let orchestrator = ResolverOrchestrator(executors: ResolverOrchestrator.Executors(
            isEndpointBackedOff: { _ in false },
            resolveDoH: { _, _, completion in
                // Must NOT be reached: the refusal is honored, not escalated.
                completion(DNSTransportResponse(response: Data([0xEE]), outcome: .success))
            },
            resolveDoT: { _, _, _, completion in completion(DNSTransportResponse(response: nil, outcome: .receiveFailed)) },
            resolveDoQ: { _, _, _, completion in completion(DNSTransportResponse(response: nil, outcome: .receiveFailed)) },
            resolvePlain: { _, addresses, transport in
                DNSResolutionResult(
                    response: nil,
                    successfulResolverAddress: nil,
                    attempts: [ResolverAttempt(address: addresses.first ?? "none", outcome: .timeout, transport: transport)],
                    transport: transport,
                    udpTruncated: false,
                    tcpFallbackAttempted: false,
                    tcpFallbackSucceeded: false
                )
            },
            resolveDevice: { _, addresses in
                DNSResolutionResult(
                    response: refusedReply,
                    successfulResolverAddress: addresses.first,
                    attempts: [ResolverAttempt(address: addresses.first ?? "none", outcome: .success, transport: .deviceDNS)],
                    transport: .deviceDNS,
                    udpTruncated: false,
                    tcpFallbackAttempted: false,
                    tcpFallbackSucceeded: false
                )
            }
        ))

        let endpoint = DNSResolverRuntimePlan.mullvadEncryptedFallbackEndpoint
        let plan = DNSResolverRuntimePlan(
            transport: .deviceDNS,
            plainAddresses: ["10.0.0.1"],
            dohEndpoints: [],
            dotEndpoints: [],
            doqEndpoints: [],
            cacheIdentifier: "device",
            deviceDNSFallbackAddresses: [],
            shouldFallbackToDeviceDNS: false,
            usesDeviceDNSFallbackMode: false,
            shouldFallbackToEncrypted: true,
            encryptedFallbackEndpoints: [endpoint],
            // Resolver is healthy (not wedged) → refusal is an authoritative verdict.
            treatsResolverRejectionAsFallbackTrigger: false
        )

        orchestrator.resolveUpstream(Data([0x12, 0x34, 0x01, 0x00]), plan: plan) { box.store($0) }

        XCTAssertEqual(box.value?.response, refusedReply)
        XCTAssertEqual(box.value?.transport, .deviceDNS)
        XCTAssertFalse(box.value?.usedEncryptedFallback ?? true)
        XCTAssertNotEqual(box.value?.attempts.last?.address, endpoint.cacheIdentifier)
    }

    func testEncryptedFallbackHonorsEndpointBackoff() {
        let box = ResultBox()
        let endpoint = DNSResolverRuntimePlan.mullvadEncryptedFallbackEndpoint

        let orchestrator = ResolverOrchestrator(executors: ResolverOrchestrator.Executors(
            // The Mullvad endpoint is already backed off (blocked / timing out).
            isEndpointBackedOff: { $0 == endpoint.cacheIdentifier },
            resolveDoH: { _, _, completion in
                // Must NOT be reached while the endpoint is backed off.
                completion(DNSTransportResponse(response: Data([0xEE]), outcome: .success))
            },
            resolveDoT: { _, _, _, completion in completion(DNSTransportResponse(response: nil, outcome: .receiveFailed)) },
            resolveDoQ: { _, _, _, completion in completion(DNSTransportResponse(response: nil, outcome: .receiveFailed)) },
            resolvePlain: { _, addresses, transport in
                DNSResolutionResult(
                    response: nil,
                    successfulResolverAddress: nil,
                    attempts: [ResolverAttempt(address: addresses.first ?? "none", outcome: .timeout, transport: transport)],
                    transport: transport,
                    udpTruncated: false,
                    tcpFallbackAttempted: false,
                    tcpFallbackSucceeded: false
                )
            },
            resolveDevice: { _, addresses in
                DNSResolutionResult(
                    response: nil,
                    successfulResolverAddress: nil,
                    attempts: [ResolverAttempt(address: addresses.first ?? "none", outcome: .timeout, transport: .deviceDNS)],
                    transport: .deviceDNS,
                    udpTruncated: false,
                    tcpFallbackAttempted: false,
                    tcpFallbackSucceeded: false
                )
            }
        ))

        let plan = DNSResolverRuntimePlan(
            transport: .deviceDNS,
            plainAddresses: ["10.0.0.1"],
            dohEndpoints: [],
            dotEndpoints: [],
            doqEndpoints: [],
            cacheIdentifier: "device",
            deviceDNSFallbackAddresses: [],
            shouldFallbackToDeviceDNS: false,
            usesDeviceDNSFallbackMode: false,
            shouldFallbackToEncrypted: true,
            encryptedFallbackEndpoints: [endpoint]
        )

        orchestrator.resolveUpstream(Data([0x01, 0x02]), plan: plan) { box.store($0) }

        // Backed off → the DoH wire is skipped (resolveDoH not called) and the primary
        // (failing) result stands: no response, encrypted-fallback flag clear, and the
        // transport stays deviceDNS (withEncryptedFallback only switches transport on a
        // non-nil response). The backoff gate now lives inside resolveEndpoints, which
        // records a `.backedOff` attempt for the endpoint instead of short-circuiting.
        XCTAssertNil(box.value?.response)
        XCTAssertFalse(box.value?.usedEncryptedFallback ?? true)
        XCTAssertEqual(box.value?.transport, .deviceDNS)
        XCTAssertEqual(box.value?.attempts.last?.outcome, .backedOff)
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
