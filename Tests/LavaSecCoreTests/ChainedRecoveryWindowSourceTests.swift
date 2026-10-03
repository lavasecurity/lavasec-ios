import XCTest

@testable import LavaSecCore

/// The QA recovery-measurement window's honesty rules (`PacketTunnelProvider`).
///
/// Pinned rather than executed because the window is provider state read on `dnsStateQueue` and
/// emitted to the device log — there is no value type to hand assertions. What is pinned is not
/// the mechanism but the one thing a reader of the log has to be able to trust: whether a given
/// sample measures the TUNNEL or merely measures when traffic happened to arrive.
///
/// Neither opening site (`cold-start`, `path-change:…`) issues a probe, so a window can run over
/// an idle device. Left unqualified, the next organic query's answer books the entire idle wait as
/// `firstAnswerMs` and a healthy tunnel reads as a multi-second stall — the exact shape this
/// instrumentation exists to find, manufactured by the instrument (Codex, PR #575).
final class ChainedRecoveryWindowSourceTests: XCTestCase {
    private func sampler() throws -> String {
        try sourceBlock(
            in: try readPacketTunnelProviderSource(),
            startingAt: "private func fireChainedRecoveryFastTickIfOpen()",
            endingBefore: "/// Copies a chained driver counter snapshot into `health`")
    }

    func testTheTransportSinksStampTheObservationNotTheDrain() throws {
        // The appends hop off the NWConnection/producer queues so filesystem latency cannot block
        // packet processing. That hop moved the TIMESTAMP too: `LavaSecDeviceDebugLog.append`
        // stamps `Date()` when the queued block runs, so under IO backlog these entries drift and
        // can reorder against the synchronously-logged path/DNS/reconnect lines they exist to be
        // correlated with — which is the whole value of the telemetry (Codex P2, PR #582).
        let sinks = try sourceBlock(
            in: try readPacketTunnelProviderSource(),
            startingAt: "transportTelemetry: { sequence, event in",
            endingBefore: "// The tick handler holds the driver WEAKLY")
        let callbacks = [
            (
                source: try sourceBlock(
                    in: sinks,
                    startingAt: "transportTelemetry: { sequence, event in",
                    endingBefore: "dataPathDiagnostics: { event in"),
                recorderCall: "transportDiagnostics.recordTransport("
            ),
            (
                source: try sourceBlock(
                    in: sinks,
                    startingAt: "dataPathDiagnostics: { event in",
                    endingBefore: "}, entryConfiguration:"),
                recorderCall: "transportDiagnostics.recordPressure("
            ),
        ]

        for callback in callbacks {
            // Production mutations caught: moving capture into the async block records drain
            // order, capturing after the recorder can invert callback-entry order on its shared
            // lock, and capturing again at append forwards a different observation token.
            XCTAssertEqual(
                sourceOccurrenceCount(
                    of: "let observation = DeviceLogObservationClock.capture()", in: callback.source),
                1, "each sink must capture exactly one observation on its producer queue")
            XCTAssertEqual(
                sourceOccurrenceCount(of: "observation: observation", in: callback.source), 1,
                "each sink must forward that same observation to append")

            let capture = try XCTUnwrap(
                callback.source.range(of: "let observation = DeviceLogObservationClock.capture()"))
            let recording = try XCTUnwrap(callback.source.range(of: callback.recorderCall))
            let submission = try XCTUnwrap(
                callback.source.range(of: "Self.transportDiagnosticsLogQueue.async"))
            XCTAssertLessThan(
                capture.lowerBound, recording.lowerBound,
                "capture must be the callback's first executable work, before the shared recorder lock")
            XCTAssertLessThan(
                capture.lowerBound, submission.lowerBound,
                "capture must happen before asynchronous submission, never in the drain")
        }
    }

    func testTheLivenessEntryReportsWhatTheRateBoundSuppressed() throws {
        // The recorder tracks `suppressedLogCount` precisely so thinning is visible, and its only
        // production consumer dropped the field — so a throttled storm vanished silently
        // (Codex P2, PR #582).
        let liveness = try sourceBlock(
            in: try readPacketTunnelProviderSource(),
            startingAt: "event: \"chained-session-liveness\"",
            // Ends at the self-heal backstop that follows the append. `hasHandshake` was the
            // first anchor I reached for and it sits EARLIER than the transport tallies, so the
            // block closed before the field under test — a pin that would have passed for the
            // wrong reason had the assertion been negative.
            endingBefore: "PRODUCTION self-heal backstop")
        // BY MECHANISM. The recorder's total covers all kinds, so emitting it under a
        // channel-shaped name attributed a queue-pressure storm to the NWConnection — sending a
        // reader at the opposite mechanism (Codex P2, PR #582).
        XCTAssertTrue(
            liveness.contains("transport.suppressedTransportLogCount"),
            "a suppressed-log tally that is never emitted cannot make thinning visible")
        XCTAssertTrue(
            liveness.contains("transport.suppressedPressureLogCount"),
            "pressure suppression needs its own field, or it reads as channel suppression")
        XCTAssertFalse(
            liveness.contains("transport.suppressedLogCount)"),
            "the all-kinds total must not be emitted under a per-mechanism name")
    }

