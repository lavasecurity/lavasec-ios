import XCTest
@testable import LavaSecCore

final class ProtectionStatusTests: XCTestCase {

    func testReadinessIsNeutralAndYieldsToPauseUnknownAndRealFailure() {
        XCTAssertEqual(ProtectionStatus.resolve(lifecycle: .connected, chainedEstablishing: true,
            setupReady: true, connectivity: .healthy), .tunnelReady)
        for severity in [ProtectionConnectivitySeverity.networkUnavailable, .needsReconnect, .dnsSlow, .recovering,
                         .usingDeviceDNSFallback, .usingEncryptedFallback] {
            XCTAssertEqual(ProtectionStatus.resolve(lifecycle: .connected, chainedEstablishing: true,
                setupReady: true, connectivity: severity), .connected(severity))
        }
        XCTAssertEqual(ProtectionStatus.resolve(lifecycle: .connected, observationUnavailable: true,
            setupReady: true, connectivity: .healthy), .unavailable)
        let until = Date(timeIntervalSince1970: 123)
        XCTAssertEqual(ProtectionStatus.resolve(lifecycle: .connected, pauseUntil: until,
            setupReady: true, connectivity: .healthy), .paused(until))
        XCTAssertEqual(ProtectionStatus.resolve(lifecycle: .disconnecting, setupReady: true), .turningOff)
    }

    func testVPNTransportRecoveryDoesNotReportADNSFailure() {
        for severity in [ProtectionConnectivitySeverity.dnsSlow, .needsReconnect] {
            let status = ProtectionStatus.resolve(lifecycle: .connected,
                runtimeCondition: .recovering, connectivity: severity)
            XCTAssertEqual(status, .connected(severity))
            XCTAssertTrue(status.recommendsReconnect)
        }
        XCTAssertEqual(ProtectionStatus.resolve(lifecycle: .connected,
            runtimeCondition: .recovering, connectivity: .networkUnavailable), .connected(.networkUnavailable))
        XCTAssertEqual(ProtectionStatus.resolve(lifecycle: .connected,
            setupReady: true, runtimeCondition: .recovering, connectivity: .healthy), .vpnRecovering)
        XCTAssertEqual(ProtectionStatus.resolve(lifecycle: .connected,
            connectivity: .recovering), .connected(.recovering))
        XCTAssertEqual(ProtectionStatus.resolve(lifecycle: .disconnected,
            awaitingOnDemandReconnect: true), .reconnecting)
    }

    func testChainingFailureHasItsOwnStatusWhileDNSFilteringRemainsConnected() {
        XCTAssertEqual(ProtectionStatus.resolve(lifecycle: .connected, chainedFailure: true,
            setupReady: true, connectivity: .healthy), .chainingFailed)
        XCTAssertEqual(ProtectionStatus.resolve(lifecycle: .connected,
            pauseUntil: Date(timeIntervalSince1970: 123), chainedFailure: true,
            connectivity: .healthy), .chainingFailed)
        XCTAssertEqual(ProtectionStatus.resolve(lifecycle: .connected, chainedFailure: true,
            runtimeCondition: .recovering, connectivity: .healthy), .chainingFailed)
        XCTAssertEqual(ProtectionStatus.resolve(lifecycle: .connected, chainedFailure: true,
            connectivity: .networkUnavailable), .connected(.networkUnavailable))
        XCTAssertEqual(ProtectionStatus.resolve(lifecycle: .disconnected, chainedFailure: true), .off)
        XCTAssertEqual(ProtectionStatus.resolve(lifecycle: .disconnected, chainedFailure: true,
            awaitingOnDemandReconnect: true), .reconnecting)
        XCTAssertTrue(ProtectionStatus.chainingFailed.recommendsReconnect)
    }

