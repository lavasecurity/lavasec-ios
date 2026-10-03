import XCTest
import LavaSecKit
@testable import LavaSecDNS

/// A resolution may only run under the session that admitted it.
///
/// Quiescing the transports (PRs #522/#523) closes the window between a stop and the next
/// start. It cannot close the case where the next start has ALREADY happened: transport
/// cancellation is asynchronous, so a lane's cancellation can run after the new session
/// re-armed everything, report its failure, and send the endpoint ladder on to the next rung —
/// which is then admitted, because by every state the transport can see it is the new session
/// asking. The old lifecycle had become indistinguishable from the new one (Codex P1,
/// PRs #522/#523).
///
/// The epoch makes them distinguishable at the only place that knows: the resolution, which
/// knows when it began. These tests drive that closure directly, so "the session ended
/// mid-resolution" is expressed exactly rather than raced for — the fake executors complete
/// synchronously, so a bump between rungs is a bump between rungs.
final class ResolverAdmissionEpochTests: XCTestCase {
    private static let query = Data([0x12, 0x34, 0x01, 0x00, 0x00, 0x01])

    // MARK: - The ladder

    func testAnEndpointLadderStopsWhenTheSessionEndsMidResolution() {
        // Rung 1 fails, which is the signal to walk on. Between the two, the session ends.
        let recorder = ExecutorRecorder()
        let epoch = MutableEpoch(1)
        let orchestrator = Self.orchestrator(recorder: recorder, epoch: epoch)
        recorder.dohResults = [
            .init(response: nil, outcome: .receiveFailed),
            .init(response: ExecutorRecorder.plainResponse, outcome: .success)
        ]
        recorder.onDoH = { epoch.set(2) }

        let result = Self.resolveUpstreamSync(
            orchestrator, plan: Self.dohPlan(endpointHosts: ["one.example", "two.example"]))

        XCTAssertEqual(
            recorder.dohCallCount, 1,
            "the second endpoint must not be attempted — a lane cancelled by the previous "
                + "session's teardown reports a nil response, and walking on is what opened a "
                + "connection in the new session"
        )
        XCTAssertNil(result?.response, "a stale ladder resolves nothing")
        XCTAssertEqual(
            result?.attempts.map(\.outcome),
            [.receiveFailed, .refusedAfterLifecycleEnded],
            "the rung that really ran is preserved, and the refusal is recorded rather than "
                + "leaving an attempt list whose last entry reads as the resolution's verdict"
        )
    }

    func testALiveSessionStillWalksTheLadder() {
        // Guards the guard: the epoch check must stop a STALE ladder, not laddering itself.
        let recorder = ExecutorRecorder()
        let orchestrator = Self.orchestrator(recorder: recorder, epoch: MutableEpoch(1))
        recorder.dohResults = [
            .init(response: nil, outcome: .receiveFailed),
            .init(response: ExecutorRecorder.plainResponse, outcome: .success)
        ]

        let result = Self.resolveUpstreamSync(
            orchestrator, plan: Self.dohPlan(endpointHosts: ["one.example", "two.example"]))

        XCTAssertEqual(recorder.dohCallCount, 2, "failover must still reach the second endpoint")
        XCTAssertEqual(result?.response, ExecutorRecorder.plainResponse)
    }

    func testTheTerminalRungIsGatedToo() {
        // The per-rung check runs at the TOP of `resolveEndpoints`, so it only fires when
        // ADVANCING. A single-endpoint plan whose session ends during that one attempt used
        // to hand its result straight back — and `resolvePrimaryUpstream` is public: the smoke
        // probe calls it directly and schedules its own device-DNS fallback from that
        // completion, checking only the egress allowance (Codex P1, PR #524).
        let recorder = ExecutorRecorder()
        let epoch = MutableEpoch(1)
        let orchestrator = Self.orchestrator(recorder: recorder, epoch: epoch)
        recorder.dohResults = [.init(response: nil, outcome: .receiveFailed)]
        recorder.onDoH = { epoch.set(2) }

        let box = EpochResultBox()
        orchestrator.resolvePrimaryUpstream(
            Self.query, plan: Self.dohPlan(endpointHosts: ["only.example"])
        ) { box.store($0) }

        XCTAssertEqual(
            box.value?.attempts.map(\.outcome),
            [.receiveFailed, .refusedAfterLifecycleEnded],
            "the terminal result must be replaced with a refusal, not passed through — a "
                + "caller outside resolveUpstream reads it to decide what to do next, and a "
                + "real failure invites exactly the follow-on work this refuses"
        )
        XCTAssertNil(box.value?.response)
    }

