import XCTest
@testable import LavaSecKit

final class ProtectionStatusPublicationTests: XCTestCase {
    private let date = Date(timeIntervalSince1970: 10_000)
    private func clock(_ seconds: Double, boot: String = "boot-A") -> ProtectionStatusPublicationClock.Sample {
        .init(date: date.addingTimeInterval(seconds), bootSessionID: boot,
              continuousNanoseconds: UInt64(seconds * 1_000_000_000))
    }
    private func evidence(_ seconds: Double, bytes: UInt64 = 8, ready: Bool = true,
                          epoch: UInt64 = 1, transport: UInt64 = 1, baseline: UInt64 = 0,
                          condition: ChainedRuntimeCondition = .normal, online: Bool = true,
                          active: Bool = true, id: String = "provider-A") -> ProtectionStatusEvidence {
        .init(sampledAt: date.addingTimeInterval(seconds), lifecycleIsActive: active,
              health: .init(startedAt: date, networkPathIsSatisfied: online), pauseUntil: nil,
              isChained: true, sessionGeneration: 1, forwardedBytes: bytes,
              transportGeneration: transport, setupReady: ready, providerLifecycleID: id,
              verificationEpoch: epoch, forwardingBaseline: baseline, runtimeCondition: condition)
    }
    func testProviderKeepsIdleProofWhileAppIsAwayAndPendingTrafficDoesNotEraseSetup() throws {
        var publisher = ProtectionStatusPublisher()
        var publication = try XCTUnwrap(publisher.observe(evidence(1), clock: clock(1)))
        for second in stride(from: 6.0, through: 3601.0, by: 5) {
            publication = try XCTUnwrap(publisher.observe(evidence(second, ready: false), clock: clock(second)))
        }
        XCTAssertEqual(publication.status, .connected(.healthy))
        XCTAssertTrue(publication.isValid(clock: clock(3602), providerLifecycleID: "provider-A", connectedAt: date))
        var setup = ProtectionStatusPublisher()
        _ = setup.observe(evidence(1, bytes: 0), clock: clock(1))
        XCTAssertEqual(setup.observe(evidence(30, bytes: 0, ready: false), clock: clock(30))?.status, .tunnelReady)
    }
    func testKnownNegativeEvidenceImmediatelyReplacesHealthyPublication() throws {
        for (condition, expected): (ChainedRuntimeCondition, ProtectionStatus) in [
            (.recovering, .vpnRecovering), (.offline, .connected(.networkUnavailable)),
            (.suspended, .unavailable), (.retired, .unavailable)
        ] {
            var publisher = ProtectionStatusPublisher()
            _ = publisher.observe(evidence(1), clock: clock(1))
            XCTAssertEqual(publisher.observe(evidence(1.1, condition: condition), clock: clock(1.1))?.status, expected)
        }
        var publisher = ProtectionStatusPublisher()
        _ = publisher.observe(evidence(1), clock: clock(1))
        XCTAssertEqual(publisher.observe(evidence(1.1, online: false), clock: clock(1.1))?.status,
                       .connected(.networkUnavailable))
        XCTAssertEqual(publisher.observe(evidence(1.2, active: false), clock: clock(1.2))?.status, .unavailable)
    }
    func testWakeAndTransportEpochCannotBorrowOldForwardingProof() throws {
        var publisher = ProtectionStatusPublisher()
        _ = publisher.observe(evidence(1, bytes: 100), clock: clock(1))
        let woke = try XCTUnwrap(publisher.observe(evidence(2, bytes: 100, ready: false, epoch: 2, baseline: 100), clock: clock(2)))
        XCTAssertNotEqual(woke.status, .connected(.healthy))
        XCTAssertEqual(publisher.observe(evidence(3, bytes: 101, ready: false, epoch: 2, baseline: 100), clock: clock(3))?.status,
                       .connected(.healthy))
        let moved = try XCTUnwrap(publisher.observe(evidence(4, bytes: 0, ready: false, epoch: 2, transport: 2), clock: clock(4)))
        XCTAssertNotEqual(moved.status, .connected(.healthy))
    }
    func testLeaseIncludesSleepAndRejectsRebootFutureTimeAndNewConnectedSession() throws {
        var publisher = ProtectionStatusPublisher()
        let publication = try XCTUnwrap(publisher.observe(evidence(1), clock: clock(1)))
        XCTAssertTrue(publication.isValid(clock: clock(10.999), providerLifecycleID: "provider-A", connectedAt: date))
        for sample in [clock(11), clock(3600), clock(0), clock(2, boot: "boot-B")] {
            XCTAssertFalse(publication.isValid(clock: sample, providerLifecycleID: "provider-A", connectedAt: date))
        }
        XCTAssertFalse(publication.isValid(clock: clock(2), providerLifecycleID: "provider-B", connectedAt: date))
        XCTAssertFalse(publication.isValid(clock: clock(2), providerLifecycleID: "provider-A", connectedAt: date.addingTimeInterval(1.5)))
        let rollback = ProtectionStatusPublicationClock.Sample(date: date.addingTimeInterval(-3600),
            bootSessionID: "boot-A", continuousNanoseconds: 11_000_000_000)
        XCTAssertFalse(publication.isValid(clock: rollback, providerLifecycleID: "provider-A", connectedAt: date))
    }
    func testStartupPublicationBeforeNEConnectedDateNeedsFencedLiveProofToTakeOwnership() throws {
        var publisher = ProtectionStatusPublisher()
        let startup = try XCTUnwrap(publisher.observe(evidence(1), clock: clock(1)))
        let connectedAt = date.addingTimeInterval(1.01)
        var reader = ProtectionStatusPublicationReader()
        XCTAssertFalse(reader.admit(startup, clock: clock(1.02), providerLifecycleID: nil, connectedAt: connectedAt))
        XCTAssertFalse(reader.admit(startup, clock: clock(1.03), providerLifecycleID: "provider-A", connectedAt: connectedAt))
        XCTAssertNil(reader.publication, "unadmitted startup files cannot own the operational surface")
        let proof = ProtectionStatusPublicationConnectionProof(publication: startup,
            connectedAt: connectedAt, verifiedAt: clock(1.04))
        XCTAssertTrue(reader.admit(startup, clock: clock(1.04), providerLifecycleID: "provider-A",
            connectedAt: connectedAt, connectionProof: proof))
        XCTAssertEqual(reader.status(clock: clock(1.04), providerLifecycleID: "provider-A",
            connectedAt: connectedAt, connectionProof: proof), .connected(.healthy))
        XCTAssertEqual(reader.status(clock: clock(11), providerLifecycleID: "provider-A",
            connectedAt: connectedAt, connectionProof: proof), .unavailable, "startup proof never renews the lease")
    }
    func testDelayedReplyCannotOverwriteFailureAndMissingRepliesDoNotRenewLease() throws {
        var publisher = ProtectionStatusPublisher()
        let healthy = try XCTUnwrap(publisher.observe(evidence(1), clock: clock(1)))
        let failure = try XCTUnwrap(publisher.observe(evidence(2, online: false), clock: clock(2)))
        var reader = ProtectionStatusPublicationReader()
        XCTAssertTrue(reader.admit(failure, clock: clock(2), providerLifecycleID: "provider-A", connectedAt: date))
        XCTAssertFalse(reader.admit(healthy, clock: clock(3), providerLifecycleID: "provider-A", connectedAt: date))
        XCTAssertEqual(reader.status(clock: clock(3), providerLifecycleID: "provider-A", connectedAt: date), failure.status)
        for second in [4.0, 6, 9, 12] {
            XCTAssertFalse(reader.admit(nil, clock: clock(second), providerLifecycleID: "provider-A", connectedAt: date))
        }
        XCTAssertEqual(reader.status(clock: clock(12), providerLifecycleID: "provider-A", connectedAt: date), .unavailable)
        XCTAssertEqual(reader.status(clock: clock(3), providerLifecycleID: "provider-B", connectedAt: date), .unavailable)
        let roundTrip = try JSONDecoder().decode(ProtectionStatusPublication.self, from: JSONEncoder().encode(failure))
        XCTAssertEqual(roundTrip, failure)
        let wire = ChainedHandshakeStatus(isChained: true, hasHandshake: true, everHandshaked: true,
            statusPublication: failure)
        XCTAssertEqual(ChainedHandshakeStatus.decode(wire.encoded())?.statusPublication, failure)
        var shortcutEvidence = evidence(2, online: false)
        shortcutEvidence.statusPublication = failure
        XCTAssertEqual(try JSONDecoder().decode(ProtectionStatusEvidence.self,
            from: JSONEncoder().encode(shortcutEvidence)).statusPublication, failure)
    }

