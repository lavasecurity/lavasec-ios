import Foundation
import LavaSecKit

/// What the supervisor tells the caller to do next.
public enum ChainedOutageAction: Equatable, Sendable {
    /// Traffic is flowing. Nothing to do.
    case carryOn
    /// Start a session attempt after this delay.
    ///
    /// Deliberately carries NO deadline. It used to, and that value was computed at decision
    /// time — so a caller that armed it after waiting `afterSeconds` had already overrun by
    /// the wait. Two values where one is a trap is worse than one: the deadline comes from
    /// ``ChainedOutageSupervisor/authorizeAttemptStartingNow(atSeconds:in:)``, called at the
    /// moment the attempt actually begins.
    ///
    /// It DOES carry a single-use ticket, which the authorization requires back. A delay has
    /// to be waited out somewhere, and an outage can end and a new one begin while it is waited
    /// out — so without a token, outage A's callback authorizes against outage B's fresh
    /// budget, launching a duplicate session and recording A's attempt in B's ladder. And the
    /// ticket is per-ATTEMPT rather than per-outage, because a token that outlives its attempt
    /// can be replayed to start concurrent sessions inside one outage.
    case attempt(afterSeconds: Int, attempt: Int, ticket: ChainedAttemptTicket)
    /// Stop. Restart the tunnel into DNS-only with this reason.
    case surrender(ChainedReconnectPolicy.Surrender)
}

/// Identifies one outage, so a callback belonging to it cannot act on another.
///
/// Opaque and not constructible outside this file: a caller that could mint one could mint the
/// CURRENT one, which is precisely the check being made. It is obtained from
/// ``ChainedOutageSupervisor/beginOutage(atSeconds:)`` and handed back to
/// ``ChainedOutageSupervisor/endOutage(in:)``.
public struct ChainedOutageGeneration: Equatable, Sendable {
    fileprivate let value: Int
    fileprivate init(_ value: Int) { self.value = value }
}

/// Proof of which attempt a completion belongs to.
///
/// Opaque and obtainable only from an authorization, so a caller cannot retire an attempt it
/// did not start. Without it, retirement was positional — "whatever is running now" — and a
/// stale completion retired a newer attempt.
public struct ChainedAttemptReceipt: Equatable, Sendable {
    fileprivate let generation: Int
    fileprivate let serial: Int
    fileprivate init(generation: Int, serial: Int) {
        self.generation = generation
        self.serial = serial
    }
}

/// Authority to start ONE session attempt.
///
/// Separate from ``ChainedOutageGeneration`` because they answer different questions and
/// conflating them was a defect: a generation identifies an outage, and an outage lasts for
/// many attempts, so spending it as an attempt capability let one scheduled callback be
/// replayed to authorize an unbounded number of concurrent sessions — each believing it was
/// attempt 1, each with its own watchdog.
///
/// Single-use and ordered: consuming a ticket retires every ticket issued before it, so an
/// out-of-order callback from earlier in the same outage cannot start a second session either.
/// pinned: ChainedOutageSupervisorTests.testATicketAuthorizesExactlyOneAttempt
public struct ChainedAttemptTicket: Equatable, Sendable {
    fileprivate let generation: Int
    fileprivate let serial: Int
    fileprivate init(generation: Int, serial: Int) {
        self.generation = generation
        self.serial = serial
    }
}

