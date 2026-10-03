import XCTest

@testable import LavaSecChainedUpstream

/// The outage budget, enforced from when traffic stopped rather than from a session boundary.
///
/// The plan for this slice names the failure explicitly: a test that walks the retry ladder
/// passes while the real hole stays open. boringtun retransmits an in-flight handshake for
/// `REKEY_ATTEMPT_TIME` (90 s) before reporting `connectionExpired`, so a budget enforced only
/// when a session ENDS is not consulted for a minute and a half — while the tunnel holds
/// `0.0.0.0/0` and forwards nothing.
final class ChainedOutageSupervisorTests: XCTestCase {
    private typealias Policy = ChainedReconnectPolicy

    /// Authorizes an attempt and immediately retires it, for tests walking the ladder.
    ///
    /// Retirement needs the receipt from the authorization now, so a test cannot complete an
    /// attempt it did not start — the same constraint the provider is under.
    @discardableResult
    private func runOneAttempt(
        _ supervisor: inout ChainedOutageSupervisor, atSeconds now: Int,
        file: StaticString = #filePath, line: UInt = #line
    ) -> Bool {
        guard let ticket = nextTicket(&supervisor, atSeconds: now, file: file, line: line) else {
            return false
        }
        guard case .authorized(_, _, let receipt) =
            supervisor.authorizeAttemptStartingNow(atSeconds: now, with: ticket)
        else { return false }
        supervisor.recordAttempt(receipt)
        return true
    }

    /// The generation token for the outage `supervisor` is currently timing.
    ///
    /// Obtained the only way a caller can obtain one — from a scheduling decision — because
    /// `ChainedOutageGeneration` is deliberately not constructible outside its own file. A
    /// test able to mint a token could not test the check that the token exists for.
    /// Takes the next scheduling decision's ticket, as the provider would.
    ///
    /// `completing` is the receipt of the attempt whose session just ended. It is `nil` only
    /// for the FIRST end of an outage, whose session was running before the outage began and
    /// which this supervisor therefore never authorized — after that, a receipt-less end is a
    /// stale callback and is deliberately refused.
    private func nextTicket(
        _ supervisor: inout ChainedOutageSupervisor,
        atSeconds now: Int = 0,
        completing receipt: ChainedAttemptReceipt? = nil,
        file: StaticString = #filePath, line: UInt = #line
    ) -> ChainedAttemptTicket? {
        let expired = ChainedSessionEndCause(
            ChainedDataPathPolicy.action(for: .failure(.connectionExpired)))
        guard let expired else {
            XCTFail("connectionExpired must be a session-ending cause", file: file, line: line)
            return nil
        }
        guard case .attempt(_, _, let ticket) =
            supervisor.action(atSeconds: now, endedBy: (expired, receipt))
        else {
            XCTFail("expected a scheduling decision to take a ticket from",
                    file: file, line: line)
            return nil
        }
        return ticket
    }

    // MARK: - The 90-second hole

    func testTheBudgetCoversTheFirstHandshakeNotJustTheRetries() {
        // The regression this type exists for. The engine reports NOTHING while it
        // retransmits, so `endedBy` is nil the whole time. A supervisor that only acts on
        // session ends would carry on here until the engine gave up at 90 s.
        var supervisor = ChainedOutageSupervisor()
        supervisor.beginOutage(atSeconds: 0)

        for second in 0...Policy.maximumBlackholeSeconds - 1 {
            XCTAssertEqual(
                supervisor.action(atSeconds: second, endedBy: nil), .carryOn,
                "still inside the budget at \(second)s")
        }
        XCTAssertEqual(
            supervisor.action(atSeconds: Policy.maximumBlackholeSeconds, endedBy: nil),
            .surrender(.budgetExhausted),
            "the budget must expire without the engine reporting anything"
        )

        // And well before the engine would have said a word.
        XCTAssertEqual(
            supervisor.action(atSeconds: 90, endedBy: nil), .surrender(.budgetExhausted))
        XCTAssertLessThan(
            Policy.maximumBlackholeSeconds, 90,
            "if the budget ever exceeds REKEY_ATTEMPT_TIME this type stops mattering")
    }

    func testAnIdleSupervisorAuthorizesNothing() {
        // No outage in progress means nothing to bound. A supervisor that surrendered here
        // would tear down a working tunnel.
        var supervisor = ChainedOutageSupervisor()
        XCTAssertFalse(supervisor.isTimingAnOutage)
        XCTAssertEqual(supervisor.action(atSeconds: 10_000, endedBy: nil), .carryOn)
        XCTAssertEqual(supervisor.elapsedSeconds(atSeconds: 10_000), 0)
    }

    // MARK: - The clock cannot be gamed

    func testAFlappingPathCannotRestartTheClock() {
        // A clock that restarts is not a budget. Repeated path flaps would each reset it, and
        // the tunnel could blackhole indefinitely while every individual measurement looked
        // short — the failure is invisible precisely because each reading is small.
        var supervisor = ChainedOutageSupervisor()
        supervisor.beginOutage(atSeconds: 0)
        for flap in 1...20 {
            supervisor.beginOutage(atSeconds: flap)
        }
        XCTAssertEqual(supervisor.elapsedSeconds(atSeconds: 20), 20, "the first call must win")
        XCTAssertEqual(
            supervisor.action(atSeconds: 20, endedBy: nil), .surrender(.budgetExhausted))
    }

    func testRecoveryClearsTheClockSoTheNextOutageGetsAFullBudget() {
        var supervisor = ChainedOutageSupervisor()
        let generationToken = supervisor.beginOutage(atSeconds: 0)
        runOneAttempt(&supervisor, atSeconds: 0)
        supervisor.endOutage(in: generationToken)

        XCTAssertFalse(supervisor.isTimingAnOutage)
        supervisor.beginOutage(atSeconds: 1000)
        XCTAssertEqual(supervisor.elapsedSeconds(atSeconds: 1000), 0)
        XCTAssertEqual(supervisor.completedAttempts, 0, "a new outage starts at attempt zero")
    }