    func testCounterRegressionCannotRetainConfirmationAndUnreadableClockCannotPublish() throws {
        var publisher = ProtectionStatusPublisher()
        _ = publisher.observe(evidence(1, bytes: 100), clock: clock(1))
        let regressed = try XCTUnwrap(publisher.observe(evidence(2, bytes: 5, ready: false), clock: clock(2)))
        let idle = try XCTUnwrap(publisher.observe(evidence(3, bytes: 5, ready: false), clock: clock(3)))
        XCTAssertNotEqual(regressed.status, .connected(.healthy))
        XCTAssertNotEqual(idle.status, .connected(.healthy))
        XCTAssertEqual(publisher.observe(evidence(4, bytes: 6, ready: false), clock: clock(4))?.status,
                       .connected(.healthy))
        XCTAssertNil(publisher.observe(evidence(5), clock: .init(date: date, bootSessionID: nil,
            continuousNanoseconds: 5_000_000_000)))
    }

    func testForeignPublicationOnlyChallengesOlderIdentityProofInTheSameLiveClockDomain() throws {
        var publisher = ProtectionStatusPublisher()
        let publication = try XCTUnwrap(publisher.observe(evidence(2), clock: clock(2)))
        XCTAssertTrue(publication.requiresIdentityRevalidation(providerLifecycleID: "provider-B", verifiedAt: clock(1), clock: clock(3)))
        XCTAssertTrue(publication.requiresIdentityRevalidation(providerLifecycleID: nil, verifiedAt: nil, clock: clock(3)))
        XCTAssertFalse(publication.requiresIdentityRevalidation(providerLifecycleID: "provider-B", verifiedAt: clock(3), clock: clock(4)))
        XCTAssertFalse(publication.requiresIdentityRevalidation(providerLifecycleID: "provider-A", verifiedAt: nil, clock: clock(3)))
        XCTAssertFalse(publication.requiresIdentityRevalidation(providerLifecycleID: "provider-B", verifiedAt: clock(1), clock: clock(12)))
        XCTAssertFalse(publication.requiresIdentityRevalidation(providerLifecycleID: "provider-B", verifiedAt: nil, clock: clock(3, boot: "boot-B")))
    }