/// Whether an attempt may start at this instant, and how long it may run.
///
/// Separate from ``ChainedOutageAction`` because the two answer different questions, and
/// collapsing them is what let the deadline drift away from the check that validated it.
/// An action SCHEDULES — it says "in `n` seconds" and cannot carry a deadline, because the
/// delay is spent before the attempt begins. An authorization is asked for at the moment of
/// starting, so its deadline is valid, and it carries the value rather than making the
/// caller take a second clock reading to get it.
///
/// That second reading was the bug: authorized at elapsed 9 with six seconds remaining —
/// exactly ``ChainedReconnectPolicy/minimumUsefulAttemptSeconds`` — the caller then read the
/// deadline at elapsed 10 and armed five, which is the sub-minimum window the authorization
/// had just refused to grant. Validating a value the caller must go and fetch again
/// separately validates nothing.
/// pinned: ChainedOutageSupervisorTests.testTheAuthorizedDeadlineNeverOutlivesTheBudgetHoweverLateItIsArmed
public enum ChainedAttemptAuthorization: Equatable, Sendable {
    /// Start now, and arm a watchdog for this ABSOLUTE instant on the caller's clock.
    ///
    /// The `receipt` is what retires this attempt. `recordAttempt()` used to retire whatever
    /// was running, so a DUPLICATED session-end callback — the same delivery this type already
    /// defends against elsewhere — could complete attempt A, retire attempt B which had since
    /// started, and let a third begin concurrently with B.
    ///
    /// An instant, not a duration, because a duration is only valid at the moment it is
    /// issued. Authorized at elapsed 9 with six seconds left, a caller that reached its
    /// arming code at elapsed 10 armed a six-second timer expiring at elapsed 16 — one second
    /// past a budget this type exists to hold. Scheduling latency between authorization and
    /// arming cannot extend an instant.
    case authorized(attempt: Int, deadlineAtSeconds: Int, receipt: ChainedAttemptReceipt)
    /// Nothing to attempt. Do nothing.
    ///
    /// Deliberately NOT a ``refused``. Refusal restarts the tunnel into DNS-only, and the
    /// states this reports are ones where nothing is wrong — traffic is flowing, or a later
    /// outage has already taken over. A late callback answered with a surrender would tear
    /// down a working chained tunnel to fix a problem that had already resolved itself.
    case standDown(StandDownReason)
    /// Do not start. Restart the tunnel into DNS-only with this reason.
    case refused(ChainedReconnectPolicy.Surrender)

    /// Why an attempt was not authorized despite nothing being wrong.
    public enum StandDownReason: String, Equatable, Sendable {
        /// No outage is being timed. Traffic is flowing.
        case noOutageInProgress
        /// The callback belongs to an outage that has since ended; another has begun.
        case supersededByALaterOutage
        /// This ticket, or a newer one, has already started an attempt.
        case attemptAlreadyStarted
    }
}

