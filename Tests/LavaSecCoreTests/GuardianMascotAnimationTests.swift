import XCTest
@testable import LavaSecCore
@testable import LavaSecKit

final class GuardianMascotAnimationTests: XCTestCase {
    func testGuardianMascotStateGraphKeepsWakeupAsTheOnlySleepingExit() {
        XCTAssertEqual(GuardianMascotState.sleeping.allowedNextStates, [.waking])
        XCTAssertEqual(GuardianMascotState.waking.allowedNextStates, [.awake, .retrying, .concerned, .sleeping])
        XCTAssertEqual(GuardianMascotState.awake.allowedNextStates, [.sleeping, .paused, .retrying, .concerned, .grateful])
        XCTAssertEqual(GuardianMascotState.paused.allowedNextStates, [.awake, .sleeping])
        XCTAssertEqual(GuardianMascotState.retrying.allowedNextStates, [.awake, .concerned, .sleeping])
        XCTAssertEqual(GuardianMascotState.concerned.allowedNextStates, [.awake, .retrying, .sleeping])
        XCTAssertEqual(GuardianMascotState.grateful.allowedNextStates, [.awake])
    }

    func testSleepWakeTransitionMirrorsWakeSleepWithoutWink() {
        let wakePlan = GuardianMascotAnimationPlan.transition(from: .sleeping, to: .awake)
        let sleepPlan = GuardianMascotAnimationPlan.transition(from: .awake, to: .sleeping)

        XCTAssertEqual(wakePlan.duration, GuardianMascotAnimationPlan.sleepWakeDuration, accuracy: 0.001)
        XCTAssertEqual(sleepPlan.duration, GuardianMascotAnimationPlan.sleepWakeDuration, accuracy: 0.001)

        let sleeping = wakePlan.frame(at: 0)
        XCTAssertEqual(sleeping.shieldWakeAmount, 0, accuracy: 0.001)
        XCTAssertEqual(sleeping.sleepyEyeAmount, 1, accuracy: 0.001)
        XCTAssertEqual(sleeping.leftEyeOpenAmount, 0, accuracy: 0.001)
        XCTAssertEqual(sleeping.rightEyeOpenAmount, 0, accuracy: 0.001)

        let progressSamples = [0.2, 0.5, 0.8]
        for progress in progressSamples {
            let waking = wakePlan.frame(at: wakePlan.duration * progress)
            let sleeping = sleepPlan.frame(at: sleepPlan.duration * (1 - progress))

            XCTAssertEqual(waking.shieldWakeAmount, sleeping.shieldWakeAmount, accuracy: 0.001)
            XCTAssertEqual(waking.sleepyEyeAmount, sleeping.sleepyEyeAmount, accuracy: 0.001)
            XCTAssertEqual(waking.leftEyeOpenAmount, sleeping.leftEyeOpenAmount, accuracy: 0.001)
            XCTAssertEqual(waking.rightEyeOpenAmount, sleeping.rightEyeOpenAmount, accuracy: 0.001)
            XCTAssertEqual(waking.mouthCurve, sleeping.mouthCurve, accuracy: 0.001)
            XCTAssertEqual(waking.winkAmount, 0, accuracy: 0.001)
            XCTAssertEqual(waking.leftEyeOpenAmount, waking.rightEyeOpenAmount, accuracy: 0.001)
        }

        let awake = wakePlan.frame(at: wakePlan.duration)
        XCTAssertEqual(awake.shieldWakeAmount, 1, accuracy: 0.001)
        XCTAssertEqual(awake.sleepyEyeAmount, 0, accuracy: 0.001)
        XCTAssertEqual(awake.leftEyeOpenAmount, 1, accuracy: 0.001)
        XCTAssertEqual(awake.rightEyeOpenAmount, 1, accuracy: 0.001)
        XCTAssertEqual(awake.winkAmount, 0, accuracy: 0.001)
    }

