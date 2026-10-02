import CryptoKit
import LavaSecKit
import XCTest

@testable import LavaSecChainedUpstream

/// The budget, the ladder and the C1 step, driven against a set clock and a recording scheduler.
final class ChainedOutageDriverTests: XCTestCase {


    func testGenuineWakeCapturesForwardingAfterTheSuspendedIntervalAndOnlyOnce() throws {
        for selfHeal in [false, true] {
            let harness = try DriverHarness()
            harness.session.stubStatistics = ChainedRunnerStatistics(transmittedByteCount: 0,
                receivedByteCount: 0, hasHandshake: true, forwardedNonDNSByteCount: 40,
                transportGeneration: 1)
            let initial = harness.driver.snapshotStatusEvidence()
            XCTAssertEqual(initial.verificationEpoch, 1)
            XCTAssertEqual(initial.forwardingBaseline, 0)
            harness.driver.sleep()
            XCTAssertEqual(harness.driver.snapshotStatusEvidence().runtimeCondition, .suspended)
            // A pre-suspension drain can deliver more bytes after sleep() has been requested.
            harness.session.stubStatistics?.forwardedNonDNSByteCount = 65
            if selfHeal {
                harness.driver.confirmSuspensionBoundary()
                harness.driver.handleOutboundBatch([], protocols: [])
            } else {
                harness.driver.wake()
            }
            let resumed = harness.driver.snapshotStatusEvidence()
            XCTAssertEqual(resumed.verificationEpoch, initial.verificationEpoch + 1)
            XCTAssertEqual(resumed.forwardingBaseline, 65)
            XCTAssertEqual(resumed.statistics?.forwardedNonDNSByteCount, 65,
                "Evidence metadata must not reset or fabricate the forwarding tally")
            XCTAssertEqual(resumed.statistics?.setupReady, false)
            harness.driver.wake()
            XCTAssertEqual(harness.driver.snapshotStatusEvidence(), resumed,
                "An unpaired wake must not advance verification or recapture its watermark")
            harness.session.stubStatistics?.forwardedNonDNSByteCount = 66
            let forwarded = try XCTUnwrap(harness.driver.snapshotStatistics())
            XCTAssertEqual(forwarded.forwardedNonDNSByteCount - forwarded.forwardingBaseline, 1)
            harness.driver.sleep()
            harness.driver.wake()
            XCTAssertEqual(harness.driver.snapshotStatusEvidence().verificationEpoch, 3)
            XCTAssertEqual(harness.driver.snapshotStatusEvidence().forwardingBaseline, 66)
        }
    }

    func testVerificationBaselineDoesNotCrossRunnerOrTransportReplacement() throws {
        let harness = try DriverHarness()
        harness.session.stubStatistics = ChainedRunnerStatistics(transmittedByteCount: 0,
            receivedByteCount: 0, hasHandshake: true, forwardedNonDNSByteCount: 100,
            transportGeneration: 1)
        harness.driver.sleep()
        harness.driver.wake()
        XCTAssertEqual(harness.driver.snapshotStatusEvidence().forwardingBaseline, 100)
        harness.session.stubStatistics?.transportGeneration = 2
        harness.session.stubStatistics?.forwardedNonDNSByteCount = 3
        let rebound = try XCTUnwrap(harness.driver.snapshotStatistics())
        XCTAssertEqual(rebound.forwardingBaseline, 0)
        XCTAssertEqual(rebound.forwardedNonDNSByteCount, 3,
            "The first observed positive bytes on a genuinely new transport remain usable")
        let replacement = StubSession()
        replacement.stubStatistics = ChainedRunnerStatistics(transmittedByteCount: 0,
            receivedByteCount: 0, hasHandshake: true, forwardedNonDNSByteCount: 2,
            transportGeneration: 1)
        harness.driver.adopt(replacement)
        let rebuilt = try XCTUnwrap(harness.driver.snapshotStatistics())
        XCTAssertNotEqual(rebuilt.sessionGeneration, rebound.sessionGeneration)
        XCTAssertEqual(rebuilt.forwardingBaseline, 0)
        XCTAssertEqual(rebuilt.forwardedNonDNSByteCount, 2)
    }

    func testMissingWakeBoundaryStatisticsCannotBorrowOldForwardingOnLaterReads() throws {
        let harness = try DriverHarness()
        harness.session.stubStatistics = nil
        harness.driver.sleep()
        harness.driver.wake()
        XCTAssertEqual(harness.driver.snapshotStatusEvidence().runtimeCondition, .recovering)
        harness.session.stubStatistics = ChainedRunnerStatistics(transmittedByteCount: 0,
            receivedByteCount: 0, hasHandshake: true, forwardedNonDNSByteCount: 80,
            transportGeneration: 1)
        let unknownBoundary = try XCTUnwrap(harness.driver.snapshotStatistics())
        XCTAssertEqual(unknownBoundary.runtimeCondition, .recovering)
        XCTAssertEqual(unknownBoundary.forwardingBaseline, UInt64.max)
        XCTAssertFalse(unknownBoundary.setupReady)
        XCTAssertEqual(unknownBoundary.forwardedNonDNSByteCount, 80,
            "Preserve the real tally, but do not claim those bytes belong after an unknown boundary")
        let replacement = StubSession()
        replacement.stubStatistics = ChainedRunnerStatistics(transmittedByteCount: 0,
            receivedByteCount: 0, hasHandshake: true, forwardedNonDNSByteCount: 1,
            transportGeneration: 1)
        harness.driver.adopt(replacement)
        let fresh = try XCTUnwrap(harness.driver.snapshotStatistics())
        XCTAssertEqual(fresh.runtimeCondition, .normal)
        XCTAssertEqual(fresh.forwardingBaseline, 0)
        XCTAssertEqual(fresh.forwardedNonDNSByteCount, 1)
    }

    func testRuntimeConditionSeparatesPendingDemandFromDecisiveInvalidation() throws {
        let harness = try DriverHarness()
        harness.session.stubStatistics = ChainedRunnerStatistics(transmittedByteCount: 0,
            receivedByteCount: 0, hasHandshake: true, transportGeneration: 1)
        let initial = harness.driver.snapshotStatusEvidence()
        XCTAssertEqual(initial.runtimeCondition, .normal)
        XCTAssertEqual(initial.statistics?.setupReady, true)
        harness.session.stubCounters.unansweredDestinationCount = 1
        harness.report(.unanswered(nameKey: 1))
        let pending = harness.driver.snapshotStatusEvidence()
        XCTAssertEqual(pending.runtimeCondition, .normal)
        XCTAssertEqual(pending.verificationEpoch, initial.verificationEpoch)
        XCTAssertEqual(pending.statistics?.setupReady, false,
            "Pending demand withholds first-setup proof without revoking a witnessed milestone")
        harness.driver.pathChanged(satisfied: false, interfacesChanged: false)
        XCTAssertEqual(harness.driver.snapshotStatusEvidence().runtimeCondition, .offline)
        harness.driver.retire()
        let retired = harness.driver.snapshotStatusEvidence()
        XCTAssertEqual(retired.runtimeCondition, .retired)
        XCTAssertNil(retired.statistics)
    }

    func testCoalescedPathTransitionInvalidatesSameTransportProofBeforeItsDeferredSwap() throws {
        let harness = try DriverHarness()
        harness.session.stubStatistics = ChainedRunnerStatistics(transmittedByteCount: 0,
            receivedByteCount: 0, hasHandshake: true, forwardedNonDNSByteCount: 100,
            transportGeneration: 1)
        harness.driver.pathChanged(satisfied: true, interfacesChanged: true)
        XCTAssertEqual(harness.driver.snapshotStatusEvidence().verificationEpoch, 2)
        // Model the real runner's leading successful rebind and subsequent forwarding.
        harness.session.stubStatistics?.transportGeneration = 2
        harness.session.stubStatistics?.forwardedNonDNSByteCount = 41
        harness.session.pretendAuthenticatedPeerDatagram()
        harness.driver.tick()
        let leading = try XCTUnwrap(harness.driver.snapshotStatistics())
        XCTAssertEqual(leading.runtimeCondition, .normal)
        XCTAssertEqual(leading.forwardingBaseline, 0)
        harness.clock.advance(1)
        harness.driver.pathChanged(satisfied: true, interfacesChanged: true)
        let settling = try XCTUnwrap(harness.driver.snapshotStatistics())
        XCTAssertEqual(settling.sessionGeneration, leading.sessionGeneration)
        XCTAssertEqual(settling.transportGeneration, leading.transportGeneration)
        XCTAssertEqual(settling.verificationEpoch, leading.verificationEpoch + 1)
        XCTAssertEqual(settling.forwardingBaseline, 41)
        XCTAssertEqual(settling.forwardedNonDNSByteCount, 41)
        XCTAssertEqual(settling.runtimeCondition, .recovering)
        XCTAssertFalse(settling.setupReady)
        XCTAssertEqual(harness.driver.snapshotCounters().coalescedPathRecoveryCount, 1)
        harness.driver.pathChanged(satisfied: true, interfacesChanged: false)
        XCTAssertEqual(harness.driver.snapshotStatistics(), settling,
            "Repeated satisfied callbacks cannot advance epochs or re-anchor evidence")
        harness.clock.advance(ChainedOutageDriver.pathRecoverySettleSeconds)
        harness.fireDue()
        // The actual trailing replacement starts its own counter incarnation.
        harness.session.stubStatistics?.transportGeneration = 3
        harness.session.stubStatistics?.forwardedNonDNSByteCount = 1
        XCTAssertEqual(harness.driver.snapshotStatistics()?.forwardingBaseline, 0)
    }

    func testOverlappingQuiescenceNeverPublishesNormalReadiness() throws {
        let harness = try DriverHarness()
        harness.session.stubStatistics = ChainedRunnerStatistics(transmittedByteCount: 0,
            receivedByteCount: 0, hasHandshake: true, transportGeneration: 1)
        harness.driver.pathChanged(satisfied: false, interfacesChanged: false)
        XCTAssertEqual(harness.driver.snapshotStatusEvidence().runtimeCondition, .offline)
        harness.driver.sleep()
        XCTAssertEqual(harness.driver.snapshotStatusEvidence().runtimeCondition, .suspended)
        XCTAssertEqual(harness.driver.snapshotStatistics()?.setupReady, false)
        harness.driver.wake()
        XCTAssertEqual(harness.driver.snapshotStatusEvidence().runtimeCondition, .offline,
            "Wake does not clear the independently owned offline latch")
        XCTAssertEqual(harness.driver.snapshotStatistics()?.setupReady, false)
        harness.driver.retire()
        XCTAssertEqual(harness.driver.snapshotStatusEvidence().runtimeCondition, .retired)
        XCTAssertNil(harness.driver.snapshotStatistics())
    }

    func testSetupReadinessUsesCurrentHandshakeTransportDemandAndLifecycle() throws {
        let harness = try DriverHarness()
        func handshake(_ hasHandshake: Bool, transport: UInt64 = 1) {
            harness.session.stubStatistics = ChainedRunnerStatistics(transmittedByteCount: 0,
                receivedByteCount: 0, hasHandshake: hasHandshake, transportGeneration: transport)
        }
        handshake(false)
        XCTAssertEqual(harness.driver.snapshotStatistics()?.setupReady, false)
        handshake(true)
        XCTAssertEqual(harness.driver.snapshotStatistics()?.setupReady, true)
        for transport: UInt64 in [0, 2] {
            handshake(true, transport: transport)
            XCTAssertEqual(harness.driver.snapshotStatistics()?.setupReady, false)
        }
        handshake(true)
        harness.session.stubCounters.unansweredDestinationCount = 1
        XCTAssertEqual(harness.driver.snapshotStatistics()?.setupReady, false)
        harness.session.stubCounters.unansweredDestinationCount = 0
        XCTAssertEqual(harness.driver.snapshotStatistics()?.setupReady, true)
        harness.report(.unanswered(nameKey: 1))
        XCTAssertEqual(harness.driver.snapshotStatistics()?.setupReady, false)
        harness.report(.answered)
        XCTAssertEqual(harness.driver.snapshotStatistics()?.setupReady, true)
        harness.driver.sleep()
        XCTAssertEqual(harness.driver.snapshotStatistics()?.setupReady, false)
    }

    func testPairedWakeDiscardsPreSleepAuthenticationForSetupReadiness() throws {
        for selfHeal in [false, true] {
            let harness = try DriverHarness()
            harness.session.stubStatistics = ChainedRunnerStatistics(transmittedByteCount: 0,
                receivedByteCount: 0, hasHandshake: true, transportGeneration: 1)
            harness.session.pretendAuthenticatedPeerDatagram()
            harness.driver.sleep()
            if selfHeal {
                harness.driver.confirmSuspensionBoundary()
                harness.driver.resumeIfSuspended()
            } else {
                harness.driver.wake()
            }
            harness.driver.tick()
            let stats = try XCTUnwrap(harness.driver.snapshotStatistics())
            XCTAssertTrue(stats.hasHandshake, "The old engine keypair deliberately survives")
            XCTAssertEqual(stats.transportGeneration, 1)
            XCTAssertFalse(stats.setupReady, "A drained pre-sleep response cannot verify the woken path")
        }
    }

    func testWakeHandshakeInitiationAndRepeatedSnapshotsCannotRestoreReadiness() throws {
        let harness = try DriverHarness()
        harness.session.stubStatistics = ChainedRunnerStatistics(transmittedByteCount: 0,
            receivedByteCount: 0, hasHandshake: true, transportGeneration: 1)
        XCTAssertEqual(harness.driver.snapshotStatistics()?.setupReady, true)
        harness.driver.sleep()
        harness.driver.wake()
        for _ in 0..<3 {
            harness.driver.tick()
            XCTAssertEqual(harness.driver.snapshotStatistics()?.setupReady, false,
                "Sending the existing wake handshake is not a reply from the peer")
        }
    }

    func testFreshPostWakePeerEvidenceRestoresSetupWithoutInventingForwarding() throws {
        let harness = try DriverHarness()
        harness.session.stubStatistics = ChainedRunnerStatistics(transmittedByteCount: 0,
            receivedByteCount: 0, hasHandshake: true, transportGeneration: 1)
        harness.driver.sleep()
        harness.driver.wake()
        XCTAssertEqual(harness.driver.snapshotStatistics()?.setupReady, false)
        harness.session.pretendAuthenticatedPeerDatagram()
        harness.driver.tick()
        let stats = try XCTUnwrap(harness.driver.snapshotStatistics())
        XCTAssertTrue(stats.setupReady)
        XCTAssertEqual(stats.forwardedNonDNSByteCount, 0)
        harness.driver.sleep()
        harness.driver.wake()
        XCTAssertEqual(harness.driver.snapshotStatistics()?.setupReady, false,
            "Every paired suspension requires new peer evidence")
        let replacement = StubSession()
        replacement.stubStatistics = ChainedRunnerStatistics(transmittedByteCount: 0,
            receivedByteCount: 0, hasHandshake: true, transportGeneration: 1)
        harness.driver.adopt(replacement)
        XCTAssertEqual(harness.driver.snapshotStatistics()?.setupReady, true,
            "A genuinely new runner does not inherit another runner's wake latch")
    }

    func testUnpairedWakeDoesNotInvalidateVerifiedSetup() throws {
        let harness = try DriverHarness()
        harness.session.stubStatistics = ChainedRunnerStatistics(transmittedByteCount: 0,
            receivedByteCount: 0, hasHandshake: true, transportGeneration: 1)
        harness.driver.wake()
        XCTAssertEqual(harness.driver.snapshotStatistics()?.setupReady, true,
            "A callback without a suspension is not a new evidence epoch")
    }

    func testRecoveryCannotReuseAHandshakeAsIdleSetupEvidence() throws {
        let harness = try DriverHarness()
        harness.beginSilentOutage()
        harness.currentSession.stubStatistics = ChainedRunnerStatistics(transmittedByteCount: 0,
            receivedByteCount: 0, hasHandshake: true, transportGeneration: 1)
        XCTAssertTrue(harness.driver.isTimingAnOutage())
        XCTAssertEqual(harness.driver.snapshotStatistics()?.setupReady, false)
    }

    // MARK: - The finding that shaped this slice

    func testADeadPathReachesTheRetryLadderWithoutWaitingForTheEngine() throws {
        // THE DEFECT THIS SLICE EXISTS TO FIX, and it makes the whole retry apparatus dead code
        // without it.
        //
        // `ChainedAttemptTicket` is minted at exactly one site — inside the supervisor's retry
        // branch — reachable only with a non-nil session end. The watchdog path returns carryOn
        // or surrender and nothing else. And because an authorized deadline is `now + remaining`
        // while the policy guarantees a minimum useful window, the attempt deadline and the
        // outage deadline are the SAME absolute instant, so every watchdog fire lands exactly at
        // exhaustion. On a path that is simply dead the engine reports nothing for far longer
        // than the budget, so the whole budget would be carryOn and then surrender, with ZERO
        // attempts.
        //
        // Here the engine never reports anything: the session is alive as far as it knows, and
        // no session end is ever delivered.
        let harness = try DriverHarness()
        harness.beginSilentOutage()

        XCTAssertTrue(harness.driver.isTimingAnOutage(), "the outage clock never started")
        XCTAssertGreaterThanOrEqual(
            harness.driver.snapshotCounters().startedAttemptCount, 1,
            "the budget was spent without a single handshake being attempted")
    }

    // MARK: - C1

    func testTheWatchdogIsArmedAtTheAuthorizedInstantHoweverLateTheAttemptStarts() throws {
        // Specified at elapsed >= 1 ON PURPOSE. At elapsed 0 an implementation that armed
        // `now + maximumBlackholeSeconds`, or re-read the clock between authorizing and arming,
        // or armed a duration, would be indistinguishable from the correct one.
        let harness = try DriverHarness()
        harness.beginSilentOutage()
        let outageStart = harness.outageStartedAtSeconds

        // Let the retry delay elapse so the attempt starts LATE.
        harness.clock.advance(3)
        harness.fireDue()

        let armed = harness.timers.liveArmedSeconds()
        XCTAssertTrue(
            armed.contains(outageStart + ChainedReconnectPolicy.maximumBlackholeSeconds),
            "nothing is armed at the budget's own instant; armed = \(armed)")
        XCTAssertFalse(
            armed.contains { $0 > outageStart + ChainedReconnectPolicy.maximumBlackholeSeconds },
            "something is armed BEYOND the budget; armed = \(armed)")
    }

    func testAnAttemptIsAlreadyArmedWhenItsSessionBuildFails() throws {
        // Building can throw and the runner's initialiser can return nil — both reachable. If the
        // watchdog were armed after the build, this path would leave an authorized attempt with
        // nothing bounding it and the supervisor's in-flight flag set, so every later
        // authorization would stand down forever.
        let harness = try DriverHarness(provideSessions: false)
        harness.beginSilentOutage()

        let armedWhenAsked = harness.armedCountWhenSessionWasRequested
        XCTAssertGreaterThanOrEqual(
            armedWhenAsked, 2,
            "the session was requested before its watchdog was armed — armed = \(armedWhenAsked)")
    }

    func testASessionThatFailsToBuildSurrendersInsteadOfSpendingARung() throws {
        // WHAT AN UNTRIAGEABLE BUILD FAILURE COSTS, which is the fact every "the ladder will retry
        // it" argument about the transport has to be checked against.
        //
        // It is not a rung. The source here throws `ScriptedSessionSource.Unavailable`, which is
        // not a `ChainedSessionBuildFailure` and therefore carries no transience claim this module
        // can read — so `ChainedSessionEndCause.buildFailure` answers with the conservative
        // `sessionCreationFailed`, and `ChainedReconnectPolicy.decision` classifies that origin as
        // permanent: `.fallBackToDNSOnly(.engineUnusable)`. One such build ends chained mode for
        // the rest of the tunnel lifecycle, whatever is left in the budget.
        //
        // A failure the factory DOES diagnose as transient is the other test below. This one is
        // the floor: an error nobody classified never silently acquires the retry ladder.
        let harness = try DriverHarness(provideSessions: false)
        harness.beginSilentOutage()

        XCTAssertEqual(
            harness.surrenders, [.engineUnusable],
            "a build failure was absorbed rather than surrendered — surrenders = \(harness.surrenders)")
        XCTAssertTrue(harness.driver.hasSurrenderedChaining())

        // The sink is handed the driver's counter snapshot with the reason, so the surrender log can
        // attribute WHICH arm fired even when no 60 s liveness poll lands in the ~36 s window. It must
        // be the driver's real counters — a surrender begins an outage, so outageCount is ≥ 1 (Codex,
        // PR #567). Reading `snapshotCounters()` from the sink itself would deadlock (the sink runs on
        // the engine queue), which is why the value is passed rather than fetched.
        let handed = try XCTUnwrap(harness.lastSurrenderCounters, "the sink got no counter snapshot")
        XCTAssertGreaterThanOrEqual(handed.outageCount, 1, "the surrender's counters must be the live ones")
        XCTAssertEqual(handed.outageCount, harness.driver.snapshotCounters().outageCount)
        XCTAssertEqual(
            harness.source.callCount, 1,
            "a second session was requested, so the failure did buy another rung")
    }

    func testATransientBuildFailureSpendsARungRatherThanSurrendering() throws {
        // THE DEFECT: `ChainedSessionBuildFailure.noEligibleInterface` documents itself as
        // transient — "a handoff has no eligible interface for a moment" — and the factory throws
        // it when `currentInterface` or `currentEndpoint` briefly returns nil during a Wi-Fi to
        // cellular handoff. The driver discarded the error with `try?` and reported
        // `sessionCreationFailed`, which the reconnect policy answers with
        // `.fallBackToDNSOnly(.engineUnusable)` — whose own comment says "a refused construction
        // refuses identically next time". Two comments in the tree contradicted each other and the
        // transient one lost, so one momentary gap between interfaces permanently disabled chained
        // mode for the whole tunnel lifecycle.
        //
        // What it must cost instead: one rung, exactly like a handshake that did not complete.
        let harness = try DriverHarness(provideSessions: false)
        harness.source.pushFailure(ChainedSessionBuildFailure.noEligibleInterface)
        harness.source.push(StubSession())
        harness.beginSilentOutage()

        XCTAssertEqual(
            harness.surrenders, [],
            "a momentary handoff ended chained mode for the lifecycle — surrenders = "
                + "\(harness.surrenders)")
        XCTAssertFalse(harness.driver.hasSurrenderedChaining())
        XCTAssertTrue(harness.driver.isTimingAnOutage(), "the outage clock stopped running")

        // The rung was spent — the attempt was recorded — and the ladder scheduled another. Let
        // its delay elapse.
        harness.clock.advance(2)
        harness.fireDue()
        XCTAssertEqual(
            harness.source.callCount, 2,
            "the transient failure bought no second attempt, so it was not a spent rung either")
        XCTAssertEqual(harness.driver.snapshotCounters().startedAttemptCount, 2)

        // AND THE BUDGET IS THE SAME BUDGET. A rung is not a refund: nothing may be armed past the
        // instant the outage deadline was fixed at, however many builds fail.
        let ceiling = harness.outageStartedAtSeconds + ChainedReconnectPolicy.maximumBlackholeSeconds
        let armed = harness.timers.liveArmedSeconds()
        XCTAssertFalse(
            armed.contains { $0 > ceiling },
            "a transient build failure extended the budget — armed = \(armed), ceiling = \(ceiling)")
    }