/// Keeps the outage budget honest across session boundaries.
///
/// Plan: lavasec-infra `plans/backlog/2026-07-27-vpn-upstream-phase-3-data-path-plan.md` (S4).
///
/// ## Why this type exists at all
///
/// ``ChainedReconnectPolicy`` decides what to do when a session ENDS. That is not enough to
/// bound an outage, and the gap is the whole reason this exists:
///
/// The engine does not end a session promptly. boringtun retransmits an in-flight handshake
/// for `REKEY_ATTEMPT_TIME` — 90 seconds — before it reports `connectionExpired`. So on the
/// first loss of reachability the reconnect policy is **not consulted for a minute and a
/// half**, while the tunnel holds `0.0.0.0/0` and forwards nothing. A 15-second budget
/// enforced only at session boundaries permits roughly a 91-second blackhole, and every test
/// that walks the retry ladder passes while that hole is wide open.
///
/// So the budget is measured from the moment traffic STOPPED, not from the moment a session
/// ended, and this type owns that clock. `ChainedReconnectPolicy.remainingBlackholeSeconds`
/// is the arithmetic; this is the state machine that makes sure someone actually calls it.
///
/// ## The clock starts before the first handshake
///
/// `beginOutage` is called when traffic stops — not when the first attempt fails. A supervisor
/// whose clock starts at the first FAILURE has already lost the 90 seconds that matter.
/// pinned: ChainedOutageSupervisorTests.testTheBudgetCoversTheFirstHandshakeNotJustTheRetries
public struct ChainedOutageSupervisor: Equatable, Sendable {
    /// Seconds since the outage began, or `nil` while traffic is flowing.
    public private(set) var outageStartedAtSeconds: Int?
    /// Completed attempts this outage.
    public private(set) var completedAttempts: Int
    /// The end already turned into a scheduling decision, keyed by the receipt that named it.
    ///
    /// A receipt stays valid until the NEXT attempt authorizes, and a session end is delivered
    /// by callback — so the same end arriving twice before its replacement ran matched every
    /// time and minted a newer ticket on each delivery. Each newer ticket superseded the
    /// legitimate scheduled retry, whose authorization then stood down, and repeating it
    /// postponed recovery until the budget forced DNS-only. An end is news exactly once.
    /// pinned: ChainedOutageSupervisorTests.testASessionEndIsTurnedIntoADecisionOnlyOnce
    private var consumedEndSerial: Int?
    /// Whether an authorized attempt is still running.
    ///
    /// Superseding pending tickets was not enough: it protects two callbacks that both
    /// schedule BEFORE either is authorized, and does nothing once one has started. A
    /// duplicated session-end callback arriving while the replacement session runs got a fresh
    /// ticket, which satisfied both `serial == lastIssuedTicket` and
    /// `serial > lastConsumedTicket` and started a second concurrent session. Repeating it
    /// bypassed the single-use guarantee indefinitely.
    ///
    /// Cleared by ``recordAttempt()``, which is how the caller says the attempt is retired.
    /// pinned: ChainedOutageSupervisorTests.testNoSecondAttemptStartsWhileOneIsRunning
    private var attemptInFlight: Bool
    /// The last ticket serial issued, and the last consumed.
    ///
    /// Consuming retires everything issued earlier, so a late callback from the same outage
    /// cannot start a second session after a newer attempt has begun.
    private var lastIssuedTicket: Int
    private var lastConsumedTicket: Int
    /// Identifies the outage itself. Advances only when one STARTS, so a flap during an
    /// outage does not invalidate tickets already issued for it.
    private var outageEpoch: Int
    /// Identifies one traffic-stopped notification. Advances on EVERY `beginOutage`, so only
    /// the most recent notification's recovery can end the outage.
    ///
    /// Wrapping rather than saturating: equality is the only operation, and a stale token
    /// colliding with a live one needs 2^63 outages in one tunnel lifetime. Saturating would
    /// make every outage after the ceiling share a generation, which is the failure this
    /// prevents.
    private var recoverySerial: Int
    /// Time already spent in this outage, accumulated from FORWARD movement only.
    ///
    /// The first version reported `max(0, now - start)`, which let a backward jump read as
    /// zero elapsed and hand the outage a fresh budget. The second took a high-water mark of
    /// the largest displacement from the start, which stopped the refund and introduced a
    /// worse failure: after a backward jump the elapsed value FROZE until the clock caught up
    /// to its previous reading. An outage begun at 100 and observed at 112, with the clock
    /// then stepping back to 50, stayed at 12 elapsed for the next 62 seconds — a nominal
    /// 15-second budget extended to 77, and repeatable indefinitely.
    ///
    /// Accumulating deltas between successive observations is the only shape that refuses
    /// both: a backward step contributes nothing, and forward movement after it counts
    /// immediately because the baseline has moved with the clock.
    /// pinned: ChainedOutageSupervisorTests.testABackwardClockIsReportedRatherThanAbsorbed
    private var accumulatedElapsed: Int
    /// The clock reading the accumulation is measured from.
    private var lastObservedAtSeconds: Int?
    /// Set once the caller's clock has been seen to move BACKWARDS.
    ///
    /// Three implementations tried to cope with a backward jump — reporting `max(0, delta)`
    /// refunded the budget, a high-water mark froze it, and accumulating forward deltas fixed
    /// both but still loses any excursion that happens BETWEEN two observations. That last one
    /// cannot be fixed by arithmetic: a caller observing sparsely, whose clock steps back and
    /// then forward between samples, banks only the net displacement, so the bound silently
    /// becomes a function of polling density.
    ///
    /// The premise was wrong. `now` is documented as a monotonic reading, and a monotonic
    /// clock cannot go backwards — so a backward reading is not a condition to absorb, it is
    /// evidence the caller passed a wall clock. Coping with it silently accepts that and then
    /// has to be perfect forever; reporting it says so once. The budget cannot be enforced on
    /// a time source that moves both ways, and pretending otherwise is the more dangerous
    /// answer.
    /// pinned: ChainedOutageSupervisorTests.testABackwardClockIsReportedRatherThanAbsorbed
    private var sawBackwardClock: Bool