    func testNoSecondAttemptStartsWhileOneIsRunning() throws {
        // The in-flight guard, reached the only way it still can be. A session end for the
        // RUNNING attempt legitimately schedules its replacement — but that replacement must
        // not start until the running one is retired, or two sessions exist at once.
        var supervisor = ChainedOutageSupervisor()
        supervisor.beginOutage(atSeconds: 0)
        let first = try XCTUnwrap(nextTicket(&supervisor))
        guard case .authorized(_, _, let receipt) =
            supervisor.authorizeAttemptStartingNow(atSeconds: 0, with: first)
        else { return XCTFail("the first attempt must authorize") }

        let replacement = try XCTUnwrap(nextTicket(&supervisor, atSeconds: 1, completing: receipt))
        XCTAssertEqual(
            supervisor.authorizeAttemptStartingNow(atSeconds: 1, with: replacement),
            .standDown(.attemptAlreadyStarted),
            "a replacement started while the attempt it replaces was still running")

        // `recordAttempt` retires it, and only then may the replacement start — otherwise the
        // budget would permit exactly one try per outage, the opposite failure.
        supervisor.recordAttempt(receipt)
        guard case .authorized = supervisor.authorizeAttemptStartingNow(
            atSeconds: 1, with: replacement)
        else { return XCTFail("a retired attempt must let its replacement start") }
    }

    func testTheFirstSessionEndOfAnOutageNeedsNoReceiptAndIsStillNewsOnlyOnce() throws {
        // The session that ends FIRST was running before the outage began, so this supervisor
        // never authorized it and has no receipt to give. Requiring one unconditionally would
        // mean the retry ladder never started, since the first end is what starts it.
        var supervisor = ChainedOutageSupervisor()
        supervisor.beginOutage(atSeconds: 0)
        let expired = try XCTUnwrap(ChainedSessionEndCause(
            ChainedDataPathPolicy.action(for: .failure(.connectionExpired))))

        guard case .attempt = supervisor.action(atSeconds: 0, endedBy: (expired, nil)) else {
            return XCTFail("the first session end must start the ladder")
        }
        // And exactly once: a second delivery of the same receipt-less end is a duplicate
        // callback, not a second session ending.
        if case .attempt = supervisor.action(atSeconds: 0, endedBy: (expired, nil)) {
            XCTFail("a duplicated receipt-less end scheduled a second attempt")
        }
    }

    func testTheLiveSessionIsIdentifiedByItsSerialHoweverOldItsOutage() throws {
        // A session is not rebuilt by a stop/recovery cycle, so it can outlive several
        // outages. Two epoch restrictions were wrong in turn: requiring the CURRENT epoch
        // rejected the session an outage inherits, and allowing exactly one epoch back rejects
        // one that survives two. Rejecting a live session's end means no retry is scheduled
        // and the supervisor waits out the whole budget before falling back to DNS-only.
        //
        // The serial is sufficient on its own: it names the last attempt this supervisor
        // authorized, and serials are monotonic and never reused.
        var supervisor = ChainedOutageSupervisor()
        let outageA = supervisor.beginOutage(atSeconds: 0)
        let ticket = try XCTUnwrap(nextTicket(&supervisor))
        guard case .authorized(_, _, let receipt) =
            supervisor.authorizeAttemptStartingNow(atSeconds: 0, with: ticket)
        else { return XCTFail("A must authorize") }

        supervisor.endOutage(in: outageA)
        let outageB = supervisor.beginOutage(atSeconds: 100)
        supervisor.endOutage(in: outageB)
        supervisor.beginOutage(atSeconds: 200)

        let expired = try XCTUnwrap(ChainedSessionEndCause(
            ChainedDataPathPolicy.action(for: .failure(.connectionExpired))))
        guard case .attempt = supervisor.action(atSeconds: 201, endedBy: (expired, receipt))
        else {
            return XCTFail("a session surviving two outages had its end ignored")
        }
    }

    func testAReceiptForAnAttemptThatIsNotTheLiveOneIsRefused() throws {
        // The other side of dropping the epoch check: a receipt whose serial is NOT the last
        // authorized attempt names a session already replaced, and its cause must not be
        // classified against the current one.
        //
        // Three attempts deep on purpose. An earlier version of this test used the FIRST
        // attempt's receipt one attempt later, and passed for the wrong reason — that receipt
        // had already been consumed as an end, so the once-only guard refused it before the
        // serial check ran. Dropping the serial check entirely failed nothing. Going three
        // deep leaves attempt one's receipt unconsumed while attempt three is live, so the
        // serial check is the only thing that can refuse it.
        var supervisor = ChainedOutageSupervisor()
        supervisor.beginOutage(atSeconds: 0)

        let firstTicket = try XCTUnwrap(nextTicket(&supervisor))
        guard case .authorized(_, _, let firstReceipt) =
            supervisor.authorizeAttemptStartingNow(atSeconds: 0, with: firstTicket)
        else { return XCTFail("attempt one must authorize") }
        supervisor.recordAttempt(firstReceipt)

        let secondTicket = try XCTUnwrap(
            nextTicket(&supervisor, atSeconds: 1, completing: firstReceipt))
        guard case .authorized(_, _, let secondReceipt) =
            supervisor.authorizeAttemptStartingNow(atSeconds: 1, with: secondTicket)
        else { return XCTFail("attempt two must authorize") }
        supervisor.recordAttempt(secondReceipt)

        let thirdTicket = try XCTUnwrap(
            nextTicket(&supervisor, atSeconds: 2, completing: secondReceipt))
        guard case .authorized = supervisor.authorizeAttemptStartingNow(
            atSeconds: 2, with: thirdTicket)
        else { return XCTFail("attempt three must authorize") }

        // Attempt ONE's end arrives now — never consumed, two attempts out of date.
        let unusable = ChainedSessionEndCause(
            ChainedDataPathPolicy.action(for: .failure(.unrecognized(code: -9))))
        guard let unusable else { return XCTFail("an unrecognised code must end a session") }
        XCTAssertEqual(
            supervisor.action(atSeconds: 3, endedBy: (unusable, firstReceipt)), .carryOn,
            "a superseded attempt's end surrendered the outage")
    }

