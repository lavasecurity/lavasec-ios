import Foundation
import LavaSecKit

// Upstream resolution orchestration, extracted from PacketTunnelProvider:
// transport routing, degradation to plain DNS when an encrypted plan has no
// endpoints, per-endpoint failover with backoff gates, attempt assembly, and
// device-DNS fallback sequencing. Wire-level execution stays behind injected
// executors so the policy is testable with fakes; backoff STATE also stays
// with the caller — the orchestrator only consults the injected gate.

/// Stable per-attempt classification used by retry policy, health scoring, and cross-process diagnostics.
public enum ResolverAttemptOutcome: String, Sendable {
    /// The transport completed with a response matching the query identity.
    case success
    /// The attempt exceeded its configured time budget.
    case timeout
    /// A DoH endpoint responded with a non-success HTTP status.
    case httpStatusFailure = "http-status-failure"
    /// Backoff policy suppressed the endpoint without a wire attempt.
    case backedOff = "backed-off"
    /// The query could not be sent to the selected endpoint.
    case sendFailed = "send-failed"
    /// The endpoint produced no readable or valid response.
    case receiveFailed = "receive-failed"
    /// A configured plain-DNS address was not a valid numeric endpoint.
    case invalidAddress = "invalid-address"
    /// The requested resolver transport is unavailable on this runtime path.
    case unsupported
    /// A UDP or TCP resolver socket could not be created or configured.
    case socketUnavailable = "socket-unavailable"
    /// A response arrived for a different DNS transaction or question.
    case mismatchedResponse = "mismatched-response"
    /// Device DNS was selected but no captured resolver address was available.
    case deviceDNSUnavailable = "device-dns-unavailable"