    public init() {
        self.outageStartedAtSeconds = nil
        self.completedAttempts = 0
        self.accumulatedElapsed = 0
        self.lastObservedAtSeconds = nil
        self.outageEpoch = 0
        self.recoverySerial = 0
        self.lastIssuedTicket = 0
        self.lastConsumedTicket = 0
        self.attemptInFlight = false
        self.consumedEndSerial = nil
        self.sawBackwardClock = false
    }

    /// Whether an outage is currently being timed.
    public var isTimingAnOutage: Bool { outageStartedAtSeconds != nil }

    /// Records that traffic has stopped.
    ///
    /// Idempotent by design: the first call wins. A second call would restart the clock, and a
    /// clock that restarts is not a budget — repeated path flaps would each reset it and the
    /// tunnel could blackhole indefinitely while every individual measurement looked short.
    /// pinned: ChainedOutageSupervisorTests.testAFlappingPathCannotRestartTheClock
    @discardableResult
    public mutating func beginOutage(atSeconds now: Int) -> ChainedOutageGeneration {
        // THREE things advance at different rates here, and conflating any two of them has
        // been a defect:
        //
        // The CLOCK is idempotent — the first call wins, because a clock that restarts is not
        // a budget and repeated path flaps would each reset it.
        //
        // The OUTAGE EPOCH advances only when an outage actually starts. Attempt tickets carry
        // it, so a flap during an outage must NOT advance it: doing so invalidated in-flight
        // tickets for an outage that had not changed, standing down attempts that were still
        // valid.
        //
        // The RECOVERY token advances on every notification, and only the most recent one can
        // end the outage. Sharing it was a hole of the same shape as the one `endOutage(in:)`
        // closed: two traffic-stopped notifications during one outage received the same token,
        // so the FIRST one's delayed recovery cleared a clock the second was still reporting
        // against, and the budget started over on the next notification — the refund the
        // monotonic floor exists to prevent, reached by another route.
        recoverySerial &+= 1
        guard outageStartedAtSeconds == nil else { return ChainedOutageGeneration(recoverySerial) }
        outageStartedAtSeconds = now
        completedAttempts = 0
        accumulatedElapsed = 0
        lastObservedAtSeconds = now
        sawBackwardClock = false
        attemptInFlight = false
        consumedEndSerial = nil
        outageEpoch &+= 1
        return ChainedOutageGeneration(recoverySerial)
    }

    /// Records that traffic is flowing again, ending the outage this token names.
    ///
    /// The token is required for the same reason the authorization needs one, and its absence
    /// was the more dangerous of the two omissions: recovery is also delivered by callback, so
    /// outage A's late "traffic resumed" could clear outage B's clock. The budget then read as
    /// "no outage in progress" and `action` returned `.carryOn` forever — an UNBOUNDED
    /// blackhole assembled entirely out of correct-looking calls, in the one type whose whole
    /// purpose is to bound it.
    ///
    /// A stale token is ignored rather than reported. There is nothing for the caller to do
    /// about it: the outage it refers to is already over.
    /// pinned: ChainedOutageSupervisorTests.testAStaleRecoveryCannotDisarmALaterOutage
    public mutating func endOutage(in generation: ChainedOutageGeneration) {
        guard generation.value == recoverySerial else { return }
        outageStartedAtSeconds = nil
        completedAttempts = 0
        accumulatedElapsed = 0
        lastObservedAtSeconds = nil
        attemptInFlight = false
    }