    func testARejectedStaleEndDoesNotClobberTheConsumedRecord() throws {
        // The consequence of removing a guard because "mutation testing showed it failed
        // nothing". That inference was wrong: no test covered the sequence, which is not the
        // same as the guard doing nothing.
        //
        // A rejected stale end still overwrote the consumed-end record, so a duplicate
        // delivery of the CURRENT end then passed the once-only guard and minted another
        // ticket — reintroducing exactly the supersession that state exists to prevent.
        var supervisor = ChainedOutageSupervisor()
        supervisor.beginOutage(atSeconds: 0)
        let ticket = try XCTUnwrap(nextTicket(&supervisor))
        guard case .authorized(_, _, let receipt) =
            supervisor.authorizeAttemptStartingNow(atSeconds: 0, with: ticket)
        else { return XCTFail("the attempt must authorize") }
        supervisor.recordAttempt(receipt)

        let expired = try XCTUnwrap(ChainedSessionEndCause(
            ChainedDataPathPolicy.action(for: .failure(.connectionExpired))))
        guard case .attempt(_, _, let scheduled) =
            supervisor.action(atSeconds: 1, endedBy: (expired, receipt))
        else { return XCTFail("the end must schedule a retry") }

        // A stale receipt-less end arrives and is refused — it must leave the record alone.
        _ = supervisor.action(atSeconds: 1, endedBy: (expired, nil))

        if case .attempt = supervisor.action(atSeconds: 1, endedBy: (expired, receipt)) {
            XCTFail("a duplicate of the current end minted a second ticket")
        }
        guard case .authorized = supervisor.authorizeAttemptStartingNow(
            atSeconds: 1, with: scheduled)
        else { return XCTFail("the legitimate scheduled retry was superseded") }
    }

    func testASessionEndIsTurnedIntoADecisionOnlyOnce() throws {
        // A receipt stays valid until the NEXT attempt authorizes, and a session end arrives
        // by callback — so the same end delivered twice before its replacement ran matched
        // every time and minted a newer ticket on each delivery. Each newer ticket superseded
        // the retry the previous one had scheduled, whose authorization then stood down, and
        // repeating it postponed recovery until the budget forced DNS-only fallback.
        //
        // Measured before the fix: two duplicate deliveries minted two extra tickets and the
        // legitimate scheduled retry stood down with `attemptAlreadyStarted`.
        var supervisor = ChainedOutageSupervisor()
        supervisor.beginOutage(atSeconds: 0)
        let first = try XCTUnwrap(nextTicket(&supervisor))
        guard case .authorized(_, _, let receipt) =
            supervisor.authorizeAttemptStartingNow(atSeconds: 0, with: first)
        else { return XCTFail("the first attempt must authorize") }
        supervisor.recordAttempt(receipt)

        let expired = try XCTUnwrap(ChainedSessionEndCause(
            ChainedDataPathPolicy.action(for: .failure(.connectionExpired))))
        guard case .attempt(_, _, let scheduled) =
            supervisor.action(atSeconds: 1, endedBy: (expired, receipt))
        else { return XCTFail("the end must schedule a retry") }

        for delivery in 1...3 {
            if case .attempt = supervisor.action(atSeconds: 1, endedBy: (expired, receipt)) {
                XCTFail("delivery \(delivery) of the same end scheduled another attempt")
            }
        }

        // The retry that was actually scheduled is still the one that runs.
        guard case .authorized = supervisor.authorizeAttemptStartingNow(
            atSeconds: 1, with: scheduled)
        else { return XCTFail("duplicate ends superseded the legitimate scheduled retry") }
    }

    func testAReceiptlessEndIsAcceptedOnlyBeforeAnythingHasBeenAuthorized() {
        // The hole a ticket WATERMARK left. `lastConsumedTicket` is monotonic across outages —
        // `beginOutage` does not reset it, because the supersede rule needs serials ordered —
        // so for every outage after the first, a watermark taken at its start carries the
        // PREVIOUS outage's value. An unlimited number of stale receipt-less ends satisfied
        // it, and each was classified against the current outage: a deterministic cause from
        // an outage that was already over surrendered a healthy one.
        var supervisor = ChainedOutageSupervisor()
        let outageA = supervisor.beginOutage(atSeconds: 0)
        guard let ticketA = nextTicket(&supervisor) else { return }
        guard case .authorized = supervisor.authorizeAttemptStartingNow(atSeconds: 0, with: ticketA)
        else { return XCTFail("A must authorize") }
        supervisor.endOutage(in: outageA)
        supervisor.beginOutage(atSeconds: 100)

        let unusable = ChainedSessionEndCause(
            ChainedDataPathPolicy.action(for: .failure(.unrecognized(code: -9))))
        guard let unusable else { return XCTFail("an unrecognised code must end a session") }
        XCTAssertEqual(
            supervisor.action(atSeconds: 101, endedBy: (unusable, nil)), .carryOn,
            "a receipt-less end surrendered an outage it did not belong to")
        XCTAssertTrue(supervisor.isTimingAnOutage)
    }



    func testTheClockIsRecheckedAfterObservingTheAuthorizationTime() {
        // The guard used to run BEFORE `observe`, so it saw the flag as it stood a moment ago,
        // `observe` then set it, and execution carried on to return an authorization whose
        // deadline was computed from the very reading that proved the clock bad. A caller on a
        // wall clock could start an attempt whose watchdog was not bounded at all.
        var supervisor = ChainedOutageSupervisor()
        supervisor.beginOutage(atSeconds: 100)
        guard let ticket = nextTicket(&supervisor, atSeconds: 100) else { return }
        supervisor.observe(atSeconds: 105)

        XCTAssertEqual(
            supervisor.authorizeAttemptStartingNow(atSeconds: 50, with: ticket),
            .refused(.clockUnusable),
            "the first backward reading arriving through authorize still authorized")
    }


