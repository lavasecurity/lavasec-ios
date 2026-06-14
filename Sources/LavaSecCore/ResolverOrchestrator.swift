import Foundation

// Upstream resolution orchestration, extracted from PacketTunnelProvider:
// transport routing, degradation to plain DNS when an encrypted plan has no
// endpoints, per-endpoint failover with backoff gates, attempt assembly, and
// device-DNS fallback sequencing. Wire-level execution stays behind injected
// executors so the policy is testable with fakes; backoff STATE also stays
// with the caller — the orchestrator only consults the injected gate.

public enum ResolverAttemptOutcome: String, Sendable {
    case success
    case timeout
    case httpStatusFailure = "http-status-failure"
    case backedOff = "backed-off"
    case sendFailed = "send-failed"
    case receiveFailed = "receive-failed"
    case invalidAddress = "invalid-address"
    case unsupported
    case socketUnavailable = "socket-unavailable"
    case mismatchedResponse = "mismatched-response"
    case deviceDNSUnavailable = "device-dns-unavailable"

    public init(_ outcome: DNSTransportOutcome) {
        switch outcome {
        case .success:
            self = .success
        case .timeout:
            self = .timeout
        case .httpStatusFailure:
            self = .httpStatusFailure
        case .sendFailed:
            self = .sendFailed
        case .receiveFailed:
            self = .receiveFailed
        case .mismatchedResponse:
            self = .mismatchedResponse
        }
    }
}

public struct ResolverAttempt: Sendable {
    public let address: String
    public let outcome: ResolverAttemptOutcome
    public var transport: DNSResolverTransport
    public var usedTCP: Bool
    public var negotiatedDoHProtocol: String?

    public init(
        address: String,
        outcome: ResolverAttemptOutcome,
        transport: DNSResolverTransport = .plainDNS,
        usedTCP: Bool = false,
        negotiatedDoHProtocol: String? = nil
    ) {
        self.address = address
        self.outcome = outcome
        self.transport = transport
        self.usedTCP = usedTCP
        self.negotiatedDoHProtocol = negotiatedDoHProtocol
    }
}

public struct DNSResolutionResult: Sendable {
    public let response: Data?
    public let successfulResolverAddress: String?
    public let attempts: [ResolverAttempt]
    public let transport: DNSResolverTransport
    public let udpTruncated: Bool
    public let tcpFallbackAttempted: Bool
    public let tcpFallbackSucceeded: Bool
    public var deviceDNSFallbackAttempted: Bool
    public var deviceDNSFallbackSucceeded: Bool
    public var deviceDNSUnavailable: Bool
    public var durationMilliseconds: Int?

    public init(
        response: Data?,
        successfulResolverAddress: String?,
        attempts: [ResolverAttempt],
        transport: DNSResolverTransport,
        udpTruncated: Bool,
        tcpFallbackAttempted: Bool,
        tcpFallbackSucceeded: Bool,
        deviceDNSFallbackAttempted: Bool = false,
        deviceDNSFallbackSucceeded: Bool = false,
        deviceDNSUnavailable: Bool = false,
        durationMilliseconds: Int? = nil
    ) {
        self.response = response
        self.successfulResolverAddress = successfulResolverAddress
        self.attempts = attempts
        self.transport = transport
        self.udpTruncated = udpTruncated
        self.tcpFallbackAttempted = tcpFallbackAttempted
        self.tcpFallbackSucceeded = tcpFallbackSucceeded
        self.deviceDNSFallbackAttempted = deviceDNSFallbackAttempted
        self.deviceDNSFallbackSucceeded = deviceDNSFallbackSucceeded
        self.deviceDNSUnavailable = deviceDNSUnavailable
        self.durationMilliseconds = durationMilliseconds
    }

    public var failureSummary: String? {
        attempts.last?.outcome.rawValue
    }

    public var negotiatedDoHProtocol: String? {
        attempts.last { attempt in
            attempt.outcome == .success && attempt.transport == .dnsOverHTTPS
        }?.negotiatedDoHProtocol
    }

    public var hasFallbackActivationEvidence: Bool {
        attempts.contains { attempt in
            attempt.transport != .deviceDNS && attempt.outcome != .backedOff
        }
    }

    public func withAttempts(_ newAttempts: [ResolverAttempt]) -> DNSResolutionResult {
        DNSResolutionResult(
            response: response,
            successfulResolverAddress: successfulResolverAddress,
            attempts: newAttempts,
            transport: transport,
            udpTruncated: udpTruncated,
            tcpFallbackAttempted: tcpFallbackAttempted,
            tcpFallbackSucceeded: tcpFallbackSucceeded,
            deviceDNSFallbackAttempted: deviceDNSFallbackAttempted,
            deviceDNSFallbackSucceeded: deviceDNSFallbackSucceeded,
            deviceDNSUnavailable: deviceDNSUnavailable,
            durationMilliseconds: durationMilliseconds
        )
    }