    func testTransientBuildFailuresSpendTheBudgetRatherThanExtendIt() throws {
        // The other half of "spends a rung": a build that keeps failing transiently must still
        // reach DNS-only inside `maximumBlackholeSeconds`, and must get there by EXHAUSTING the
        // budget rather than by being re-labelled as an unusable engine. A transient cause that
        // refunded or restarted the outage clock would turn the one bound this whole stack exists
        // to hold into a suggestion — and it would look healthy the entire time, because every
        // individual decision is a legitimate retry.
        let harness = try DriverHarness(provideSessions: false)
        // Far more failures than the budget can pay for. If the ladder ever ran past them the
        // source would start throwing `Unavailable`, which surrenders as `.engineUnusable` — so
        // running out is a visible failure of this test rather than a silent pass.
        for _ in 0..<12 {
            harness.source.pushFailure(ChainedSessionBuildFailure.noEligibleInterface)
        }
        harness.beginSilentOutage()
        let ceiling = harness.outageStartedAtSeconds + ChainedReconnectPolicy.maximumBlackholeSeconds

        for step in 0..<24 {
            harness.clock.advance(1)
            _ = harness.timers.fireDue(atSeconds: harness.clock.currentSeconds, on: harness.engineQueue)
            harness.driver.tick()
            let armed = harness.timers.liveArmedSeconds()
            XCTAssertFalse(
                armed.contains { $0 > ceiling },
                "step \(step): a transient build failure armed something past the budget — \(armed)")
        }

        XCTAssertTrue(
            harness.driver.hasSurrenderedChaining(),
            "transient build failures retried forever — the budget is not bounding anything")
        XCTAssertEqual(
            harness.surrenders, [.budgetExhausted],
            "the ladder ended for a reason other than running out of budget — \(harness.surrenders)")
    }

    func testTheAuthorizeAndArmStepReadsTheClockExactlyOnce() throws {
        // A second reading between authorizing and arming would authorize against one instant
        // and arm for another, and the two would differ by however long the step took.
        let harness = try DriverHarness()
        harness.beginSilentOutage()
        harness.clock.resetReadCount()
        harness.clock.advance(2)
        harness.fireDue()

        XCTAssertLessThanOrEqual(
            harness.clock.readCount, 2,
            "the attempt step read the clock \(harness.clock.readCount) times")
    }

    // MARK: - The bound

    func testSomethingIsAlwaysArmedInsideTheBudgetAndNothingBeyondIt() throws {
        // `INV-CHAIN-3`, walked rather than asserted at one point. After EVERY step: if an
        // outage is being timed and nothing has surrendered, at least one deadline is armed, and
        // no armed instant is past the budget.
        //
        // This walk never suspends, so it never enters the exemption — the suspended case is
        // walked by `testTheSuspensionExemptionIsBoundedByTheWakeThatFollowsIt` instead, and
        // keeping them separate is deliberate: folding a `!isSuspended` term into this loop
        // would weaken the property it is here to hold.
        let harness = try DriverHarness()
        harness.beginSilentOutage()
        let ceiling = harness.outageStartedAtSeconds + ChainedReconnectPolicy.maximumBlackholeSeconds

        for step in 0..<24 {
            harness.clock.advance(1)
            _ = harness.timers.fireDue(atSeconds: harness.clock.currentSeconds, on: harness.engineQueue)
            harness.driver.tick()

            let armed = harness.timers.liveArmedSeconds()
            if harness.driver.hasSurrenderedChaining() {
                XCTAssertTrue(armed.isEmpty, "step \(step): armed after surrender — \(armed)")
                XCTAssertNil(
                    harness.timers.currentTickInterval, "step \(step): the tick survived surrender")
                XCTAssertEqual(harness.surrenders.count, 1, "step \(step): surrendered more than once")
            } else if harness.driver.isTimingAnOutage() {
                XCTAssertFalse(armed.isEmpty, "step \(step): an outage with nothing armed")
                XCTAssertFalse(
                    armed.contains { $0 > ceiling },
                    "step \(step): armed past the budget — \(armed)")
            }
        }
        XCTAssertTrue(
            harness.driver.hasSurrenderedChaining(),
            "a permanently dead path never surrendered — the budget is not bounding anything")
    }

    func testARetiredAttemptTakesItsWatchdogWithIt() throws {
        // A retire that forgets the watchdog leaves a timer armed for the old attempt's deadline
        // — and that instant is the budget's own, so it fires into a tunnel that has been
        // healthy for seconds and surrenders it. `DispatchSource.cancel()` is the only thing
        // that stops it; nothing else in the driver would notice.
        let harness = try DriverHarness()
        harness.beginSilentOutage()
        XCTAssertFalse(
            harness.timers.liveArmedSeconds().isEmpty, "no attempt was armed to retire")

        // The path recovers, so the outage ends and the attempt is retired.
        harness.currentSession.pretendAuthenticatedPeerDatagram()
        harness.clock.advance(1)
        harness.driver.tick()
        XCTAssertFalse(harness.driver.isTimingAnOutage())

        XCTAssertTrue(
            harness.timers.liveArmedSeconds().isEmpty,
            "a retired attempt left its watchdog armed — \(harness.timers.liveArmedSeconds())")

        // And if one somehow fires anyway, it must not surrender a tunnel that recovered.
        harness.clock.advance(ChainedReconnectPolicy.maximumBlackholeSeconds + 5)
        harness.fireDue()
        XCTAssertFalse(
            harness.driver.hasSurrenderedChaining(),
            "a stale watchdog surrendered a recovered tunnel")
    }

    // MARK: - Liveness

    func testInboundDataEndsAnOutageWithoutARekey() throws {
        // Recovery is the inverse of detection: data in, not a handshake. Defining it as "a
        // handshake completed" would be wrong twice — that value is session age rather than
        // evidence, so a path healing WITHOUT a rekey never ends the outage, and it is
        // denominated on the engine's clock, which cannot be compared against this one.
        let harness = try DriverHarness()
        harness.beginSilentOutage()
        XCTAssertTrue(harness.driver.isTimingAnOutage())

        harness.currentSession.pretendAuthenticatedPeerDatagram()
        harness.clock.advance(1)
        harness.driver.tick()

        XCTAssertFalse(
            harness.driver.isTimingAnOutage(),
            "inbound data did not end the outage — recovery is keyed on the wrong evidence")
    }

    func testAnAmbiguousSampleReadsAsAnswered() throws {
        // Within one sample window there is no way to order a send against an answer. Set-then-
        // clear makes an ambiguous window read as ANSWERED, which is the false-negative-leaning
        // tie-break: it costs at most one sample of arming delay, and only while the peer is
        // answering — which is to say only while the link works. Clearing first would arm the
        // clock on a window in which the peer did reply.
        let harness = try DriverHarness()
        harness.currentSession.pretendObligingSend()
        harness.currentSession.pretendAuthenticatedPeerDatagram()
        harness.driver.tick()
        harness.clock.advance(ChainedOutageDriver.linkSilenceThresholdSeconds + 5)
        harness.driver.tick()

        XCTAssertFalse(
            harness.driver.isTimingAnOutage(),
            "a sample containing both a send and an answer armed the silence clock")
    }

    func testASilentDestinationCannotForceAnOutage() throws {
        // THE ATTACK THIS REDESIGN CLOSES. A destination that silently drops SYNs produces
        // outbound retransmissions for far longer than any threshold, with nothing coming back
        // from it — and under the previous predicate (data silence plus current demand) that was
        // enough to tear down a healthy session and spend the whole budget. Any web page could
        // do it.
        //
        // The link is fine throughout: the peer keeps answering, which is evidence no remote
        // party can manufacture.
        let harness = try DriverHarness()

        for _ in 0..<12 {
            harness.currentSession.pretendObligingSend()      // the retransmissions
            harness.currentSession.pretendAuthenticatedPeerDatagram()  // the peer is alive
            harness.driver.tick()
            harness.clock.advance(5)
        }

        XCTAssertFalse(
            harness.driver.isTimingAnOutage(),
            "a silent destination tore down a working tunnel")
        XCTAssertFalse(harness.driver.hasSurrenderedChaining())
    }

    func testAnUnansweredObligingSendDoesDeclareAnOutage() throws {
        // THE ANTI-VACUITY PAIR. Without it, a predicate that never declares anything passes the
        // test above identically — and the fault this feature exists to bound would go
        // undetected forever.
        let harness = try DriverHarness()
        harness.currentSession.pretendObligingSend()
        harness.driver.tick()
        harness.clock.advance(ChainedOutageDriver.linkSilenceThresholdSeconds + 1)
        harness.driver.tick()

        XCTAssertTrue(
            harness.driver.isTimingAnOutage(),
            "an obliging send went unanswered past the threshold and nothing noticed")
    }

    func testAWedgedTransportDeclaresAnOutageWithoutASingleObligingSend() throws {
        // THE ONE STATE THE SEND-BASED PREDICATE CANNOT SEE. A transport at its send bound
        // parks every outbound packet (`ChainedSessionRunner.encapsulateOnQueue`), so no
        // obliging send is ever issued, `firstUnansweredSendAtSeconds` never arms, and the
        // engine — never obliged either — reports nothing. Without the saturation arm a wedged
        // socket blackholes `0.0.0.0/0` with no clock running, permanently, and deleting that
        // arm is invisible to every other test in this file.
        let harness = try DriverHarness()

        // Saturation is a LEVEL, re-read at every sample — the runner reports it from
        // `outstandingSends` at sample time and the stub resets on take — so the wedge is
        // asserted per tick, exactly as production delivers it.
        harness.currentSession.pretendChannelSaturated()
        harness.driver.tick()
        XCTAssertFalse(
            harness.driver.isTimingAnOutage(), "saturation declared before the threshold")

        harness.clock.advance(ChainedOutageDriver.linkSilenceThresholdSeconds + 1)
        harness.currentSession.pretendChannelSaturated()
        harness.driver.tick()

        XCTAssertTrue(
            harness.driver.isTimingAnOutage(),
            "a transport at its send bound for the full threshold declared nothing — the "
                + "wedge arm is dead and a wedged socket blackholes with no clock running")
    }

    func testASaturationThatDrainsBeforeTheThresholdRestartsTheClock() throws {
        // The wedge clock measures ONE CONTINUOUS saturation, cleared the moment a sample
        // shows the transport taking bytes again. A latch here would accumulate disjoint
        // bursts of ordinary back-pressure into a phantom threshold and tear down a link that
        // is merely busy — the same class of false positive the silent-destination redesign
        // exists to refuse.
        let harness = try DriverHarness()

        harness.currentSession.pretendChannelSaturated()
        harness.driver.tick()
        harness.clock.advance(ChainedOutageDriver.linkSilenceThresholdSeconds - 5)
        // A sample with the bound clear: the transport drained.
        harness.driver.tick()

        // A second, separate saturation. Its clock must start HERE, not inherit the first
        // burst's start.
        harness.clock.advance(30)
        harness.currentSession.pretendChannelSaturated()
        harness.driver.tick()
        harness.clock.advance(ChainedOutageDriver.linkSilenceThresholdSeconds - 1)
        harness.currentSession.pretendChannelSaturated()
        harness.driver.tick()
        XCTAssertFalse(
            harness.driver.isTimingAnOutage(),
            "two separate saturations were accumulated into one — the wedge clock latched")

        // THE ANTI-VACUITY HALF: the same continuous saturation carried past the threshold
        // does declare. Without it, a wedge arm that never fires passes the assert above
        // identically.
        harness.clock.advance(2)
        harness.currentSession.pretendChannelSaturated()
        harness.driver.tick()
        XCTAssertTrue(
            harness.driver.isTimingAnOutage(),
            "a continuous saturation was reset by its own re-assertion — the clock is not "
                + "measuring from when the wedge began")
    }

    func testTheLinkSilenceThresholdSitsBetweenTheEnginesOwnTimers() {
        // Derived, not chosen. The floor is the engine's own grounds for a fresh handshake
        // (KEEPALIVE_TIMEOUT + REKEY_TIMEOUT = 15 s) plus one REKEY_TIMEOUT so that handshake
        // survives a lost datagram; declaring earlier pre-empts the recovery the engine is
        // already attempting. The ceiling is REKEY_ATTEMPT_TIME, where the engine reports
        // connectionExpired itself and a clock starts anyway.
        XCTAssertGreaterThanOrEqual(
            ChainedOutageDriver.linkSilenceThresholdSeconds, 21,
            "declaring before the engine's own handshake attempt pre-empts its recovery")
        XCTAssertLessThan(
            ChainedOutageDriver.linkSilenceThresholdSeconds, 90,
            "at or past REKEY_ATTEMPT_TIME the engine reports the fault itself — this is dead code")
    }

    func testSilenceWithoutDemandIsNotAnOutage() throws {
        // An idle tunnel is not a fault. Without the demand half, a device sitting untouched
        // would blackhole-detect itself and spend the budget.
        let harness = try DriverHarness()
        harness.clock.advance(ChainedOutageDriver.linkSilenceThresholdSeconds + 5)
        harness.driver.tick()

        XCTAssertFalse(
            harness.driver.isTimingAnOutage(),
            "an idle tunnel declared itself to be in an outage")
    }

    func testWakingEndsTheOutageAndDiscardsStaleLiveness() throws {
        // Sleeping past the midpoint of an outage would otherwise surrender on wake without a
        // handshake: the elapsed time is already too large for the policy to authorize a useful
        // attempt, so the first decision after waking is to fall back. A permanent downgrade, on
        // a network the device has not tried yet.
        let harness = try DriverHarness()
        harness.beginSilentOutage()
        XCTAssertTrue(harness.driver.isTimingAnOutage())

        harness.clock.advance(9)
        // Inbound data the runner LATCHED but nobody sampled, which is the state a device
        // actually sleeps in — the sample is a level, not an edge.
        harness.currentSession.pretendAuthenticatedPeerDatagram()

        harness.driver.sleep()
        harness.clock.advance(30_000)
        harness.driver.wake()

        XCTAssertFalse(harness.driver.isTimingAnOutage(), "the outage survived a sleep")
        XCTAssertFalse(harness.driver.hasSurrenderedChaining(), "waking surrendered")

        // The credit must be gone on BOTH sides. If `wake()` reset only its own instants and
        // left the runner's latched sample, the very next tick would consume it and read a peer
        // that has been unreachable for eight hours as proof the tunnel is fine.
        // Arm a fresh unanswered send, then let the threshold pass. If `wake()` had left the
        // runner's latched sample in place, the very next tick would consume it and clear the
        // clock — reading a peer that has been unreachable for eight hours as proof of life.
        harness.currentSession.pretendObligingSend()
        harness.driver.tick()
        harness.clock.advance(ChainedOutageDriver.linkSilenceThresholdSeconds + 1)
        harness.driver.tick()
        XCTAssertTrue(
            harness.driver.isTimingAnOutage(),
            "post-wake silence was excused by liveness latched before the sleep")
    }

    // MARK: - Tick

    func testTheTickRunsFastOnlyInsideAnOutageAndStopsWithoutARunner() throws {
        let harness = try DriverHarness()
        XCTAssertEqual(
            harness.timers.currentTickInterval, ChainedOutageDriver.establishedTickInterval,
            "an established session is not being pumped at the established cadence")

        harness.beginSilentOutage()
        XCTAssertEqual(
            harness.timers.currentTickInterval, ChainedOutageDriver.outageTickInterval,
            "an outage did not raise the cadence")

        harness.driver.sleep()
        XCTAssertNil(harness.timers.currentTickInterval, "the tick survived a sleep")
    }

    func testTheTickCadenceClearsTheRateLimiterFloor() {
        // Asserted as an inequality against the constant rather than as a magic number, so a
        // change to the interval has to argue with the reason rather than with a literal.
        guard case .milliseconds(let established) = ChainedOutageDriver.establishedTickInterval else {
            return XCTFail("the established cadence is no longer expressed in milliseconds")
        }
        XCTAssertLessThanOrEqual(
            established, 500,
            "at more than 500 ms a single deferred fire doubles the engine's rate-limiter window")
        guard case .milliseconds(let fast) = ChainedOutageDriver.outageTickInterval else {
            return XCTFail("the outage cadence is no longer expressed in milliseconds")
        }
        XCTAssertLessThan(fast, established, "the outage cadence is not faster than the idle one")
    }

    func testTheTickIsCancelledRatherThanSuspended() throws {
        // Releasing a suspended `DispatchSourceTimer` traps, and a trap in the extension is a
        // tunnel abort. The fake records a suspend if one ever happens.
        let harness = try DriverHarness()
        harness.driver.sleep()
        harness.driver.wake()
        XCTAssertFalse(harness.timers.suspendWasCalled, "the tick was suspended rather than cancelled")
    }

    func testAPreSuspensionBatchIsNotMistakenForAResume() throws {
        // THE WINDOW (Codex P1, PR #581). `sleep()` latches `isSuspended`, but the process keeps
        // RUNNING: the provider then drains the event log — its own comment bounds that at roughly
        // four seconds — before signalling the sleep completion. Packet-flow callbacks still
        // arrive in there, and the self-heal read one as proof of a resume: it cleared the latch,
        // forced a handshake and re-armed the timers moments before iOS actually suspended. The
        // real wake then looked unpaired, and the re-armed timers could run and SURRENDER, which
        // is unrecoverable and is precisely what quiescing them was for.
        let harness = try DriverHarness()
        let handshakesBefore = harness.currentSession.forcedHandshakeCount

        harness.driver.sleep()
        XCTAssertTrue(harness.driver.snapshotCounters().isSuspended)

        // A batch inside the pre-suspension window: proof the process is executing, which it
        // legitimately is, and NOT proof it resumed.
        harness.driver.handleOutboundBatch([Data([0x45, 0x00])], protocols: [NSNumber(value: 2)])

        XCTAssertTrue(
            harness.driver.snapshotCounters().isSuspended,
            "a pre-suspension batch cleared the latch — the process had not resumed")
        XCTAssertNil(
            harness.timers.currentTickInterval,
            "the timers were re-armed before iOS suspended, undoing the quiescence")
        XCTAssertEqual(
            harness.currentSession.forcedHandshakeCount, handshakesBefore,
            "a handshake was forced into a suspension that had not happened yet")
        XCTAssertEqual(harness.driver.snapshotCounters().selfHealResumeCount, 0)

        // PAST the boundary, the same batch IS proof: a suspended process runs nothing, so
        // execution here means the sleep went unpaired and the self-heal must fire.
        harness.driver.confirmSuspensionBoundary()
        harness.driver.handleOutboundBatch([Data([0x45, 0x00])], protocols: [NSNumber(value: 2)])

        XCTAssertFalse(
            harness.driver.snapshotCounters().isSuspended,
            "past the boundary an executing process is a resume, and the self-heal must fire")
        XCTAssertEqual(harness.driver.snapshotCounters().selfHealResumeCount, 1)
    }

    func testResumeIfSuspendedRecoversAnUnpairedSleep() throws {
        // Field 2026-08-24: iOS delivers sleep() but no paired wake(), and the disarmed tick never
        // re-arms — the tunnel is dark (engine unpumped, detectors frozen) until a manual re-chain.
        // resumeIfSuspended() is the self-heal: proof-of-life while still suspended recovers it
        // exactly as a paired wake would (re-arm tick + force a handshake to re-anchor the session).
        let harness = try DriverHarness()
        let handshakesBefore = harness.currentSession.forcedHandshakeCount

        harness.driver.sleep()
        XCTAssertNil(harness.timers.currentTickInterval, "sleep did not disarm the tick")
        XCTAssertTrue(harness.driver.snapshotCounters().isSuspended, "sleep did not latch isSuspended")

        // The provider signals this after its pre-suspension drain, immediately before the sleep
        // completion. Modelled here because the self-heal is fenced on it — see
        // `testAPreSuspensionBatchIsNotMistakenForAResume` for why (Codex P1, PR #581).
        harness.driver.confirmSuspensionBoundary()
        harness.driver.resumeIfSuspended()
        XCTAssertFalse(
            harness.driver.snapshotCounters().isSuspended, "the self-heal did not clear isSuspended")
        XCTAssertNotNil(harness.timers.currentTickInterval, "the self-heal did not re-arm the tick")
        XCTAssertEqual(
            harness.currentSession.forcedHandshakeCount, handshakesBefore + 1,
            "the self-heal did not force a handshake to re-anchor the stale session")
        XCTAssertEqual(harness.driver.snapshotCounters().selfHealResumeCount, 1)

        // Idempotent: a call on an already-resumed driver is a no-op (no double-count, no churn).
        harness.driver.resumeIfSuspended()
        XCTAssertEqual(
            harness.driver.snapshotCounters().selfHealResumeCount, 1,
            "resumeIfSuspended acted while the driver was not suspended")
    }

    func testHandleOutboundBatchWhileSuspendedSelfHeals() throws {
        // The user's first packet after an unpaired resume must recover the tunnel instantly, not
        // blackhole behind a handshake the disarmed tick will never complete.
        let harness = try DriverHarness()
        harness.driver.sleep()
        XCTAssertTrue(harness.driver.snapshotCounters().isSuspended)
        // Past the suspension boundary: the provider has signalled the sleep completion, so from
        // here execution really is proof of a resume. Before it, it is not — see
        // `testAPreSuspensionBatchIsNotMistakenForAResume` (Codex P1, PR #581).
        harness.driver.confirmSuspensionBoundary()

        harness.driver.handleOutboundBatch([Data([1])], protocols: [NSNumber(value: AF_INET)])

        XCTAssertFalse(
            harness.driver.snapshotCounters().isSuspended,
            "an outbound batch did not self-heal an unpaired sleep")
        XCTAssertEqual(harness.driver.snapshotCounters().selfHealResumeCount, 1)
        XCTAssertNotNil(harness.timers.currentTickInterval, "the self-heal did not re-arm the tick")
    }

    func testASecondOutageReachesTheLadderToo() throws {
        // The first fix was only a first-outage fix. The supervisor accepts a RECEIPT-LESS end
        // only while nothing has ever been authorized — once in its lifetime, not once per
        // outage — so once the first outage authorizes anything, every later synthesized end is
        // rejected and the ladder is exactly as dead as it was before this slice existed.
        //
        // No test here walked a second outage, which is why the gap survived the first round.
        let harness = try DriverHarness()
        harness.beginSilentOutage()
        let afterFirst = harness.driver.snapshotCounters().startedAttemptCount
        XCTAssertGreaterThanOrEqual(afterFirst, 1, "the first outage made no attempt")

        // The path recovers.
        harness.currentSession.pretendAuthenticatedPeerDatagram()
        harness.clock.advance(1)
        harness.driver.tick()
        XCTAssertFalse(harness.driver.isTimingAnOutage())

        // ...and blackholes again.
        harness.currentSession.pretendObligingSend()
        harness.driver.tick()
        harness.clock.advance(ChainedOutageDriver.linkSilenceThresholdSeconds + 1)
        harness.currentSession.pretendObligingSend()
        harness.driver.tick()
        harness.clock.advance(2)
        harness.fireDue()

        XCTAssertEqual(harness.driver.snapshotCounters().outageCount, 2, "the second outage never began")
        XCTAssertGreaterThan(
            harness.driver.snapshotCounters().startedAttemptCount, afterFirst,
            "the second outage spent its budget without attempting a handshake")
    }

    func testASessionDyingOutsideAnOutageStartsOne() throws {
        // An idle rekey expiring, or the first tick after a long sleep, reports a session end
        // while nothing is being timed. The supervisor guards `action` on an active outage, so
        // it answers carryOn — and by then the runner has been shut down and the tick cancelled,
        // so no later liveness sample can start one either. A permanent blackhole assembled out
        // of two correct-looking pieces.
        let harness = try DriverHarness()
        XCTAssertFalse(harness.driver.isTimingAnOutage())

        guard let expired = ChainedSessionEndCause(.reconnect(reason: .connectionExpired)) else {
            return XCTFail("the validated door refused a cause the policy produces")
        }
        harness.engineQueue.run { harness.driver.sessionEnded(expired) }

        XCTAssertTrue(
            harness.driver.isTimingAnOutage(),
            "a session died outside an outage and nothing started one — the tunnel is now silent "
                + "with no clock running")
        XCTAssertFalse(
            harness.timers.liveArmedSeconds().isEmpty, "nothing is bounding the resulting outage")
    }