    func testADuplicatedCompletionCannotRetireANewerAttempt() {
        // Retirement used to be positional — `recordAttempt()` cleared whatever was running —
        // so a duplicated session-end callback completed attempt A, retired attempt B which
        // had since started, and let a third begin concurrently with B.
        //
        // Binding the receipt closed that, and binding `action` to the receipt as well made
        // the guarantee stronger than the original assertion: A's duplicate callback cannot
        // even obtain a ticket now, because the attempt it names is not the one running.
        var supervisor = ChainedOutageSupervisor()
        supervisor.beginOutage(atSeconds: 0)

        guard let ticketA = nextTicket(&supervisor) else { return }
        guard case .authorized(_, _, let receiptA) =
            supervisor.authorizeAttemptStartingNow(atSeconds: 0, with: ticketA)
        else { return XCTFail("A must authorize") }
        supervisor.recordAttempt(receiptA)

        guard let ticketB = nextTicket(&supervisor, atSeconds: 1, completing: receiptA)
        else { return }
        guard case .authorized(_, _, let receiptB) =
            supervisor.authorizeAttemptStartingNow(atSeconds: 1, with: ticketB)
        else { return XCTFail("B must authorize") }

        // A's callback arrives a second time, naming an attempt that is over.
        supervisor.recordAttempt(receiptA)

        let expired = ChainedSessionEndCause(
            ChainedDataPathPolicy.action(for: .failure(.connectionExpired)))
        guard let expired else { return XCTFail("connectionExpired must end a session") }
        if case .attempt = supervisor.action(atSeconds: 2, endedBy: (expired, receiptA)) {
            XCTFail("a stale completion scheduled another attempt while B was running")
        }

        // And B is still the running attempt: its own completion still retires it.
        supervisor.recordAttempt(receiptB)
        XCTAssertEqual(
            supervisor.completedAttempts, 2,
            "B's own completion must still retire it after the stale one was refused")
    }

    func testABackwardClockIsReportedRatherThanAbsorbed() {
        // Four implementations tried to COPE with a backward jump and each was wrong in a new
        // way. Reporting `max(0, delta)` refunded the budget on every jump. A high-water mark
        // of displacement from the start stopped the refund and froze the clock instead — a
        // measured 77-second blackhole against a 15-second budget. Accumulating forward deltas
        // fixed both and still lost any excursion happening BETWEEN two observations, so the
        // bound quietly became a function of how often the caller looked at its clock.
        //
        // That last one cannot be fixed by arithmetic, and it exposed the wrong premise: `now`
        // is documented as MONOTONIC, and a monotonic clock cannot go backwards. A backward
        // reading is therefore not a condition to absorb — it is evidence the caller passed a
        // wall clock. The budget cannot be enforced on a time source that moves both ways, and
        // coping silently accepts one and then has to be perfect about it forever.
        var supervisor = ChainedOutageSupervisor()
        supervisor.beginOutage(atSeconds: 100)
        supervisor.observe(atSeconds: 112)
        XCTAssertFalse(supervisor.clockIsUnusable)
        XCTAssertEqual(supervisor.elapsedSeconds(atSeconds: 112), 12)

        supervisor.observe(atSeconds: 50)
        XCTAssertTrue(supervisor.clockIsUnusable, "a backward reading must be recorded as a fault")
        XCTAssertEqual(
            supervisor.action(atSeconds: 50, endedBy: nil), .surrender(.clockUnusable),
            "a tunnel cannot hold 0.0.0.0/0 on a clock whose readings move both ways")
    }

    func testAnUnusableClockRefusesEveryAttemptRatherThanTiming() {
        // The other half: once the clock is known bad, an authorization must not hand out a
        // deadline computed from it. Refused as `clockUnusable` rather than `budgetExhausted`,
        // because the budget was not spent — it could not be measured, and a field report
        // naming the wrong one sends whoever reads it looking for slow handshakes.
        var supervisor = ChainedOutageSupervisor()
        supervisor.beginOutage(atSeconds: 100)
        guard let ticket = nextTicket(&supervisor, atSeconds: 100) else { return }
        supervisor.observe(atSeconds: 101)
        supervisor.observe(atSeconds: 99)

        XCTAssertEqual(
            supervisor.authorizeAttemptStartingNow(atSeconds: 99, with: ticket),
            .refused(.clockUnusable))
    }

    func testAForwardOnlyClockIsUnaffected() {
        // The guarantee this must not break: a monotonic caller — which is every correct
        // caller — sees exactly the behaviour it did before, and still surrenders on the
        // budget rather than on the clock.
        var supervisor = ChainedOutageSupervisor()
        supervisor.beginOutage(atSeconds: 1_000)
        for second in 1_000...1_014 {
            supervisor.observe(atSeconds: second)
            XCTAssertFalse(supervisor.clockIsUnusable, "at \(second)")
            XCTAssertEqual(supervisor.action(atSeconds: second, endedBy: nil), .carryOn)
        }
        supervisor.observe(atSeconds: 1_015)
        XCTAssertEqual(
            supervisor.action(atSeconds: 1_015, endedBy: nil), .surrender(.budgetExhausted),
            "a forward-only clock must still surrender on the BUDGET, not on the clock")
    }

    func testARepeatedReadingIsNotBackward() {
        // Equal readings are ordinary — a caller can observe twice within one second, and the
        // clock has not misbehaved. Rejecting `<=` instead of `<` would make every dense
        // poller look broken.
        var supervisor = ChainedOutageSupervisor()
        supervisor.beginOutage(atSeconds: 500)
        supervisor.observe(atSeconds: 500)
        supervisor.observe(atSeconds: 500)
        supervisor.observe(atSeconds: 501)
        XCTAssertFalse(supervisor.clockIsUnusable)
        XCTAssertEqual(supervisor.elapsedSeconds(atSeconds: 501), 1)
    }