    public func withDeviceDNSFallback(_ fallbackResult: DNSResolutionResult) -> DNSResolutionResult {
        DNSResolutionResult(
            response: fallbackResult.response,
            successfulResolverAddress: fallbackResult.successfulResolverAddress,
            attempts: attempts + fallbackResult.attempts,
            transport: fallbackResult.response == nil ? transport : .deviceDNS,
            udpTruncated: udpTruncated || fallbackResult.udpTruncated,
            tcpFallbackAttempted: tcpFallbackAttempted || fallbackResult.tcpFallbackAttempted,
            tcpFallbackSucceeded: tcpFallbackSucceeded || fallbackResult.tcpFallbackSucceeded,
            deviceDNSFallbackAttempted: true,
            deviceDNSFallbackSucceeded: fallbackResult.response != nil,
            deviceDNSUnavailable: fallbackResult.deviceDNSUnavailable,
            durationMilliseconds: durationMilliseconds
        )
    }

    public func recordingDuration(since startedAt: Date, now: Date = Date()) -> DNSResolutionResult {
        let elapsedMilliseconds = max(0, Int((now.timeIntervalSince(startedAt) * 1_000).rounded()))
        return DNSResolutionResult(
            response: response,
            successfulResolverAddress: successfulResolverAddress,
            attempts: attempts,
            transport: transport,
            udpTruncated: udpTruncated,
            tcpFallbackAttempted: tcpFallbackAttempted,
            tcpFallbackSucceeded: tcpFallbackSucceeded,
            deviceDNSFallbackAttempted: deviceDNSFallbackAttempted,
            deviceDNSFallbackSucceeded: deviceDNSFallbackSucceeded,
            deviceDNSUnavailable: deviceDNSUnavailable,
            durationMilliseconds: elapsedMilliseconds
        )
    }
}

public struct ResolverOrchestrator: Sendable {
    public struct Executors: Sendable {
        public var isEndpointBackedOff: @Sendable (String) -> Bool
        public var resolveDoH: @Sendable (Data, DNSOverHTTPSEndpoint, @escaping @Sendable (DNSTransportResponse) -> Void) -> Void
        public var resolveDoT: @Sendable (Data, DNSOverTLSEndpoint, Bool, @escaping @Sendable (DNSTransportResponse) -> Void) -> Void
        public var resolveDoQ: @Sendable (Data, DNSOverQUICEndpoint, Bool, @escaping @Sendable (DNSTransportResponse) -> Void) -> Void
        public var resolvePlain: @Sendable (Data, [String], DNSResolverTransport) -> DNSResolutionResult
        public var resolveDevice: @Sendable (Data, [String]) -> DNSResolutionResult

        public init(
            isEndpointBackedOff: @escaping @Sendable (String) -> Bool,
            resolveDoH: @escaping @Sendable (Data, DNSOverHTTPSEndpoint, @escaping @Sendable (DNSTransportResponse) -> Void) -> Void,
            resolveDoT: @escaping @Sendable (Data, DNSOverTLSEndpoint, Bool, @escaping @Sendable (DNSTransportResponse) -> Void) -> Void,
            resolveDoQ: @escaping @Sendable (Data, DNSOverQUICEndpoint, Bool, @escaping @Sendable (DNSTransportResponse) -> Void) -> Void,
            resolvePlain: @escaping @Sendable (Data, [String], DNSResolverTransport) -> DNSResolutionResult,
            resolveDevice: @escaping @Sendable (Data, [String]) -> DNSResolutionResult
        ) {
            self.isEndpointBackedOff = isEndpointBackedOff
            self.resolveDoH = resolveDoH
            self.resolveDoT = resolveDoT
            self.resolveDoQ = resolveDoQ
            self.resolvePlain = resolvePlain
            self.resolveDevice = resolveDevice
        }
    }

    private let executors: Executors

    public init(executors: Executors) {
        self.executors = executors
    }

    // Primary resolution then device-DNS fallback, mirroring the tunnel's
    // long-standing sequencing: fallback runs only when the primary produced
    // no response and the plan allows it.
    public func resolveUpstream(
        _ query: Data,
        plan: DNSResolverRuntimePlan,
        usesIsolatedEncryptedConnections: Bool = false,
        completion: @escaping @Sendable (DNSResolutionResult) -> Void
    ) {
        let executors = executors
        resolvePrimaryUpstream(
            query,
            plan: plan,
            usesIsolatedEncryptedConnections: usesIsolatedEncryptedConnections
        ) { primaryResult in
            guard primaryResult.response == nil,
                  plan.shouldFallbackToDeviceDNS
            else {
                completion(primaryResult)
                return
            }

            let fallbackResult = executors.resolveDevice(query, plan.deviceDNSFallbackAddresses)
            completion(primaryResult.withDeviceDNSFallback(fallbackResult))
        }
    }