    func testARecoverySampleReportsWhatTheRateBoundSuppressedBeforeSixtySeconds() throws {
        // The periodic liveness line runs every 60 s, but this window caps at 30 s. A session
        // that dies inside the cap therefore needs both suppression tallies on THIS sample or a
        // rate-bounded storm disappears before the periodic line can ever report it.
        let sampler = try sampler()
        XCTAssertEqual(
            sourceOccurrenceCount(
                of: "let transport = runtime.transportDiagnostics.snapshotTallies()", in: sampler),
            1,
            "the recovery sample must capture one transport snapshot for all of its tallies")
        XCTAssertEqual(
            sourceOccurrenceCount(
                of: "\"channelSuppressedLogs\": \"\\(transport.suppressedTransportLogCount)\"",
                in: sampler),
            1,
            "channel suppression must come from the channel-specific tally in that snapshot")
        XCTAssertEqual(
            sourceOccurrenceCount(
                of: "\"pressureSuppressedLogs\": \"\\(transport.suppressedPressureLogCount)\"",
                in: sampler),
            1,
            "pressure suppression must come from the pressure-specific tally in that snapshot")

        // Production mutations caught: swapping either source counter points triage at the
        // opposite mechanism even though both public field names still look correct.
        XCTAssertFalse(
            sampler.contains(
                "\"channelSuppressedLogs\": \"\\(transport.suppressedPressureLogCount)\""))
        XCTAssertFalse(
            sampler.contains(
                "\"pressureSuppressedLogs\": \"\\(transport.suppressedTransportLogCount)\""))
        XCTAssertFalse(
            sampler.contains("transport.suppressedLogCount)"),
            "the all-kinds total cannot preserve mechanism attribution")
    }

    func testTheFirstAnswerCarriesTheEvidenceThatAnythingWasBeingAsked() throws {
        let sampler = try sampler()
        // Stamped INSIDE the first-answer branch: the unanswered delta at any later tick includes
        // failures that happened AFTER recovery (the patchy tail this window deliberately keeps
        // sampling), which say nothing about whether the tunnel was being asked before it came
        // back. The qualifier is only meaningful frozen at that instant.
        let firstAnswer = try sourceBlock(
            in: sampler,
            startingAt: "if ansDelta > 0, chainedRecoveryFirstAnswerAtMillis == nil {",
            endingBefore: "let cappedByTime =")
        XCTAssertTrue(
            firstAnswer.contains(
                "chainedRecoveryUnansweredBeforeFirstAnswer = chainedRecoveryUnansweredAtPreviousSample"),
            "the validity qualifier must be frozen with the first answer, not read later")
        // 🔴 The PREVIOUS sample's tally, not this tick's. Counters give totals, not order, and
        // both events fit in one interval — the coarse cadence is 1500 ms and `udpDNSTimeoutSeconds`
        // is 1, so a burst can answer fast and then time out a DIFFERENT query before the next
        // tick. Reading the current delta calls that anchored when the failure came AFTER the
        // answer, smuggling the idle interval back in under a trusted flag — worse than the
        // unqualified number it replaced (Codex, PR #575).
        XCTAssertFalse(
            firstAnswer.contains("chainedRecoveryUnansweredBeforeFirstAnswer = unansDelta"),
            "this tick's delta cannot establish that its failures preceded its answer")
    }

    func testThePrecedingTallyIsAdvancedOnlyAfterItIsRead() throws {
        let sampler = try sampler()
        // Ordering is the whole guarantee: advancing the carry BEFORE the first-answer branch
        // would make this tick's own arrivals count as preceding this tick's answer, which is
        // precisely the inversion the carry exists to prevent. So the advance sits after the
        // emission, and the assertion is positional rather than a bare `contains`.
        let stamp = try XCTUnwrap(
            sampler.range(
                of: "chainedRecoveryUnansweredBeforeFirstAnswer = chainedRecoveryUnansweredAtPreviousSample"),
            "the stamp must read the carry")
        let advance = try XCTUnwrap(
            sampler.range(of: "chainedRecoveryUnansweredAtPreviousSample = unansDelta"),
            "the carry must be advanced once per sample")
        XCTAssertLessThan(
            stamp.lowerBound, advance.lowerBound,
            "the carry must be READ at the first answer before it is advanced for the next tick")
    }

    func testAReopenedWindowDoesNotInheritThePrecedingTally() throws {
        // The deltas restart from the new window's baselines, so a surviving carry would read as
        // evidence that preceded THIS window's first answer — the same stale-carry class the
        // window serial guards for the tick cadence.
        let opener = try sourceBlock(
            in: try readPacketTunnelProviderSource(),
            startingAt: "func openChainedRecoveryWindow(reason: String)",
            endingBefore: "private func scheduleChainedRecoveryFastTick()")
        XCTAssertTrue(
            opener.contains("chainedRecoveryUnansweredAtPreviousSample = 0"),
            "a reopened window must start its preceding-failure tally from zero")
    }