    func testBlinkIsAtomicBothEyeAction() {
        let plan = GuardianMascotAnimationPlan.blink(on: .awake)

        XCTAssertEqual(plan.duration, GuardianMascotAnimationPlan.blinkDuration, accuracy: 0.001)
        XCTAssertEqual(plan.startState, .awake)
        XCTAssertEqual(plan.endState, .awake)

        let start = plan.frame(at: 0)
        XCTAssertEqual(start.leftEyeOpenAmount, 1, accuracy: 0.001)
        XCTAssertEqual(start.rightEyeOpenAmount, 1, accuracy: 0.001)
        XCTAssertEqual(start.winkAmount, 0, accuracy: 0.001)

        let closed = plan.frame(at: plan.duration * 0.45)
        XCTAssertLessThan(closed.leftEyeOpenAmount, 0.08)
        XCTAssertLessThan(closed.rightEyeOpenAmount, 0.08)
        XCTAssertEqual(closed.leftEyeOpenAmount, closed.rightEyeOpenAmount, accuracy: 0.001)
        XCTAssertEqual(closed.winkAmount, 0, accuracy: 0.001)
        XCTAssertEqual(closed.shieldWakeAmount, 1, accuracy: 0.001)

        let end = plan.frame(at: plan.duration)
        XCTAssertEqual(end.leftEyeOpenAmount, 1, accuracy: 0.001)
        XCTAssertEqual(end.rightEyeOpenAmount, 1, accuracy: 0.001)
        XCTAssertEqual(end.winkAmount, 0, accuracy: 0.001)
    }

    func testAnimationSequenceAddsBlinkOnlyAfterSleepingWake() {
        let wakeSequence = GuardianMascotAnimationPlan.sequence(from: .sleeping, to: .awake)
        XCTAssertEqual(wakeSequence, [
            GuardianMascotAnimationPlan.transition(from: .sleeping, to: .awake),
            GuardianMascotAnimationPlan.hold(on: .awake),
            GuardianMascotAnimationPlan.blink(on: .awake)
        ])

        let offSequence = GuardianMascotAnimationPlan.sequence(from: .awake, to: .sleeping)
        XCTAssertEqual(offSequence, [
            GuardianMascotAnimationPlan.transition(from: .awake, to: .sleeping)
        ])
    }

    func testWakeAnimationComposesSleepWakeAndAtomicBlinkIntoOnePlan() {
        let plan = GuardianMascotAnimationPlan.animation(from: .sleeping, to: .awake)

        XCTAssertEqual(plan.startState, .sleeping)
        XCTAssertEqual(plan.endState, .awake)
        XCTAssertEqual(
            plan.duration,
            GuardianMascotAnimationPlan.sleepWakeDuration + 0.5 + GuardianMascotAnimationPlan.blinkDuration,
            accuracy: 0.001
        )

        let beforeBlink = plan.frame(at: GuardianMascotAnimationPlan.sleepWakeDuration * 0.96)
        XCTAssertGreaterThan(beforeBlink.leftEyeOpenAmount, 0.98)
        XCTAssertGreaterThan(beforeBlink.rightEyeOpenAmount, 0.98)

        let waitingBeforeBlink = plan.frame(at: GuardianMascotAnimationPlan.sleepWakeDuration + 0.25)
        XCTAssertGreaterThan(waitingBeforeBlink.leftEyeOpenAmount, 0.98)
        XCTAssertGreaterThan(waitingBeforeBlink.rightEyeOpenAmount, 0.98)

        let blinkClosed = plan.frame(
            at: GuardianMascotAnimationPlan.sleepWakeDuration + 0.5 + GuardianMascotAnimationPlan.blinkDuration * 0.45
        )
        XCTAssertLessThan(blinkClosed.leftEyeOpenAmount, 0.08)
        XCTAssertLessThan(blinkClosed.rightEyeOpenAmount, 0.08)
        XCTAssertEqual(blinkClosed.leftEyeOpenAmount, blinkClosed.rightEyeOpenAmount, accuracy: 0.001)
        XCTAssertEqual(blinkClosed.winkAmount, 0, accuracy: 0.001)
    }