    /// Seconds spent in the current outage, saturating and never negative.
    ///
    /// A clock that goes backwards is a real input, not a hypothetical: the caller's time
    /// source can jump. Treating a backwards jump as negative elapsed time would hand the
    /// budget arithmetic a value it normalizes away, silently extending the outage.
    public func elapsedSeconds(atSeconds now: Int) -> Int {
        guard outageStartedAtSeconds != nil else { return 0 }
        guard let last = lastObservedAtSeconds else { return accumulatedElapsed }
        // Only forward movement since the last observation counts. A backward reading adds
        // nothing and takes nothing away — the time already accumulated stays accumulated.
        let (delta, overflowed) = now.subtractingReportingOverflow(last)
        if overflowed { return Int.max }
        let (total, totalOverflowed) = accumulatedElapsed.addingReportingOverflow(max(0, delta))
        return totalOverflowed ? Int.max : total
    }

    /// Records the clock reading, banking any forward movement since the last one.
    ///
    /// Separate from `elapsedSeconds` so that reading the clock stays non-mutating; the caller
    /// observes on its own cadence and this is what moves the baseline.
    public mutating func observe(atSeconds now: Int) {
        guard outageStartedAtSeconds != nil else { return }
        if let last = lastObservedAtSeconds, now < last { sawBackwardClock = true }
        accumulatedElapsed = elapsedSeconds(atSeconds: now)
        lastObservedAtSeconds = now
    }

    /// Whether the caller's clock has been observed moving backwards this outage.
    ///
    /// Exposed so the provider can log the fault. The budget cannot be enforced on a time
    /// source that moves both ways, so every decision surrenders once this is true.
    public var clockIsUnusable: Bool { sawBackwardClock }