    func testAWorkUnitAcceptedInAnEarlierSessionIsRefusedEvenIfItReachesTheOrchestratorLater() {
        // The provider admits DNS work through a bounded FIFO and retains over-bound requests
        // as closures, so a query ACCEPTED in session A can reach the orchestrator only after
        // session B has begun. A snapshot taken at orchestrator entry would name B and admit
        // all of A's work; the caller must pass the epoch it was accepted under.
        let recorder = ExecutorRecorder()
        let epoch = MutableEpoch(2)   // session B is already live by the time this runs
        let orchestrator = Self.orchestrator(recorder: recorder, epoch: epoch)

        let box = EpochResultBox()
        orchestrator.resolveUpstream(
            Self.query,
            plan: Self.dohPlan(endpointHosts: ["one.example"]),
            admittedAtEpoch: 1        // ...but it was accepted in session A
        ) { box.store($0) }

        XCTAssertEqual(
            recorder.dohCallCount, 0,
            "work accepted by a session that has ended must not egress under the next one"
        )
        XCTAssertEqual(box.value?.attempts.map(\.outcome), [.refusedAfterLifecycleEnded])
    }

    func testAWorkUnitAcceptedInTheLiveSessionStillRuns() {
        // Guards the guard: the caller-supplied epoch must ADMIT matching work, or the
        // bounded FIFO would refuse everything it ever queued.
        let recorder = ExecutorRecorder()
        let orchestrator = Self.orchestrator(recorder: recorder, epoch: MutableEpoch(2))
        recorder.dohResults = [.init(response: ExecutorRecorder.plainResponse, outcome: .success)]

        let box = EpochResultBox()
        orchestrator.resolveUpstream(
            Self.query,
            plan: Self.dohPlan(endpointHosts: ["one.example"]),
            admittedAtEpoch: 2
        ) { box.store($0) }

        XCTAssertEqual(recorder.dohCallCount, 1)
        XCTAssertEqual(box.value?.response, ExecutorRecorder.plainResponse)
    }

    func testAStaleSynchronousPrimaryIsMarkedAbandonedRatherThanPassedThrough() {
        // Plain and Device DNS are SYNCHRONOUS: they return their own result rather than
        // going through the endpoint ladder that appends the refusal. A stale one therefore
        // arrived carrying only real failures, and the health reducer — seeing no refusal —
        // scored `.totalFailure`, advancing aggregate outage and recovery state for a session
        // that had already ended (Codex P2, PR #524).
        let recorder = ExecutorRecorder()
        let epoch = MutableEpoch(1)
        let orchestrator = Self.orchestrator(recorder: recorder, epoch: epoch)
        recorder.onPlain = { epoch.set(2) }

        let box = EpochResultBox()
        orchestrator.resolveUpstream(Self.query, plan: Self.plainPlan()) { box.store($0) }

        XCTAssertEqual(recorder.plainCallCount, 1, "precondition: the primary really ran")
        XCTAssertEqual(
            box.value?.attempts.last?.outcome, .refusedAfterLifecycleEnded,
            "a stale synchronous primary must carry the marker that selects the neutral "
                + "abandoned path, not arrive looking like a concluded failure"
        )
        XCTAssertEqual(
            box.value?.attempts.count, 2,
            "and the real attempt is preserved beside it, not replaced"
        )
    }

    // MARK: - Entry

    func testAResolutionAdmittedWithNoLiveSessionIsRefusedBeforeAnyExecutor() {
        // Zero is what the provider reports for "no lifecycle" — provider gone, or stopped
        // but not yet cleaned up. Equality alone would admit it against itself, which is why
        // the check is `epoch != 0 && epoch == current` rather than just the comparison.
        let recorder = ExecutorRecorder()
        let orchestrator = Self.orchestrator(recorder: recorder, epoch: MutableEpoch(0))

        let result = Self.resolveUpstreamSync(
            orchestrator, plan: Self.dohPlan(endpointHosts: ["one.example"]))

        XCTAssertEqual(recorder.dohCallCount, 0, "no wire attempt for a session that does not exist")
        XCTAssertEqual(result?.attempts.map(\.outcome), [.refusedAfterLifecycleEnded])
        XCTAssertNil(result?.response)
    }