    func testTheArmedDeadlineIsAnInstantSoSchedulingLatencyCannotExtendIt() throws {
        // Two bugs in a row lived here. The action carried a deadline computed at DECISION
        // time, spent by the delay before the attempt began. Replacing it with a duration
        // returned by the authorization fixed the first gap and left a smaller one: a
        // duration is only valid at the instant it is issued, so a caller authorized at
        // elapsed 9 with six seconds left, reaching its arming code at elapsed 10, armed a
        // six-second timer expiring at elapsed 16 — past a 15-second budget.
        //
        // An instant cannot be stretched by the latency between being issued and being armed.
        var supervisor = ChainedOutageSupervisor()
        supervisor.beginOutage(atSeconds: 0)

        let first = try XCTUnwrap(nextTicket(&supervisor))
        guard case .authorized(_, let atDecision, let firstReceipt) =
            supervisor.authorizeAttemptStartingNow(atSeconds: 0, with: first)
        else { return XCTFail("expected an authorization at decision time") }
        XCTAssertEqual(atDecision, 15, "the whole budget, expressed as an instant")

        // A second attempt, scheduled later in the same outage, takes its own ticket — one
        // ticket is authority for one attempt. Its deadline is the SAME instant, because the
        // instant is pinned to when the outage began rather than to when an attempt starts.
        supervisor.recordAttempt(firstReceipt)
        let second = try XCTUnwrap(
            nextTicket(&supervisor, atSeconds: 3, completing: firstReceipt))
        guard case .authorized(_, let armedLate, _) =
            supervisor.authorizeAttemptStartingNow(atSeconds: 3, with: second)
        else { return XCTFail("3s in, an attempt is still authorized") }
        XCTAssertEqual(
            armedLate, ChainedReconnectPolicy.maximumBlackholeSeconds,
            "the deadline is pinned to when the outage began, not to when the attempt started")
        XCTAssertEqual(armedLate, atDecision, "a later start must not move the deadline out")
    }

    func testATicketAuthorizesExactlyOneAttempt() {
        // A ticket that stayed valid could be replayed: one scheduled callback authorized an
        // unbounded number of concurrent sessions, each reporting itself as the same attempt
        // number and each arming its own watchdog. A probe confirmed five from one ticket.
        //
        // The generation alone could not prevent this — it identifies the OUTAGE, and an
        // outage lasts for many attempts, so spending it as an attempt capability conflated
        // two different lifetimes.
        var supervisor = ChainedOutageSupervisor()
        supervisor.beginOutage(atSeconds: 0)
        guard let ticket = nextTicket(&supervisor) else { return }

        guard case .authorized = supervisor.authorizeAttemptStartingNow(atSeconds: 0, with: ticket)
        else { return XCTFail("the first use must be authorized") }
        for replay in 1...4 {
            XCTAssertEqual(
                supervisor.authorizeAttemptStartingNow(atSeconds: 0, with: ticket),
                .standDown(.attemptAlreadyStarted),
                "replay \(replay) started a concurrent session")
        }
    }

    /// A spent ticket stays spent AFTER its attempt has been retired.
    ///
    /// 🔴 THE CASE THE TEST ABOVE CANNOT REACH, and without it the single-use clause is untested.
    /// Those four replays all happen while `attemptInFlight` is still true, so TWO independent
    /// guards return the identical `.standDown(.attemptAlreadyStarted)` — the single-use clause
    /// (`ticket.serial > lastConsumedTicket`) and the in-flight clause. Comparing only the
    /// returned value cannot say which fired, so deleting the single-use half moves the refusal
    /// one line down and the assertion never notices (sweep, PR #623).
    ///
    /// `recordAttempt` is what separates them: it clears `attemptInFlight` while leaving
    /// `lastIssuedTicket` where it is, because no new ticket is minted until a session end is
    /// classified. In that window the in-flight guard is open and ONLY single-use stands between
    /// one scheduled callback and a second session — the unbounded replay this type exists to
    /// prevent, of which "a probe confirmed five from one ticket".
    func testASpentTicketIsStillRefusedOnceItsAttemptHasBeenRetired() {
        var supervisor = ChainedOutageSupervisor()
        supervisor.beginOutage(atSeconds: 0)
        guard let ticket = nextTicket(&supervisor) else { return }

        guard case .authorized(_, _, let receipt) =
            supervisor.authorizeAttemptStartingNow(atSeconds: 0, with: ticket)
        else { return XCTFail("the first use must be authorized") }

        // Retire the attempt. `attemptInFlight` is now false, so the second guard is WIDE OPEN
        // and cannot mask the first.
        supervisor.recordAttempt(receipt)

        XCTAssertEqual(
            supervisor.authorizeAttemptStartingNow(atSeconds: 0, with: ticket),
            .standDown(.attemptAlreadyStarted),
            "a ticket already spent authorized a SECOND attempt once its first was retired — one "
                + "scheduled callback can then start an unbounded number of sessions")
    }




    func testEachTrafficStoppedNotificationGetsItsOwnRecoveryToken() {
        // The clock is idempotent and the recovery identity is not, because they answer
        // different questions. Two notifications during one outage used to share a token, so
        // the FIRST one's delayed recovery cleared a clock the second was still reporting
        // against — and the budget then started over on the next notification, which is the
        // refund the monotonic floor exists to prevent, reached by another route.
        var supervisor = ChainedOutageSupervisor()
        let first = supervisor.beginOutage(atSeconds: 0)
        let second = supervisor.beginOutage(atSeconds: 5)
        XCTAssertNotEqual(first, second, "overlapping notifications shared a recovery identity")
        XCTAssertEqual(supervisor.elapsedSeconds(atSeconds: 5), 5, "the clock must NOT restart")

        supervisor.endOutage(in: first)
        XCTAssertTrue(supervisor.isTimingAnOutage, "a stale recovery cleared a live outage")
        supervisor.endOutage(in: second)
        XCTAssertFalse(supervisor.isTimingAnOutage, "the current recovery must still work")
    }

    func testAFlapDoesNotInvalidateATicketForTheSameOutage() {
        // The regression the split prevents. Advancing one counter for both identities made a
        // flap — which does not start a new outage — stand down attempts that were still valid
        // for the outage in progress. The outage epoch advances only when an outage STARTS.
        var supervisor = ChainedOutageSupervisor()
        supervisor.beginOutage(atSeconds: 0)
        guard let ticket = nextTicket(&supervisor) else { return }
        supervisor.beginOutage(atSeconds: 1)

        guard case .authorized = supervisor.authorizeAttemptStartingNow(atSeconds: 1, with: ticket)
        else { return XCTFail("a flap invalidated a ticket for the same outage") }
    }