    public func resolvePrimaryUpstream(
        _ query: Data,
        plan: DNSResolverRuntimePlan,
        usesIsolatedEncryptedConnections: Bool = false,
        completion: @escaping @Sendable (DNSResolutionResult) -> Void
    ) {
        switch plan.transport {
        case .dnsOverHTTPS:
            guard !plan.dohEndpoints.isEmpty else {
                completion(executors.resolvePlain(query, plan.plainAddresses, .plainDNS))
                return
            }

            resolveEndpoints(
                query,
                endpoints: plan.dohEndpoints,
                transport: .dnsOverHTTPS,
                index: plan.dohEndpoints.startIndex,
                previousAttempts: [],
                resolveEndpoint: { query, endpoint, completion in
                    executors.resolveDoH(query, endpoint, completion)
                },
                cacheIdentifier: { $0.cacheIdentifier },
                completion: completion
            )

        case .dnsOverTLS:
            guard !plan.dotEndpoints.isEmpty else {
                completion(executors.resolvePlain(query, plan.plainAddresses, .plainDNS))
                return
            }

            resolveEndpoints(
                query,
                endpoints: plan.dotEndpoints,
                transport: .dnsOverTLS,
                index: plan.dotEndpoints.startIndex,
                previousAttempts: [],
                resolveEndpoint: { query, endpoint, completion in
                    executors.resolveDoT(query, endpoint, usesIsolatedEncryptedConnections, completion)
                },
                cacheIdentifier: { $0.cacheIdentifier },
                completion: completion
            )

        case .dnsOverQUIC:
            guard !plan.doqEndpoints.isEmpty else {
                completion(executors.resolvePlain(query, plan.plainAddresses, .plainDNS))
                return
            }

            resolveEndpoints(
                query,
                endpoints: plan.doqEndpoints,
                transport: .dnsOverQUIC,
                index: plan.doqEndpoints.startIndex,
                previousAttempts: [],
                resolveEndpoint: { query, endpoint, completion in
                    executors.resolveDoQ(query, endpoint, usesIsolatedEncryptedConnections, completion)
                },
                cacheIdentifier: { $0.cacheIdentifier },
                completion: completion
            )

        case .plainDNS:
            completion(executors.resolvePlain(query, plan.plainAddresses, .plainDNS))

        case .deviceDNS:
            completion(executors.resolveDevice(query, plan.plainAddresses))
        }
    }

    // Endpoint failover: each endpoint gets one shot (the transports handle
    // their own bootstrap/retry internally); a backed-off endpoint records an
    // attempt without touching the wire, and the next endpoint is tried until
    // one responds or the list is exhausted.
    private func resolveEndpoints<Endpoint: Sendable>(
        _ query: Data,
        endpoints: [Endpoint],
        transport: DNSResolverTransport,
        index: Array<Endpoint>.Index,
        previousAttempts: [ResolverAttempt],
        resolveEndpoint: @escaping @Sendable (Data, Endpoint, @escaping @Sendable (DNSTransportResponse) -> Void) -> Void,
        cacheIdentifier: @escaping @Sendable (Endpoint) -> String,
        completion: @escaping @Sendable (DNSResolutionResult) -> Void
    ) {
        guard endpoints.indices.contains(index) else {
            completion(DNSResolutionResult(
                response: nil,
                successfulResolverAddress: nil,
                attempts: previousAttempts,
                transport: transport,
                udpTruncated: false,
                tcpFallbackAttempted: false,
                tcpFallbackSucceeded: false
            ))
            return
        }

        let endpoint = endpoints[index]
        let resolverAddress = cacheIdentifier(endpoint)

        let continueOrFinish: @Sendable (DNSResolutionResult) -> Void = { result in
            guard result.response == nil, index < endpoints.index(before: endpoints.endIndex) else {
                completion(result)
                return
            }

            self.resolveEndpoints(
                query,
                endpoints: endpoints,
                transport: transport,
                index: endpoints.index(after: index),
                previousAttempts: result.attempts,
                resolveEndpoint: resolveEndpoint,
                cacheIdentifier: cacheIdentifier,
                completion: completion
            )
        }

        guard !executors.isEndpointBackedOff(resolverAddress) else {
            continueOrFinish(DNSResolutionResult(
                response: nil,
                successfulResolverAddress: nil,
                attempts: previousAttempts + [
                    ResolverAttempt(
                        address: resolverAddress,
                        outcome: .backedOff,
                        transport: transport
                    )
                ],
                transport: transport,
                udpTruncated: false,
                tcpFallbackAttempted: false,
                tcpFallbackSucceeded: false
            ))
            return
        }

        resolveEndpoint(query, endpoint) { upstreamResponse in
            let attempt = ResolverAttempt(
                address: resolverAddress,
                outcome: ResolverAttemptOutcome(upstreamResponse.outcome),
                transport: transport,
                negotiatedDoHProtocol: upstreamResponse.negotiatedHTTPProtocolName
            )

            continueOrFinish(DNSResolutionResult(
                response: upstreamResponse.response,
                successfulResolverAddress: upstreamResponse.response == nil ? nil : resolverAddress,
                attempts: previousAttempts + [attempt],
                transport: transport,
                udpTruncated: false,
                tcpFallbackAttempted: false,
                tcpFallbackSucceeded: false
            ))
        }
    }
}