    /// The deadline to arm for an attempt STARTING NOW.
    ///
    /// Not the value carried by the `.attempt` action. That one was computed when the decision
    /// was made, and the delay has been spent since — `ChainedReconnectPolicy` says so in its
    /// own documentation and I forwarded it verbatim anyway. A retry decided at elapsed 0 with
    /// a one-second delay and a fourteen-second deadline, actually started at elapsed 3,
    /// authorizes fourteen more seconds and reaches elapsed 17 against a fifteen-second budget.
    ///
    /// Callers arm THIS, at the moment the attempt begins.
    ///
    /// There is deliberately no way to ask for the deadline on its own. A separate accessor
    /// existed, documented as "only meaningful once an attempt has been authorized" — a
    /// contract in prose, which is the shape of every other defect in this feature. The
    /// deadline now leaves only through the authorization that validated it.
    /// pinned: ChainedOutageSupervisorTests.testTheAuthorizedDeadlineNeverOutlivesTheBudgetHoweverLateItIsArmed
    public mutating func authorizeAttemptStartingNow(
        atSeconds now: Int,
        with ticket: ChainedAttemptTicket
    ) -> ChainedAttemptAuthorization {
        // A scheduled start has to wait out its delay somewhere, and the session it was
        // waiting on can succeed meanwhile. Without this guard `elapsedSeconds` returns 0 for
        // a supervisor timing nothing, which reads as a FULL budget, so a late callback
        // authorizes attempt 1 of an outage that is not happening and starts a session on top
        // of flowing traffic.
        guard outageStartedAtSeconds != nil else { return .standDown(.noOutageInProgress) }
        // And "some outage is active" is not enough. If outage A schedules an attempt,
        // recovers, and outage B begins before A's callback runs, the guard above passes and
        // A's callback spends B's fresh budget. No clock reading distinguishes the two; B's
        // elapsed time is small and legitimate.
        guard ticket.generation == outageEpoch else {
            return .standDown(.supersededByALaterOutage)
        }
        // Only the ticket most recently ISSUED may be authorized, and only once.
        //
        // UNREACHABLE as written, and kept deliberately. Consuming each session end once means
        // a new ticket can only be minted after the pending one has been authorized, so two
        // tickets can never be pending simultaneously — verified by probing the public API.
        // The rule was added when they could, it costs a comparison, and it fails closed if a
        // future path mints without consuming. It has no test, because no test can construct
        // the state, and that is stated rather than implied by a passing suite.
        //
        // `serial > lastConsumedTicket` was not enough, and the gap is subtle: a duplicated or
        // re-entrant session-end callback can call `action` twice before either scheduled
        // start runs, producing two PENDING tickets. Authorizing the older then the newer
        // satisfies a `>` check both times, so both start sessions — the unbounded replay the
        // ticket exists to prevent, reached by holding two tickets instead of reusing one.
        //
        // Issuing supersedes: a newer ticket invalidates every older pending one regardless of
        // the order they are authorized in, so at most one attempt can be outstanding.
        guard ticket.serial == lastIssuedTicket, ticket.serial > lastConsumedTicket else {
            return .standDown(.attemptAlreadyStarted)
        }
        // And nothing may start while an attempt is already running. The supersede rule above
        // covers two tickets pending before either is authorized; it does nothing once one has
        // started, so a duplicated session-end callback arriving mid-attempt got a fresh ticket
        // that passed both checks. `recordAttempt()` is what retires the running one.
        guard !attemptInFlight else { return .standDown(.attemptAlreadyStarted) }
        // AFTER observing this call's reading, not before. Checking first saw the flag as it
        // stood a moment ago, then `observe` set it, then execution carried on and returned an
        // authorization whose deadline was computed from the very reading that proved the
        // clock bad. A caller on a wall clock could start an attempt whose watchdog was not
        // bounded at all.
        //
        // A time source that moves both ways cannot bound anything. Refused rather than
        // absorbed, because absorbing it makes the 15-second guarantee a function of how often
        // the caller happens to look at its clock.
        observe(atSeconds: now)
        guard !sawBackwardClock else { return .refused(.clockUnusable) }
        let remaining = ChainedReconnectPolicy.remainingBlackholeSeconds(
            elapsedSeconds: elapsedSeconds(atSeconds: now))
        // Re-AUTHORIZED, not just re-measured. Scheduling can consume more time than the delay
        // asked for, so an attempt that was worth starting when it was decided may no longer
        // be — and returning a sub-floor deadline would authorize a window that ends before
        // the engine's first retransmit, which is the case `minimumUsefulAttemptSeconds`
        // exists to refuse.
        guard remaining >= ChainedReconnectPolicy.minimumUsefulAttemptSeconds else {
            return .refused(.budgetExhausted)
        }
        // An ABSOLUTE instant on the caller's clock. `now + remaining` is fixed at this
        // reading, so latency between here and the caller's arming code cannot extend it —
        // returning `remaining` as a duration let exactly that happen, one second at a time.
        //
        // An overflow is REFUSED, not saturated. Saturating returned `.authorized` with a
        // deadline of `Int.max`: a watchdog instant that never arrives, which is an unbounded
        // blackhole wearing the shape of a successful authorization. The comment here used to
        // claim the budget check refused it first; it does not, and a probe confirmed the
        // authorization was issued.
        let (deadline, overflowed) = now.addingReportingOverflow(remaining)
        guard !overflowed else { return .refused(.clockUnusable) }
        lastConsumedTicket = ticket.serial
        attemptInFlight = true
        return .authorized(
            attempt: completedAttempts + 1,
            deadlineAtSeconds: deadline,
            receipt: ChainedAttemptReceipt(generation: outageEpoch, serial: ticket.serial))
    }