    func testTheEntryRefusalCoversPlainDNSToo() {
        // The entry gate sits ahead of the transport switch on purpose: plain and device
        // resolution egress on the physical interface just as the pooled transports do, and
        // the ladder gate below them would never see either.
        let recorder = ExecutorRecorder()
        let orchestrator = Self.orchestrator(recorder: recorder, epoch: MutableEpoch(0))

        let result = Self.resolveUpstreamSync(orchestrator, plan: Self.plainPlan())

        XCTAssertEqual(recorder.plainCallCount, 0, "plain DNS is not exempt from admission")
        XCTAssertEqual(result?.attempts.map(\.outcome), [.refusedAfterLifecycleEnded])
    }

    // MARK: - Fallback

    func testTheDeviceFallbackIsRefusedWhenTheSessionEndsDuringThePrimary() {
        // The primary is exactly what makes this late: a device or plain primary spends real
        // UDP timeouts, and a stop during them would otherwise have the fallback admitted
        // into whatever session exists by the time the ladder reaches it.
        let recorder = ExecutorRecorder()
        let epoch = MutableEpoch(1)
        let orchestrator = Self.orchestrator(recorder: recorder, epoch: epoch)
        recorder.dohResults = [.init(response: nil, outcome: .receiveFailed)]
        recorder.onDoH = { epoch.set(2) }

        _ = Self.resolveUpstreamSync(
            orchestrator,
            plan: Self.dohPlan(endpointHosts: ["one.example"], shouldFallbackToDeviceDNS: true))

        XCTAssertEqual(
            recorder.deviceCallCount, 0,
            "the device fallback must not egress on behalf of a session that has ended"
        )
    }

    func testALiveSessionStillTakesTheDeviceFallback() {
        // Guards the guard, as above: the fallback must still happen for a live session.
        let recorder = ExecutorRecorder()
        let orchestrator = Self.orchestrator(recorder: recorder, epoch: MutableEpoch(1))
        recorder.dohResults = [.init(response: nil, outcome: .receiveFailed)]

        let result = Self.resolveUpstreamSync(
            orchestrator,
            plan: Self.dohPlan(endpointHosts: ["one.example"], shouldFallbackToDeviceDNS: true))

        XCTAssertEqual(recorder.deviceCallCount, 1)
        XCTAssertEqual(result?.response, ExecutorRecorder.deviceResponse)
    }

    func testASessionEndingDuringTheDeviceFallbackMarksTheCombinedResult() {
        // The fallback itself spends real UDP timeouts. The pre-fallback gate has already
        // passed by then, so a session ending INSIDE the fallback completed this resolution
        // carrying only real failures — which the health reducer scored `.totalFailure`,
        // advancing aggregate outage and recovery state for a resolution that was abandoned
        // (Codex P2, PR #524). The combined result must leave carrying the refusal marker,
        // which is what selects the neutral abandoned path.
        let recorder = ExecutorRecorder()
        let epoch = MutableEpoch(1)
        let orchestrator = Self.orchestrator(recorder: recorder, epoch: epoch)
        recorder.dohResults = [.init(response: nil, outcome: .receiveFailed)]
        recorder.deviceResult = DNSResolutionResult(
            response: nil,
            successfulResolverAddress: nil,
            attempts: [ResolverAttempt(address: "10.0.0.1", outcome: .timeout, transport: .deviceDNS)],
            transport: .deviceDNS,
            udpTruncated: false,
            tcpFallbackAttempted: false,
            tcpFallbackSucceeded: false)
        recorder.onDevice = { epoch.set(2) }

        let result = Self.resolveUpstreamSync(
            orchestrator,
            plan: Self.dohPlan(endpointHosts: ["one.example"], shouldFallbackToDeviceDNS: true))

        XCTAssertEqual(
            result?.attempts.last?.outcome, .refusedAfterLifecycleEnded,
            "a fallback the session ended under must be marked abandoned, not returned as "
                + "an ordinary total failure"
        )
        XCTAssertNil(result?.response, "a stale resolution resolves nothing")
    }