    func testAWakeWithNoPairedSleepDoesNotRefundTheBudget() throws {
        // The provider delivers wakes that were never preceded by a suspension this driver saw.
        // An unpaired one is not evidence of a user-invisible interval, and refunding on it lets
        // repeated wakes extend the blackhole past the bound the budget exists to be.
        let harness = try DriverHarness()
        harness.beginSilentOutage()
        XCTAssertTrue(harness.driver.isTimingAnOutage())

        harness.clock.advance(3)
        harness.driver.wake()  // no sleep() before it

        XCTAssertTrue(
            harness.driver.isTimingAnOutage(),
            "an unpaired wake refunded the budget — the blackhole can now be extended at will")
    }

    func testASessionDyingOutsideAnOutageAfterAnEarlierOneStillAttempts() throws {
        // `testASessionDyingOutsideAnOutageStartsOne` proved the CLOCK starts and stopped there,
        // and a fresh harness is exactly the state where a receipt-less end is accepted — once
        // per supervisor lifetime. Production reaches this line having already authorized
        // something, and then the end was refused: the clock ran with no attempt scheduled and
        // the budget expired into a surrender, while every counter about outages looked right.
        //
        // So the walk has to be: outage, recover, THEN die outside an outage.
        let harness = try DriverHarness()
        harness.beginSilentOutage()
        let afterFirst = harness.driver.snapshotCounters().startedAttemptCount
        XCTAssertGreaterThanOrEqual(afterFirst, 1, "the first outage made no attempt")

        harness.currentSession.pretendAuthenticatedPeerDatagram()
        harness.clock.advance(1)
        harness.driver.tick()
        XCTAssertFalse(harness.driver.isTimingAnOutage(), "the outage did not end")

        guard let expired = ChainedSessionEndCause(.reconnect(reason: .connectionExpired)) else {
            return XCTFail("the validated door refused a cause the policy produces")
        }
        harness.clock.advance(30)
        harness.engineQueue.run { harness.driver.sessionEnded(expired) }
        XCTAssertTrue(harness.driver.isTimingAnOutage(), "the session death started no outage")

        // The ladder must have been reached, which means an attempt was scheduled — let its
        // delay elapse and check one actually started.
        harness.clock.advance(2)
        harness.fireDue()
        XCTAssertGreaterThan(
            harness.driver.snapshotCounters().startedAttemptCount, afterFirst,
            "the end was refused for want of a receipt: clock running, ladder dead, and the "
                + "budget now counting down to a surrender with zero handshakes tried")
    }

    func testAnUnpairedWakeDoesNotPostponeDetection() throws {
        // The resets used to run before the pairing check, so a wake the driver never saw a
        // sleep for — "just a callback", in the code's own words — cleared the silence clock
        // that was most of the way to declaring. Wakes arriving oftener than the threshold
        // postpone detection forever, which is the same "extend the blackhole at will" the
        // refund rule exists to prevent, through the door beside it.
        let harness = try DriverHarness()
        harness.session.pretendObligingSend()
        harness.driver.tick()

        // Most of the way to the threshold...
        harness.clock.advance(ChainedOutageDriver.linkSilenceThresholdSeconds - 1)
        harness.driver.wake()  // no sleep() before it
        // ...and past it.
        harness.clock.advance(2)
        harness.driver.tick()

        XCTAssertTrue(
            harness.driver.isTimingAnOutage(),
            "an unpaired wake reset the silence clock — detection is postponed by a callback")
    }

    // MARK: - Transport rebind (R2)

    /// A path change outside an outage swaps the SOCKET, not the session.
    ///
    /// The whole value of R2. R1's recovery ran `beginOutage` → `startOutageClock` (which nulls
    /// the runner) → an armed RETRY DELAY before a session is even built → the build → a
    /// handshake, and spent one of roughly three ladder rungs the 15-second budget buys. The
    /// fast path costs none of that.
    func testAPathChangeOutsideAnOutageRebindsRatherThanRebuilding() throws {
        let harness = try DriverHarness()
        let adopted = harness.currentSession
        let shutdownsBefore = adopted.shutdownCount

        harness.driver.pathChanged(satisfied: true, interfacesChanged: true)

        XCTAssertEqual(adopted.adoptedChannelCount, 1, "the transport was not replaced")
        XCTAssertEqual(
            adopted.shutdownCount, shutdownsBefore,
            "the session was torn down for a socket change — that spends a ladder rung and a "
                + "handshake to fix something only the socket was wrong about")
        XCTAssertFalse(
            harness.driver.isTimingAnOutage(),
            "a rebind opened an outage; the fast path exists precisely to avoid one")
        XCTAssertEqual(harness.driver.snapshotCounters().rebindCount, 1)
    }

    /// A flap burst builds ONE socket at its leading edge and ONE more when the window ends —
    /// never one per callback (C5).
    ///
    /// The failure this bounds: every `NWPathMonitor` callback rebuilt the socket, so a burst
    /// closed each newly advertised source port before the peer's replies could arrive, and
    /// the supervisor never saw it because no session ends. The clock is STEPPED through the
    /// burst so a debounce mutant — one that re-arms the trailing deadline per coalesced
    /// transition — fails here too: under a continuing flap a pushed-out deadline never fires,
    /// and the burst's final path never gets its socket.
    func testAFlapBurstBuildsOneSocketNowAndOneAtTheWindowEnd() throws {
        let harness = try DriverHarness()

        harness.driver.pathChanged(satisfied: true, interfacesChanged: true)
        // Confirm the leading rebind, so the only timer left due at the window's end is the
        // trailing recovery — an unconfirmed rebind falling back is its own test.
        harness.session.pretendAuthenticatedPeerDatagram()
        harness.driver.tick()

        for _ in 0..<2 {
            harness.clock.advance(1)
            harness.driver.pathChanged(satisfied: true, interfacesChanged: true)
        }

        var counters = harness.driver.snapshotCounters()
        XCTAssertEqual(counters.rebindCount, 1, "the burst ran the socket work per callback")
        XCTAssertEqual(harness.source.madeChannelCount, 1)
        XCTAssertEqual(counters.coalescedPathRecoveryCount, 2)
        XCTAssertEqual(counters.pathRecoveryCount, 3, "observations must stay per-transition")

        // The window ends relative to the LEADING recovery, however long the flapping went on.
        harness.clock.advance(1)
        harness.fireDue()

        counters = harness.driver.snapshotCounters()
        XCTAssertEqual(
            counters.rebindCount, 2,
            "the burst's final path never got its socket — the trailing recovery is what "
                + "keeps the settle window from trading a churn bug for a stale-socket one")
        XCTAssertEqual(harness.source.madeChannelCount, 2)
        XCTAssertFalse(harness.driver.isTimingAnOutage())
    }

    /// A burst that ends with the path going away cancels the pending trailing recovery.
    ///
    /// The companion case: firing the deferred rebuild onto a dead path is the one thing the
    /// settle window must not add. Defence runs in layers — the offline teardown cancels and
    /// clears the slot, the fire guard checks the quiesce latch, and the serial rejects a
    /// stale delivery — because each covers a sequence the others cannot (a due fire under a
    /// missing cancel, a delivery already enqueued at teardown, a re-armed slot).
    func testABurstThatEndsOfflineDoesNotFireTheTrailingRecovery() throws {
        let harness = try DriverHarness()

        harness.driver.pathChanged(satisfied: true, interfacesChanged: true)
        harness.session.pretendAuthenticatedPeerDatagram()
        harness.driver.tick()
        harness.clock.advance(1)
        harness.driver.pathChanged(satisfied: true, interfacesChanged: true)
        let settleSerial = try XCTUnwrap(harness.timers.allArmedSerials().last)

        harness.driver.pathChanged(satisfied: false, interfacesChanged: true)

        // Both delivery shapes: the due fire (skips a cancelled timer) and the
        // already-enqueued delivery a cancel cannot retract (rejected by the cleared slot).
        harness.clock.advance(ChainedOutageDriver.pathRecoverySettleSeconds + 1)
        harness.fireDue()
        _ = harness.timers.fireAlreadyDelivered(serial: settleSerial, on: harness.engineQueue)

        XCTAssertEqual(
            harness.source.madeChannelCount, 1,
            "the trailing recovery ran onto a path that is gone")
        XCTAssertFalse(harness.driver.isTimingAnOutage(), "a rebuild opened an outage offline")
    }

    /// An unconfirmed leading rebind falls back before the trailing recovery can supersede it.
    ///
    /// The confirmation and the trailing timer share one interval measured from the same
    /// instant, and dispatch does not order two independent sources due together. The
    /// trailing fire landing first would cancel the still-pending confirmation inside
    /// `attemptRebind` and grant the next socket a fresh three-second window — a dead path
    /// claimed for six seconds instead of three, indefinitely under a continuing burst
    /// (Codex, PR #504). The harness fires the trailing timer FIRST deliberately: it is the
    /// adversarial order.
    func testAnUnconfirmedLeadingRebindFallsBackBeforeTheTrailingRecovery() throws {
        let harness = try DriverHarness()

        harness.driver.pathChanged(satisfied: true, interfacesChanged: true)
        XCTAssertEqual(harness.driver.snapshotCounters().rebindCount, 1)
        let confirmationSerial = try XCTUnwrap(harness.timers.allArmedSerials().last)
        harness.clock.advance(1)
        harness.driver.pathChanged(satisfied: true, interfacesChanged: true)

        // Both timers due; `fireDue` picks the LAST armed — the trailing recovery.
        harness.clock.advance(ChainedOutageDriver.pathRecoverySettleSeconds)
        harness.fireDue()

        // The confirmation is CANCELLED, not merely dropped: a cleared slot leaves a source
        // that wakes the engine queue only to be rejected by its own serial guard.
        XCTAssertFalse(
            harness.timers.liveArmed.contains { $0.serial == confirmationSerial },
            "the resolved confirmation is still armed — a wake with nothing to decide")

        XCTAssertTrue(
            harness.driver.isTimingAnOutage(),
            "the trailing recovery superseded a socket that never proved itself — the "
                + "confirmation deadline was cancelled instead of resolved")
        XCTAssertEqual(harness.driver.snapshotCounters().rebindUnconfirmedCount, 1)
        XCTAssertEqual(
            harness.driver.snapshotCounters().rebindCount, 1,
            "an unproven socket was replaced by another unproven socket")
    }

    /// Evidence latched when the trailing fire runs still confirms the LEADING socket.
    ///
    /// The counterpart: an answer that arrived before the swap belongs to the socket that
    /// carried it, exactly as `rebindUnconfirmed` credits it — the resolve-first rule must
    /// not turn late-but-valid evidence into a false fallback.
    func testEvidenceLatchedByTheTrailingFireStillConfirmsTheLeadingRebind() throws {
        let harness = try DriverHarness()

        harness.driver.pathChanged(satisfied: true, interfacesChanged: true)
        harness.clock.advance(1)
        harness.driver.pathChanged(satisfied: true, interfacesChanged: true)

        // The peer answers on the leading socket; nothing has sampled it yet.
        harness.session.pretendAuthenticatedPeerDatagram()

        harness.clock.advance(ChainedOutageDriver.pathRecoverySettleSeconds)
        harness.fireDue()

        XCTAssertFalse(
            harness.driver.isTimingAnOutage(),
            "evidence that confirmed the leading socket was read as an unconfirmed rebind")
        XCTAssertEqual(harness.driver.snapshotCounters().rebindUnconfirmedCount, 0)
        XCTAssertEqual(
            harness.driver.snapshotCounters().rebindCount, 2,
            "the trailing recovery must still run once the confirmation is resolved")
    }

    /// Evidence latched on the outgoing socket cannot certify the trailing rebind.
    ///
    /// The per-transition semantics drain the stale sample, but the deferred recovery runs
    /// seconds later — a peer answer arriving on the leading-edge socket in between stays
    /// latched in the runner, and the first tick after the swap would read it as evidence
    /// on the NEW socket, cancel the confirmation, and falsely certify a socket that never
    /// carried a byte (Codex, PR #504 round 2). The deferred recovery drains first, so a
    /// dead final-path socket falls back through the confirmation deadline as designed.
    func testStaleEvidenceCannotCertifyTheTrailingRebind() throws {
        let harness = try DriverHarness()

        harness.driver.pathChanged(satisfied: true, interfacesChanged: true)
        harness.session.pretendAuthenticatedPeerDatagram()
        harness.driver.tick()
        harness.clock.advance(1)
        harness.driver.pathChanged(satisfied: true, interfacesChanged: true)

        // The peer answers on the OUTGOING socket after the last transition, before the
        // trailing fire — latched in the runner, drained by nothing per-transition.
        harness.session.pretendAuthenticatedPeerDatagram()

        harness.clock.advance(ChainedOutageDriver.pathRecoverySettleSeconds)
        harness.fireDue()
        XCTAssertEqual(harness.driver.snapshotCounters().rebindCount, 2)

        // The first tick after the swap must NOT confirm from the stale sample.
        harness.driver.tick()

        // No evidence ever arrives on the new socket. The trailing rebind is now a LONE one (the
        // burst's settle recovery already fired and cleared), so its first miss spends the one
        // re-anchor retry; only the second miss falls back.
        harness.clock.advance(ChainedOutageDriver.rebindConfirmationSeconds + 1)
        harness.fireDue()
        XCTAssertFalse(harness.driver.isTimingAnOutage())
        XCTAssertEqual(harness.driver.snapshotCounters().rebindReanchorRetryCount, 1)

        harness.clock.advance(ChainedOutageDriver.rebindReanchorRetrySeconds)
        harness.fireDue()
        XCTAssertTrue(
            harness.driver.isTimingAnOutage(),
            "evidence from the retired socket certified the trailing rebind — a dead "
                + "final-path socket stays claimed until silence detection")
        XCTAssertEqual(harness.driver.snapshotCounters().rebindUnconfirmedCount, 1)
    }

    /// The settle timer dies when the ladder takes over, exactly as the rebind confirmation
    /// does — and for the same rung.
    ///
    /// A coalesced trailing recovery armed before an outage opened has nothing left to
    /// recover: the ladder's next attempt builds a fresh socket on the current path. Left
    /// installed, it fires mid-ladder, re-enters `beginOutage`, retires whatever attempt is
    /// live, and spends a rung on a socket that was never given its chance. The
    /// cancel-in-`startOutageClock` mutation SURVIVED the first sweep — nothing else
    /// exercises a settle window crossed by an outage — which is why the cancel gets its own
    /// test rather than a comment.
    func testAnOutageOpeningInsideTheSettleWindowRetiresTheTrailingRecovery() throws {
        let harness = try DriverHarness()

        harness.driver.pathChanged(satisfied: true, interfacesChanged: true)
        harness.session.pretendAuthenticatedPeerDatagram()
        harness.driver.tick()
        harness.clock.advance(1)
        harness.driver.pathChanged(satisfied: true, interfacesChanged: true)
        let settleSerial = try XCTUnwrap(harness.timers.allArmedSerials().last)

        // The session dies inside the window; the ladder now owns recovery.
        guard let expired = ChainedSessionEndCause(.reconnect(reason: .connectionExpired)) else {
            return XCTFail("the validated door refused a cause the policy produces")
        }
        harness.engineQueue.run { harness.driver.sessionEnded(expired) }
        XCTAssertTrue(harness.driver.isTimingAnOutage())

        // The retry delay elapses and the ladder's attempt goes live.
        harness.clock.advance(2)
        harness.fireDue()
        let attemptSession = try XCTUnwrap(
            harness.source.handedOut.last, "the ladder made no attempt")

        // Both delivery shapes of the stale settle timer: a due fire (skips the cancelled
        // slot) and a delivery already enqueued at teardown (rejected by the cleared slot).
        harness.fireDue()
        _ = harness.timers.fireAlreadyDelivered(serial: settleSerial, on: harness.engineQueue)

        XCTAssertFalse(
            attemptSession.isShutDown,
            "the trailing recovery fired mid-ladder and retired an attempt that was never "
                + "given its chance — a rung spent on a socket the ladder was about to build")
        XCTAssertEqual(harness.source.handedOut.count, 1, "a second attempt was scheduled")
    }

    /// A sleep landing inside the settle window defers the trailing recovery to the wake.
    ///
    /// Cancelling alone would swallow it: the wake's surviving-runner branch re-handshakes
    /// into the PRE-BURST socket, and only the 21 s silence detector would clean that up —
    /// the settle window must not widen the very blackhole it exists to shorten. The deferred
    /// transition latch is the machinery built for recovery-across-suspension, so the wake
    /// consumes it and rebuilds on whatever path the device woke onto.
    func testASleepInsideTheSettleWindowDefersTheTrailingRecoveryToWake() throws {
        let harness = try DriverHarness()

        harness.driver.pathChanged(satisfied: true, interfacesChanged: true)
        harness.session.pretendAuthenticatedPeerDatagram()
        harness.driver.tick()
        harness.clock.advance(1)
        harness.driver.pathChanged(satisfied: true, interfacesChanged: true)
        XCTAssertEqual(harness.source.madeChannelCount, 1)

        harness.driver.sleep()
        harness.clock.advance(ChainedOutageDriver.pathRecoverySettleSeconds + 1)
        harness.driver.wake()

        XCTAssertEqual(
            harness.source.madeChannelCount, 2,
            "the coalesced recovery was swallowed by the suspension — the wake re-handshakes "
                + "into the pre-burst socket and the handoff blackholes until the silence "
                + "detector notices")
        let counters = harness.driver.snapshotCounters()
        XCTAssertEqual(counters.rebindCount, 2)
        // The deferral carries the SOCKET half only. Routing it through the
        // deferred-transition latch replayed `recoverAfterPathChange` at wake, so every
        // sleep inside a settle window counted a path transition that never occurred —
        // corrupting the outage-vs-flap diagnostic the counter pair exists for
        // (Codex, PR #504).
        XCTAssertEqual(
            counters.pathRecoveryCount, 2,
            "the wake replayed an already-counted transition as a new observation")
        XCTAssertEqual(counters.coalescedPathRecoveryCount, 1)
        XCTAssertFalse(harness.driver.isTimingAnOutage())
    }

    /// A coalesced flap INSIDE an outage must not arm the trailing recovery at all.
    ///
    /// `startOutageClock`'s cancel covers timers armed BEFORE the outage opened; a
    /// coalesced transition arriving after would re-arm past it, and its fire lands
    /// mid-ladder — retiring whatever replacement attempt is live and spending a rung on a
    /// socket the ladder was about to build (Codex, PR #504). Inside an outage the ladder
    /// IS the trailing recovery: its next attempt binds a fresh socket on whatever path is
    /// current at that moment.
    func testACoalescedFlapInsideAnOutageDoesNotArmATrailingRecovery() throws {
        let harness = try DriverHarness()
        guard let expired = ChainedSessionEndCause(.reconnect(reason: .connectionExpired)) else {
            return XCTFail("the validated door refused a cause the policy produces")
        }
        harness.engineQueue.run { harness.driver.sessionEnded(expired) }
        XCTAssertTrue(harness.driver.isTimingAnOutage())

        // Flap 1 leads (a rebuild via the ladder); flap 2 coalesces inside the window.
        harness.driver.pathChanged(satisfied: true, interfacesChanged: true)
        harness.clock.advance(1)
        harness.driver.pathChanged(satisfied: true, interfacesChanged: true)

        // The retry delay elapses and the ladder's replacement attempt goes live.
        harness.clock.advance(1)
        harness.fireDue()
        let attemptSession = try XCTUnwrap(
            harness.source.handedOut.last, "the ladder made no attempt")

        // The settle window's moment passes. Nothing may fire into the ladder.
        harness.clock.advance(ChainedOutageDriver.pathRecoverySettleSeconds + 1)
        harness.fireDue()

        XCTAssertFalse(
            attemptSession.isShutDown,
            "a trailing recovery armed inside the outage fired mid-ladder and retired an "
                + "attempt that was never given its confirmation window")
        XCTAssertEqual(
            harness.driver.snapshotCounters().coalescedPathRecoveryCount, 1,
            "the flap must still be OBSERVED — the skip is about arming, not counting")
    }

    /// An outage that ends on EVIDENCE consumes the owed recovery — the success leg of the
    /// in-outage skip.
    ///
    /// "The ladder is the trailing recovery" fails exactly here: a successful attempt means
    /// NO next attempt, and the evidence that ended the outage can arrive through the old
    /// interface's brief afterlife — so without the debt, the session stays bound to the
    /// pre-transition socket until silence detection tears down a link that just proved
    /// itself (Codex, PR #504 round 2).
    func testAnOutageEndedByEvidenceRunsTheOwedRecovery() throws {
        let harness = try DriverHarness()
        // A leading recovery before the outage, so the in-outage flap coalesces.
        harness.driver.pathChanged(satisfied: true, interfacesChanged: true)
        harness.session.pretendAuthenticatedPeerDatagram()
        harness.driver.tick()

        guard let expired = ChainedSessionEndCause(.reconnect(reason: .connectionExpired)) else {
            return XCTFail("the validated door refused a cause the policy produces")
        }
        harness.engineQueue.run { harness.driver.sessionEnded(expired) }
        harness.clock.advance(1)
        harness.fireDue()
        let attemptSession = try XCTUnwrap(
            harness.source.handedOut.last, "the ladder made no attempt")

        // The flap lands while the attempt is live, inside the settle window: coalesced,
        // debt recorded, nothing armed.
        harness.driver.pathChanged(satisfied: true, interfacesChanged: true)
        XCTAssertFalse(attemptSession.isShutDown, "the coalesced flap retired the attempt")

        // The attempt succeeds — evidence ends the outage and KEEPS the runner.
        attemptSession.pretendAuthenticatedPeerDatagram()
        harness.driver.tick()
        XCTAssertFalse(harness.driver.isTimingAnOutage())

        XCTAssertEqual(
            attemptSession.adoptedChannelCount, 1,
            "the owed recovery never ran — the session stays on the pre-transition socket "
                + "until the silence detector tears down a link that just proved itself")
        XCTAssertEqual(harness.source.handedOut.count, 1, "the debt bought a whole rebuild")
    }

    /// The ladder's fresh attempt satisfies the owed recovery — the other leg.
    ///
    /// A build that happens AFTER the coalesced flap binds the path current at build time,
    /// which is the settled path. Without the clear, the first evidence on that new socket
    /// would end the outage and buy a redundant rebind plus confirmation for a socket that
    /// is already the right one.
    func testTheLaddersFreshAttemptSatisfiesTheOwedRecovery() throws {
        let harness = try DriverHarness()
        harness.driver.pathChanged(satisfied: true, interfacesChanged: true)
        harness.session.pretendAuthenticatedPeerDatagram()
        harness.driver.tick()

        guard let expired = ChainedSessionEndCause(.reconnect(reason: .connectionExpired)) else {
            return XCTFail("the validated door refused a cause the policy produces")
        }
        harness.engineQueue.run { harness.driver.sessionEnded(expired) }
        // The flap coalesces BEFORE any attempt exists: the debt is recorded.
        harness.driver.pathChanged(satisfied: true, interfacesChanged: true)

        // The retry delay elapses; the fresh attempt binds the settled path itself.
        harness.clock.advance(2)
        harness.fireDue()
        let attemptSession = try XCTUnwrap(
            harness.source.handedOut.last, "the ladder made no attempt")

        attemptSession.pretendAuthenticatedPeerDatagram()
        harness.driver.tick()
        XCTAssertFalse(harness.driver.isTimingAnOutage())

        XCTAssertEqual(
            attemptSession.adoptedChannelCount, 0,
            "a fresh build already bound the settled path; the debt must not buy a "
                + "redundant rebind and confirmation on top of it")
        XCTAssertEqual(harness.driver.snapshotCounters().rebindCount, 1, "only the pre-outage rebind")
    }