    /// Decides what to do at this instant.
    ///
    /// - Parameters:
    ///   - now: the caller's monotonic clock, in seconds.
    ///   - endedBy: the cause AND the receipt of the attempt that ended, when this call
    ///     follows a session ending. `nil` means the watchdog fired while a session was still
    ///     notionally alive — the 90-second case — and the budget is being enforced from
    ///     outside the engine, which is the point.
    ///
    ///     The receipt is required because a session end is delivered by callback like
    ///     everything else here, and a delayed one from a previous outage was classified
    ///     against the CURRENT one: it could surrender a healthy outage outright, or mint a
    ///     current-epoch ticket that superseded the legitimate pending retry. Calling
    ///     `recordAttempt` first did not help, because it returns nothing to say the receipt
    ///     was stale.
    /// pinned: ChainedOutageSupervisorTests.testAReceiptForAnAttemptThatIsNotTheLiveOneIsRefused
    public mutating func action(
        atSeconds now: Int,
        endedBy ending: (cause: ChainedSessionEndCause, receipt: ChainedAttemptReceipt?)?
    ) -> ChainedOutageAction {
        guard outageStartedAtSeconds != nil else { return .carryOn }
        observe(atSeconds: now)
        guard !sawBackwardClock else { return .surrender(.clockUnusable) }
        let elapsed = elapsedSeconds(atSeconds: now)

        // A session end whose receipt does not name the attempt this outage is running is not
        // this outage's news. Treated as the watchdog path — the budget is still enforced,
        // nothing is classified from a stale cause, and no ticket is minted from it.
        //
        // Which session's end is this?
        //
        // The session running when an outage BEGINS was started before it, so its end carries
        // a receipt from the PREVIOUS outage — the caller holds it, because it is holding that
        // session. Accepting the previous epoch's receipt is therefore not a loosening: it
        // identifies that session exactly, and it is what starts this outage's retry ladder.
        //
        // A receipt-less end is accepted only when nothing has EVER been authorized, which is
        // once in a supervisor's lifetime rather than once per outage. Comparing against a
        // ticket watermark instead was wrong: `lastConsumedTicket` is monotonic across
        // outages, so for every outage after the first the watermark carries the previous
        // one's value, and unlimited stale receipt-less ends satisfied it.
        // Keyed by the attempt the end names — 0 for the receipt-less inherited session, which
        // is why the sentinel and `lastConsumedTicket`'s initial value agree.
        let endKey = ending?.receipt?.serial ?? 0
        let cause: ChainedSessionEndCause? = {
            guard let ending else { return nil }
            // An end is news exactly once. Without this the same callback delivered twice
            // minted a ticket each time, and each newer ticket superseded the retry the
            // previous one had scheduled.
            guard consumedEndSerial != endKey else { return nil }
            guard let receipt = ending.receipt else {
                return lastConsumedTicket == 0 ? ending.cause : nil
            }
            // The SERIAL is the whole check. It names the last attempt this supervisor
            // authorized, and serials are monotonic and never reused — so a receipt matching
            // it IS the session currently running, whichever outage started it.
            //
            // An epoch restriction was wrong. I first required the CURRENT epoch, which
            // rejected the session an outage inherits; I then allowed exactly one epoch back,
            // which rejects a session that survives two. A session is not rebuilt by a
            // stop/recovery cycle, so it can outlive several outages and its receipt can be
            // arbitrarily old while still being the live one. Rejecting it means no retry is
            // scheduled and the supervisor waits out the budget before falling back.
            return receipt.serial == lastConsumedTicket ? ending.cause : nil
        }()
        // Only an ACCEPTED end is recorded as consumed.
        //
        // I removed this condition in the previous commit because mutation testing showed it
        // failed nothing, and that was the wrong inference: "no test covers it" is not "it does
        // nothing". A rejected stale end still overwrote the record, so a duplicate delivery of
        // the CURRENT end then passed the once-only guard and minted another ticket —
        // reintroducing exactly the supersession this state exists to prevent, via a sequence
        // my tests did not walk.
        if cause != nil { consumedEndSerial = endKey }

        guard let cause else {
            // No session end, so the reconnect policy has nothing to classify. This is the
            // watchdog path: the engine is still retransmitting and will not report anything
            // for up to REKEY_ATTEMPT_TIME. If the budget is gone, the outage is over whatever
            // the engine thinks.
            //
            // Checked against the FULL budget rather than the useful-attempt floor: there is no
            // new attempt being authorized here, only a decision about whether to keep waiting
            // on the one already running.
            return ChainedReconnectPolicy.remainingBlackholeSeconds(elapsedSeconds: elapsed) > 0
                ? .carryOn
                : .surrender(.budgetExhausted)
        }

        switch ChainedReconnectPolicy.decision(
            completedAttempts: completedAttempts, elapsedSeconds: elapsed, cause: cause)
        {
        case .retry(let afterSeconds, let attempt, _):
            // The policy's deadline is discarded here on purpose: it is valid only if the
            // attempt starts on time, and the caller asks for the real one when it starts.
            lastIssuedTicket &+= 1
            return .attempt(
                afterSeconds: afterSeconds, attempt: attempt,
                ticket: ChainedAttemptTicket(generation: outageEpoch, serial: lastIssuedTicket))
        case .fallBackToDNSOnly(let reason):
            return .surrender(reason)
        }
    }