    func testALiveSessionsFailingDeviceFallbackStaysAnHonestFailure() {
        // The mark must not leak into live results: a fallback that really failed, in a
        // session that is still running, is exactly the evidence the health model exists
        // to score.
        let recorder = ExecutorRecorder()
        let orchestrator = Self.orchestrator(recorder: recorder, epoch: MutableEpoch(1))
        recorder.dohResults = [.init(response: nil, outcome: .receiveFailed)]
        recorder.deviceResult = DNSResolutionResult(
            response: nil,
            successfulResolverAddress: nil,
            attempts: [ResolverAttempt(address: "10.0.0.1", outcome: .timeout, transport: .deviceDNS)],
            transport: .deviceDNS,
            udpTruncated: false,
            tcpFallbackAttempted: false,
            tcpFallbackSucceeded: false)

        let result = Self.resolveUpstreamSync(
            orchestrator,
            plan: Self.dohPlan(endpointHosts: ["one.example"], shouldFallbackToDeviceDNS: true))

        XCTAssertEqual(
            result?.attempts.last?.outcome, .timeout,
            "a live session's failed fallback is real evidence and must stay unmarked"
        )
    }

    // MARK: - Classification

    func testAStaleRefusalIsNotScoredAgainstTheResolver() {
        // The whole point of `isDeliberateRefusal`. A tunnel that merely stopped must not
        // bench the user's resolver or advance the escalation ladder — and every classifier
        // held its own `== .refusedByEgressPolicy`, so a second refusal case would have been
        // scored as a failure at each of them.
        XCTAssertTrue(ResolverAttemptOutcome.refusedAfterLifecycleEnded.isDeliberateRefusal)
        XCTAssertTrue(ResolverAttemptOutcome.refusedByEgressPolicy.isDeliberateRefusal)
        XCTAssertEqual(
            ResolverBackoffPolicy.AttemptOutcome(.refusedAfterLifecycleEnded), .backedOff,
            "backoff must treat it as suppressed-without-an-attempt, never as endpoint failure"
        )
        XCTAssertEqual(
            ResolverOrganicUpstreamEvidence.AttemptOutcome(.refusedAfterLifecycleEnded),
            .notAttempted,
            "organic evidence must read it as a decision we made, not resolver behaviour"
        )

        for failing in [ResolverAttemptOutcome.timeout, .receiveFailed, .sendFailed,
                        .httpStatusFailure, .socketUnavailable, .mismatchedResponse,
                        .invalidAddress, .unsupported, .deviceDNSUnavailable] {
            XCTAssertFalse(
                failing.isDeliberateRefusal,
                "\(failing.rawValue) is the resolver misbehaving and must stay scoreable"
            )
        }
        XCTAssertFalse(
            ResolverAttemptOutcome.success.isDeliberateRefusal,
            "a success is not a refusal, and folding it in would silence real evidence"
        )
    }

    func testAnAbandonedResolutionIsNotAnAggregateFailure() {
        // The mixture the ladder gate actually produces: a rung that really failed, then the
        // abandon. `allSatisfy(isDeliberateRefusal)` is false for it, so it fell through to
        // `.totalFailure` and advanced the escalation ladder for a tunnel that merely stopped
        // (Kilo, PR #524). The LAST attempt decides, because it says how the resolution ENDED
        // — the remaining endpoints were never tried, so "every resolver failed" is not
        // something this result establishes.
        let abandoned = DNSResolutionResult(
            response: nil,
            successfulResolverAddress: nil,
            attempts: [
                ResolverAttempt(address: "one.example", outcome: .receiveFailed, transport: .dnsOverHTTPS),
                ResolverAttempt(
                    address: "two.example", outcome: .refusedAfterLifecycleEnded, transport: .dnsOverHTTPS)
            ],
            transport: .dnsOverHTTPS,
            udpTruncated: false,
            tcpFallbackAttempted: false,
            tcpFallbackSucceeded: false)

        let evidence = ResolverOrganicUpstreamEvidence(
            occurredAt: Date(timeIntervalSince1970: 1_000), result: abandoned)

        XCTAssertEqual(
            evidence.outcome, ResolverOrganicUpstreamEvidence.Outcome.declinedByPolicy,
            "a resolution abandoned mid-ladder is not a verdict on the resolvers it never reached"
        )

        // ...but the rung that DID run keeps its per-resolver scoring. Withholding the
        // aggregate verdict must not also erase the real failure that happened before the
        // stop — the first version of this fix did exactly that while a comment claimed
        // otherwise (Codex P2, PR #524).
        let after = ResolverOrganicEvidenceReducer.reduce(
            state: ResolverHealthEvidenceState(),
            evidence: evidence,
            projectingOnto: TunnelHealthSnapshot()
        )
        XCTAssertEqual(
            after.state.session.resolverAttemptCounts["one.example"], 1,
            "the endpoint that really ran must still be counted"
        )
        XCTAssertEqual(
            after.state.session.resolverFailureCounts["one.example"], 1,
            "and its real failure must still be scored against it"
        )
        XCTAssertNil(
            after.state.session.resolverAttemptCounts["two.example"],
            "while the refusal itself is not an attempt against anything"
        )
        // IMMEDIATE, because this arm runs by definition after the session ended and stop
        // cleanup has already taken its forced flush — a deferred write would be scheduled
        // past the point NetworkExtension may suspend the process (Codex P2, PR #524).
        XCTAssertTrue(
            after.effects.contains(.persistHealth(.immediate)),
            "counters moved after the session ended, so the write cannot wait for a cadence "
                + "that may never run again"
        )
    }