    /// A rebind that never proves itself falls back to exactly R1.
    ///
    /// The keepalive obliges the peer nothing, so its emission is NOT evidence the new socket
    /// carries traffic. Without the deadline a failed rebind leaves `0.0.0.0/0` claimed with
    /// nothing armed — the blackhole INV-CHAIN-3 forbids — and the fast path's worst case
    /// becomes "R1, never" instead of "R1, a few seconds late".
    func testAnUnconfirmedRebindFallsBackToAFullRebuild() throws {
        let harness = try DriverHarness()
        harness.driver.pathChanged(satisfied: true, interfacesChanged: true)
        XCTAssertEqual(harness.driver.snapshotCounters().rebindCount, 1)
        XCTAssertFalse(harness.driver.isTimingAnOutage())

        // First window: no evidence, so a LONE rebind spends its one re-anchor retry rather than
        // rebuilding on a single lost datagram.
        harness.clock.advance(ChainedOutageDriver.rebindConfirmationSeconds)
        harness.timers.fireDue(atSeconds: harness.clock.nowSeconds(), on: harness.engineQueue)
        XCTAssertFalse(
            harness.driver.isTimingAnOutage(),
            "a lone unconfirmed rebind rebuilt on the FIRST miss instead of retrying the re-anchor")
        XCTAssertEqual(harness.driver.snapshotCounters().rebindReanchorRetryCount, 1)
        XCTAssertEqual(harness.driver.snapshotCounters().rebindUnconfirmedCount, 0)

        // Second window (the longer retry window): still no evidence — NOW it falls back to rebuild.
        harness.clock.advance(ChainedOutageDriver.rebindReanchorRetrySeconds)
        harness.timers.fireDue(atSeconds: harness.clock.nowSeconds(), on: harness.engineQueue)
        XCTAssertTrue(
            harness.driver.isTimingAnOutage(),
            "an unconfirmed rebind that missed even the retry left the tunnel claiming everything")
        XCTAssertEqual(harness.driver.snapshotCounters().rebindUnconfirmedCount, 1)
    }

    /// A lone rebind that misses its first window re-anchors ONCE and re-arms instead of rebuilding.
    ///
    /// The device-evidenced fix: a roam whose single `.unobliging` re-anchor keepalive was lost
    /// used to spend a full rebuild — a fresh handshake and connect-gate establishment, the worst
    /// roam latency (App Store blackhole, 2026-08-23). The retry re-anchors with a forced handshake
    /// (obliging, engine-retransmitted) so a transient loss on a working path costs one window, not
    /// a rebuild.
    func testAnUnconfirmedRebindRetriesTheReAnchorBeforeRebuilding() throws {
        let harness = try DriverHarness()
        harness.driver.pathChanged(satisfied: true, interfacesChanged: true)
        XCTAssertEqual(harness.driver.snapshotCounters().rebindCount, 1)
        let handshakesBefore = harness.currentSession.forcedHandshakeCount

        // First window, no evidence.
        harness.clock.advance(ChainedOutageDriver.rebindConfirmationSeconds)
        harness.fireDue()

        XCTAssertEqual(
            harness.currentSession.forcedHandshakeCount, handshakesBefore + 1,
            "the retry did not re-anchor the peer with a forced handshake")
        XCTAssertEqual(harness.driver.snapshotCounters().rebindReanchorRetryCount, 1)
        XCTAssertFalse(
            harness.driver.isTimingAnOutage(),
            "a lone rebind rebuilt on its first miss instead of retrying the re-anchor")
        XCTAssertEqual(harness.driver.snapshotCounters().rebindUnconfirmedCount, 0)
        XCTAssertEqual(
            harness.driver.snapshotCounters().rebindCount, 1, "the retry is a re-anchor, not a fresh rebind")
    }

    /// The re-anchor retry that lands confirms the rebind — no rebuild, no unconfirmed tally.
    func testAReanchorRetryThatConfirmsAvoidsTheRebuild() throws {
        let harness = try DriverHarness()
        harness.driver.pathChanged(satisfied: true, interfacesChanged: true)

        // First window misses → the retry re-anchors and re-arms one more window.
        harness.clock.advance(ChainedOutageDriver.rebindConfirmationSeconds)
        harness.fireDue()
        XCTAssertEqual(harness.driver.snapshotCounters().rebindReanchorRetryCount, 1)
        XCTAssertFalse(harness.driver.isTimingAnOutage())

        // The peer answers the forced handshake on the new path; a tick reads it.
        harness.currentSession.pretendAuthenticatedPeerDatagram()
        harness.driver.tick()

        // The retry window comes due — confirmed now, so no rebuild and no unconfirmed tally.
        harness.clock.advance(ChainedOutageDriver.rebindReanchorRetrySeconds + 1)
        harness.fireDue()
        XCTAssertFalse(
            harness.driver.isTimingAnOutage(),
            "a rebind the peer answered during the retry window was rebuilt anyway")
        XCTAssertEqual(harness.driver.snapshotCounters().rebindUnconfirmedCount, 0)
        XCTAssertEqual(harness.driver.snapshotCounters().rebindCount, 1)
    }

    /// A rebind caught in a flap BURST does NOT get the lone-rebind retry.
    ///
    /// The retry is for a lone roam. During a burst a trailing settle recovery is already due, and
    /// PR #504 requires the fallback to be identical whichever of the two same-instant timers fires
    /// first. Granting the confirmation-fires-first order a retry would reintroduce the exact
    /// race-order asymmetry #504 removed (a dead path claimed six seconds one order, three the
    /// other). So with a settle recovery pending, the confirmation's own fire rebuilds immediately —
    /// the mirror of `testAnUnconfirmedLeadingRebindFallsBackBeforeTheTrailingRecovery`.
    func testARebindInAFlapBurstDoesNotGetTheReAnchorRetry() throws {
        let harness = try DriverHarness()
        harness.driver.pathChanged(satisfied: true, interfacesChanged: true)
        let confirmationSerial = try XCTUnwrap(harness.timers.allArmedSerials().last)

        // A second change inside the settle window coalesces into a trailing recovery, so both the
        // leading confirmation and the settle timer are armed for the same instant.
        harness.clock.advance(1)
        harness.driver.pathChanged(satisfied: true, interfacesChanged: true)

        // The confirmation fires FIRST: with a settle recovery still pending it must NOT retry.
        harness.clock.advance(ChainedOutageDriver.rebindConfirmationSeconds)
        _ = harness.timers.fireAlreadyDelivered(serial: confirmationSerial, on: harness.engineQueue)

        XCTAssertTrue(
            harness.driver.isTimingAnOutage(),
            "a burst rebind took the lone-rebind retry and delayed the bounded fallback")
        XCTAssertEqual(harness.driver.snapshotCounters().rebindReanchorRetryCount, 0)
        XCTAssertEqual(harness.driver.snapshotCounters().rebindUnconfirmedCount, 1)
    }

    /// The re-anchor retry window must outlast the engine's own REKEY_TIMEOUT (5 s) retransmit, or a
    /// lost forced-handshake initiation would rebuild before its resend could land — the exact
    /// weakness a 3-second window carried (Codex, PR #574). Pins the derivation so a future shrink
    /// cannot silently reintroduce it.
    func testTheReanchorRetryWindowOutlastsTheEngineRetransmit() {
        XCTAssertGreaterThanOrEqual(
            ChainedOutageDriver.rebindReanchorRetrySeconds, 5,
            "retry window shorter than REKEY_TIMEOUT — the engine's resend cannot land before rebuild")
        XCTAssertGreaterThan(
            ChainedOutageDriver.rebindReanchorRetrySeconds, ChainedOutageDriver.rebindConfirmationSeconds,
            "the retry window must be longer than the first confirmation window")
    }

    /// Authenticated evidence on the new transport confirms the rebind.
    func testAConfirmedRebindDoesNotFallBackToARebuild() throws {
        let harness = try DriverHarness()
        harness.driver.pathChanged(satisfied: true, interfacesChanged: true)

        // A datagram the peer authenticated — the only thing that proves the new socket works.
        harness.session.pretendAuthenticatedPeerDatagram()
        harness.driver.tick()

        harness.clock.advance(ChainedOutageDriver.rebindConfirmationSeconds + 1)
        harness.timers.fireDue(atSeconds: harness.clock.nowSeconds(), on: harness.engineQueue)

        XCTAssertFalse(
            harness.driver.isTimingAnOutage(),
            "a rebind the peer had already answered was torn down anyway — the confirmation is "
                + "never cleared, so every rebind falls back and the fast path is theatre")
        XCTAssertEqual(harness.driver.snapshotCounters().rebindUnconfirmedCount, 0)
    }

    /// The WEAKER half of the recovery predicate confirms a rebind too, and must.
    ///
    /// `sawInboundData` is the signal that may not carry DETECTION on its own; confirmation is a
    /// different question — which socket carried the traffic — and the runner's generation check
    /// answers that before either flag is set. Requiring the stronger flag would send a working
    /// rebind back through a full rebuild whenever the peer's first answer through the new socket
    /// happened to be an ICMP error rather than data (Kilo, PR #493).
    func testInboundDataAloneConfirmsARebind() throws {
        let harness = try DriverHarness()
        harness.driver.pathChanged(satisfied: true, interfacesChanged: true)

        harness.session.pretendInboundData()
        harness.driver.tick()

        harness.clock.advance(ChainedOutageDriver.rebindConfirmationSeconds + 1)
        harness.timers.fireDue(atSeconds: harness.clock.nowSeconds(), on: harness.engineQueue)

        XCTAssertFalse(
            harness.driver.isTimingAnOutage(),
            "a rebind the peer had already answered through was rebuilt anyway, because the "
                + "confirmation only accepted the stronger flag")
        XCTAssertEqual(harness.driver.snapshotCounters().rebindUnconfirmedCount, 0)
    }

    /// Evidence the runner latched but no tick drained still confirms the rebind.
    ///
    /// The two clocks do not line up. Liveness is drained by the repeating tick — 500 ms with
    /// 50 ms of leeway — and the confirmation deadline has none, so there is a window of up to
    /// ~550 ms in which a peer's answer sits in an unread sample. Deciding without reading it
    /// tears down a link that works and spends the whole retry ladder on it.
    ///
    /// No `tick()` here ON PURPOSE, and that is what makes the test the window rather than a
    /// restatement of `testAConfirmedRebindDoesNotFallBackToARebuild`: the evidence exists in the
    /// runner and the driver has never sampled it when the deadline fires.
    func testEvidenceArrivingAfterTheLastTickStillConfirmsTheRebind() throws {
        let harness = try DriverHarness()
        harness.driver.pathChanged(satisfied: true, interfacesChanged: true)
        XCTAssertEqual(harness.driver.snapshotCounters().rebindCount, 1)

        harness.session.pretendAuthenticatedPeerDatagram()

        harness.clock.advance(ChainedOutageDriver.rebindConfirmationSeconds)
        harness.fireDue()

        XCTAssertFalse(
            harness.driver.isTimingAnOutage(),
            "the peer had answered on the new socket before the deadline, but the deadline "
                + "decided without reading the sample and tore down a working link")
        XCTAssertEqual(harness.driver.snapshotCounters().rebindUnconfirmedCount, 0)
    }

    /// A session dying inside the confirmation window must not cost the ladder a rung.
    ///
    /// The rebind arms a three-second deadline and hands the tunnel back. If the rebound session
    /// then dies on its own — a rekey expiring, the peer's endpoint going away — the ladder takes
    /// over, and by the time the deadline comes due a REPLACEMENT attempt is already running. Left
    /// installed, that deadline re-enters `beginOutage`, which retires the live attempt and
    /// advances the ladder for a socket that never got its chance (Codex + Kilo, PR #493).
    func testASessionDyingDuringTheConfirmationWindowDoesNotCostAnExtraRung() throws {
        let harness = try DriverHarness()
        harness.driver.pathChanged(satisfied: true, interfacesChanged: true)
        XCTAssertEqual(harness.driver.snapshotCounters().rebindCount, 1)
        XCTAssertFalse(harness.driver.isTimingAnOutage())

        guard let expired = ChainedSessionEndCause(.reconnect(reason: .connectionExpired)) else {
            return XCTFail("the validated door refused a cause the policy produces")
        }
        harness.engineQueue.run { harness.driver.sessionEnded(expired) }
        XCTAssertTrue(harness.driver.isTimingAnOutage(), "the session death started no outage")

        // Let the ladder's retry delay elapse so an attempt is actually live when the stale
        // deadline comes due. The confirmation was armed for second 3; this lands on second 2.
        harness.clock.advance(2)
        harness.fireDue()
        let sessionsAfterLadder = harness.source.handedOut.count
        XCTAssertGreaterThanOrEqual(
            harness.driver.snapshotCounters().startedAttemptCount, 1, "the ladder made no attempt")

        harness.clock.advance(ChainedOutageDriver.rebindConfirmationSeconds - 2)
        harness.fireDue()

        XCTAssertEqual(
            harness.driver.snapshotCounters().rebindUnconfirmedCount, 0,
            "the confirmation deadline outlived the session it was confirming and fired mid-ladder")

        // The consequence, which is what makes the counter worth asserting: a re-entered
        // `beginOutage` retires the running attempt and schedules another, so the next timer
        // hands out a session this outage should never have needed.
        harness.clock.advance(3)
        harness.fireDue()
        XCTAssertEqual(
            harness.source.handedOut.count, sessionsAfterLadder,
            "the stale deadline tore down the replacement attempt that was already running and "
                + "spent another rung of a 15-second budget on it")
    }

    /// A rebind with no current keypair must REPORT that, not be trusted.
    ///
    /// `encapsulate` emits a keepalive only while a keypair is current; with none it queues the
    /// empty packet and returns a handshake, which answers `Done` mid-handshake. Zero bytes, no
    /// counter, no event. A path change landing in a rekey window is exactly that case.
    func testARebindWithNoCurrentKeypairFallsBackInsteadOfTrustingAProbeThatNeverWentOut() throws {
        let harness = try DriverHarness()
        let adopted = harness.currentSession
        adopted.rebindOutcome = .noCurrentSession

        harness.driver.pathChanged(satisfied: true, interfacesChanged: true)

        XCTAssertEqual(harness.driver.snapshotCounters().rebindCount, 0)
        XCTAssertEqual(harness.driver.snapshotCounters().rebindDeclinedCount, 1)
        XCTAssertTrue(
            harness.driver.isTimingAnOutage(),
            "the driver trusted a rebind whose keepalive was never emitted, so nothing is armed "
                + "and nothing will ever confirm it")
    }

    /// A transport that cannot be built falls back rather than forward.
    func testARebindThatCannotBuildAChannelFallsBackToTheLadder() throws {
        let harness = try DriverHarness()
        let adopted = harness.currentSession
        harness.source.channelOutcome = .failure(ScriptedSessionSource.Unavailable())

        harness.driver.pathChanged(satisfied: true, interfacesChanged: true)

        XCTAssertEqual(adopted.adoptedChannelCount, 0, "a channel that does not exist was adopted")
        XCTAssertTrue(
            harness.driver.isTimingAnOutage(),
            "no eligible interface left the driver with neither a rebind nor a ladder")
    }

    /// During an outage the LADDER owns recovery, not the fast path.
    ///
    /// Two recovery mechanisms running at once is not redundancy: the confirmation deadline can
    /// fire `beginOutage` while one is already being timed, and the rebind counters stop
    /// describing anything a reader can act on.
    func testAPathChangeDuringAnOutageLeavesRecoveryToTheLadder() throws {
        let harness = try DriverHarness()
        harness.beginSilentOutage()
        XCTAssertTrue(harness.driver.isTimingAnOutage(), "precondition: an outage is running")
        let rebindsBefore = harness.driver.snapshotCounters().rebindCount

        harness.driver.pathChanged(satisfied: true, interfacesChanged: true)

        XCTAssertEqual(
            harness.driver.snapshotCounters().rebindCount, rebindsBefore,
            "the fast path ran inside an outage, so a confirmation deadline and the ladder are "
                + "now both trying to recover the same session")
    }

    // MARK: - Path change (R1)

    /// A path that vanished must not have its budget spent dialling it.
    ///
    /// The whole point of the entry point. Before it, a handoff or a lift lobby arrived only as
    /// silence: the threshold expires, an outage opens, the entire blackhole budget is spent on
    /// a path that no longer exists, and the surrender is permanent — over a fault that was
    /// never the upstream's.
    func testAnUnsatisfiedPathEndsTheOutageRatherThanSpendingItsBudget() throws {
        let harness = try DriverHarness()
        harness.session.pretendObligingSend()
        harness.driver.tick()
        harness.clock.advance(ChainedOutageDriver.linkSilenceThresholdSeconds + 1)
        harness.driver.tick()
        XCTAssertTrue(harness.driver.isTimingAnOutage(), "precondition: an outage is running")

        harness.driver.pathChanged(satisfied: false, interfacesChanged: false)

        XCTAssertFalse(
            harness.driver.isTimingAnOutage(),
            "the outage kept running against a path that is gone; its budget will expire and "
                + "surrender chaining permanently for a fault that was never the upstream's")
        XCTAssertEqual(harness.driver.snapshotCounters().offlinePathCount, 1)

        // And it must not surrender while there is no network to try.
        harness.clock.advance(ChainedReconnectPolicy.maximumBlackholeSeconds * 3)
        harness.driver.tick()
        XCTAssertFalse(
            harness.driver.hasSurrenderedChaining(),
            "chaining was surrendered while the device had no network at all")
    }

    /// Repeated satisfied updates must NOT postpone detection.
    ///
    /// The exact defect `testAnUnpairedWakeDoesNotPostponeDetection` exists to prevent, arriving
    /// through the door beside it. `NWPathMonitor` delivers satisfied updates for reasons that
    /// are not transitions; clearing the silence clock on each would let a chatty monitor hold
    /// the blackhole open forever.
    func testARepeatedSatisfiedPathUpdateDoesNotPostponeDetection() throws {
        let harness = try DriverHarness()
        harness.session.pretendObligingSend()
        harness.driver.tick()

        harness.clock.advance(ChainedOutageDriver.linkSilenceThresholdSeconds - 1)
        harness.driver.pathChanged(satisfied: true, interfacesChanged: false)
        harness.clock.advance(2)
        harness.driver.tick()

        XCTAssertTrue(
            harness.driver.isTimingAnOutage(),
            "a satisfied path update that was not a transition reset the silence clock — a "
                + "chatty monitor now postpones detection indefinitely")
    }

    /// A changed path REBUILDS. It must not re-handshake into a socket bound to the old one.
    ///
    /// The first version of this asserted a forced handshake, which is the bug rather than the
    /// fix: `ChainedUpstreamChannelParameters` pins the socket to a specific `NWInterface`
    /// (`parameters.requiredInterface = live`), so a surviving runner sends through the
    /// interface that just went away — and it fails SILENTLY, because a stale binding does not
    /// error. `ChainedUpstreamEgressPolicy.lifecycle(after: .pathChanged)` already returned
    /// `.rebuild` for exactly this reason, and had zero callers (Codex, PR #492).
    func testAChangedPathReplacesTheTransportAndNeverReHandshakesIntoTheOldOne() throws {
        // SUPERSEDED BY R2, and the assertion moved rather than the intent. R1 could only fix a
        // stale socket by tearing the whole session down, so this asserted a shutdown. R2
        // replaces the transport under a live session, so a shutdown is now the WRONG outcome —
        // it is the expensive fallback, not the fix.
        //
        // What has not changed is the thing this test was written for: the socket is pinned to a
        // specific `NWInterface` at construction, so forcing a handshake on the surviving runner
        // re-handshakes into the interface that just went away, silently.
        let harness = try DriverHarness()
        harness.session.pretendObligingSend()
        harness.driver.tick()
        let handshakesBefore = harness.session.forcedHandshakeCount
        let shutdownsBefore = harness.session.shutdownCount

        harness.driver.pathChanged(satisfied: true, interfacesChanged: true)

        XCTAssertEqual(
            harness.session.adoptedChannelCount, 1,
            "the transport was not replaced, so the runner is still on the socket bound to the "
                + "interface that went away")
        XCTAssertEqual(
            harness.session.forcedHandshakeCount, handshakesBefore,
            "a handshake was forced on the surviving runner — into the old socket, which fails "
                + "silently because a stale binding does not error")
        XCTAssertEqual(
            harness.session.shutdownCount, shutdownsBefore,
            "the session was torn down for a socket change, which spends a ladder rung and a "
                + "handshake to fix something only the transport was wrong about")
        XCTAssertEqual(harness.driver.snapshotCounters().pathRecoveryCount, 1)
    }

    /// A satisfied transition arriving mid-suspension must WAIT for the paired wake.
    ///
    /// Recovering there does the two things suspension exists to prevent: `beginOutage` arms
    /// one-shots whose handlers do not check the quiesce state, so a long suspension surrenders
    /// chaining outright; and a rebuild drives the engine through the interval `sleep()`
    /// promised was quiet.
    func testASatisfiedPathDuringSuspensionIsDeferredToWake() throws {
        let harness = try DriverHarness()
        harness.driver.pathChanged(satisfied: false, interfacesChanged: false)
        harness.driver.sleep()

        harness.driver.pathChanged(satisfied: true, interfacesChanged: true)

        XCTAssertEqual(
            harness.driver.snapshotCounters().pathRecoveryCount, 0,
            "the driver recovered while suspended, arming timers that can surrender chaining "
                + "before the device is even awake")

        harness.driver.wake()

        XCTAssertEqual(
            harness.driver.snapshotCounters().pathRecoveryCount, 1,
            "the deferred transition was dropped rather than consumed at wake, so the driver "
                + "never recovers onto the path it woke up on")
    }

    /// A paired wake while the path is STILL offline must not rebuild.
    ///
    /// The unsatisfied branch tears down during a retry delay, so `runner == nil` — which is
    /// precisely the shape that reaches `wake()`'s rebuild. Rebuilding there arms retries and
    /// deadlines against a network that is still absent, and those one-shot handlers do not
    /// check the quiesce state, so they fire and surrender chaining while offline.
    func testAPairedWakeWhileStillOfflineDoesNotRebuild() throws {
        let harness = try DriverHarness()
        harness.session.pretendObligingSend()
        harness.driver.tick()
        harness.clock.advance(ChainedOutageDriver.linkSilenceThresholdSeconds + 1)
        harness.driver.tick()
        harness.driver.pathChanged(satisfied: false, interfacesChanged: false)

        harness.driver.sleep()
        harness.driver.wake()

        XCTAssertFalse(
            harness.driver.isTimingAnOutage(),
            "the paired wake rebuilt against a network that is still not there; its deadline "
                + "will fire and surrender chaining while the device is still offline")

        harness.clock.advance(ChainedReconnectPolicy.maximumBlackholeSeconds * 3)
        harness.driver.tick()
        XCTAssertFalse(harness.driver.hasSurrenderedChaining())
    }

    /// Offline then online with nothing built must leave something armed.
    ///
    /// Going offline retires the live attempt and ends the outage, so coming back with no runner
    /// leaves no runner, no armed timer and no tick — a permanent blackhole assembled out of two
    /// correct-looking halves. Same shape as `testWakingDuringARetryDelayLeavesSomethingArmed`.
    func testComingBackOnlineWithNoRunnerStartsAFreshOutage() throws {
        let harness = try DriverHarness()
        harness.session.pretendObligingSend()
        harness.driver.tick()
        harness.clock.advance(ChainedOutageDriver.linkSilenceThresholdSeconds + 1)
        harness.driver.tick()
        harness.driver.pathChanged(satisfied: false, interfacesChanged: false)

        harness.driver.pathChanged(satisfied: true, interfacesChanged: true)

        XCTAssertTrue(
            harness.driver.isTimingAnOutage() || harness.driver.hasSurrenderedChaining(),
            "the driver came back online with nothing armed and nothing running — INV-CHAIN-3's "
                + "armed-budget rule is violated outside the quiesced window it is exempt for")
    }