    func testReadOnlyDNSFallbackUsesTheSharedChainedFailureMarker() {
        let now = Date(timeIntervalSince1970: 10_000)
        let dnsOnly = ProtectionStatusEvidence(sampledAt: now, lifecycleIsActive: true,
            health: TunnelHealthSnapshot(startedAt: now.addingTimeInterval(-60)),
            pauseUntil: nil, isChained: false, sessionGeneration: nil, forwardedBytes: nil)
        XCTAssertEqual(dnsOnly.status(now: now), .connected(.healthy))
        XCTAssertEqual(dnsOnly.status(now: now, chainedFailure: true), .chainingFailed)
        let evidence = ProtectionStatusEvidence(sampledAt: now, lifecycleIsActive: true,
            health: TunnelHealthSnapshot(startedAt: now.addingTimeInterval(-60)),
            pauseUntil: now.addingTimeInterval(60), isChained: false,
            sessionGeneration: nil, forwardedBytes: nil)
        XCTAssertEqual(evidence.status(now: now), .paused(now.addingTimeInterval(60)))
        XCTAssertEqual(evidence.status(now: now, chainedFailure: true), .chainingFailed)
        XCTAssertEqual(evidence.status(now: now.addingTimeInterval(6), chainedFailure: true), .unavailable)
    }

    func testExternalReadinessRequiresExplicitCurrentTransportEvidenceAndNeverMakesProtected() throws {
        let now = Date(timeIntervalSince1970: 10_000)
        func read(transport: UInt64?, ready: Bool?, bytes: UInt64 = 0) -> ProtectionStatusEvidence {
            ProtectionStatusEvidence(sampledAt: now, lifecycleIsActive: true,
                health: TunnelHealthSnapshot(startedAt: now.addingTimeInterval(-60)), pauseUntil: nil,
                isChained: true, sessionGeneration: 1, forwardedBytes: bytes,
                transportGeneration: transport, setupReady: ready)
        }
        XCTAssertEqual(read(transport: nil, ready: nil).status(now: now), .vpnUnconfirmed)
        XCTAssertEqual(read(transport: 1, ready: true).status(now: now), .tunnelReady)
        XCTAssertEqual(read(transport: 2, ready: true).status(now: now), .vpnUnconfirmed)
        XCTAssertEqual(read(transport: 1, ready: true, bytes: 1).status(now: now), .connected(.healthy))
        let data = try JSONEncoder().encode(read(transport: nil, ready: nil))
        let legacy = try JSONDecoder().decode(ProtectionStatusEvidence.self, from: data)
        XCTAssertNil(legacy.setupReady)
        XCTAssertEqual(legacy.status(now: now), .vpnUnconfirmed)
    }

    @MainActor
    func testHandledStartFailureStopsTheShortcutAndReleasesItsGate() async {
        for completed in [true, false] {
            let gate = ProtectionActionOrchestrator()
            var reachedNextAction = false
            do {
                try await ProtectionShortcutCoordinator.perform(enabled: true, gate: gate,
                    authorize: { true }, readState: { (.disconnected, false) },
                    connect: {
                        try ProtectionShortcutCoordinator.validateStartResult(completed: completed, hasError: true)
                    }, resume: { XCTFail("Must not resume") }, disconnect: { XCTFail("Must not disconnect") })
                reachedNextAction = true
            } catch {
                XCTAssertEqual(error as? ProtectionShortcutError, .startFailed)
            }
            XCTAssertFalse(reachedNextAction, "A handled start error must not report normal shortcut completion")
            XCTAssertFalse(gate.isActionInFlight)
        }
    }

    func testStartResultDistinguishesSupersessionFromSuccessfulCompletion() throws {
        XCTAssertNoThrow(try ProtectionShortcutCoordinator.validateStartResult(completed: true, hasError: false))
        XCTAssertThrowsError(try ProtectionShortcutCoordinator.validateStartResult(completed: false, hasError: false)) {
            XCTAssertTrue($0 is CancellationError)
        }
    }

    func testPauseAndChainedEstablishmentTakePrecedence() {
        let until = Date(timeIntervalSince1970: 123)
        XCTAssertEqual(ProtectionStatus.resolve(lifecycle: .connected, pauseUntil: until,
            chainedEstablishing: true, connectivity: .healthy), .paused(until))
        XCTAssertEqual(ProtectionStatus.resolve(lifecycle: .connected,
            chainedEstablishing: true, connectivity: .healthy), .establishing)
        XCTAssertEqual(ProtectionStatus.resolve(lifecycle: .disconnected, pauseUntil: until), .off)
    }