    func testLiveConnectionProofSurvivesWallClockRollbackWithoutBypassingIdentityOrLease() throws {
        var publisher = ProtectionStatusPublisher()
        _ = publisher.observe(evidence(1), clock: clock(1))
        let rollback = ProtectionStatusPublicationClock.Sample(date: date.addingTimeInterval(-3600),
            bootSessionID: "boot-A", continuousNanoseconds: 2_000_000_000)
        let publication = try XCTUnwrap(publisher.observe(evidence(2), clock: rollback))
        let proof = ProtectionStatusPublicationConnectionProof(publication: publication, connectedAt: date, verifiedAt: clock(1))
        var reader = ProtectionStatusPublicationReader()
        XCTAssertFalse(reader.admit(publication, clock: rollback, providerLifecycleID: "provider-A", connectedAt: date))
        XCTAssertTrue(reader.admit(publication, clock: rollback, providerLifecycleID: "provider-A", connectedAt: date,
            connectionProof: proof))
        XCTAssertEqual(reader.status(clock: rollback, providerLifecycleID: "provider-A", connectedAt: date,
            connectionProof: proof), publication.status)
        XCTAssertFalse(publication.isValid(clock: rollback, providerLifecycleID: "provider-B", connectedAt: date,
            connectionProof: proof))
        XCTAssertFalse(publication.isValid(clock: clock(12), providerLifecycleID: "provider-A", connectedAt: date,
            connectionProof: proof))
        XCTAssertFalse(publication.isValid(clock: clock(3, boot: "boot-B"), providerLifecycleID: "provider-A", connectedAt: date,
            connectionProof: proof))
        XCTAssertFalse(publication.isValid(clock: rollback, providerLifecycleID: "provider-A", connectedAt: nil,
            connectionProof: proof))
        XCTAssertFalse(rollback.isAtOrAfter(clock(3)))
        XCTAssertTrue(rollback.isAtOrAfter(clock(1)))
        XCTAssertFalse(rollback.isAtOrAfter(clock(1, boot: "boot-B")))
    }