    /// A path update during suspension must not resurrect the tick `sleep()` cancelled.
    ///
    /// `rescheduleTick()` is reached from paths that run while a latch is held, and it did not
    /// consider quiescence — so an ordinary satisfied-but-unchanged `NWPathMonitor` update
    /// during a suspension recreated the repeating timer at 250 or 500 ms. `tick()` returns
    /// early so nothing DECIDES anything, but the extension still wakes its engine queue right
    /// through the interval that was supposed to be quiet.
    func testAPathUpdateDuringSuspensionDoesNotResurrectTheTick() throws {
        let harness = try DriverHarness()
        harness.driver.sleep()
        XCTAssertNil(
            harness.timers.currentTickInterval,
            "precondition: sleep() cancelled the repeating tick")

        harness.driver.pathChanged(satisfied: true, interfacesChanged: false)

        XCTAssertNil(
            harness.timers.currentTickInterval,
            "a path update during suspension rearmed the repeating tick, so the extension wakes "
                + "its engine queue throughout an interval sleep() promised was quiet")
    }

    /// A deferred recovery must not outlive the transition that set it.
    ///
    /// Satisfied-while-suspended sets the flag; going offline again takes the path away; the
    /// paired wake returns early on the offline latch; a later satisfied update recovers
    /// immediately. Without clearing, the flag is STILL set — and the next unrelated sleep/wake
    /// consumes it and performs a second full session rebuild, blackholing traffic through its
    /// retry delay for nothing.
    func testADeferredRecoveryDoesNotOutliveTheTransitionThatSetIt() throws {
        let harness = try DriverHarness()
        harness.driver.pathChanged(satisfied: false, interfacesChanged: false)
        harness.driver.sleep()
        harness.driver.pathChanged(satisfied: true, interfacesChanged: true)   // deferred
        harness.driver.pathChanged(satisfied: false, interfacesChanged: false) // superseded
        harness.driver.wake()
        harness.driver.pathChanged(satisfied: true, interfacesChanged: true)   // recovers now
        let afterRealRecovery = harness.driver.snapshotCounters().pathRecoveryCount

        // A later, unrelated suspension must not replay the spent deferral.
        harness.driver.sleep()
        harness.driver.wake()

        XCTAssertEqual(
            harness.driver.snapshotCounters().pathRecoveryCount, afterRealRecovery,
            "an unrelated sleep/wake consumed a stale deferred recovery and rebuilt the session "
                + "again, blackholing traffic through a retry delay for a transition that was "
                + "superseded long ago")
    }

    /// A rebuild inside an existing outage is not a second outage.
    ///
    /// `offlinePathCount` exists to be read ALONGSIDE `outageCount`: an outage count that tracks
    /// the offline count means a flapping device rather than a failing upstream. A counter that
    /// the rebuilds themselves inflate says that whatever is true, which makes the pair useless
    /// for the one question it was added to answer.
    func testRebuildingInsideAnOutageDoesNotCountASecondOne() throws {
        // RESTATED FOR C5, deliberately. This test's two back-to-back flaps used to produce
        // two full rebuilds and its counter assertion pinned that 1:1 behaviour by
        // implication. `pathRecoveryCount` is now the OBSERVATION counter — still 2, so the
        // outage-vs-flap diagnostic pair keeps working — while the second flap's socket work
        // is coalesced into the settle window rather than run again.
        let harness = try DriverHarness()
        harness.session.pretendObligingSend()
        harness.driver.tick()
        harness.clock.advance(ChainedOutageDriver.linkSilenceThresholdSeconds + 1)
        harness.driver.tick()
        XCTAssertTrue(harness.driver.isTimingAnOutage())
        let outagesAfterFirst = harness.driver.snapshotCounters().outageCount

        harness.driver.pathChanged(satisfied: true, interfacesChanged: true)
        harness.driver.pathChanged(satisfied: true, interfacesChanged: true)

        let counters = harness.driver.snapshotCounters()
        XCTAssertEqual(
            counters.outageCount, outagesAfterFirst,
            "each path rebuild inside one outage counted another outage, so a device that roams "
                + "during a single upstream failure reads as repeatedly failing")
        XCTAssertEqual(counters.pathRecoveryCount, 2, "every transition is still OBSERVED")
        XCTAssertEqual(
            counters.coalescedPathRecoveryCount, 1,
            "the second flap's socket work must coalesce into the settle window, not run 1:1")
    }

    /// Sleep and offline are DIFFERENT latches, and they overlap.
    ///
    /// One shared flag would let `wake()` clear a latch the path monitor owns, and the driver
    /// would resume spending the budget on a network that is still not there.
    func testWakingWhileStillOfflineDoesNotOpenAnOutage() throws {
        // THIS TEST WAS VACUOUS IN ITS FIRST FORM, and the mutation is what said so. It asserted
        // that waking while offline does not SURRENDER — but going offline already ends any
        // outage in progress, so there was nothing left to expire and the assertion held whether
        // or not the latches were shared. A test whose precondition its own subject removes.
        //
        // What the separate latch actually protects is the NEXT outage: if `wake()` cleared the
        // offline latch, `tick()` would resume, `sampleLiveness()` would see the still-unanswered
        // send, and the driver would OPEN an outage — and spend its budget — on a network that is
        // still not there. So the assertion is about a fresh outage, not a surrender.
        // THE SEND COMES AFTER THE WAKE, and that ordering is the whole test. Two earlier
        // versions were vacuous for two different reasons, both of which look like coverage:
        //   1. asserting no SURRENDER — but going offline already ends the outage, so nothing
        //      was left to expire and the assertion held either way;
        //   2. arming the silence clock BEFORE the sleep — but `wake()` legitimately clears that
        //      clock on a paired wake, so no outage could open whatever the latch did.
        // Only an unanswered send that begins AFTER the wake can distinguish a driver that is
        // still quiesced from one that has resumed sampling.
        let harness = try DriverHarness()
        harness.driver.pathChanged(satisfied: false, interfacesChanged: false)
        harness.driver.sleep()
        harness.driver.wake()

        harness.session.pretendObligingSend()
        harness.driver.tick()
        harness.clock.advance(ChainedOutageDriver.linkSilenceThresholdSeconds + 1)
        harness.driver.tick()

        XCTAssertFalse(
            harness.driver.isTimingAnOutage(),
            "waking cleared the OFFLINE latch as well as the suspension one, so the driver "
                + "opened an outage against a network that is still not there and will spend "
                + "the whole blackhole budget dialling it")
        XCTAssertFalse(harness.driver.hasSurrenderedChaining())
    }

    func testSleepingQuiescesTheOneShotsSoNoneSurrenders() throws {
        // Cancelling only the repeating tick left the deadline, watchdog and retry delay armed
        // across the suspension boundary. A handler already due when `sleep()` runs can then
        // execute while the device suspends, and the only thing it can decide there is to
        // surrender — which is unrecoverable rather than merely early, because `wake()` returns
        // immediately once `hasSurrendered` is set, so the refund this path exists to grant can
        // never undo it.
        let harness = try DriverHarness()
        harness.beginSilentOutage()
        XCTAssertTrue(harness.driver.isTimingAnOutage())
        XCTAssertFalse(
            harness.timers.liveArmedSeconds().isEmpty,
            "nothing was armed, so this does not exercise the boundary")

        // The budget deadline comes due at the moment the device suspends.
        harness.clock.advance(ChainedReconnectPolicy.maximumBlackholeSeconds + 1)
        harness.driver.sleep()
        harness.fireDue()

        XCTAssertEqual(
            harness.surrenders, [],
            "a one-shot surrendered while the device was suspending, and the sleep refund "
                + "cannot undo a surrender")

        // And the wake still recovers. It ENDS the outage rather than resuming it, so the
        // right observable is that no budget is running and the tick is back — not an armed
        // one-shot, which is what `INV-CHAIN-3` requires only INSIDE a budget.
        harness.driver.wake()
        XCTAssertFalse(harness.driver.hasSurrenderedChaining())
        XCTAssertFalse(
            harness.driver.isTimingAnOutage(),
            "the paired wake did not end the outage it refunded")
        XCTAssertNotNil(
            harness.timers.currentTickInterval,
            "the wake left the driver with no tick, so nothing can observe the link again")
    }

    func testAOneShotAlreadyDeliveredWhenSleepBeganDecidesNothing() throws {
        // Cancelling is not enough and the first version of the sleep fix stopped there.
        // `cancel()` does not retract a handler the queue has already been handed, and a
        // cancelled timer whose SLOT is still installed still satisfies its handler's identity
        // guard — so the handler runs during suspension and surrenders anyway. The sibling test
        // cannot see this, because the fake scheduler's `fireDue` skips cancelled timers, which
        // models a timer that never ran rather than one already in flight.
        let harness = try DriverHarness()
        harness.beginSilentOutage()
        let serials = harness.timers.allArmedSerials()
        XCTAssertFalse(serials.isEmpty, "nothing was armed, so this proves nothing")

        harness.clock.advance(ChainedReconnectPolicy.maximumBlackholeSeconds + 1)
        harness.driver.sleep()

        // Every handler the queue could already have been holding, delivered anyway.
        for serial in serials {
            _ = harness.timers.fireAlreadyDelivered(serial: serial, on: harness.engineQueue)
        }

        XCTAssertEqual(
            harness.surrenders, [],
            "a handler already in flight when sleep began still surrendered — cancelling it "
                + "was never going to be enough, because the slot still matched its serial")
        XCTAssertFalse(harness.driver.hasSurrenderedChaining())
    }

    func testATickDeliveredAfterSleepBeganDecidesNothing() throws {
        // Cancelling the repeating timer cannot retract a tick the queue already holds, for the
        // same reason cancelling a one-shot cannot. A tick that runs past the boundary drives
        // the engine and samples liveness — and an engine end then arms a fresh deadline and
        // retry, re-arming exactly what the boundary quiesced.
        let harness = try DriverHarness()
        harness.beginSilentOutage()
        harness.clock.advance(ChainedReconnectPolicy.maximumBlackholeSeconds + 1)
        harness.driver.sleep()
        let armedAfterSleep = harness.timers.liveArmedSeconds().count
        let ticksBefore = harness.currentSession.tickCount

        harness.driver.tick()  // the tick the queue was already holding

        XCTAssertEqual(
            harness.currentSession.tickCount, ticksBefore,
            "a tick delivered after suspension began still drove the engine")
        XCTAssertEqual(
            harness.timers.liveArmedSeconds().count, armedAfterSleep,
            "a post-sleep tick re-armed the timers the boundary had just quiesced")
        XCTAssertEqual(harness.surrenders, [], "a post-sleep tick surrendered")

        // And the tick works again once awake, so this is a suspension latch and not a wedge.
        harness.driver.wake()
        harness.driver.tick()
        XCTAssertGreaterThan(
            harness.currentSession.tickCount, ticksBefore,
            "the driver never resumed ticking after the wake")
    }

    func testASessionEndDeliveredAfterSleepBeganDecidesNothing() throws {
        // The other handler the queue may already hold. Acting on it runs `finishAttempt`,
        // which arms a fresh deadline and retry into a suspending process — or surrenders
        // outright, which the paired wake can never undo.
        let harness = try DriverHarness()
        harness.beginSilentOutage()
        harness.driver.sleep()
        let armedAfterSleep = harness.timers.liveArmedSeconds().count

        guard let expired = ChainedSessionEndCause(.reconnect(reason: .connectionExpired)) else {
            return XCTFail("the validated door refused a cause the policy produces")
        }
        harness.engineQueue.run { harness.driver.sessionEnded(expired) }

        XCTAssertEqual(
            harness.timers.liveArmedSeconds().count, armedAfterSleep,
            "a session end delivered after suspension began armed fresh timers")
        XCTAssertEqual(harness.surrenders, [], "a session end during suspension surrendered")
    }

    func testAWakeRebuildsARunnerThatEndedWhileSuspended() throws {
        // Dropping the end during suspension wedged the tunnel, and this is the shape: the
        // runner latches `hasEnded` before the driver is even told, so an end that is merely
        // ignored leaves a dead runner INSTALLED. The wake then sees it as non-nil and asks it
        // to handshake — and `forceHandshake()` returns immediately on an ended runner, as does
        // every later `tick()`. No runner that can carry traffic, no clock, nothing armed.
        let harness = try DriverHarness()
        harness.beginSilentOutage()
        let sessionsBefore = harness.source.callCount

        harness.driver.sleep()
        guard let expired = ChainedSessionEndCause(.reconnect(reason: .connectionExpired)) else {
            return XCTFail("the validated door refused a cause the policy produces")
        }
        harness.engineQueue.run { harness.driver.sessionEnded(expired) }
        harness.driver.wake()

        XCTAssertFalse(harness.driver.hasSurrenderedChaining(), "the wake surrendered instead of rebuilding")
        XCTAssertFalse(
            harness.timers.liveArmedSeconds().isEmpty,
            "the wake left nothing armed, so the tunnel can never recover")

        // The rebuild is what matters: a fresh session, not the dead one kept and prodded.
        harness.clock.advance(2)
        harness.fireDue()
        XCTAssertGreaterThan(
            harness.source.callCount, sessionsBefore,
            "the wake never built a replacement session — the ended runner was kept and asked "
                + "to handshake, which an ended runner ignores")
    }

    func testTheSuspensionExemptionIsBoundedByTheWakeThatFollowsIt() throws {
        // INV-CHAIN-3 says something is always armed inside the budget. Suspension is the one
        // exemption: `sleep()` quiesces every timer while the outage stays open, so between a
        // sleep and its wake the driver IS timing an outage with nothing armed. This pins that
        // the exemption is exactly that shape — deliberate, and closed by the wake — rather
        // than a hole the invariant's prose quietly permits.
        let harness = try DriverHarness()
        harness.beginSilentOutage()
        XCTAssertFalse(harness.timers.liveArmedSeconds().isEmpty, "the budget was never armed")

        harness.driver.sleep()
        XCTAssertTrue(
            harness.driver.isTimingAnOutage(),
            "sleep ended the outage — then this is not an exemption but a different design, "
                + "and the invariant should say so")
        XCTAssertTrue(
            harness.timers.liveArmedSeconds().isEmpty,
            "sleep left a timer armed, so a one-shot can still surrender during suspension")

        // The exemption is closed by the wake, which is what makes it bounded rather than a
        // hole: either the outage ends, or a fresh one begins with a fresh deadline.
        harness.driver.wake()
        XCTAssertFalse(harness.driver.hasSurrenderedChaining())
        let armedAfterWake = !harness.timers.liveArmedSeconds().isEmpty
        XCTAssertTrue(
            !harness.driver.isTimingAnOutage() || armedAfterWake,
            "the wake left an outage running with nothing armed — the exemption outlived the "
                + "suspension it exists for")
    }

    func testWakingWithALiveRunnerReArmsTheSilenceClock() throws {
        // Clearing the pre-sleep liveness is right, and on its own it disarms the detector for
        // the rest of the attempt. A runner whose handshake was already in flight cannot arm
        // anything again by itself: `tick()`'s retransmissions are `.unobliging`, and an
        // outbound packet offered while a handshake is in progress is queued by the engine
        // rather than sent. So an unreachable peer would go undetected until the engine's own
        // ~90 s expiry, well past the bound this driver holds.
        let harness = try DriverHarness()

        // Demand, then a paired sleep/wake in the middle of it.
        harness.session.pretendObligingSend()
        harness.driver.tick()
        harness.driver.sleep()
        harness.clock.advance(4)
        harness.driver.wake()

        // One tick consumes the sample the wake produced, which is what arms the clock; the
        // peer is unreachable, so the session reports nothing on its own from here.
        harness.driver.tick()
        harness.clock.advance(ChainedOutageDriver.linkSilenceThresholdSeconds + 1)
        harness.driver.tick()

        XCTAssertTrue(
            harness.driver.isTimingAnOutage(),
            "waking left the silence clock unarmed with a live runner, so an unreachable peer "
                + "is invisible until the engine expires the session")
    }

    func testWakingDuringARetryDelayLeavesSomethingArmed() throws {
        // `INV-CHAIN-3` says something is always armed inside the budget, and this sequence
        // left NOTHING: during a retry delay there is no runner, so ending the outage on wake
        // cancelled the delay that was going to rebuild one and retired the only recovery path.
        // No runner, no timer, no tick, no surrender reported — a permanent blackhole reached
        // by a sequence as ordinary as "the phone slept while chaining was retrying".
        let harness = try DriverHarness()
        harness.beginSilentOutage()

        // Kill the attempt's session so the driver schedules a retry DELAY and holds no runner.
        guard let expired = ChainedSessionEndCause(.reconnect(reason: .connectionExpired)) else {
            return XCTFail("the validated door refused a cause the policy produces")
        }
        harness.clock.advance(1)
        harness.engineQueue.run { harness.driver.sessionEnded(expired) }
        XCTAssertTrue(harness.driver.isTimingAnOutage(), "the outage ended on its own")

        // The device sleeps and wakes mid-delay.
        harness.driver.sleep()
        harness.clock.advance(5)
        harness.driver.wake()

        XCTAssertFalse(
            harness.driver.hasSurrenderedChaining(),
            "waking surrendered instead of retrying on the network it just woke onto")
        XCTAssertFalse(
            harness.timers.liveArmedSeconds().isEmpty,
            "nothing is armed after the wake — no runner, no timer, no tick, and no surrender: "
                + "the tunnel can never recover and INV-CHAIN-3 is violated")
    }

    // MARK: - Re-entrancy

    func testAReEntrantSessionEndKeepsItsCause() throws {
        // The runner reaches `sessionEnded` from inside its own loops and from a transport that
        // completes inline, so a second end arriving while the first is being processed is
        // ordinary. A boolean "another one is pending" would lose the CAUSE — and an end with no
        // cause routes to the watchdog path, which never records the attempt, which wedges the
        // ladder permanently. The fix for re-entrancy would have reintroduced the defect it was
        // fixing.
        let harness = try DriverHarness()
        harness.beginSilentOutage()
        let endsBefore = harness.driver.snapshotCounters().sessionEndCount

        // Two ends, the second delivered from inside the first.
        guard let expired = ChainedSessionEndCause(.reconnect(reason: .connectionExpired)),
              let bug = ChainedSessionEndCause(.callerBug(reason: .packetTooLarge))
        else { return XCTFail("the validated door refused a cause the policy produces") }

        // 🔴 GENUINELY RE-ENTRANT, which two sibling calls are NOT. `sessionEnded` drains its
        // queue and clears `isProcessingEnd` via `defer` before returning, so
        // `run { sessionEnded(a); sessionEnded(b) }` enters the second call with the flag already
        // false — the queue never holds two elements and the re-entrant branch never executes.
        // The version of this test that did that passed with `pendingEnds` deleted entirely
        // (sweep, PR #623).
        //
        // The second end is delivered from the runner's `shutdown()`, which `finishAttempt` calls
        // while it is INSIDE the first `sessionEnded` frame — the shape the doc block describes as
        // ordinary ("the runner reaches this from inside its own loops").
        let live = try XCTUnwrap(
            harness.source.handedOut.last, "the outage attempt should have adopted a session")
        let delivered = OneShotBox()
        let driver = harness.driver
        live.onShutdown = {
            guard delivered.takeFirstUse() else { return }
            driver.sessionEnded(bug)
        }

        harness.engineQueue.run { harness.driver.sessionEnded(expired) }

        XCTAssertTrue(delivered.wasUsed, "the re-entrant end never reached the driver")
        XCTAssertEqual(
            harness.driver.snapshotCounters().sessionEndCount, endsBefore + 2,
            "a re-entrant session end was dropped rather than queued")
        XCTAssertFalse(
            harness.driver.hasSurrenderedChaining(),
            "a re-entrant end surrendered — the cause was lost and routed to the watchdog path")
    }

    /// One-shot latch for a re-entrancy hook that must fire exactly once.
    ///
    /// A class because the hook is `@Sendable` and Swift 6 refuses a captured mutable local.
    final class OneShotBox: @unchecked Sendable {
        private let lock = NSLock()
        private var used = false
        /// True on the FIRST call only, so a hook installed on a session the driver shuts down
        /// more than once cannot deliver an unbounded number of ends.
        func takeFirstUse() -> Bool {
            lock.withLock {
                if used { return false }
                used = true
                return true
            }
        }
        var wasUsed: Bool { lock.withLock { used } }
    }

    // MARK: - Harness

    // MARK: - Retirement (the teardown funnel's half of the driver's lifetime)

    /// Retiring shuts the runner down and RELEASES it.
    ///
    /// The driver and its runner hold each other strongly — the runner's `events` sink is the
    /// driver — so `retire()` is the only place the cycle breaks. A retire that shuts down but
    /// keeps the reference, or nils without shutting down, leaks an engine and its buffers
    /// inside the ~50 MB NE ceiling for the rest of the process (`INV-MEM-1`).
    func testRetiringShutsDownAndReleasesTheRunner() throws {
        let harness = try DriverHarness()
        harness.driver.retire()
        XCTAssertEqual(
            harness.session.shutdownCount, 1,
            "retiring must shut the session down, not merely drop it")

        var adopted: StubSession? = StubSession()
        weak let released = adopted
        let second = try DriverHarness()
        second.driver.adopt(adopted!)
        adopted = nil
        XCTAssertNotNil(released, "precondition: the driver holds the adopted runner strongly")
        second.driver.retire()
        XCTAssertNil(
            released,
            "retiring must RELEASE the runner — the driver↔runner cycle breaks here or never")
    }

    /// After `retire()`, every entry point is a no-op: nothing arms, nothing is requested,
    /// nothing surrenders, and no late `adopt` resurrects a runner.
    ///
    /// The dangerous legs are the ones that can OPEN an outage for a tunnel that is gone: a
    /// late wake finding no runner would begin a fresh outage with a fresh deadline, a
    /// satisfied path transition would run the socket recovery into `beginOutage`, and a
    /// session end already queued by the dying runner would walk the ladder. Each of those
    /// arms timers that wake the engine queue — or calls the surrender sink — on behalf of a
    /// tunnel that no longer claims the routes an outage would blackhole.
    func testARetiredDriverIsInertOnEveryEntryPoint() throws {
        let harness = try DriverHarness()
        guard let expired = ChainedSessionEndCause(.reconnect(reason: .connectionExpired)) else {
            return XCTFail("the validated door refused a cause the policy produces")
        }
        harness.driver.retire()

        harness.driver.sleep()
        harness.driver.wake()
        harness.driver.pathChanged(satisfied: true, interfacesChanged: true)
        harness.driver.handleOutboundBatch([Data([1])], protocols: [NSNumber(value: AF_INET)])
        harness.engineQueue.run { harness.driver.sessionEnded(expired) }
        let late = StubSession()
        harness.driver.adopt(late)
        harness.driver.tick()

        XCTAssertNil(
            harness.timers.currentTickInterval,
            "a retired driver rearmed its repeating tick, waking the engine queue for a "
                + "tunnel that is gone")
        XCTAssertTrue(
            harness.timers.liveArmed.isEmpty,
            "a retired driver armed a one-shot — a late wake, path update or session end "
                + "opened an outage after teardown")
        XCTAssertEqual(
            harness.source.callCount, 0,
            "a retired driver asked its source for a session")
        XCTAssertEqual(late.tickCount, 0, "a runner adopted after retirement was driven")
        XCTAssertTrue(harness.surrenders.isEmpty, "a retired driver called the surrender sink")
    }

    /// A runner adopted after retirement is not even RETAINED.
    ///
    /// The first version of the inert-entry-points test could not see this: `adopt` without
    /// its guard stores the runner, but `rescheduleTick` and `tick` are independently
    /// quiesce-guarded, so nothing schedules and nothing is driven — every behavioural
    /// assertion holds while the driver silently re-forms the exact cycle `retire()` exists
    /// to break (a production runner's `events` sink is the driver) and retains the late
    /// runner and everything it holds for the rest of the process. Retention is the
    /// observable; the mutation that drops the guard survives anything weaker.
    func testARetiredDriverDoesNotRetainALateAdoptedRunner() throws {
        let harness = try DriverHarness()
        harness.driver.retire()

        var late: StubSession? = StubSession()
        weak let lateReleased = late
        harness.driver.adopt(late!)
        late = nil

        XCTAssertNil(
            lateReleased,
            "a retired driver retained a late-adopted runner — the cycle retire() breaks "
                + "was re-formed after teardown")
    }