    internal init(_ outcome: DNSTransportOutcome) {
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

/// One ordered resolver attempt, including the endpoint label and transport metadata exposed in tunnel diagnostics.
public struct ResolverAttempt: Sendable {
    /// Resolver endpoint identifier or address recorded for this attempt.
    public let address: String
    /// Classified result consumed by fallback and backoff policy.
    public let outcome: ResolverAttemptOutcome
    /// Effective transport used for this attempt; public clients receive read-only access after construction.
    public private(set) var transport: DNSResolverTransport
    internal var usedTCP: Bool
    /// Negotiated HTTP protocol observed for a DoH attempt, including failed outcomes when metrics were available.
    public private(set) var negotiatedDoHProtocol: String?

    /// Records one attempt; `usedTCP` is retained only for DNS-internal assembly compatibility.
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

/// Aggregate result of primary and optional fallback resolution, with attempts retained in execution order.
public struct DNSResolutionResult: Sendable {
    /// DNS response bytes selected for the caller; a failed encrypted fallback may replace a primary packet with `nil`.
    public let response: Data?
    /// Resolver identifier retained during combination; it may remain non-`nil`
    /// when an encrypted fallback leaves `response` nil.
    public let successfulResolverAddress: String?
    /// Every attempted or backoff-suppressed endpoint in execution order.
    public let attempts: [ResolverAttempt]
    /// Transport associated with the final selected result.
    public let transport: DNSResolverTransport
    /// Whether a UDP reply carried the DNS truncated bit and required TCP consideration.
    public let udpTruncated: Bool
    /// Whether plain-DNS resolution attempted TCP after UDP truncation.
    public let tcpFallbackAttempted: Bool
    /// Whether the TCP fallback produced the selected response.
    public let tcpFallbackSucceeded: Bool
    /// Whether the resolver sequence reached the captured Device-DNS fallback route.
    public private(set) var deviceDNSFallbackAttempted: Bool
    /// Whether Device-DNS fallback produced the selected response.
    public private(set) var deviceDNSFallbackSucceeded: Bool
    /// Whether Device DNS could not run because no captured resolver was available.
    public private(set) var deviceDNSUnavailable: Bool
    // Set when the encrypted (Mullvad DoH) fallback produced this response because
    // a Device-DNS primary was wedged. Observable so the provider can log/diagnose
    // that the fallback engaged; distinct from the device-DNS-fallback flags.
    /// Whether an encrypted fallback, rather than the Device-DNS primary, produced the selected response.
    public private(set) var usedEncryptedFallback: Bool
    /// End-to-end resolver duration in rounded milliseconds, or `nil` until timing is recorded.
    public private(set) var durationMilliseconds: Int?

    /// Creates a complete result whose fallback and timing fields are read-only to public clients after construction.
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
        usedEncryptedFallback: Bool = false,
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
        self.usedEncryptedFallback = usedEncryptedFallback
        self.durationMilliseconds = durationMilliseconds
    }

    /// Diagnostic raw value of the final attempt outcome, or `nil` when no attempt was recorded.
    public var failureSummary: String? {
        attempts.last?.outcome.rawValue
    }

    /// Protocol name from the last successful DoH attempt, excluding failed or non-DoH attempts.
    public var negotiatedDoHProtocol: String? {
        attempts.last { attempt in
            attempt.outcome == .success && attempt.transport == .dnsOverHTTPS
        }?.negotiatedDoHProtocol
    }

    /// Whether any non-Device-DNS endpoint was actually attempted instead of merely suppressed by backoff.
    public var hasFallbackActivationEvidence: Bool {
        attempts.contains { attempt in
            attempt.transport != .deviceDNS && attempt.outcome != .backedOff
        }
    }

    internal func withAttempts(_ newAttempts: [ResolverAttempt]) -> DNSResolutionResult {
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
            usedEncryptedFallback: usedEncryptedFallback,
            durationMilliseconds: durationMilliseconds
        )
    }

    /// Combine a primary result with an *encrypted* fallback (Device-DNS primary →
    /// Mullvad DoH). Unlike withDeviceDNSFallback this does NOT set the
    /// deviceDNSFallback flags — the encrypted fallback is a per-query safety net,
    /// not the device-DNS-fallback *mode* — so on success the result just looks
    /// like a normal resolution on the fallback's (DoH) transport.
    internal func withEncryptedFallback(_ fallbackResult: DNSResolutionResult) -> DNSResolutionResult {
        DNSResolutionResult(
            response: fallbackResult.response,
            successfulResolverAddress: fallbackResult.response == nil
                ? successfulResolverAddress
                : fallbackResult.successfulResolverAddress,
            attempts: attempts + fallbackResult.attempts,
            transport: fallbackResult.response == nil ? transport : fallbackResult.transport,
            udpTruncated: udpTruncated,
            tcpFallbackAttempted: tcpFallbackAttempted,
            tcpFallbackSucceeded: tcpFallbackSucceeded,
            deviceDNSFallbackAttempted: deviceDNSFallbackAttempted,
            deviceDNSFallbackSucceeded: deviceDNSFallbackSucceeded,
            deviceDNSUnavailable: deviceDNSUnavailable,
            usedEncryptedFallback: usedEncryptedFallback || fallbackResult.response != nil,
            durationMilliseconds: durationMilliseconds
        )
    }

    internal func withDeviceDNSFallback(_ fallbackResult: DNSResolutionResult) -> DNSResolutionResult {
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
            usedEncryptedFallback: usedEncryptedFallback,
            durationMilliseconds: durationMilliseconds
        )
    }

    /// Returns a copy whose nonnegative elapsed duration is rounded to whole milliseconds.
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
            usedEncryptedFallback: usedEncryptedFallback,
            durationMilliseconds: elapsedMilliseconds
        )
    }
}