    func testUnconfirmedVPNDoesNotHideRealConnectivityProblems() {
        XCTAssertEqual(ProtectionStatus.resolve(lifecycle: .connected,
            forwardingUnconfirmed: true, connectivity: .healthy), .vpnUnconfirmed)
        for severity in [ProtectionConnectivitySeverity.networkUnavailable, .needsReconnect, .dnsSlow, .recovering,
                         .usingDeviceDNSFallback, .usingEncryptedFallback] {
            XCTAssertEqual(ProtectionStatus.resolve(lifecycle: .connected,
                forwardingUnconfirmed: true, connectivity: severity), .connected(severity))
        }
    }

    func testMissingObservationDoesNotMasqueradeAsUserStartOrUnconfirmedForwarding() {
        XCTAssertEqual(ProtectionStatus.resolve(lifecycle: .connected,
            observationUnavailable: true, forwardingUnconfirmed: true, connectivity: .healthy), .unavailable)
        XCTAssertEqual(ProtectionStatus.resolve(lifecycle: .disconnected,
            observationUnavailable: true), .off)
        XCTAssertEqual(ProtectionStatus.resolve(lifecycle: .connecting,
            observationUnavailable: true), .turningOn)
    }

    func testUnknownHealthNeverReportsProtected() {
        XCTAssertEqual(ProtectionStatus.resolve(lifecycle: .connected), .unavailable)
        XCTAssertEqual(ProtectionStatus.resolve(lifecycle: .connecting), .turningOn)
        XCTAssertEqual(ProtectionStatus.resolve(lifecycle: .disconnecting), .turningOff)
        XCTAssertEqual(ProtectionStatus.resolve(lifecycle: .disconnected, awaitingOnDemandReconnect: true), .reconnecting)
    }

    @MainActor
    func testCancelledAuthenticationAndBusyActionsCannotMutateProtection() async throws {
        let gate = ProtectionActionOrchestrator()
        var changes = 0
        do {
            try await ProtectionShortcutCoordinator.perform(enabled: false, gate: gate,
                authorize: { false }, readState: { (.connected, false) },
                connect: { changes += 1 }, resume: { changes += 1 }, disconnect: { changes += 1 })
            XCTFail("Denied authentication must throw")
        } catch { XCTAssertEqual(error as? ProtectionShortcutError, .authenticationRequired) }
        XCTAssertEqual(changes, 0)
        XCTAssertFalse(gate.isActionInFlight)
        gate.claim(.reconnect)
        do {
            try await ProtectionShortcutCoordinator.perform(enabled: true, gate: gate,
                authorize: { true }, readState: { (.disconnected, false) },
                connect: { changes += 1 }, resume: { changes += 1 }, disconnect: { changes += 1 })
            XCTFail("Busy actions must throw")
        } catch { XCTAssertEqual(error as? ProtectionShortcutError, .busy) }
        XCTAssertEqual(changes, 0)
        XCTAssertEqual(gate.inFlightAction, .reconnect)
    }

    @MainActor
    func testCommandsSetAnExplicitStateAndReadAfterAuthorization() async throws {
        let gate = ProtectionActionOrchestrator()
        var status: ProtectionLifecycleStatus = .disconnected
        var paused = false
        var events: [String] = []
        func run(_ enabled: Bool) async throws {
            try await ProtectionShortcutCoordinator.perform(enabled: enabled, gate: gate,
                authorize: { events.append("authorize"); return true },
                readState: { events.append("read"); return (status, paused) },
                connect: { events.append("connect"); status = .connected },
                resume: { events.append("resume"); paused = false },
                disconnect: { events.append("disconnect"); status = .disconnected })
        }
        try await run(true)
        try await run(true)
        XCTAssertEqual(events, ["authorize", "read", "connect", "authorize", "read"])
        paused = true
        try await run(true)
        XCTAssertEqual(events.last, "resume")
        try await run(false)
        try await run(false)
        XCTAssertEqual(events.filter { $0 == "connect" }.count, 1)
        XCTAssertEqual(events.filter { $0 == "disconnect" }.count, 2)
        XCTAssertEqual(status, .disconnected)
    }