    /// A retired driver refuses batches — and only a retired one.
    ///
    /// The Bool exists for the read loop that captured this driver: provider instances
    /// are reused across starts, so a stale loop can fire after its lifecycle tore down,
    /// and without the refusal it would re-arm forever, stealing batches the retired
    /// driver drops whole. A SURRENDERED driver still accepts: its lifecycle is alive
    /// and the restart is on its way — refusing there would kill the live loop early.
    func testARetiredDriverRefusesBatchesSoAStaleLoopCanStop() throws {
        let harness = try DriverHarness()
        XCTAssertTrue(
            harness.driver.handleOutboundBatch([Data([1])], protocols: [NSNumber(value: AF_INET)]),
            "a live driver must keep the loop re-arming")

        harness.beginSilentOutage()
        harness.clock.advance(ChainedReconnectPolicy.maximumBlackholeSeconds + 1)
        for _ in 0..<3 {
            harness.fireDue()
            harness.driver.tick()
            if harness.driver.hasSurrenderedChaining() { break }
        }
        XCTAssertTrue(harness.driver.hasSurrenderedChaining(), "precondition: surrendered")
        XCTAssertTrue(
            harness.driver.handleOutboundBatch([Data([1])], protocols: [NSNumber(value: AF_INET)]),
            "a surrendered driver's lifecycle is still alive — the loop must keep running "
                + "until the restart lands")

        XCTAssertEqual(harness.driver.snapshotCounters().outboundInputPacketCount, 2)
        XCTAssertEqual(harness.driver.snapshotCounters().outboundWithoutRunnerPacketCount, 1)
        harness.driver.retire()
        XCTAssertFalse(
            harness.driver.handleOutboundBatch([Data([1])], protocols: [NSNumber(value: AF_INET)]),
            "a retired driver must refuse, or a stale loop from a previous lifecycle "
                + "competes with the live one for every batch")
        XCTAssertEqual(harness.driver.snapshotCounters().outboundInputPacketCount, 2,
                       "A retired read loop cannot inflate the live lifecycle's input evidence.")
        XCTAssertEqual(harness.driver.snapshotCounters().outboundWithoutRunnerPacketCount, 1)

    }

    /// Retiring mid-outage disarms the deadline, the retry delay and the watchdog.
    ///
    /// `cancel()` cannot retract a handler the queue already holds, so the SLOTS are cleared
    /// too — the same reasoning as `sleep()` — or a due deadline fires against a stale serial
    /// and, with slots intact, surrenders a tunnel that already tore down.
    func testRetiringMidOutageDisarmsEverything() throws {
        let harness = try DriverHarness()
        harness.beginSilentOutage()
        XCTAssertTrue(harness.driver.isTimingAnOutage())
        XCTAssertFalse(
            harness.timers.liveArmed.isEmpty,
            "precondition: the outage armed at least one deadline")

        let serials = harness.timers.allArmedSerials()
        harness.driver.retire()

        XCTAssertTrue(
            harness.timers.liveArmed.isEmpty,
            "retiring mid-outage left a timer armed against a torn-down tunnel")
        // A handler the queue was already handed when retire() cancelled it must decide
        // nothing against the cleared slots — WITH the budget spent, or the assertion
        // cannot fail: inside the budget a retained deadline slot answers `.carryOn`
        // either way, so the first version of this leg fired at outageStart+2 and could
        // not fail. Past the budget, a retained slot surrenders `.budgetExhausted`; a
        // cleared one fails its serial guard on nil (same shaping as the sleep-boundary
        // analog above, which advances past the budget for exactly this reason).
        harness.clock.advance(ChainedReconnectPolicy.maximumBlackholeSeconds + 1)
        let sessionRequestsBeforeFiring = harness.source.callCount
        for serial in serials {
            _ = harness.timers.fireAlreadyDelivered(serial: serial, on: harness.engineQueue)
        }
        XCTAssertTrue(
            harness.surrenders.isEmpty,
            "an already-delivered one-shot surrendered after retirement — the slot was not "
                + "cleared")
        XCTAssertTrue(
            harness.timers.liveArmed.isEmpty,
            "a fired handler re-armed a timer on a retired driver")
        XCTAssertEqual(
            harness.source.callCount, sessionRequestsBeforeFiring,
            "a fired handler asked a retired driver's source for a session")
    }

    // MARK: - The tunnel-DNS cause (S6)

    /// Declares a tunnel-DNS outage the honest way: sustained unanswered resolutions across
    /// two distinct names, then lets the ladder's retry delay elapse so an attempt starts.
    private func declareTunnelDNSOutage(
        _ harness: DriverHarness, names: (UInt64, UInt64) = (0xA1, 0xB2)
    ) {
        harness.report(.unanswered(nameKey: names.0))
        harness.clock.advance(ChainedOutageDriver.tunnelDNSUnservedThresholdSeconds + 1)
        harness.report(.unanswered(nameKey: names.1))
        harness.clock.advance(2)
        harness.fireDue()
    }

    func testATransientTunnelDNSBlipArmsNothing() throws {
        // The transient case, proven (C4): failures across two names inside the threshold,
        // then a served answer — the accumulation clears and a later single failure starts
        // from zero.
        let harness = try DriverHarness()
        harness.report(.unanswered(nameKey: 1))
        harness.report(.unanswered(nameKey: 2))
        harness.clock.advance(5)
        harness.report(.answered)
        harness.clock.advance(ChainedOutageDriver.tunnelDNSUnservedThresholdSeconds + 5)
        harness.report(.unanswered(nameKey: 3))
        XCTAssertFalse(
            harness.driver.isTimingAnOutage(),
            "a cleared accumulation must not carry old failures into a new window")
        XCTAssertEqual(harness.driver.snapshotCounters().tunnelDNSOutageCount, 0)
    }

    func testASingleNameFailureBurstNeverDeclaresAnOutage() throws {
        // The founder's trap, timeout variant (resolved decision 3): one fragmenting or
        // OPT-ignoring domain retried by a browser is a continuous single-name failure
        // stream. Resolver-wide evidence it is not; it must never spend the outage budget.
        let harness = try DriverHarness()
        for _ in 0..<20 {
            harness.report(.unanswered(nameKey: 0xDEAD))
            harness.clock.advance(3)
        }
        XCTAssertFalse(harness.driver.isTimingAnOutage())
        XCTAssertEqual(harness.driver.snapshotCounters().tunnelDNSOutageCount, 0)
        XCTAssertEqual(
            harness.driver.snapshotCounters().tunnelDNSUnansweredObservationCount, 20,
            "the observations are still counted — the diagnostic distinguishes one broken domain from a dead resolver")
    }

    func testAnsweredObservationsArmNothing() throws {
        // The TC burst arrives HERE as answered — the provider maps a truncated answer to
        // liveness before it ever reaches this door — so a browser retrying one large
        // domain arms nothing whatever the cadence.
        let harness = try DriverHarness()
        for _ in 0..<10 {
            harness.report(.answered)
            harness.clock.advance(3)
        }
        XCTAssertFalse(harness.driver.isTimingAnOutage())
        XCTAssertEqual(harness.driver.snapshotCounters().tunnelDNSAnsweredObservationCount, 10)
    }

    func testSustainedFailuresAcrossTwoNamesDeclareAnOutage() throws {
        let harness = try DriverHarness()
        let attemptsBefore = harness.source.callCount
        declareTunnelDNSOutage(harness)
        XCTAssertTrue(
            harness.driver.isTimingAnOutage(),
            "two distinct names past the threshold is the declaration predicate")
        XCTAssertEqual(harness.driver.snapshotCounters().tunnelDNSOutageCount, 1)
        XCTAssertGreaterThan(
            harness.source.callCount, attemptsBefore,
            "the declaration must reach the ladder — an outage nothing attempts to fix is a stall, not a recovery")
    }

    func testLinkEvidenceDoesNotEndATunnelDNSOutage() throws {
        // The per-cause half of the recovery predicate. On a healthy link with a dead
        // resolver, every keepalive is link evidence; ending the outage on it re-arms the
        // cause a threshold later and the kill-rebuild cycle never surrenders — unbounded
        // fail-closed.
        let harness = try DriverHarness()
        declareTunnelDNSOutage(harness)
        harness.currentSession.pretendAuthenticatedPeerDatagram()
        harness.currentSession.pretendInboundData()
        harness.driver.tick()
        XCTAssertTrue(
            harness.driver.isTimingAnOutage(),
            "link evidence ended an outage the tunnel-DNS cause holds")
    }

    func testAServedAnswerEndsATunnelDNSOutage() throws {
        // The cause's own disarming observation (C4): the answer clears the hold, its
        // delivery is inbound data, and the next sample converges through the shared
        // predicate.
        let harness = try DriverHarness()
        declareTunnelDNSOutage(harness)
        harness.report(.answered)
        harness.currentSession.pretendInboundData()
        harness.driver.tick()
        XCTAssertFalse(
            harness.driver.isTimingAnOutage(),
            "a served answer plus delivery evidence must end the outage")
    }

    func testARungRescueDisarmsTheTunnelDNSCauseWithoutClaimingTheTunnelWorks() throws {
        // BOTH halves of the rule, because either alone is a defect.
        //
        // The DISARM half: the tunnel-DNS cause's premise is that the user is losing DNS, and a
        // served physical T1 rung is direct proof they are not. Before this, the cause's only
        // disarming observation was a served answer from T0 — so a T0 that structurally cannot
        // answer a class of names held the outage open to the budget and surrendered a session
        // whose DNS the rung was serving (field 2026-09-01).
        //
        // The RESTRAINT half: the rung egresses on the PHYSICAL interface, so it says nothing
        // about the tunnel. It must not close a link outage, which has its own disarming
        // observation — the same edge `testAnAnsweredObservationDoesNotEndALinkOutage` guards,
        // and a stronger claim here because the rung never touched the tunnel at all.
        let harness = try DriverHarness()
        declareTunnelDNSOutage(harness)
        XCTAssertTrue(harness.driver.isTimingAnOutage(), "precondition: the DNS outage is open")

        harness.reportRungRescue()

        XCTAssertFalse(
            harness.driver.isTimingAnOutage(),
            "a rung rescue left its own cause's outage open — the user had DNS the whole time")
        XCTAssertTrue(harness.surrenders.isEmpty)
        XCTAssertEqual(
            harness.driver.snapshotCounters().tierOneRungRescueObservationCount, 1,
            "the rescue must be legible in a field capture, not inferred from a counter's absence")

        // The restraint half, on a fresh link outage: the rescue leaves it timing AND leaves its
        // budget unrefunded, so the ladder still ends where it was always going to end.
        let link = try DriverHarness()
        link.beginSilentOutage()
        XCTAssertTrue(link.driver.isTimingAnOutage(), "precondition: a link outage is open")

        link.reportRungRescue()

        XCTAssertTrue(
            link.driver.isTimingAnOutage(),
            "a rung that never touched the tunnel closed a LINK outage")
        link.clock.advance(ChainedReconnectPolicy.maximumBlackholeSeconds + 1)
        for _ in 0..<3 where !link.driver.hasSurrenderedChaining() {
            link.fireDue()
            link.driver.tick()
        }
        XCTAssertTrue(
            link.driver.hasSurrenderedChaining(),
            "the rescue bought the link outage fresh time — it refunds no budget (INV-CHAIN-3)")
    }

    func testASplitTunnelUpstreamThatOnlyAnswersItsOwnNamesNeverSurrenders() throws {
        // THE FIELD CASE, end to end. A split-tunnel profile with `DNS = 100.100.100.100` and
        // `AllowedIPs = 100.64.0.0/10`: MagicDNS answers tailnet names and drops public ones, so
        // every public query is a tunnelled non-answer that the physical rung then serves. Two
        // captures on 2026-09-01 surrendered at 07:18 and 09:35 with `hasHandshake: true`, 468 KB
        // and 2.7 MB flowing, and 204 public names resolved in the window before the second.
        //
        // Walked well past the budget with the rescues interleaved exactly as they arrive in the
        // field — one per unanswered T0 lookup — because the defect was never a single lost
        // observation: the cause re-armed on every subsequent miss, so any fix that only disarms
        // once still surrenders on the next name.
        let harness = try DriverHarness()
        for name in 0..<24 {
            harness.report(.unanswered(nameKey: UInt64(name)))
            harness.reportRungRescue()
            harness.clock.advance(ChainedOutageDriver.tunnelDNSUnservedThresholdSeconds + 1)
            harness.fireDue()
        }
        XCTAssertFalse(
            harness.driver.isTimingAnOutage(),
            "a T0 answering only its own namespace read as a dead resolver, while the rung served")
        XCTAssertEqual(
            harness.driver.snapshotCounters().tunnelDNSOutageCount, 0,
            "the tunnel-DNS cause declared against a user who never lost a lookup")
        XCTAssertTrue(
            harness.surrenders.isEmpty,
            "chaining surrendered a healthy session whose DNS was working — the 2026-09-01 defect")
    }

    func testATunnelDNSOutageSurrendersOnBudgetExpiry() throws {
        // The recovery is surrender, never leak (S6): a resolver that stays dead walks the
        // ladder and ends in DNS-only through the one funnel.
        let harness = try DriverHarness()
        declareTunnelDNSOutage(harness)
        harness.clock.advance(ChainedReconnectPolicy.maximumBlackholeSeconds + 1)
        harness.fireDue()
        XCTAssertEqual(harness.surrenders, [.budgetExhausted])
    }

    func testASecondTunnelDNSOutageReachesTheLadderToo() throws {
        // The receipt-less-once trap: a synthesized end that fails to name
        // `lastRetiredReceipt` fixes the FIRST outage's ladder and leaves every later one
        // dead. Only a second outage can prove the naming.
        let harness = try DriverHarness()
        for _ in 0..<4 { harness.source.push(StubSession()) }
        declareTunnelDNSOutage(harness)
        harness.report(.answered)
        harness.currentSession.pretendInboundData()
        harness.driver.tick()
        XCTAssertFalse(harness.driver.isTimingAnOutage(), "recovery between the two outages failed")

        let attemptsBeforeSecond = harness.source.callCount
        declareTunnelDNSOutage(harness, names: (0xC3, 0xD4))
        XCTAssertTrue(harness.driver.isTimingAnOutage())
        XCTAssertGreaterThan(
            harness.source.callCount, attemptsBeforeSecond,
            "the second tunnel-DNS outage never reached the ladder — the synthesized end is receipt-less")
    }

    func testTimeoutsDuringALinkOutageDoNotHoldIt() throws {
        // During an outage the runner is down for whole stretches, so resolution timeouts
        // are EXPECTED and say nothing about the resolver. Counting them would let a link
        // outage acquire a DNS hold — and a recovered link would then wait on DNS traffic
        // that may never come, surrendering a healthy tunnel.
        let harness = try DriverHarness()
        harness.beginSilentOutage()
        XCTAssertTrue(harness.driver.isTimingAnOutage())
        harness.report(.unanswered(nameKey: 1))
        harness.clock.advance(ChainedOutageDriver.tunnelDNSUnservedThresholdSeconds + 1)
        harness.report(.unanswered(nameKey: 2))
        harness.currentSession.pretendAuthenticatedPeerDatagram()
        harness.currentSession.pretendInboundData()
        harness.driver.tick()
        XCTAssertFalse(
            harness.driver.isTimingAnOutage(),
            "a link outage must still end on link evidence — DNS timeouts during it are not a hold")
    }

    func testAPathTransitionDoesNotReleaseATunnelDNSOutage() throws {
        // A roam does not make a dead resolver less dead: the transition resets the
        // ACCUMULATION latches, but an open tunnel-DNS outage keeps its hold until a served
        // answer.
        //
        // SHAPED so the post-roam evidence has a live runner to arrive through: a mid-outage
        // transition tears the runner down, and evidence pretended into a session the driver
        // no longer reads leaves the sample empty — the assertion then holds whatever the
        // hold logic does (a mutation proved that shape vacuous). The ladder's next attempt
        // is allowed to build first, and only then is link evidence delivered.
        let harness = try DriverHarness()
        declareTunnelDNSOutage(harness)
        harness.driver.pathChanged(satisfied: true, interfacesChanged: true)
        harness.clock.advance(3)
        harness.fireDue()
        XCTAssertTrue(
            harness.driver.isTimingAnOutage(),
            "precondition: the outage must still be open once the post-roam attempt builds")
        harness.currentSession.pretendAuthenticatedPeerDatagram()
        harness.currentSession.pretendInboundData()
        harness.driver.tick()
        XCTAssertTrue(
            harness.driver.isTimingAnOutage(),
            "a path transition released a tunnel-DNS hold — the first post-roam keepalive would end every such outage")
    }

    func testAWakeClearsTheTunnelDNSAccumulation() throws {
        // Evidence gathered before a suspension says nothing about the resolver on the
        // other side of it — same rationale as the silence clock's wake reset.
        let harness = try DriverHarness()
        harness.report(.unanswered(nameKey: 1))
        harness.driver.sleep()
        harness.clock.advance(5)
        harness.driver.wake()
        harness.clock.advance(ChainedOutageDriver.tunnelDNSUnservedThresholdSeconds + 1)
        harness.report(.unanswered(nameKey: 2))
        XCTAssertFalse(
            harness.driver.isTimingAnOutage(),
            "a pre-sleep failure joined a post-wake window — the accumulation survived the suspension")
    }

    func testObservationsWhileOfflineDoNotAccumulate() throws {
        // Offline, every resolution fails locally; none of it is resolver evidence.
        let harness = try DriverHarness()
        harness.driver.pathChanged(satisfied: false, interfacesChanged: false)
        harness.report(.unanswered(nameKey: 1))
        harness.clock.advance(ChainedOutageDriver.tunnelDNSUnservedThresholdSeconds + 1)
        harness.report(.unanswered(nameKey: 2))
        XCTAssertFalse(harness.driver.isTimingAnOutage())
        XCTAssertEqual(harness.driver.snapshotCounters().tunnelDNSOutageCount, 0)
    }

    func testAnAnsweredObservationAloneEndsADNSHeldOutage() throws {
        // The disarming observation must END the outage, not merely clear the hold and hope
        // a later sample notices. The liveness sample is read-and-clear and the answer's
        // packet is delivered BEFORE the resolution completes, so an ordinary tick in
        // between consumes that evidence while the hold is still set — and with no further
        // authenticated datagram the outage would run to surrender on a resolver that had
        // recovered. No tick, no pretended evidence here: the observation is the whole
        // stimulus.
        let harness = try DriverHarness()
        declareTunnelDNSOutage(harness)
        XCTAssertTrue(harness.driver.isTimingAnOutage(), "precondition: the DNS outage is open")

        harness.report(.answered)

        XCTAssertFalse(
            harness.driver.isTimingAnOutage(),
            "a served answer left its own outage open — recovery depended on evidence that may already be spent")
        XCTAssertTrue(harness.surrenders.isEmpty)
    }

    func testAnAnsweredObservationDoesNotEndALinkOutage() throws {
        // The other edge of the same rule: a cause ends the outage IT holds. DNS answering
        // proves the link carried one datagram; it is not the claim the link arm makes, and
        // closing a link outage on it would discard the ladder mid-recovery.
        let harness = try DriverHarness()
        harness.beginSilentOutage()
        XCTAssertTrue(harness.driver.isTimingAnOutage(), "precondition: a link outage is open")

        harness.report(.answered)

        XCTAssertTrue(
            harness.driver.isTimingAnOutage(),
            "a DNS answer closed a LINK outage it does not hold")
    }

    func testAnObservationIsTimedWhenItHappensNotWhenItIsHandled() throws {
        // The door hops asynchronously, so reading the clock in the handler folds queue
        // latency into the measured failure interval. Here the queue is held shut across
        // the whole threshold: both observations are HANDLED at the same instant, and only
        // an observation carrying its own occurrence time can still tell them apart. With
        // handler-time stamping the interval reads as zero and the dead resolver — with
        // sparse queries and no timer to re-evaluate — fails closed indefinitely.
        let harness = try DriverHarness()
        let blocked = DispatchSemaphore(value: 0)
        let released = DispatchSemaphore(value: 0)
        harness.engineQueue.enqueue {
            blocked.signal()
            released.wait()
        }
        XCTAssertEqual(blocked.wait(timeout: .now() + 5), .success, "the queue never got busy")

        let driver = harness.driver
        driver.reportTunnelDNSObservation(.unanswered(nameKey: 0xA1))
        harness.clock.advance(ChainedOutageDriver.tunnelDNSUnservedThresholdSeconds + 1)
        driver.reportTunnelDNSObservation(.unanswered(nameKey: 0xB2))
        released.signal()
        _ = harness.driver.snapshotCounters()  // barrier: both observations are now handled

        XCTAssertEqual(
            harness.driver.snapshotCounters().tunnelDNSOutageCount, 1,
            "failures a threshold apart were measured as simultaneous — the interval was the queue's, not the resolver's")
    }