    func testAnIdleWindowIsNotReportedAsATunnelThatNeverRecovered() throws {
        // `capped` asserts the tunnel never came back. With nothing asked in the whole window
        // there is no such claim available, and making it manufactures an outage out of a quiet
        // device — which would then be counted as a stall by the very experiment it corrupts.
        XCTAssertTrue(
            try sampler().contains("phase = unansDelta == 0 ? \"idle\" : \"capped\""),
            "a window that closed with nothing asked must close `idle`, never `capped`")
    }

    func testTheEmittedSampleSaysWhetherItMeasuredTheTunnel() throws {
        // The field a reader gates on. Without it every sample looks equally authoritative, and
        // an idle-dominated one is indistinguishable from a real multi-second recovery.
        XCTAssertTrue(
            try sampler().contains(
                "\"anchored\": chainedRecoveryUnansweredBeforeFirstAnswer.map { \"\\($0 > 0)\" } ?? \"nil\""),
            "every sample must carry whether `firstAnswerMs` is anchored to a real attempt")
    }

    func testOpeningAWindowClearsThePreviousVerdict() throws {
        // A re-open (a second path change before the first settled) re-stamps onto the newer
        // event. A surviving qualifier would let the OLD window's evidence declare the new
        // window's `firstAnswerMs` trustworthy — the same stale-carry class the window serial
        // already guards for the tick cadence.
        let opener = try sourceBlock(
            in: try readPacketTunnelProviderSource(),
            startingAt: "func openChainedRecoveryWindow(reason: String)",
            endingBefore: "private func scheduleChainedRecoveryFastTick()")
        XCTAssertTrue(
            opener.contains("chainedRecoveryUnansweredBeforeFirstAnswer = nil"),
            "a reopened window must not inherit the previous window's validity verdict")
    }

    func testASampleSaysWhetherTheLadderIsRebuildingOrSittingOnOneDeadSession() throws {
        // A session that never comes up is `hasHandshake=false` with `txBytes=0` on every sample,
        // and those two fields alone cannot say WHY. A field log from 2026-08-25 carried seven
        // such windows — each ~30 s of zero-tx samples closing in `chained-surrendered
        // budgetExhausted` — and the export could not answer whether the retry ladder was
        // building sessions that died or one session had gone inert, because the counters that
        // say so reached the log ONLY on the 60 s `chained-session-liveness` line, which a
        // session dying at ~30 s never emits.
        //
        // So they are pinned to the SAMPLE, not the liveness line: the cadence that can still see
        // a short-lived session is the whole point of carrying them twice.
        let sampler = try sampler()
        for key in ["startedAttemptCount", "sessionEndCount", "stoodDownCount"] {
            XCTAssertTrue(
                sampler.contains("\"\(key)\": \"\\(counters.\(key))\""),
                "a recovery sample must carry `\(key)` — the 60 s liveness line is too late for a "
                    + "session that dies inside the blackhole budget")
        }
    }

    func testASampleSeparatesADeadSocketFromASilentEngine() throws {
        // The other half of the branch point. With the ladder counters alone, "the socket never
        // carried the handshake initiation" and "the socket was fine and the engine emitted
        // nothing" are the same zero-tx sample; these two tallies are what tell them apart.
        //
        // Read from the transport recorder rather than the driver, and its `snapshotTallies()` is
        // lock-guarded, so the sampler's `dnsStateQueue` confinement is not widened by reading it
        // (INV-QUEUE-1: this path must not acquire the engine queue).
        let sampler = try sampler()
        XCTAssertTrue(
            sampler.contains("let transport = runtime.transportDiagnostics.snapshotTallies()"),
            "the sample must snapshot the transport tallies alongside the driver's")
        XCTAssertTrue(
            sampler.contains("\"sendToPeer\": \"\\(counters.sendToPeerCount)\""),
            "a recovery sample must carry POSITIVE engine-output evidence — the channel tallies "
                + "and `txBytes` are all flat whether the engine emitted initiations or nothing")
        XCTAssertTrue(
            sampler.contains("\"channelNotReady\": \"\\(transport.stateNotReadyTransitionCount)\""),
            "a recovery sample must say whether the socket kept leaving ready")
        XCTAssertTrue(
            sampler.contains("\"channelSendFailEdges\": \"\\(transport.sendFailedEdgeCount)\""),
            "a recovery sample must say whether sends were failing on the socket")
        // The wedge the other five cannot name: a channel that stays `ready` and stops calling
        // completions parks the runner at its in-flight bound, so `sendToPeer` rises then goes
        // flat (counted at submission) while both channel tallies stay zero.
        XCTAssertTrue(
            sampler.contains("\"saturatedTicks\": \"\\(counters.saturatedTickCount)\""),
            "a recovery sample must say whether the send channel was pinned at its bound")
    }
}