    func testAStaleRecoveryCannotDisarmALaterOutage() {
        // The most dangerous omission of the three, because it produces an UNBOUNDED
        // blackhole out of entirely correct-looking calls. Recovery is delivered by callback
        // too, so outage A's late "traffic resumed" cleared outage B's clock; the supervisor
        // then reported no outage in progress and `action` returned `.carryOn` forever, in
        // the one type whose whole purpose is to bound exactly that.
        var supervisor = ChainedOutageSupervisor()
        let outageA = supervisor.beginOutage(atSeconds: 0)
        supervisor.endOutage(in: outageA)
        supervisor.beginOutage(atSeconds: 100)

        supervisor.endOutage(in: outageA)  // A's LATE recovery callback

        XCTAssertTrue(supervisor.isTimingAnOutage, "outage B was disarmed by a stale recovery")
        XCTAssertEqual(
            supervisor.action(atSeconds: 200, endedBy: nil), .surrender(.budgetExhausted),
            "B must still surrender on its own budget")
    }

    func testAnOverflowingClockIsRefusedRatherThanGivenAnUnreachableDeadline() {
        // Saturating returned `.authorized` with `deadlineAtSeconds == Int.max`: a watchdog
        // instant that never arrives, which is an unbounded blackhole wearing the shape of a
        // successful authorization. The comment claimed the budget check refused it first. It
        // does not — a probe confirmed the authorization was issued.
        //
        // Refused as `clockUnusable`, not `budgetExhausted`: the budget was not spent, it
        // could not be measured, and a field report naming the wrong one sends whoever reads
        // it looking for slow handshakes that never happened.
        var supervisor = ChainedOutageSupervisor()
        supervisor.beginOutage(atSeconds: Int.max - 2)
        guard let ticket = nextTicket(&supervisor, atSeconds: Int.max - 2) else { return }
        XCTAssertEqual(
            supervisor.authorizeAttemptStartingNow(atSeconds: Int.max - 2, with: ticket),
            .refused(.clockUnusable))
    }

    func testTheAuthorizedDeadlineNeverOutlivesTheBudgetHoweverLateItIsArmed() {
        // The property the instant buys, asserted across every start time AND every arming
        // delay after it. The previous version could not catch the drift because it only ever
        // compared values read at the same moment; this one arms late on purpose.
        var supervisor = ChainedOutageSupervisor()
        supervisor.beginOutage(atSeconds: 0)
        guard let ticket = nextTicket(&supervisor) else { return }

        for start in 0...(ChainedReconnectPolicy.maximumBlackholeSeconds + 5) {
            var probe = supervisor
            switch probe.authorizeAttemptStartingNow(atSeconds: start, with: ticket) {
            case .authorized(let attempt, let deadlineAt, _):
                XCTAssertLessThanOrEqual(
                    deadlineAt, ChainedReconnectPolicy.maximumBlackholeSeconds,
                    "the deadline escaped the budget, start \(start)")
                XCTAssertGreaterThanOrEqual(
                    deadlineAt - start, ChainedReconnectPolicy.minimumUsefulAttemptSeconds,
                    "authorized a sub-minimum window, start \(start)")
                XCTAssertEqual(attempt, 1, "start \(start)")
                // Arming late: whatever the caller does afterwards, the instant is fixed.
                for armingDelay in 0...4 {
                    XCTAssertLessThanOrEqual(
                        deadlineAt, ChainedReconnectPolicy.maximumBlackholeSeconds,
                        "armed \(armingDelay)s late from start \(start)")
                }
            case .refused(let reason):
                XCTAssertEqual(reason, .budgetExhausted, "start \(start)")
                XCTAssertGreaterThan(
                    start, ChainedReconnectPolicy.maximumBlackholeSeconds
                        - ChainedReconnectPolicy.minimumUsefulAttemptSeconds,
                    "refused while enough budget remained, start \(start)")
            case .standDown(let reason):
                XCTFail("an outage is in progress at start \(start): \(reason)")
            }
        }
    }

    func testACallbackFromAnEarlierOutageCannotSpendALaterOnesBudget() {
        // Checking that SOME outage is active is not enough, and this is the sequence that
        // shows it: outage A schedules an attempt, traffic recovers, outage B begins — all
        // before A's callback runs. The active-outage guard passes, so A's callback was
        // authorized against B's fresh budget, launching a duplicate session and recording A's
        // attempt in B's retry ladder.
        //
        // No clock reading distinguishes the two: B's elapsed time is small and legitimate.
        // Only a token carried from the scheduling decision can.
        var supervisor = ChainedOutageSupervisor()
        let generationToken = supervisor.beginOutage(atSeconds: 0)
        guard let outageA = nextTicket(&supervisor) else { return }

        supervisor.endOutage(in: generationToken)
        supervisor.beginOutage(atSeconds: 100)

        XCTAssertEqual(
            supervisor.authorizeAttemptStartingNow(atSeconds: 101, with: outageA),
            .standDown(.supersededByALaterOutage),
            "outage A's callback spent outage B's budget")

        // B's own token still works, so the guard rejects the stale one rather than everything.
        guard let outageB = nextTicket(&supervisor, atSeconds: 101) else { return }
        guard case .authorized = supervisor.authorizeAttemptStartingNow(atSeconds: 101, with: outageB)
        else { return XCTFail("outage B's own callback must be authorized") }
    }

    func testALateCallbackAfterRecoveryStandsDownRatherThanStartingASession() {
        // The delay a scheduled start waits out has to pass somewhere, and the session it was
        // waiting on can succeed while it waits. With no outage being timed, elapsed reads 0,
        // which reads as a FULL budget — so this authorized attempt 1 of an outage that was
        // over, starting a session on top of flowing traffic.
        var supervisor = ChainedOutageSupervisor()
        let generationToken = supervisor.beginOutage(atSeconds: 0)
        guard let ticket = nextTicket(&supervisor) else { return }
        supervisor.endOutage(in: generationToken)
        XCTAssertEqual(
            supervisor.authorizeAttemptStartingNow(atSeconds: 3, with: ticket),
            .standDown(.noOutageInProgress))
    }