    func testAPreemptedProducerCannotReorderObservations() throws {
        // Stamping and submitting must be ONE step. The door is Sendable and may be called
        // concurrently, so a producer preempted between the clock read and the enqueue lets
        // a LATER observation reach the queue first — and then the newer stamp is installed
        // as the accumulation start, the older one reads as negative elapsed, and two
        // failures a threshold apart never declare.
        //
        // The window is one instruction wide, so it is opened deliberately: the first
        // producer is stalled INSIDE its clock read while the second runs to completion.
        let harness = try DriverHarness()
        let gate = harness.clock.stallNextRead()
        let driver = harness.driver

        let firstSubmitted = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            driver.reportTunnelDNSObservation(.unanswered(nameKey: 0xA1))  // stamped t=0
            firstSubmitted.signal()
        }
        // WAIT FOR THE PRODUCER TO REACH THE READ, never a fixed sleep: a sleep does not
        // establish it ever got there, so on a loaded runner the clock could move first and
        // both producers would stamp the same instant — a test that fails for a reason that
        // has nothing to do with the property.
        XCTAssertEqual(
            gate.entered.wait(timeout: .now() + 5), .success,
            "the first producer never reached the clock read")
        harness.clock.advance(ChainedOutageDriver.tunnelDNSUnservedThresholdSeconds + 1)
        let secondSubmitted = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            driver.reportTunnelDNSObservation(.unanswered(nameKey: 0xB2))  // stamped t=22
            secondSubmitted.signal()
        }
        // The second producer must be blocked on the submission lock, not merely dispatched,
        // or releasing the gate proves nothing about ordering.
        XCTAssertEqual(
            secondSubmitted.wait(timeout: .now() + 1), .timedOut,
            "the second producer completed while the first held the submission lock")
        gate.release.signal()

        XCTAssertEqual(firstSubmitted.wait(timeout: .now() + 5), .success)
        XCTAssertEqual(secondSubmitted.wait(timeout: .now() + 5), .success)
        _ = harness.driver.snapshotCounters()  // barrier: both observations handled

        XCTAssertEqual(
            harness.driver.snapshotCounters().tunnelDNSOutageCount, 1,
            "the observations were handled newest-first — the older stamp could not start the window")
    }

    func testAnObservationThatOutlivedItsWindowCannotSeedTheNextOne() throws {
        // The lock orders observations against EACH OTHER but not against the resets, which
        // submit without taking it. So an observation can be stamped while a reset is
        // already queued ahead of it: the reset clears the window first, and without an
        // epoch that pre-transition timeout would seed the NEW path's window and combine
        // with a later failure into an outage that never happened.
        //
        // STAGED ON THE ROAM'S OWN CLOCK READ, not on a sleep. `pathChanged` reads the clock
        // once, at the call to `recoverAfterPathChange`, which is BEFORE it retires the
        // window — so stalling that read parks the reset on the engine queue with the old
        // epoch still installed, and the observation stamped behind it is guaranteed both to
        // carry the doomed epoch and to be handled after the retirement.
        //
        // The earlier version slept 50 ms and hoped the roam reached the queue first. It
        // established nothing: on a loaded runner the queue drains as [observation, reset]
        // instead, the observation arms the window and the reset then clears it, and the test
        // still passes — vacuously, since the epoch gate never ran (Kilo, PR #513). Stalling
        // the RESET rather than the producer is also what keeps this deadlock-free: a producer
        // stalled inside the submission lock would deadlock the reset, which takes that lock.
        let harness = try DriverHarness()
        let driver = harness.driver
        let (entered, release) = harness.clock.stallNextRead()
        let roamed = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            driver.pathChanged(satisfied: true, interfacesChanged: true)
            roamed.signal()
        }
        XCTAssertEqual(
            entered.wait(timeout: .now() + 5), .success,
            "the roam never reached its clock read, so the interleaving was never staged")

        // Submitted WITHOUT the usual barrier: `report` settles by syncing onto the engine
        // queue, which is exactly the queue the stalled roam is holding.
        driver.reportTunnelDNSObservation(.unanswered(nameKey: 0xA1))
        release.signal()
        XCTAssertEqual(roamed.wait(timeout: .now() + 5), .success)

        // THE MECHANISM, not just the consequence. `tunnelDNSUnansweredObservationCount`
        // reads 1 under either interleaving — it increments before the gate — so only this
        // counter distinguishes "dropped by the epoch" from "cleared by the reset", which is
        // what makes the assertions below non-vacuous.
        XCTAssertEqual(
            harness.driver.snapshotCounters().tunnelDNSStaleObservationCount, 1,
            "the observation was not dropped by the epoch gate — it was merely cleared "
                + "afterwards, so this test proves nothing about the gate")

        // A single fresh failure a threshold later must NOT declare: the only other failure
        // belongs to a window that no longer exists.
        harness.clock.advance(ChainedOutageDriver.tunnelDNSUnservedThresholdSeconds + 1)
        harness.report(.unanswered(nameKey: 0xB2))
        XCTAssertFalse(
            harness.driver.isTimingAnOutage(),
            "a timeout from a retired window seeded the new one")
        XCTAssertEqual(harness.driver.snapshotCounters().tunnelDNSOutageCount, 0)
    }

    func testAnAnswerDuringTheRetryDelayLeavesSomethingArmed() throws {
        // `INV-CHAIN-3` — something is always armed inside the budget — violated through the
        // door S6 added. The declaration itself tears the runner down (`startOutageClock`),
        // and only `startAuthorizedAttempt` builds another, so an answer arriving during the
        // retry delay that follows found an outage with NO session. Ending it there cancelled
        // the retry delay and the deadline, while `rescheduleTick` cancelled the tick for want
        // of a runner: no session, nothing armed, no surrender reported — a permanent
        // blackhole. Identical in shape to `testWakingDuringARetryDelayLeavesSomethingArmed`,
        // reached through an observation instead of a wake.
        let harness = try DriverHarness()
        harness.report(.unanswered(nameKey: 0xA1))
        harness.clock.advance(ChainedOutageDriver.tunnelDNSUnservedThresholdSeconds + 1)
        harness.report(.unanswered(nameKey: 0xB2))
        XCTAssertTrue(harness.driver.isTimingAnOutage(), "precondition: the DNS outage is open")
        // NO `fireDue` above, deliberately: this is the state between the declaration and the
        // ladder's first attempt, which is exactly where the runner is nil.
        XCTAssertTrue(
            harness.source.handedOut.isEmpty,
            "precondition: the ladder has not been asked for a replacement yet, so the driver "
                + "holds no runner")

        harness.report(.answered)

        XCTAssertFalse(
            harness.driver.hasSurrenderedChaining(),
            "the answer surrendered chaining instead of letting the ladder rebuild")
        XCTAssertFalse(
            harness.timers.liveArmedSeconds().isEmpty,
            "nothing is armed after the answer — no runner, no timer, no tick, and no "
                + "surrender: the tunnel can never recover and INV-CHAIN-3 is violated")

        // AND THE HOLD REALLY WAS RELEASED. Staying armed would also be satisfied by doing
        // nothing at all, so the recovery is walked to its end: the ladder rebuilds, and the
        // replacement session's inbound data ends the outage through `sampleLiveness` — which
        // only a released hold permits.
        for _ in 0..<8 where harness.source.handedOut.isEmpty {
            harness.clock.advance(1)
            harness.fireDue()
        }
        XCTAssertFalse(
            harness.source.handedOut.isEmpty,
            "the ladder never built a replacement, so the recovery below proves nothing")
        harness.currentSession.pretendInboundData()
        harness.driver.tick()
        XCTAssertFalse(
            harness.driver.isTimingAnOutage(),
            "the answer left the DNS hold set, so the rebuilt session's own traffic could "
                + "not end the outage it recovered from")
    }

    func testAnAnswerRetiresTheObservationWindowExactlyOnce() throws {
        // A served answer that ends a DNS-held outage passes through two retiring paths — the
        // handler's own clear and `endOutage`'s — and retiring twice for one event is not a
        // tidiness problem. Each retirement invalidates every report in flight, so a producer
        // that stamped a genuinely NEW failure between the two updates was discarded by the
        // epoch gate; with sparse DNS traffic that erases the first failure of the new window
        // and a dead resolver never reaches the declaration predicate again.
        //
        // Asserted on the retirement tally rather than by staging the interleaving: the gap
        // between the two updates is a few instructions on the engine queue, so a racing
        // producer could not be scheduled into it deterministically. The tally is incremented
        // in the single function that retires, so it cannot drift from the epoch it counts.
        let harness = try DriverHarness()
        declareTunnelDNSOutage(harness)
        XCTAssertTrue(harness.driver.isTimingAnOutage(), "precondition: the DNS outage is open")
        XCTAssertFalse(
            harness.source.handedOut.isEmpty,
            "precondition: the ladder holds a runner, so the answer takes the ending path")
        let before = harness.driver.snapshotCounters().tunnelDNSWindowRetirementCount

        harness.report(.answered)

        XCTAssertFalse(harness.driver.isTimingAnOutage(), "precondition: the answer ended the outage")
        XCTAssertEqual(
            harness.driver.snapshotCounters().tunnelDNSWindowRetirementCount - before, 1,
            "one answer retired the observation window twice — an observation stamped between "
                + "the two updates is dropped by the epoch gate although its window was open")
    }

    func testGoingOfflineReleasesATunnelDNSHold() throws {
        // The THIRD end site: `pathChanged(satisfied: false)` ends the outage in the
        // supervisor directly, without going through `endOutage()`. A hold left set there
        // outlives the outage it held — the next outage, from ANY cause, is born held with
        // an empty accumulation, so no `.answered` is ever coming to release it and link
        // evidence can never end it: the budget runs to surrender on a working link. A
        // resolver hiccup followed by an ordinary signal loss is the whole trigger.
        let harness = try DriverHarness()
        for _ in 0..<8 { harness.source.push(StubSession()) }
        declareTunnelDNSOutage(harness)
        harness.driver.pathChanged(satisfied: false, interfacesChanged: false)
        XCTAssertFalse(harness.driver.isTimingAnOutage(), "precondition: going offline ends the outage")

        // Coming back drives the rebind/settle machinery, which opens its own outage and
        // then builds an attempt for it. Walk one second at a time to that state rather
        // than jumping the clock: an advance long enough to be safe would also spend the
        // new outage's budget, and the surrender that followed would end the outage for a
        // reason that has nothing to do with the hold (that shape passed while proving
        // nothing).
        // A lone rebind now spends one re-anchor retry (~one confirmation window) before it opens
        // the recovery outage, so walk far enough to cross BOTH windows — still one second at a
        // time so the advance does not spend the new outage's budget.
        harness.driver.pathChanged(satisfied: true, interfacesChanged: true)
        for _ in 0..<13 {
            harness.clock.advance(1)
            harness.fireDue()
        }
        XCTAssertTrue(harness.driver.isTimingAnOutage(), "precondition: the recovery outage is open")
        XCTAssertEqual(
            harness.driver.snapshotCounters().startedAttemptCount, 2,
            "precondition: the ladder has built a live runner for the evidence to arrive through")

        harness.currentSession.pretendAuthenticatedPeerDatagram()
        harness.currentSession.pretendInboundData()
        harness.driver.tick()
        XCTAssertFalse(
            harness.driver.isTimingAnOutage(),
            "a stale tunnel-DNS hold survived going offline and blocked a LINK outage's recovery")
        XCTAssertTrue(harness.surrenders.isEmpty, "a working link surrendered")
    }

    func testAnOutageEndingClearsTheTunnelDNSAccumulation() throws {
        // The accumulation measures "sustained NOW". An outage ended by LINK evidence
        // involves no observation, so a pre-outage failure timestamp used to survive with no
        // expiry — and one unanswered lookup minutes later, on a second name, declared
        // instantly against a clock that started before the previous outage.
        let harness = try DriverHarness()
        harness.report(.unanswered(nameKey: 1))
        harness.beginSilentOutage()
        harness.currentSession.pretendAuthenticatedPeerDatagram()
        harness.currentSession.pretendInboundData()
        harness.driver.tick()
        XCTAssertFalse(harness.driver.isTimingAnOutage(), "precondition: the link outage ended")

        harness.clock.advance(600)
        harness.report(.unanswered(nameKey: 2))
        XCTAssertFalse(
            harness.driver.isTimingAnOutage(),
            "a single failure declared instantly against a timestamp from before the last recovery")
        XCTAssertEqual(harness.driver.snapshotCounters().tunnelDNSOutageCount, 0)
    }

    func testTheTunnelDNSCauseIsBoundedPerLifecycle() throws {
        // The bound that makes a chosen-traffic cause safe beside an unforgeable one. Each
        // declaration tears the session down and rebuilds it — a blackhole for ALL traffic —
        // and a domain an attacker controls supplies unlimited distinct name keys on demand,
        // so the two-name floor is an accident defence, not an adversary one.
        let harness = try DriverHarness()
        for _ in 0..<24 { harness.source.push(StubSession()) }
        var key: UInt64 = 0
        for cycle in 0..<(ChainedOutageDriver.maximumTunnelDNSOutagesPerLifecycle + 3) {
            key += 2
            declareTunnelDNSOutage(harness, names: (key, key + 1))
            if cycle < ChainedOutageDriver.maximumTunnelDNSOutagesPerLifecycle {
                XCTAssertTrue(
                    harness.driver.isTimingAnOutage(), "cycle \(cycle) should have declared")
                // Recover, so the next cycle starts from a clean session exactly as a
                // repeating attacker would let it.
                harness.report(.answered)
                harness.currentSession.pretendInboundData()
                harness.driver.tick()
                XCTAssertFalse(harness.driver.isTimingAnOutage(), "cycle \(cycle) did not recover")
            }
        }
        XCTAssertEqual(
            harness.driver.snapshotCounters().tunnelDNSOutageCount,
            ChainedOutageDriver.maximumTunnelDNSOutagesPerLifecycle,
            "the cause declared past its per-lifecycle bound — an unbounded chosen-traffic blackhole")
        XCTAssertFalse(
            harness.driver.isTimingAnOutage(),
            "a declaration past the cap opened an outage")
        XCTAssertTrue(harness.surrenders.isEmpty)
    }

    func testTheObservationDoorNeverBlocksItsCaller() throws {
        // INV-QUEUE-1: the door must not park its caller behind the engine queue. Reporting
        // while the queue is occupied has to return immediately; the work lands later.
        let harness = try DriverHarness()
        let occupied = DispatchSemaphore(value: 0)
        let released = DispatchSemaphore(value: 0)
        harness.engineQueue.enqueue {
            occupied.signal()
            released.wait()
        }
        XCTAssertEqual(occupied.wait(timeout: .now() + 5), .success, "the queue never got busy")

        let returned = DispatchSemaphore(value: 0)
        // The driver itself is Sendable; the harness is not, so the closure captures only
        // the driver.
        let driver = harness.driver
        DispatchQueue.global().async {
            driver.reportTunnelDNSObservation(.unanswered(nameKey: 1))
            returned.signal()
        }
        let verdict = returned.wait(timeout: .now() + 2)
        released.signal()
        XCTAssertEqual(
            verdict, .success,
            "the door blocked its caller on a busy engine queue — a synchronous hop from the DNS path")
    }

    func testATunnelDNSObservationAfterRetirementIsInert() throws {
        let harness = try DriverHarness()
        harness.driver.retire()
        harness.report(.unanswered(nameKey: 1))
        harness.clock.advance(ChainedOutageDriver.tunnelDNSUnservedThresholdSeconds + 1)
        harness.report(.unanswered(nameKey: 2))
        XCTAssertFalse(harness.driver.isTimingAnOutage())
        XCTAssertTrue(harness.timers.liveArmed.isEmpty, "a retired driver armed a timer from a DNS observation")
    }

    func testTheNameKeyIsOneFactPerNormalizedName() {
        // The declaration floor counts distinct KEYS; the producer's canonical hasher is
        // what makes distinct keys mean distinct NAMES. Same normalized name → same key
        // (a browser retry burst of one domain must never read as two names), distinct
        // names → distinct keys (or the floor could never be met), and the empty name is
        // an ordinary input rather than a crash.
        typealias Observation = ChainedOutageDriver.TunnelDNSObservation
        XCTAssertEqual(
            Observation.nameKey(forNormalizedName: "example.com"),
            Observation.nameKey(forNormalizedName: "example.com"))
        XCTAssertNotEqual(
            Observation.nameKey(forNormalizedName: "example.com"),
            Observation.nameKey(forNormalizedName: "example.org"))
        XCTAssertNotEqual(
            Observation.nameKey(forNormalizedName: "a.example.com"),
            Observation.nameKey(forNormalizedName: "b.example.com"))
        _ = Observation.nameKey(forNormalizedName: "")
    }

    /// Slice C / Codex #554: the driver stamps its session generation onto each byte sample and
    /// bumps it on every runner swap, so the provider can tell two samples apart across a session
    /// boundary — where the engine's byte totals reset and a bare monotonicity check would
    /// mis-difference (a replacement can accumulate PAST the old total within one window).
    func testSnapshotStatisticsStampsAGenerationThatBumpsOnRunnerSwap() throws {
        let harness = try DriverHarness(provideSessions: true)
        harness.session.stubStatistics = ChainedRunnerStatistics(
            transmittedByteCount: 1_000, receivedByteCount: 500, hasHandshake: true)
        let first = try XCTUnwrap(harness.driver.snapshotStatistics())
        XCTAssertEqual(first.transmittedByteCount, 1_000)
        XCTAssertEqual(first.sessionGeneration, 1, "one adopt = generation 1, not the runner's default 0")

        // A rebuild swaps in a new session (its byte totals reset); the generation must advance so
        // the provider does not difference the new total against the old one.
        harness.beginSilentOutage()
        harness.currentSession.stubStatistics = ChainedRunnerStatistics(
            transmittedByteCount: 42, receivedByteCount: 7, hasHandshake: true)
        let second = try XCTUnwrap(harness.driver.snapshotStatistics())
        XCTAssertEqual(second.transmittedByteCount, 42, "reads the NEW session's totals")
        XCTAssertGreaterThan(
            second.sessionGeneration, first.sessionGeneration,
            "a runner swap must advance the session generation")
    }

    // MARK: - Egress-dead cause (link healthy, upstream forwarding dead)

    private func stats(forwarded: UInt64) -> ChainedRunnerStatistics {
        ChainedRunnerStatistics(
            transmittedByteCount: 0, receivedByteCount: 0,
            hasHandshake: true, forwardedNonDNSByteCount: forwarded)
    }

    private func anchorForwardingBaseline(_ harness: DriverHarness, bytes: UInt64 = 1_000) {
        // The chain forwarded at connect; the connect gate required it. Anchor that baseline so a
        // later flatline is measured from real forwarding, not from a never-forwarding session.
        harness.currentSession.stubStatistics = stats(forwarded: bytes)
        harness.driver.tick()
    }

    /// One tick of the egress-dead world: the link answers (a keepalive) and the user asks for
    /// general traffic, but not one byte is forwarded — the byte total does not move.
    private func tickLinkAliveWithDemand(_ harness: DriverHarness) {
        harness.currentSession.pretendAuthenticatedPeerDatagram()
        harness.currentSession.pretendObligingNonDNSSend()
        harness.driver.tick()
    }

    /// Drives `seconds` of SUSTAINED egress-dead demand from the current time: the user keeps asking
    /// for general traffic (a send every step, steps kept under the continuity gap so the window
    /// never lapses) on a live chain whose byte total is flat. Call `anchorForwardingBaseline` first
    /// so the session generation is stable — otherwise a generation change absorbs the first tick.
    private func driveSustainedEgressDeadDemand(_ harness: DriverHarness, seconds: Int) {
        let step = ChainedOutageDriver.egressDeadDemandContinuitySeconds - 1
        tickLinkAliveWithDemand(harness)
        var elapsed = 0
        while elapsed < seconds {
            let advance = min(step, seconds - elapsed)
            harness.clock.advance(advance)
            elapsed += advance
            tickLinkAliveWithDemand(harness)
        }
    }

    func testSustainedNonDNSDemandWithoutForwardingDeclaresAnOutage() throws {
        // THE ANTI-VACUITY MUST-FIRE. A chain whose WireGuard link answers every send but whose
        // upstream forwards nothing to the internet, while the user keeps asking for general
        // traffic, is the "Protected over a dead path" fault. Without this arm nothing notices:
        // link silence stays quiet (the peer answers) and tunnel-DNS stays quiet (a SERVFAIL is
        // an answer).
        let harness = try DriverHarness()
        anchorForwardingBaseline(harness)

        driveSustainedEgressDeadDemand(harness, seconds: ChainedOutageDriver.egressDeadThresholdSeconds - 3)
        XCTAssertFalse(harness.driver.isTimingAnOutage(), "declared before the threshold")

        driveSustainedEgressDeadDemand(harness, seconds: 5) // continues asking, now past the threshold
        XCTAssertTrue(
            harness.driver.isTimingAnOutage(),
            "a chain forwarded nothing for the full threshold while the user asked, and nothing noticed")
    }

    func testASplitTunnelNeverDeclaresAnEgressDeadOutage() throws {
        // THE SPLIT-TUNNEL COUNTERPART to the must-fire above, and its mutation guard: the EXACT
        // same script — the user sustainedly asking for general traffic while the forwarding counter
        // stays flat — that MUST declare in full tunnel must NOT declare in split. In split the
        // runner still carries the configured `AllowedIPs` traffic, so `sawObligingNonDNSSend` fires
        // on those sends too; a cached or literal `AllowedIPs` host that is merely unresponsive
        // leaves the counter flat on a perfectly HEALTHY chain, and no unrelated DNS reply is
        // guaranteed inside the window to reset it — so this arm is confined to full tunnel, where a
        // dead forwarding counter under demand is unambiguous (Codex, PR #567). Remove the routing
        // gate and this fails: same stimulus, the full-tunnel sibling proves it declares.
        let harness = try DriverHarness(routingPolicy: .splitTunnel)
        anchorForwardingBaseline(harness)

        driveSustainedEgressDeadDemand(harness, seconds: ChainedOutageDriver.egressDeadThresholdSeconds + 10)

        XCTAssertFalse(
            harness.driver.isTimingAnOutage(),
            "a split tunnel declared egress-dead on a flat counter — a silent AllowedIPs host is not "
                + "a dead upstream, and general traffic bypasses the tunnel entirely")
        XCTAssertTrue(
            harness.surrenders.isEmpty,
            "a split tunnel must never surrender the chain through the egress-dead cause")
    }

    func testASplitTunnelStillReportsAnUnansweredDestination() throws {
        // THE POINT OF THE SLICE, stated against its own guard. The test directly above proves a
        // split tunnel never DECLARES egress-dead, and that confinement must stay (PR #567): a
        // flat aggregate is not proof of dead egress while the runner still carries the
        // configured AllowedIPs traffic. But the confinement left split tunnel with no
        // forwarding-health signal of any kind, which is how the 2026-08-27 capture reported
        // "healthy" through a total connection failure. A per-destination reading is not an
        // aggregate and a read-only one is not a gate, so neither of that reason's halves reaches
        // it — and it must surface under BOTH routing policies.
        let harness = try DriverHarness(routingPolicy: .splitTunnel)
        harness.session.stubCounters.unansweredDestinationCount = 1
        harness.session.stubCounters.longestUnansweredDestinationSeconds = 34

        let counters = harness.driver.snapshotCounters()
        XCTAssertEqual(
            counters.unansweredDestinationCount, 1,
            "a split tunnel reported nothing about a destination that is not answering")
        XCTAssertEqual(counters.longestUnansweredDestinationSeconds, 34)
        XCTAssertEqual(
            counters.egressDeadOutageCount, 0,
            "reporting a silent destination declared an outage — this signal gates nothing")
        XCTAssertTrue(harness.surrenders.isEmpty)
    }

    func testTheReachabilityLevelsAreAssignedFromTheLiveRunnerNotAccumulated() throws {
        // The pressure tallies beside these are folded across retired runners so a 60 s delta
        // stays honest. These two must NOT be: they are levels stamped from the live destination
        // table, so accumulating them would report a wait nothing is still waiting on, growing
        // with every poll.
        let harness = try DriverHarness()
        harness.session.stubCounters.unansweredDestinationCount = 2
        harness.session.stubCounters.longestUnansweredDestinationSeconds = 21

        for _ in 0..<3 {
            let counters = harness.driver.snapshotCounters()
            XCTAssertEqual(counters.unansweredDestinationCount, 2)
            XCTAssertEqual(counters.longestUnansweredDestinationSeconds, 21)
        }
    }

    func testAnEgressDeadDeclarationIncrementsItsOwnAttributionCounter() throws {
        // The egress-dead surrender logs the generic `budgetExhausted` reason, so
        // `egressDeadOutageCount` is what lets a device log (and the owed device proof) attribute an
        // outage to THIS arm rather than link-silence or the DNS arm. It must advance on an
        // egress-dead declaration while the DNS arm's counter stays flat, and stay a subset of the
        // total outage count (PR #567).
        let harness = try DriverHarness()
        anchorForwardingBaseline(harness)
        XCTAssertEqual(
            harness.driver.snapshotCounters().egressDeadOutageCount, 0, "nothing declared yet")

        driveSustainedEgressDeadDemand(harness, seconds: ChainedOutageDriver.egressDeadThresholdSeconds + 2)

        let counters = harness.driver.snapshotCounters()
        XCTAssertEqual(
            counters.egressDeadOutageCount, 1,
            "an egress-dead declaration must advance its own attribution counter")
        XCTAssertEqual(
            counters.tunnelDNSOutageCount, 0,
            "an egress-dead outage must not be attributed to the tunnel-DNS arm")
        XCTAssertLessThanOrEqual(
            counters.egressDeadOutageCount, counters.outageCount,
            "egress-dead outages are a subset of all outages")
    }

    func testAnIdleChainThatForwardsNothingIsNotAnOutage() throws {
        // An idle chain forwards nothing too, and that is not a fault. Without the demand half a
        // device sitting untouched on a WORKING chain would surrender itself.
        let harness = try DriverHarness()
        anchorForwardingBaseline(harness)

        harness.clock.advance(ChainedOutageDriver.egressDeadThresholdSeconds + 5)
        harness.currentSession.pretendAuthenticatedPeerDatagram() // link alive, but NO demand
        harness.driver.tick()

        XCTAssertFalse(
            harness.driver.isTimingAnOutage(),
            "an idle chain that simply forwarded nothing declared itself dead")
    }

    func testDNSOnlyDemandDoesNotArmEgressDead() throws {
        // The demand half is GENERAL traffic only. A session whose only obliging sends are the
        // tunnel's own resolver queries or forced handshakes sets `sawObligingSend` but NOT
        // `sawObligingNonDNSSend`, so a working chain whose resolver merely ticks — or one still
        // handshaking — cannot be surrendered by this arm.
        let harness = try DriverHarness()
        anchorForwardingBaseline(harness)

        harness.clock.advance(ChainedOutageDriver.egressDeadThresholdSeconds + 5)
        harness.currentSession.pretendAuthenticatedPeerDatagram()
        harness.currentSession.pretendObligingSend() // NOT .obligingNonDNS
        harness.driver.tick()

        XCTAssertFalse(
            harness.driver.isTimingAnOutage(),
            "a DNS-only / handshake-only obliging send armed the egress-dead cause")
    }

    func testForwardingProgressKeepsTheEgressDeadClockFromFiring() throws {
        // A byte delivered within each window resets the demand window: a busy, working chain must
        // never declare no matter how long the user asks.
        let harness = try DriverHarness()
        var forwarded: UInt64 = 1_000
        anchorForwardingBaseline(harness, bytes: forwarded)

        for _ in 0..<5 {
            forwarded += 10 // a byte got through since the last window
            harness.currentSession.stubStatistics = stats(forwarded: forwarded)
            driveSustainedEgressDeadDemand(harness, seconds: ChainedOutageDriver.egressDeadThresholdSeconds - 2)
        }
        XCTAssertFalse(harness.driver.isTimingAnOutage(), "forwarding progress did not keep the window from firing")

        // ANTI-VACUITY: forwarding stops; sustained demand across the threshold declares.
        driveSustainedEgressDeadDemand(harness, seconds: ChainedOutageDriver.egressDeadThresholdSeconds + 1)
        XCTAssertTrue(
            harness.driver.isTimingAnOutage(),
            "forwarding stopped for the full threshold under demand and nothing declared")
    }

    func testIdleTimeBeforeDemandIsNotCountedTowardTheThreshold() throws {
        // The clock measures from DEMAND ONSET, not from the last forwarding: idle time BEFORE the
        // user asks must not count, or a healthy chain surrenders the instant it is touched after an
        // idle spell. (The primary false-surrender the pre-push panel caught.)
        let harness = try DriverHarness()
        anchorForwardingBaseline(harness)

        // Idle across the threshold: link alive, byte total flat, NO demand. Keep sampling.
        for _ in 0..<8 {
            harness.clock.advance(3)
            harness.currentSession.pretendAuthenticatedPeerDatagram()
            harness.driver.tick()
        }
        XCTAssertFalse(harness.driver.isTimingAnOutage(), "idle time armed the window before any demand")

        // The user finally asks ONCE: the window anchors HERE, so it cannot already be past threshold.
        harness.currentSession.pretendAuthenticatedPeerDatagram()
        harness.currentSession.pretendObligingNonDNSSend()
        harness.driver.tick()
        XCTAssertFalse(
            harness.driver.isTimingAnOutage(),
            "idle time before the user asked was counted — a healthy chain surrenders on first touch")
    }

    func testAOneShotSendThenIdleNeverDeclares() throws {
        // SUSTAINED demand is required. A single general packet followed by an idle chain — a
        // fire-and-forget send, or the user giving up — must never surrender: the demand window
        // lapses after the continuity gap.
        let harness = try DriverHarness()
        anchorForwardingBaseline(harness)

        harness.currentSession.pretendAuthenticatedPeerDatagram()
        harness.currentSession.pretendObligingNonDNSSend() // one packet
        harness.driver.tick()

        for _ in 0..<9 { // then idle, link alive, well past the threshold
            harness.clock.advance(3)
            harness.currentSession.pretendAuthenticatedPeerDatagram()
            harness.driver.tick()
        }
        XCTAssertFalse(
            harness.driver.isTimingAnOutage(),
            "a one-shot send then an idle chain declared — sustained demand is not enforced")
    }

    private func declareEgressDeadOutage(_ harness: DriverHarness) {
        anchorForwardingBaseline(harness)
        driveSustainedEgressDeadDemand(harness, seconds: ChainedOutageDriver.egressDeadThresholdSeconds + 1)
        // Elapse the retry delay so the rebuilt attempt is live.
        harness.clock.advance(2)
        harness.fireDue()
    }

    func testLinkEvidenceDoesNotEndAnEgressDeadOutage() throws {
        // The deceptive part of egress-dead is a HEALTHY link. If a keepalive could end the
        // outage, the cause would re-arm a threshold later and the kill-rebuild cycle would repeat
        // forever without surrendering — the exact unbounded fail-closed the hold prevents.
        let harness = try DriverHarness()
        declareEgressDeadOutage(harness)
        XCTAssertTrue(harness.driver.isTimingAnOutage())

        harness.currentSession.pretendAuthenticatedPeerDatagram()
        harness.currentSession.pretendInboundData()
        harness.clock.advance(1)
        harness.driver.tick()
        XCTAssertTrue(
            harness.driver.isTimingAnOutage(),
            "link evidence ended an egress-dead outage — the kill-rebuild cycle is back")
    }

    func testRealForwardingEndsAnEgressDeadOutage() throws {
        // THE ANTI-VACUITY of the hold: a delivered non-DNS byte on the rebuilt session — real
        // forwarding resumed — DOES end it. Without this the outage could never recover and the
        // hold would be a permanent trap.
        let harness = try DriverHarness()
        declareEgressDeadOutage(harness)
        XCTAssertTrue(harness.driver.isTimingAnOutage())

        // The rebuilt session delivers bytes.
        harness.currentSession.stubStatistics = stats(forwarded: 5_000)
        harness.driver.tick()
        XCTAssertFalse(
            harness.driver.isTimingAnOutage(),
            "real forwarding resumed but the egress-dead outage did not end")
    }

    func testARebuiltSessionThatStillForwardsNothingDoesNotEndTheOutage() throws {
        // A mere reconnect re-establishes the deceptive link; it must NOT end an egress-dead
        // outage. Only a delivered byte does — a rebuilt session reporting zero forwarding leaves
        // it open, so the budget proceeds to surrender.
        let harness = try DriverHarness()
        declareEgressDeadOutage(harness)
        XCTAssertTrue(harness.driver.isTimingAnOutage())

        harness.currentSession.stubStatistics = stats(forwarded: 0)
        harness.currentSession.pretendAuthenticatedPeerDatagram()
        harness.driver.tick()
        XCTAssertTrue(
            harness.driver.isTimingAnOutage(),
            "a rebuilt-but-not-forwarding session ended the outage — a reconnect is not forwarding")
    }

    func testAPathTransitionDoesNotReleaseAnEgressDeadOutage() throws {
        // An OPEN egress-dead outage stays held across a roam: a dead upstream is dead on either
        // network, so a post-roam keepalive must not end it and restart the cycle. The evidence has
        // to reach a LIVE runner, so walk the roam to a built attempt before delivering it (else the
        // keepalive lands on a torn-down session and the assertion is vacuous).
        let harness = try DriverHarness()
        for _ in 0..<8 { harness.source.push(StubSession()) }
        declareEgressDeadOutage(harness)
        XCTAssertTrue(harness.driver.isTimingAnOutage())

        harness.driver.pathChanged(satisfied: true, interfacesChanged: true)
        for _ in 0..<5 {
            harness.clock.advance(1)
            harness.fireDue()
        }
        XCTAssertTrue(harness.driver.isTimingAnOutage(), "precondition: the post-roam attempt is open")

        harness.currentSession.pretendAuthenticatedPeerDatagram()
        harness.currentSession.pretendInboundData()
        harness.driver.tick()
        XCTAssertTrue(
            harness.driver.isTimingAnOutage(),
            "a path transition released the egress-dead hold — a post-roam keepalive ended it")
    }

    func testGoingOfflineReleasesAnEgressDeadHold() throws {
        // The offline "third end site" (`pathChanged(satisfied:false)`) ends the outage directly,
        // bypassing `endOutage()`. An egress-dead hold left set there outlives its outage: the next
        // outage from ANY cause is born held, and with only real forwarding able to release it — and
        // none coming on a fresh idle session — the budget surrenders on a working link.
        let harness = try DriverHarness()
        for _ in 0..<8 { harness.source.push(StubSession()) }
        declareEgressDeadOutage(harness)
        harness.driver.pathChanged(satisfied: false, interfacesChanged: false)
        XCTAssertFalse(harness.driver.isTimingAnOutage(), "precondition: going offline ends the outage")

        // Coming back drives the rebind/settle machinery, which opens its own outage and builds an
        // attempt. A lone rebind now spends one re-anchor retry (~one confirmation window) before
        // that outage opens, so walk far enough to cross BOTH windows — one second at a time so the
        // advance does not spend the new outage's budget.
        harness.driver.pathChanged(satisfied: true, interfacesChanged: true)
        for _ in 0..<13 {
            harness.clock.advance(1)
            harness.fireDue()
        }
        XCTAssertTrue(harness.driver.isTimingAnOutage(), "precondition: the recovery outage is open")

        harness.currentSession.pretendAuthenticatedPeerDatagram()
        harness.currentSession.pretendInboundData()
        harness.driver.tick()
        XCTAssertFalse(
            harness.driver.isTimingAnOutage(),
            "a stale egress-dead hold survived going offline and blocked a LINK outage's recovery")
        XCTAssertTrue(harness.surrenders.isEmpty, "a working link surrendered")
    }

    func testTheEgressDeadCauseIsBoundedPerLifecycle() throws {
        // The bound that makes a chosen-traffic cause safe: a user talking only to an unresponsive
        // destination produces obliging non-DNS sends that never forward a byte, so an unbounded
        // cause would hand one dead endpoint a repeating surrender.
        let harness = try DriverHarness()
        for _ in 0..<24 { harness.source.push(StubSession()) }
        var forwarded: UInt64 = 1_000
        for cycle in 0..<(ChainedOutageDriver.maximumEgressDeadOutagesPerLifecycle + 3) {
            forwarded += 1_000
            anchorForwardingBaseline(harness, bytes: forwarded)
            driveSustainedEgressDeadDemand(harness, seconds: ChainedOutageDriver.egressDeadThresholdSeconds + 1)

            if cycle < ChainedOutageDriver.maximumEgressDeadOutagesPerLifecycle {
                XCTAssertTrue(harness.driver.isTimingAnOutage(), "cycle \(cycle) should have declared")
                // Recover via real forwarding on the rebuilt session.
                harness.clock.advance(2)
                harness.fireDue()
                forwarded += 500
                harness.currentSession.stubStatistics = stats(forwarded: forwarded)
                harness.driver.tick()
                XCTAssertFalse(harness.driver.isTimingAnOutage(), "cycle \(cycle) did not recover")
            }
        }
        XCTAssertFalse(
            harness.driver.isTimingAnOutage(),
            "a declaration past the cap opened an outage — an unbounded chosen-traffic blackhole")
    }

    // MARK: - Data-path observability (brief-stall investigation, 2026-08-24)

    func testASaturatedSampleIsCountedSoWedgeDurationIsLegible() throws {
        // `sendChannelSaturated` is a level the driver reads at tick cadence, so counting the
        // saturated SAMPLES turns it into a duration the 60 s liveness line can difference —
        // the signal that separates a sustained back-pressure wedge from a burst that
        // saturated and drained between ticks.
        let harness = try DriverHarness()
        harness.session.pretendChannelSaturated()
        harness.driver.tick()
        harness.session.pretendChannelSaturated()
        harness.driver.tick()
        // A third tick with the bound clear: the count must hold, not climb.
        harness.driver.tick()

        XCTAssertEqual(
            harness.driver.snapshotCounters().saturatedTickCount, 2,
            "saturated samples must be tallied per tick — a level alone is invisible to the "
                + "60 s line unless the sample instant happens to land inside the wedge")
    }

    func testARetiredRunnersPressureTalliesSurviveTheRebuild() throws {
        // The pressure counters live on the runner and reset with its session. Without the
        // fold-in at retirement, every rebuild zeroes them mid-window: a 60 s delta reads
        // negative, or a real shed vanishes into a rebuild and reads as "no pressure".
        let harness = try DriverHarness()
        var tallies = ChainedRunnerCounters()
        tallies.shedPacketCount = 5
        tallies.refusedOutboundBacklogPacketCount = 3
        tallies.refusedInboundBacklogDatagramCount = 2
        tallies.sendCompletionErrorCount = 7
        tallies.dnsHandledPacketCount = 11
        tallies.malformedPacketCount = 12
        tallies.unfilterableDNSPacketCount = 13
        tallies.unfilterableEncryptedDNSPacketCount = 16
        tallies.droppedIPv6Count = 14
        tallies.encapsulationAttemptCount = 15
        harness.session.stubCounters = tallies

        let liveCounters = harness.driver.snapshotCounters()
        XCTAssertEqual(
            liveCounters.shedPacketCount, 5,
            "the LIVE runner's tallies must be visible before any retirement")
        XCTAssertEqual(liveCounters.unfilterableDNSPacketCount, 13)
        XCTAssertEqual(liveCounters.unfilterableEncryptedDNSPacketCount, 16)
        XCTAssertEqual(harness.driver.snapshotCounters(), liveCounters,
                       "Reading a live runner's counters cannot absorb them twice.")

        // The outage retires the adopted runner and builds a fresh one (zero tallies).
        harness.beginSilentOutage()

        let counters = harness.driver.snapshotCounters()
        XCTAssertEqual(
            counters.shedPacketCount, 5,
            "5 means absorbed exactly once — 0 is the rebuild zeroing the window, 10 is the "
                + "live runner double-counted on top of its own absorption")
        XCTAssertEqual(counters.refusedOutboundBacklogPacketCount, 3)
        XCTAssertEqual(counters.refusedInboundBacklogDatagramCount, 2)
        XCTAssertEqual(counters.sendCompletionErrorCount, 7)
        XCTAssertEqual(counters.dnsHandledPacketCount, 11)
        XCTAssertEqual(counters.malformedPacketCount, 12)
        XCTAssertEqual(counters.unfilterableDNSPacketCount, 13)
        XCTAssertEqual(counters.unfilterableEncryptedDNSPacketCount, 16)
        XCTAssertEqual(counters.droppedIPv6Count, 14)
        XCTAssertEqual(counters.encapsulationAttemptCount, 15)
        XCTAssertEqual(harness.driver.snapshotCounters(), counters,
                       "Reading counters cannot absorb live or retired tallies twice.")
    }

    func testForwardingProvesTheLifecycleHealthyExactlyOnce() throws {
        let harness = try DriverHarness()

        harness.session.pretendInboundData()
        harness.driver.tick()
        harness.session.pretendInboundData()
        harness.driver.tick()

        XCTAssertEqual(harness.healthyLifecycleProofs.count, 1)
    }

    func testTransientLifecycleProofFailureRetriesWhileTickIsSuspendedAndLatchesAfterSuccess() {
        let engineQueue = ChainedEngineQueue(label: "com.lavasec.test.driver-proof-retry")
        let clock = SetTestClock()
        let timers = RecordingTimerScheduler()
        let source = ScriptedSessionSource()
        let session = StubSession()
        let attempts = DriverHarness.HealthyProofAttemptScript()
        let driver = ChainedOutageDriver(
            engineQueue: engineQueue,
            clock: clock,
            timers: timers,
            source: source,
            onSurrender: { _, _ in },
            onHealthyForwarding: { completion in attempts.capture(completion) })
        driver.adopt(session)

        session.pretendInboundData()
        driver.tick()
        driver.tick()
        XCTAssertEqual(attempts.count, 1, "ticks duplicated an in-flight persistence attempt")

        driver.sleep()
        attempts.completeNext(with: false)
        _ = driver.snapshotCounters()
        clock.advance(1)
        XCTAssertTrue(
            timers.fireDue(atSeconds: clock.currentSeconds, on: engineQueue),
            "the failed proof did not arm a bounded retry independent of the suspended tick")
        XCTAssertEqual(attempts.count, 2, "a transient persistence failure was never retried")

        attempts.completeNext(with: true)
        _ = driver.snapshotCounters()
        clock.advance(1)
        _ = timers.fireDue(atSeconds: clock.currentSeconds, on: engineQueue)

        XCTAssertEqual(
            attempts.count, 2,
            "a successful durable proof did not stop later retries")
    }

    func testAPathTransitionCannotDrainForwardingBeforeItProvesTheLifecycleHealthy() throws {
        let harness = try DriverHarness()

        harness.session.pretendInboundData()
        harness.driver.pathChanged(satisfied: true, interfacesChanged: true)
        harness.driver.tick()

        XCTAssertEqual(
            harness.healthyLifecycleProofs.count, 1,
            "path recovery drained the inbound sample without reporting the durable lifecycle proof")
    }

    final class DriverHarness {
        let engineQueue = ChainedEngineQueue(label: "com.lavasec.test.driver")
        let clock = SetTestClock()
        let timers = RecordingTimerScheduler()
        let source = ScriptedSessionSource()
        let session = StubSession()
        let driver: ChainedOutageDriver
        private let box = SurrenderBox()
        var surrenders: [ChainedReconnectPolicy.Surrender] { box.all }
        /// The counter snapshot handed to the sink alongside the most recent surrender.
        var lastSurrenderCounters: ChainedDriverCounters? { box.lastCounters }
        /// What was armed at the moment the driver asked for a session, which is the observable
        /// for "the watchdog was already armed before the build could fail".
        var armedCountWhenSessionWasRequested: Int { source.armedWhenAsked.first ?? -1 }

        /// How many times the driver announced a runner change. A class so the `@Sendable`
        /// observer can count without capturing a mutable local, which Swift 6 refuses.
        final class RunnerChangeCounter: @unchecked Sendable {
            private let lock = NSLock()
            private var value = 0
            func increment() { lock.withLock { value += 1 } }
            var count: Int { lock.withLock { value } }
        }

        final class HealthyProofAttemptScript: @unchecked Sendable {
            private let lock = NSLock()
            private var completions: [@Sendable (Bool) -> Void] = []
            private var attempts = 0

            func capture(_ completion: @escaping @Sendable (Bool) -> Void) {
                lock.withLock {
                    attempts += 1
                    completions.append(completion)
                }
            }

            func completeNext(with result: Bool) {
                let completion = lock.withLock {
                    completions.isEmpty ? nil : completions.removeFirst()
                }
                completion?(result)
            }

            var count: Int { lock.withLock { attempts } }
        }
        let runnerChanges = RunnerChangeCounter()
        let healthyLifecycleProofs = RunnerChangeCounter()

        init(provideSessions: Bool = true, routingPolicy: ChainedRoutingPolicy = .fullTunnel) throws {
            let capturedBox = box
            let capturedChanges = runnerChanges
            let capturedProofs = healthyLifecycleProofs
            driver = ChainedOutageDriver(
                engineQueue: engineQueue,
                clock: clock,
                timers: timers,
                source: source,
                routingPolicy: routingPolicy,
                onSurrender: { capturedBox.append($0, $1) },
                onHealthyForwarding: { completion in
                    capturedProofs.increment()
                    completion(true)
                },
                onRunnerChanged: { capturedChanges.increment() })
            let capturedTimers = timers
            source.liveArmedCount = { capturedTimers.liveArmed.count }
            if provideSessions {
                for _ in 0..<4 { source.push(StubSession()) }
            }
            driver.adopt(session)
        }

        func fireDue() {
            _ = timers.fireDue(atSeconds: clock.currentSeconds, on: engineQueue)
        }

        /// Reports an observation and WAITS for the driver to consume it.
        ///
        /// The door is deliberately asynchronous (`INV-QUEUE-1`: the caller must never park
        /// behind the engine queue), so a test that reported and then advanced the clock
        /// would race its own stimulus — the driver would stamp the accumulation with
        /// whatever second the clock had reached by the time the hop ran. `snapshotCounters`
        /// is a sync hop onto the same serial queue, so it is the barrier.
        func report(_ observation: ChainedOutageDriver.TunnelDNSObservation) {
            driver.reportTunnelDNSObservation(observation)
            _ = driver.snapshotCounters()
        }

        /// A served physical T1 rung, barriered for the same reason `report` is.
        func reportRungRescue() {
            driver.reportTierOneRungRescue()
            _ = driver.snapshotCounters()
        }

        /// The session the driver is actually driving right now. It builds a FRESH one per
        /// attempt, so the adopted one is retired the moment an outage begins.
        var currentSession: StubSession { source.handedOut.last ?? session }

        /// The second the outage clock started, which is not the same as "now" — the retry
        /// delay elapses after it.
        private(set) var outageStartedAtSeconds = 0

        /// Silence PLUS demand, which is what the driver defines an outage as.
        func beginSilentOutage() {
            // An obliging send with nothing authenticated coming back — the only shape that
            // declares an outage now.
            session.pretendObligingSend()
            driver.tick()
            clock.advance(ChainedOutageDriver.linkSilenceThresholdSeconds + 1)
            outageStartedAtSeconds = clock.currentSeconds
            driver.tick()
            // Let the scheduled retry delay elapse so the attempt actually starts.
            clock.advance(2)
            fireDue()
        }
    }

    final class SurrenderBox: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [(ChainedReconnectPolicy.Surrender, ChainedDriverCounters)] = []
        var all: [ChainedReconnectPolicy.Surrender] { lock.withLock { storage.map(\.0) } }
        var lastCounters: ChainedDriverCounters? { lock.withLock { storage.last?.1 } }
        func append(_ reason: ChainedReconnectPolicy.Surrender, _ counters: ChainedDriverCounters) {
            lock.withLock { storage.append((reason, counters)) }
        }
    }

    // MARK: - Runner rotation identity (task #21 / Codex P2, PR #613)

    /// A LIVE RUNNER REPORTS ITS ROTATION EVEN WHEN THE ENGINE'S STATISTICS READ FAILS.
    ///
    /// The identity used to ride on `ChainedRunnerStatistics`, which `sampleStatistics()` builds
    /// from `session.statistics()` — a call that can throw. An engine error therefore made a
    /// runner that plainly exists look absent, the provider read that as "no chained session",
    /// and the settings panel went silent for as long as the error persisted, which for an
    /// internal engine fault could be the rest of the session.
    ///
    /// The generation is immutable and read directly off the runner, so it cannot be taken down
    /// by a failing transport call.
    func testTheRunnersRotationSurvivesAFailingStatisticsRead() throws {
        let harness = try DriverHarness(provideSessions: false)
        let runner = StubSession()
        runner.acceptedUpstreamGeneration = 77
        // The engine read fails — exactly the condition that used to erase the identity.
        runner.stubStatistics = nil
        harness.driver.adopt(runner)

        XCTAssertNil(runner.sampleStatistics(), "the staged failure must actually be staged")
        XCTAssertEqual(
            harness.driver.acceptedUpstreamGeneration(), 77,
            "a live runner's rotation must not depend on a statistics read that can fail")
    }

    /// No runner means no rotation — the sentinel the freshness policy reads as "no chained
    /// session", and the reason a runnerless window is silent rather than wrong.
    func testNoRunnerReportsNoRotation() throws {
        let harness = try DriverHarness(provideSessions: false)
        XCTAssertEqual(harness.driver.acceptedUpstreamGeneration(), 0)
    }


    /// ADOPTION AND RETIREMENT BOTH NOTIFY, because the observer is on the property.
    ///
    /// `runner` is assigned in six places — adopt, rebuild, and four retirement paths — and a
    /// health identity that must follow it cannot depend on every one of them remembering to
    /// announce itself. `didSet` makes the notification unforgettable by a path added later,
    /// which is the failure mode PR #613 kept reproducing.
    func testAdoptingAndRetiringARunnerBothNotify() throws {
        let harness = try DriverHarness(provideSessions: false)
        // The harness adopts one in `init`, so that announcement is already counted. Measuring
        // from here rather than from zero keeps the test about the transitions it stages.
        let afterInitialAdopt = harness.runnerChanges.count
        XCTAssertGreaterThan(afterInitialAdopt, 0, "the harness's own adopt must have announced")

        harness.driver.adopt(StubSession())
        _ = harness.driver.snapshotCounters()  // barrier: the assignment happens on the engine queue
        XCTAssertGreaterThan(
            harness.runnerChanges.count, afterInitialAdopt,
            "adoption must announce the new runner")
        let afterSecondAdopt = harness.runnerChanges.count

        harness.driver.retire()
        _ = harness.driver.snapshotCounters()
        XCTAssertGreaterThan(
            harness.runnerChanges.count, afterSecondAdopt,
            "retirement must announce that no runner is running any more")
    }

}