    func testProviderEvidenceRejectsStaleInactiveAndFutureSamples() {
        let now = Date(timeIntervalSince1970: 10_000)
        for (sample, active) in [(now.addingTimeInterval(-6), true), (now.addingTimeInterval(1), true), (now, false)] {
            let evidence = ProtectionStatusEvidence(sampledAt: sample, lifecycleIsActive: active,
                health: TunnelHealthSnapshot(startedAt: now.addingTimeInterval(-60)),
                pauseUntil: nil, isChained: false, sessionGeneration: nil, forwardedBytes: nil)
            XCTAssertEqual(evidence.status(now: now), .unavailable)
        }
    }

    func testReadOnlyEvidenceUsesCanonicalForwardingThresholdAndTimeout() {
        let now = Date(timeIntervalSince1970: 10_000)
        func read(started: Date, bytes: UInt64?, pause: Date? = nil) -> ProtectionStatus {
            ProtectionStatusEvidence(sampledAt: now, lifecycleIsActive: true,
                health: TunnelHealthSnapshot(startedAt: started), pauseUntil: pause,
                isChained: true, sessionGeneration: bytes == nil ? nil : 1,
                forwardedBytes: bytes).status(now: now)
        }
        let oldStart = now.addingTimeInterval(-60)
        XCTAssertEqual(read(started: now, bytes: 0), .establishing)
        XCTAssertEqual(read(started: oldStart, bytes: nil), .vpnUnconfirmed)
        XCTAssertEqual(read(started: oldStart, bytes: 0), .vpnUnconfirmed)
        XCTAssertEqual(read(started: oldStart,
            bytes: ChainedEstablishmentPolicy.forwardingConfirmedByteThreshold), .connected(.healthy))
        let until = now.addingTimeInterval(60)
        XCTAssertEqual(read(started: oldStart, bytes: 0, pause: until), .paused(until))
        XCTAssertEqual(read(started: oldStart, bytes: 0, pause: now), .vpnUnconfirmed)
    }

    @MainActor
    func testCancellationWhileReadingNeverAcceptsOrRunsCommand() async {
        let gate = ProtectionActionOrchestrator()
        var mutations = 0
        let task = Task { @MainActor in
            try await ProtectionShortcutCoordinator.perform(enabled: false, gate: gate,
                authorize: { true },
                readState: {
                    withUnsafeCurrentTask { $0?.cancel() }
                    return (.connected, false)
                },
                accept: { mutations += 1 }, connect: { mutations += 1 },
                resume: { mutations += 1 }, disconnect: { mutations += 1 })
        }
        do { try await task.value; XCTFail("Cancellation must throw") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(mutations, 0)
        XCTAssertFalse(gate.isActionInFlight)
    }

    @MainActor
    func testTransitionBusyAndPersistenceFailureDoNotReachLifecycleActions() async {
        enum Failure: Error { case persist }
        let gate = ProtectionActionOrchestrator()
        var mutations = 0
        for status in [ProtectionLifecycleStatus.disconnecting, .disconnected] {
            do {
                try await ProtectionShortcutCoordinator.perform(enabled: true, gate: gate,
                    authorize: { true }, readState: { (status, false) },
                    accept: { throw Failure.persist }, connect: { mutations += 1 },
                    resume: { mutations += 1 }, disconnect: { mutations += 1 })
                XCTFail("The command must fail before mutation")
            } catch {
                if status == .disconnecting { XCTAssertEqual(error as? ProtectionShortcutError, .busy) }
                else { XCTAssertTrue(error is Failure) }
            }
            XCTAssertFalse(gate.isActionInFlight)
        }
        XCTAssertEqual(mutations, 0)
    }

}