    func testStandingDownIsNotASurrender() {
        // The two non-authorizations must not be conflated. Refusal restarts the tunnel into
        // DNS-only; standing down does nothing. Answering a late callback with a surrender
        // would tear down a healthy chained tunnel to fix a problem that had already resolved.
        var supervisor = ChainedOutageSupervisor()
        let generationToken = supervisor.beginOutage(atSeconds: 0)
        guard let ticket = nextTicket(&supervisor) else { return }
        supervisor.endOutage(in: generationToken)
        let standDown = supervisor.authorizeAttemptStartingNow(atSeconds: 0, with: ticket)
        XCTAssertFalse(standDown.surrendersChaining)

        var exhausted = ChainedOutageSupervisor()
        exhausted.beginOutage(atSeconds: 0)
        guard let exhaustedTicket = nextTicket(&exhausted) else { return }
        let refusal = exhausted.authorizeAttemptStartingNow(
            atSeconds: ChainedReconnectPolicy.maximumBlackholeSeconds, with: exhaustedTicket)
        XCTAssertEqual(refusal, .refused(.budgetExhausted))
        XCTAssertTrue(refusal.surrendersChaining)

        // Each non-authorization is distinguishable in a device log, including the two
        // stand-down reasons — a stale callback and a recovered tunnel are different events.
        let values = Set([
            standDown.logValue,
            refusal.logValue,
            ChainedAttemptAuthorization.standDown(.supersededByALaterOutage).logValue,
        ])
        XCTAssertEqual(values.count, 3)
    }

    func testTheFloorAdvancesWithoutASeparateObserveCall() {
        // A guard that depends on the caller remembering to arm it is not a guard. `action`
        // advances the floor itself, so a caller using only beginOutage and action — which the
        // contract permitted — cannot have the budget refunded by a backward clock.
        var supervisor = ChainedOutageSupervisor()
        supervisor.beginOutage(atSeconds: 100)
        _ = supervisor.action(atSeconds: 112, endedBy: nil)
        XCTAssertEqual(supervisor.elapsedSeconds(atSeconds: 50), 12, "the floor advanced on its own")
    }


    func testOnlyTheAttemptsOwnReceiptAdvancesTheCount() {
        // This replaces `testAttemptCountSaturatesRatherThanTrapping`, which was named for a
        // guard it never reached: it called `recordAttempt` five times and asserted the count
        // was five, which tests incrementing, not saturation. The `Int.max` guard is
        // unreachable by any test — an outage would need 2^63 attempts inside a 15-second
        // budget — so it stays as a trap-avoidance measure and is honestly untested.
        //
        // What IS checkable is the property that replaced it: retirement is bound to the
        // attempt that was authorized, so a stale or duplicated completion advances nothing.
        var supervisor = ChainedOutageSupervisor()
        supervisor.beginOutage(atSeconds: 0)

        guard let ticket = nextTicket(&supervisor) else { return }
        guard case .authorized(_, _, let receipt) =
            supervisor.authorizeAttemptStartingNow(atSeconds: 0, with: ticket)
        else { return XCTFail("expected an authorization") }

        supervisor.recordAttempt(receipt)
        XCTAssertEqual(supervisor.completedAttempts, 1)

        // The same receipt again is a duplicated completion. It must not advance the count,
        // and — the part that matters — it must not retire whatever is running now.
        supervisor.recordAttempt(receipt)
        XCTAssertEqual(
            supervisor.completedAttempts, 1,
            "a duplicated completion advanced the retry ladder")
    }

    // MARK: - Session ends defer to the reconnect policy

    func testASessionEndDefersRatherThanRedecidingTheClassification() throws {
        // The supervisor owns the CLOCK, not the classification. Duplicating the reconnect
        // policy's judgement here is how the two would drift — three contradictions between
        // that policy and the data-path classifier have already shipped.
        var supervisor = ChainedOutageSupervisor()
        supervisor.beginOutage(atSeconds: 0)

        let expired = try XCTUnwrap(
            ChainedSessionEndCause(ChainedDataPathPolicy.action(for: .failure(.connectionExpired))))
        guard case .attempt(let after, let attempt, _) =
            supervisor.action(atSeconds: 0, endedBy: (expired, nil))
        else { return XCTFail("an expired session inside the budget should attempt again") }

        guard case .retry(let policyAfter, let policyAttempt, _) =
            Policy.decision(completedAttempts: 0, elapsedSeconds: 0, cause: expired)
        else { return XCTFail("the policy should retry") }
        XCTAssertEqual(after, policyAfter)
        XCTAssertEqual(attempt, policyAttempt)
    }

    func testATransientBuildFailureMintsATicketAndStillTerminates() throws {
        // A build failure reaches this type the same way a session end does, and until now it
        // could only ever produce `.surrender`: the driver reported `sessionCreationFailed` for
        // every thrown error and the policy classified that as deterministic. So the ticket, the
        // backoff and the receipts were unreachable from a handoff — the commonest reason an
        // attempt is happening at all.
        //
        // Both halves are asserted here, because the dangerous fix is the one that only does the
        // first: a transient failure has to mint a ticket AND leave the budget exactly where it
        // found it, or the retry ladder becomes a way to hold `0.0.0.0/0` indefinitely while every
        // individual decision looks reasonable.
        var supervisor = ChainedOutageSupervisor()
        supervisor.beginOutage(atSeconds: 0)
        let transient = ChainedSessionEndCause.buildFailure(
            ChainedSessionBuildFailure.noEligibleInterface)

        var now = 0
        var actions: [ChainedOutageAction] = []
        var walkReceipt: ChainedAttemptReceipt?
        for _ in 0..<20 {
            let action = supervisor.action(atSeconds: now, endedBy: (transient, walkReceipt))
            actions.append(action)
            guard case .attempt(let after, _, let ticket) = action else { break }
            if case .authorized(_, _, let receipt) =
                supervisor.authorizeAttemptStartingNow(atSeconds: now, with: ticket) {
                supervisor.recordAttempt(receipt)
                walkReceipt = receipt
            }
            now += after
        }

        XCTAssertTrue(
            actions.contains { if case .attempt = $0 { return true } else { return false } },
            "a transient build failure never reached the retry ladder — actions = "
                + "\(actions.map(\.logValue))")
        XCTAssertTrue(actions.last?.surrendersChaining == true, "the outage must terminate")
        XCTAssertLessThanOrEqual(
            now, Policy.maximumBlackholeSeconds,
            "transient build failures held traffic longer than the budget allows")
    }