    func testAStaleRefusalIsDistinguishableFromAnEgressRefusalInDiagnostics() {
        // They share a classification but not an identity: a log reader diagnosing "why did
        // nothing resolve" needs to tell "this transport may not egress here" from "whoever
        // asked is gone".
        XCTAssertNotEqual(
            ResolverAttemptOutcome.refusedAfterLifecycleEnded.rawValue,
            ResolverAttemptOutcome.refusedByEgressPolicy.rawValue
        )
        XCTAssertEqual(
            ResolverAttemptOutcome.refusedAfterLifecycleEnded.rawValue,
            "refused-after-lifecycle-ended"
        )
    }

    // MARK: - Fixtures

    /// The epoch a test drives. Mutable because the defect being covered is precisely a
    /// change of session BETWEEN two steps of one resolution.
    private final class MutableEpoch: @unchecked Sendable {
        private let lock = NSLock()
        private var value: UInt64

        init(_ value: UInt64) {
            self.value = value
        }

        func set(_ newValue: UInt64) {
            lock.lock()
            value = newValue
            lock.unlock()
        }

        var current: UInt64 {
            lock.lock()
            defer {
                lock.unlock()
            }
            return value
        }
    }

    private static func resolveUpstreamSync(
        _ orchestrator: ResolverOrchestrator,
        plan: DNSResolverRuntimePlan
    ) -> DNSResolutionResult? {
        let box = EpochResultBox()
        orchestrator.resolveUpstream(query, plan: plan) { box.store($0) }
        // Fake executors complete synchronously, so the result is already set.
        return box.value
    }

    private static func orchestrator(
        recorder: ExecutorRecorder,
        epoch: MutableEpoch
    ) -> ResolverOrchestrator {
        ResolverOrchestrator(
            executors: recorder.executors,
            egressAllowance: { .dnsOnlyMode },
            tunnelledPlainDNSRoute: { nil },
            admissionEpoch: { epoch.current },
            tierOneFallbackPlan: { nil })
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
                    bootstrapIPv6Servers: [])
            },
            dotEndpoints: [],
            doqEndpoints: [],
            cacheIdentifier: "doh-epoch-test",
            deviceDNSFallbackAddresses: ["192.168.1.1"],
            shouldFallbackToDeviceDNS: shouldFallbackToDeviceDNS,
            usesDeviceDNSFallbackMode: false)
    }

    private static func plainPlan() -> DNSResolverRuntimePlan {
        DNSResolverRuntimePlan(
            transport: .plainDNS,
            plainAddresses: ["9.9.9.9"],
            dohEndpoints: [],
            dotEndpoints: [],
            doqEndpoints: [],
            cacheIdentifier: "plain-epoch-test",
            deviceDNSFallbackAddresses: [],
            shouldFallbackToDeviceDNS: false,
            usesDeviceDNSFallbackMode: false)
    }
}

/// Fake executors for this suite. Deliberately its own rather than a widening of
/// `ResolverOrchestratorTests`' recorder, which is file-private there: sharing it would mean
/// making a fixture internal to the whole test target so two files could differ on one hook.
private final class ExecutorRecorder: @unchecked Sendable {
    static let plainResponse = Data([0xAA])
    static let deviceResponse = Data([0xBB])

    private let lock = NSLock()
    private var queuedDoHResults: [DNSTransportResponse] = []
    private var doHCalls = 0
    private var plainCalls = 0
    private var deviceCalls = 0
    private var doHHook: (@Sendable () -> Void)?
    private var plainHook: (@Sendable () -> Void)?
    private var deviceHook: (@Sendable () -> Void)?
    private var deviceResultOverride: DNSResolutionResult?