/// Applies resolver routing, endpoint failover, and one permitted fallback while delegating all wire I/O.
public struct ResolverOrchestrator: Sendable {
    /// Sendable wire-execution boundary supplied by the packet tunnel for each supported resolver transport.
    public struct Executors: Sendable {
        internal var isEndpointBackedOff: @Sendable (String) -> Bool
        internal var resolveDoH: @Sendable (Data, DNSOverHTTPSEndpoint, @escaping @Sendable (DNSTransportResponse) -> Void) -> Void
        internal var resolveDoT: @Sendable (Data, DNSOverTLSEndpoint, Bool, @escaping @Sendable (DNSTransportResponse) -> Void) -> Void
        internal var resolveDoQ: @Sendable (Data, DNSOverQUICEndpoint, Bool, @escaping @Sendable (DNSTransportResponse) -> Void) -> Void
        internal var resolvePlain: @Sendable (Data, [String], DNSResolverTransport) -> DNSResolutionResult
        internal var resolveDevice: @Sendable (Data, [String]) -> DNSResolutionResult

        /// Captures the backoff gate and transport executors without transferring ownership of their underlying clients.
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

    /// Creates an orchestrator backed by caller-owned transport executors and endpoint backoff state.
    public init(executors: Executors) {
        self.executors = executors
    }

    // Primary resolution then a single fallback, run only when the primary
    // produced no response and the plan allows it. The fallback direction depends
    // on the primary: an encrypted primary falls back to Device DNS
    // (shouldFallbackToDeviceDNS); a Device-DNS primary falls back to an encrypted
    // resolver (shouldFallbackToEncrypted, Mullvad DoH). The two are mutually
    // exclusive.
    /// Resolves the primary route and, only when policy permits, performs a single device or encrypted fallback.
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
            let hasResponse = primaryResult.response != nil

            if plan.shouldFallbackToDeviceDNS {
                // Encrypted primary → Device DNS, but ONLY when there was no response
                // at all. A resolver-declared SERVFAIL/REFUSED (e.g. a DNSSEC
                // validation or policy failure from a configured encrypted resolver)
                // is an authoritative verdict; silently retrying it on the
                // less-filtered Device DNS would change/leak the answer, so the
                // device-fallback contract stays "no response only".
                guard !hasResponse else {
                    completion(primaryResult)
                    return
                }
                let fallbackResult = executors.resolveDevice(query, plan.deviceDNSFallbackAddresses)
                completion(primaryResult.withDeviceDNSFallback(fallbackResult))
            } else if plan.shouldFallbackToEncrypted, let fallbackPlan = plan.encryptedFallback?.plan {
                // Device-DNS primary → encrypted fallback resolved through the
                // user-selected fallback resolver and its transport. The primary
                // produced no usable answer when it returned nothing, OR returned a
                // server-side failure (SERVFAIL/REFUSED) *while the resolver is already
                // health-confirmed as broadly wedged*. The latter is the stale
                // off-network resolver case (a reachable-but-stale Device-DNS address
                // refuses every query) — a bare `response == nil` guard would hand that
                // failing reply back. But a refusal on an otherwise-healthy resolver is
                // an authoritative per-domain verdict (a managed-network block or a
                // DNSSEC failure) and must pass through untouched, so the rejection
                // path is gated on `treatsResolverRejectionAsFallbackTrigger`.
                // NOERROR/NODATA/NXDOMAIN are always legitimate answers.
                let isWedgeRejection = plan.treatsResolverRejectionAsFallbackTrigger
                    && DNSResolverSmokeProbe.indicatesResolverFailure(primaryResult.response)
                let deviceUsable = hasResponse && !isWedgeRejection
                guard !deviceUsable else {
                    completion(primaryResult)
                    return
                }
                // Route the per-query fallback through the selected resolver's transport.
                // resolvePrimaryUpstream/resolveEndpoints already applies the backoff gate
                // for DoH/DoT/DoQ, so the old manual isEndpointBackedOff check is dropped.
                resolvePrimaryUpstream(query, plan: fallbackPlan, usesIsolatedEncryptedConnections: usesIsolatedEncryptedConnections) { fallbackResult in
                    completion(primaryResult.withEncryptedFallback(fallbackResult))
                }
            } else {
                completion(primaryResult)
            }
        }
    }

    /// Executes only the plan's primary route, including ordered endpoint failover but no cross-route fallback.
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