    /// Records that an attempt has been made, so the next decision backs off.
    ///
    /// Saturating: `completedAttempts` is bounded input to the reconnect policy, which already
    /// treats `Int.max` as in scope. In an extension a trap is a tunnel abort.
    public mutating func recordAttempt(_ receipt: ChainedAttemptReceipt) {
        // No epoch check here, deliberately: `beginOutage` clears `attemptInFlight`, so a
        // receipt from a previous outage fails the guard below before its epoch could matter.
        // One was written and mutation testing showed deleting it failed nothing.
        // Retires THAT attempt, not whatever is running. A duplicated session-end callback
        // completing an older attempt used to clear the in-flight state of a newer one, which
        // then let a third start concurrently with it — the same replay this type defends
        // against on the authorization side, arriving through the completion side instead.
        guard receipt.serial == lastConsumedTicket, attemptInFlight else { return }
        attemptInFlight = false
        guard completedAttempts != Int.max else { return }
        completedAttempts += 1
    }
}

extension ChainedAttemptAuthorization {
    /// Whether chaining is abandoned for the rest of the lifecycle.
    ///
    /// ``standDown`` is not an abandonment: nothing is wrong, so nothing is given up.
    public var surrendersChaining: Bool {
        switch self {
        case .refused:
            return true
        case .authorized, .standDown:
            return false
        }
    }

    /// Stable identifier for device logs. Never user copy.
    public var logValue: String {
        switch self {
        case .authorized(let attempt, let deadline, _):
            return "attempt-\(attempt)-authorized-until-\(deadline)"
        case .standDown(let reason):
            return "attempt-stand-down-\(reason.rawValue)"
        case .refused(let reason):
            return "attempt-refused-\(reason.rawValue)"
        }
    }
}

extension ChainedOutageAction {
    /// Whether chaining is abandoned for the rest of the lifecycle.
    public var surrendersChaining: Bool {
        switch self {
        case .surrender:
            return true
        case .carryOn, .attempt:
            return false
        }
    }

    /// Stable identifier for device logs. Never user copy.
    public var logValue: String {
        switch self {
        case .carryOn:
            return "outage-carry-on"
        case .attempt(let after, let attempt, _):
            return "outage-attempt-\(attempt)-in-\(after)s"
        case .surrender(let reason):
            return "outage-surrender-\(reason.rawValue)"
        }
    }
}