    func testADeterministicFaultSurrendersImmediatelyEvenWithBudgetLeft() throws {
        // Budget remaining is irrelevant for a cause retrying cannot fix.
        var supervisor = ChainedOutageSupervisor()
        supervisor.beginOutage(atSeconds: 0)
        let unusable = try XCTUnwrap(
            ChainedSessionEndCause(ChainedDataPathPolicy.action(for: .failure(.unrecognized(code: -9)))))
        XCTAssertEqual(
            supervisor.action(atSeconds: 0, endedBy: (unusable, nil)), .surrender(.engineUnusable))
    }

    func testEveryTriagedCauseResolvesToAnAction() throws {
        var supervisor = ChainedOutageSupervisor()
        supervisor.beginOutage(atSeconds: 0)
        let causes: [WireGuardEngineError] = [
            .invalidArgument, .destinationBufferTooSmall, .noCurrentSession, .underLoad,
            .protocolViolation, .oversizedDatagram, .connectionExpired, .engineInternal,
            .packetTooLarge, .sessionCreationFailed, .unrecognized(code: -1),
        ]
        var compared = 0
        for error in causes {
            guard let cause = ChainedSessionEndCause(
                ChainedDataPathPolicy.action(for: .failure(error)))
            else { continue }
            switch supervisor.action(atSeconds: 0, endedBy: (cause, nil)) {
            case .carryOn, .attempt, .surrender:
                compared += 1
            }
        }
        XCTAssertEqual(compared, 7, "every session-ending cause must produce an action")
    }

    // MARK: - Attempts spend the budget

    func testAttemptsWalkTheLadderAndTheOutageStillTerminates() throws {
        // The ladder AND the clock together. Each attempt advances real time, so the budget
        // runs out even though every individual decision looked reasonable.
        var supervisor = ChainedOutageSupervisor()
        supervisor.beginOutage(atSeconds: 0)
        let expired = try XCTUnwrap(
            ChainedSessionEndCause(ChainedDataPathPolicy.action(for: .failure(.connectionExpired))))

        var now = 0
        var actions: [ChainedOutageAction] = []
        var walkReceipt: ChainedAttemptReceipt?
        for _ in 0..<20 {
            let action = supervisor.action(atSeconds: now, endedBy: (expired, walkReceipt))
            actions.append(action)
            guard case .attempt(let after, _, let ticket) = action else { break }
            if case .authorized(_, _, let receipt) =
                supervisor.authorizeAttemptStartingNow(atSeconds: now, with: ticket) {
                supervisor.recordAttempt(receipt)
                walkReceipt = receipt
            }
            now += after
        }

        XCTAssertTrue(actions.last?.surrendersChaining == true, "the outage must terminate")
        XCTAssertLessThanOrEqual(
            now, Policy.maximumBlackholeSeconds,
            "the tunnel held traffic it could not carry for longer than the budget")
    }

    func testTheDeadlineInstantStaysFixedAsTheOutageProgresses() throws {
        // A duration shrank as the outage ran; an instant does not move at all, which is the
        // whole point — it is pinned to when the outage began, so no amount of scheduling
        // further attempts or arming late pushes the end of the budget out.
        var supervisor = ChainedOutageSupervisor()
        supervisor.beginOutage(atSeconds: 0)

        var deadlines: [Int] = []
        var previous: ChainedAttemptReceipt?
        // Walked, not listed: a fixed list encodes whatever `minimumUsefulAttemptSeconds` was
        // when it was written, and stops authorizing anything the moment that floor rises.
        //
        // `supervisor.action` is called directly rather than through `nextTicket`, because that
        // helper XCTFails when there is no ticket — correct for every other caller, and wrong
        // here, where running out of budget is how the walk is meant to END.
        let expired = try XCTUnwrap(
            ChainedSessionEndCause(ChainedDataPathPolicy.action(for: .failure(.connectionExpired))))

        for now in 0...ChainedReconnectPolicy.maximumBlackholeSeconds {
            // A fresh ticket per attempt, obtained by reporting the PREVIOUS attempt's end —
            // which is how the provider gets one, since a session end names the attempt it
            // ended.
            guard case .attempt(_, _, let ticket) =
                supervisor.action(atSeconds: now, endedBy: (expired, previous))
            else { break }
            guard case .authorized(_, let deadlineAt, let receipt) =
                supervisor.authorizeAttemptStartingNow(atSeconds: now, with: ticket)
            else { break }
            supervisor.recordAttempt(receipt)
            previous = receipt
            deadlines.append(deadlineAt)
            XCTAssertGreaterThanOrEqual(
                deadlineAt - now, ChainedReconnectPolicy.minimumUsefulAttemptSeconds,
                "a window this short should have been refused, not authorized")
        }
        XCTAssertGreaterThanOrEqual(
            deadlines.count, 2,
            "fewer than two authorizations — nothing here observes whether the instant MOVED")
        XCTAssertEqual(
            Set(deadlines).count, 1,
            "the deadline instant moved: \(deadlines) — re-authorizing must not extend the budget")
        XCTAssertEqual(deadlines.first, ChainedReconnectPolicy.maximumBlackholeSeconds)
    }

    // MARK: - Logging

    func testLogValuesDistinguishTheThreeOutcomes() throws {
        var supervisor = ChainedOutageSupervisor()
        supervisor.beginOutage(atSeconds: 0)
        let expired = try XCTUnwrap(
            ChainedSessionEndCause(ChainedDataPathPolicy.action(for: .failure(.connectionExpired))))

        XCTAssertEqual(ChainedOutageAction.carryOn.logValue, "outage-carry-on")
        XCTAssertTrue(
            supervisor.action(atSeconds: 0, endedBy: (expired, nil)).logValue.hasPrefix("outage-attempt-1-"))
        XCTAssertEqual(
            supervisor.action(atSeconds: 999, endedBy: nil).logValue,
            "outage-surrender-budgetExhausted")
    }















}