    func testTransitionIntoSleepingGetsDedicatedClosingDuration() {
        let plan = GuardianMascotAnimationPlan.transition(from: .awake, to: .sleeping)

        XCTAssertEqual(plan.duration, GuardianMascotAnimationPlan.sleepWakeDuration, accuracy: 0.001)
        XCTAssertGreaterThan(plan.duration, GuardianMascotAnimationPlan.stateChangeDuration)

        let nearlySleeping = plan.frame(at: plan.duration * 0.92)
        XCTAssertGreaterThan(nearlySleeping.leftEyeOpenAmount, 0)
        XCTAssertGreaterThan(nearlySleeping.rightEyeOpenAmount, 0)
        XCTAssertGreaterThan(nearlySleeping.sleepyEyeAmount, 0.95)

        let sleeping = plan.frame(at: plan.duration)
        XCTAssertEqual(sleeping.leftEyeOpenAmount, 0, accuracy: 0.001)
        XCTAssertEqual(sleeping.rightEyeOpenAmount, 0, accuracy: 0.001)
        XCTAssertEqual(sleeping.sleepyEyeAmount, 1, accuracy: 0.001)
    }

    func testStableExpressionsExposeDistinctMascotPoses() {
        let sleeping = GuardianMascotAnimationPlan.stableFrame(for: .sleeping)
        XCTAssertEqual(sleeping.shieldWakeAmount, 0, accuracy: 0.001)
        XCTAssertEqual(sleeping.sleepyEyeAmount, 1, accuracy: 0.001)

        let awake = GuardianMascotAnimationPlan.stableFrame(for: .awake)
        XCTAssertEqual(awake.shieldWakeAmount, 1, accuracy: 0.001)
        XCTAssertEqual(awake.leftEyeOpenAmount, 1, accuracy: 0.001)
        XCTAssertEqual(awake.rightEyeOpenAmount, 1, accuracy: 0.001)
        XCTAssertGreaterThan(awake.glowAmount, sleeping.glowAmount)
        XCTAssertEqual(sleeping.mouthCurve, awake.mouthCurve, accuracy: 0.001)

        let paused = GuardianMascotAnimationPlan.stableFrame(for: .paused)
        XCTAssertEqual(paused.pauseAmount, 1, accuracy: 0.001)
        XCTAssertEqual(paused.shieldWakeAmount, awake.shieldWakeAmount, accuracy: 0.001)
        XCTAssertEqual(paused.glowAmount, awake.glowAmount, accuracy: 0.001)
        XCTAssertEqual(paused.sleepyEyeAmount, 1, accuracy: 0.001)
        XCTAssertEqual(paused.leftEyeOpenAmount, 0, accuracy: 0.001)
        XCTAssertEqual(paused.rightEyeOpenAmount, 0, accuracy: 0.001)
        XCTAssertEqual(paused.mouthCurve, awake.mouthCurve, accuracy: 0.001)

        let concerned = GuardianMascotAnimationPlan.stableFrame(for: .concerned)
        XCTAssertEqual(concerned.concernAmount, 1, accuracy: 0.001)
        XCTAssertEqual(concerned.shieldWakeAmount, awake.shieldWakeAmount, accuracy: 0.001)
        XCTAssertEqual(concerned.glowAmount, awake.glowAmount, accuracy: 0.001)
        XCTAssertLessThan(concerned.leftEyeOpenAmount, awake.leftEyeOpenAmount)
        XCTAssertLessThan(concerned.rightEyeOpenAmount, awake.rightEyeOpenAmount)
        XCTAssertLessThan(concerned.mouthCurve, 0)
        XCTAssertGreaterThan(concerned.mouthCurve, -0.30)

        let retrying = GuardianMascotAnimationPlan.stableFrame(for: .retrying)
        XCTAssertEqual(retrying.concernAmount, 0, accuracy: 0.001)
        XCTAssertEqual(retrying.mouthCurve, 0, accuracy: 0.001)
        XCTAssertEqual(retrying.sleepyEyeAmount, 0, accuracy: 0.001)
        XCTAssertEqual(retrying.shieldWakeAmount, awake.shieldWakeAmount, accuracy: 0.001)
        XCTAssertEqual(retrying.glowAmount, awake.glowAmount, accuracy: 0.001)
        XCTAssertEqual(retrying.leftEyeOpenAmount, retrying.rightEyeOpenAmount, accuracy: 0.001)
        XCTAssertLessThan(retrying.leftEyeOpenAmount, awake.leftEyeOpenAmount)
        XCTAssertGreaterThan(retrying.leftEyeOpenAmount, concerned.leftEyeOpenAmount)

        let grateful = GuardianMascotAnimationPlan.stableFrame(for: .grateful)
        XCTAssertEqual(grateful.gratitudeAmount, 1, accuracy: 0.001)
        XCTAssertGreaterThan(grateful.happyEyeAmount, awake.happyEyeAmount)
        XCTAssertGreaterThan(grateful.mouthCurve, awake.mouthCurve)
    }