    func testFencedLiveReplyBridgesChangedBootTimeFallbackOnlyForItsProviderAndObserverBoot() throws {
        var publisher = ProtectionStatusPublisher()
        let publication = try XCTUnwrap(publisher.observe(evidence(2), clock: clock(2)))
        let appClock = clock(3, boot: "boot-time-after-edit")
        let proof = ProtectionStatusPublicationConnectionProof(publication: publication, connectedAt: date, verifiedAt: appClock)
        var reader = ProtectionStatusPublicationReader()
        XCTAssertFalse(reader.admit(publication, clock: appClock, providerLifecycleID: "provider-A", connectedAt: date))
        XCTAssertTrue(reader.admit(publication, clock: appClock, providerLifecycleID: "provider-A", connectedAt: date,
            connectionProof: proof))
        XCTAssertEqual(publication.remainingLease(clock: appClock, connectionProof: proof), 9)
        XCTAssertEqual(reader.status(clock: appClock, providerLifecycleID: "provider-A", connectedAt: date,
            connectionProof: proof), .connected(.healthy))
        XCTAssertEqual(reader.status(clock: appClock, providerLifecycleID: "provider-A", connectedAt: date.addingTimeInterval(0.5),
            connectionProof: proof), .unavailable)
        XCTAssertEqual(reader.status(clock: clock(12, boot: "boot-time-after-edit"), providerLifecycleID: "provider-A", connectedAt: date,
            connectionProof: proof), .unavailable)
        XCTAssertEqual(reader.status(clock: clock(4, boot: "new-boot"), providerLifecycleID: "provider-A", connectedAt: date,
            connectionProof: proof), .unavailable)
        var replacement = ProtectionStatusPublisher()
        let foreign = try XCTUnwrap(replacement.observe(evidence(4, id: "provider-B"), clock: clock(4)))
        XCTAssertFalse(foreign.isValid(clock: clock(5, boot: "boot-time-after-edit"), providerLifecycleID: "provider-B", connectedAt: date,
            connectionProof: proof))
        XCTAssertTrue(foreign.requiresIdentityRevalidation(providerLifecycleID: "provider-A", verifiedAt: appClock,
            clock: clock(5, boot: "boot-time-after-edit"), connectionProof: proof))
        let failure = try XCTUnwrap(publisher.observe(evidence(5, online: false), clock: clock(5)))
        XCTAssertTrue(reader.admit(failure, clock: clock(6, boot: "boot-time-after-edit"), providerLifecycleID: "provider-A", connectedAt: date,
            connectionProof: proof))
        XCTAssertFalse(reader.admit(publication, clock: clock(6, boot: "boot-time-after-edit"), providerLifecycleID: "provider-A", connectedAt: date,
            connectionProof: proof))
        XCTAssertEqual(reader.status(clock: clock(6, boot: "boot-time-after-edit"), providerLifecycleID: "provider-A", connectedAt: date,
            connectionProof: proof), .connected(.networkUnavailable))
    }

    func testEstablishmentTimeoutUsesContinuousElapsedTimeAcrossWallClockJumps() throws {
        var publisher = ProtectionStatusPublisher()
        XCTAssertEqual(try XCTUnwrap(publisher.observe(evidence(1, bytes: 0, ready: false), clock: clock(1))).status, .establishing)
        for (second, jump) in [(2.0, 3600.0), (3.0, -3600.0)] {
            let changedClock = ProtectionStatusPublicationClock.Sample(date: date.addingTimeInterval(jump),
                bootSessionID: "boot-A", continuousNanoseconds: UInt64(second * 1_000_000_000))
            XCTAssertEqual(try XCTUnwrap(publisher.observe(evidence(second, bytes: 0, ready: false), clock: changedClock)).status, .establishing)
        }
        let expiredAt = 1 + ChainedConnectLifecyclePolicy.establishmentTimeoutSeconds
        let unchangedWallClock = ProtectionStatusPublicationClock.Sample(date: date,
            bootSessionID: "boot-A", continuousNanoseconds: UInt64(expiredAt * 1_000_000_000))
        XCTAssertEqual(try XCTUnwrap(publisher.observe(evidence(expiredAt, bytes: 0, ready: false), clock: unchangedWallClock)).status, .vpnUnconfirmed)
    }
}