    /// Queued DoH outcomes, consumed one per endpoint attempt.
    var dohResults: [DNSTransportResponse] {
        get {
            lock.lock()
            defer { lock.unlock() }
            return queuedDoHResults
        }
        set {
            lock.lock()
            queuedDoHResults = newValue
            lock.unlock()
        }
    }

    /// Runs AFTER a DoH attempt completes — the seam where "the session ended during this
    /// attempt" is expressed, since the fakes complete synchronously.
    var onDoH: (@Sendable () -> Void)? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return doHHook
        }
        set {
            lock.lock()
            doHHook = newValue
            lock.unlock()
        }
    }

    /// Runs AFTER the synchronous plain executor — the seam for "the session ended during
    /// this primary".
    var onPlain: (@Sendable () -> Void)? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return plainHook
        }
        set {
            lock.lock()
            plainHook = newValue
            lock.unlock()
        }
    }

    /// Runs AFTER the synchronous device executor — the seam for "the session ended during
    /// the device fallback", which spends real UDP timeouts in production.
    var onDevice: (@Sendable () -> Void)? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return deviceHook
        }
        set {
            lock.lock()
            deviceHook = newValue
            lock.unlock()
        }
    }

    /// Overrides the device executor's default success, for fallbacks that must FAIL.
    var deviceResult: DNSResolutionResult? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return deviceResultOverride
        }
        set {
            lock.lock()
            deviceResultOverride = newValue
            lock.unlock()
        }
    }

    var dohCallCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return doHCalls
    }

    var plainCallCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return plainCalls
    }

    var deviceCallCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return deviceCalls
    }

    private func nextDoHResult() -> DNSTransportResponse {
        lock.lock()
        doHCalls += 1
        let next = queuedDoHResults.isEmpty
            ? DNSTransportResponse(response: nil, outcome: .receiveFailed)
            : queuedDoHResults.removeFirst()
        let hook = doHHook
        lock.unlock()
        hook?()
        return next
    }

    var executors: ResolverOrchestrator.Executors {
        ResolverOrchestrator.Executors(
            isEndpointBackedOff: { _ in false },
            resolveDoH: { [self] _, _, _, completion in completion(nextDoHResult()) },
            resolveDoT: { _, _, _, _, completion in
                completion(DNSTransportResponse(response: nil, outcome: .receiveFailed))
            },
            resolveDoQ: { _, _, _, _, completion in
                completion(DNSTransportResponse(response: nil, outcome: .receiveFailed))
            },
            resolvePlain: { [self] _, addresses, transport, _, _, _ in
                lock.lock()
                plainCalls += 1
                let hook = plainHook
                lock.unlock()
                hook?()
                return DNSResolutionResult(
                    response: Self.plainResponse,
                    successfulResolverAddress: addresses.first,
                    attempts: [ResolverAttempt(
                        address: addresses.first ?? "none", outcome: .success, transport: transport)],
                    transport: transport,
                    udpTruncated: false,
                    tcpFallbackAttempted: false,
                    tcpFallbackSucceeded: false)
            },
            resolveTunnelledPlain: { _, _ in
                DNSResolutionResult(
                    response: nil, successfulResolverAddress: nil, attempts: [],
                    transport: .plainDNS, udpTruncated: false,
                    tcpFallbackAttempted: false, tcpFallbackSucceeded: false)
            },
            resolveDevice: { [self] _, addresses, _, _, _, _ in
                lock.lock()
                deviceCalls += 1
                let hook = deviceHook
                let override = deviceResultOverride
                lock.unlock()
                hook?()
                return override ?? DNSResolutionResult(
                    response: Self.deviceResponse,
                    successfulResolverAddress: addresses.first,
                    attempts: [ResolverAttempt(
                        address: addresses.first ?? "device", outcome: .success, transport: .deviceDNS)],
                    transport: .deviceDNS,
                    udpTruncated: false,
                    tcpFallbackAttempted: false,
                    tcpFallbackSucceeded: false)
            })
    }
}

private final class EpochResultBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: DNSResolutionResult?

    func store(_ result: DNSResolutionResult) {
        lock.lock()
        stored = result
        lock.unlock()
    }

    var value: DNSResolutionResult? {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }
}