    func testAwakeToGratefulLengthensEyesBeforeClosing() {
        let plan = GuardianMascotAnimationPlan.transition(from: .awake, to: .grateful)

        let early = plan.frame(at: plan.duration * 0.35)
        XCTAssertGreaterThan(early.happyEyeAmount, 0.55)
        XCTAssertGreaterThan(early.leftEyeOpenAmount, 0.90)
        XCTAssertGreaterThan(early.rightEyeOpenAmount, 0.90)

        let middle = plan.frame(at: plan.duration * 0.55)
        XCTAssertGreaterThan(middle.happyEyeAmount, 0.90)
        XCTAssertLessThan(middle.leftEyeOpenAmount, early.leftEyeOpenAmount)
        XCTAssertLessThan(middle.rightEyeOpenAmount, early.rightEyeOpenAmount)
        XCTAssertGreaterThan(middle.leftEyeOpenAmount, 0.50)
        XCTAssertGreaterThan(middle.rightEyeOpenAmount, 0.50)

        let late = plan.frame(at: plan.duration * 0.85)
        XCTAssertLessThan(late.leftEyeOpenAmount, middle.leftEyeOpenAmount)
        XCTAssertLessThan(late.rightEyeOpenAmount, middle.rightEyeOpenAmount)
        XCTAssertLessThan(late.leftEyeOpenAmount, 0.12)
        XCTAssertLessThan(late.rightEyeOpenAmount, 0.12)
        XCTAssertEqual(late.happyEyeAmount, 1, accuracy: 0.001)
    }

    func testGratefulToAwakeOpensBeforeRelaxingHappyEyes() {
        let plan = GuardianMascotAnimationPlan.transition(from: .grateful, to: .awake)

        let early = plan.frame(at: plan.duration * 0.35)
        XCTAssertGreaterThan(early.leftEyeOpenAmount, 0.25)
        XCTAssertGreaterThan(early.rightEyeOpenAmount, 0.25)
        XCTAssertGreaterThan(early.happyEyeAmount, 0.95)

        let middle = plan.frame(at: plan.duration * 0.55)
        XCTAssertGreaterThan(middle.leftEyeOpenAmount, 0.90)
        XCTAssertGreaterThan(middle.rightEyeOpenAmount, 0.90)
        XCTAssertGreaterThan(middle.happyEyeAmount, 0.90)

        let late = plan.frame(at: plan.duration * 0.85)
        XCTAssertGreaterThan(late.leftEyeOpenAmount, 0.98)
        XCTAssertGreaterThan(late.rightEyeOpenAmount, 0.98)
        XCTAssertLessThan(late.happyEyeAmount, 0.15)
    }
}
