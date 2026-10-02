import Foundation
import LavaSecKit

/// What to do after the chained session ends.
public enum ChainedReconnectDecision: Equatable, Sendable {
    /// Rebuild the session after this delay. `attempt` is 1-based, for logging.
    ///
    /// `attemptDeadlineSeconds` is an UPPER BOUND on how long the rebuilt session may run,
    /// valid only if the attempt starts on time. It is not advisory, and it is not on its
    /// own sufficient — see ``ChainedReconnectPolicy/remainingBlackholeSeconds(elapsedSeconds:)``.
    /// A caller that waits `afterSeconds` and then arms this value verbatim has already
    /// overrun the budget by however long the wait actually took; recompute from elapsed
    /// time at the moment the attempt starts. The engine does not return control while a
    /// handshake is in flight — boringtun retransmits for `REKEY_ATTEMPT_TIME`, 90 seconds
    /// (`ThirdParty/wireguard-core/boringtun/src/noise/timers.rs`), before it produces
    /// `connectionExpired` — so a caller that simply starts the session and waits for the
    /// engine to give up has left the outage budget unenforced no matter what this policy
    /// returns. The deadline has to be armed as a timer by the caller.
    /// pinned: ChainedReconnectPolicyTests.testARetryNeverAuthorizesMoreThanTheRemainingBudget
    case retry(afterSeconds: Int, attempt: Int, attemptDeadlineSeconds: Int)
    /// Stop trying and restart the tunnel into DNS-only.
    case fallBackToDNSOnly(reason: ChainedReconnectPolicy.Surrender)
}

/// A cause that actually ended the session — the only thing ``ChainedReconnectPolicy``
/// accepts.
///
/// ## Why this type exists rather than a bare engine error
///
/// `decision` used to take a ``WireGuardEngineError``, so nothing stopped a caller handing it
/// a PER-PACKET verdict. Those fell through to the retry path, which meant `.underLoad`,
/// `.protocolViolation`, `.noCurrentSession` and `.oversizedDatagram` — all four classified by
/// ``ChainedDataPathPolicy`` as `dropPacket` with `warrantsAnotherAttempt == false` — produced
/// a `.retry` here. Two public entry points gave opposite answers about the same value.
///
/// The cross-policy agreement test could not see it: it skipped every cause that does not end
/// the session, which is exactly the set that disagreed. So the contradiction was reachable
/// through the public API and invisible to the test guarding that API.
///
/// Comparing all eleven causes instead would have forced the reconnect policy to surrender on
/// per-packet conditions — permanently abandoning chained mode over one hostile datagram, the
/// LAV-80 failure this stack is built to avoid. Making the state unrepresentable is the
/// answer that does not trade one contradiction for a worse behaviour: there is no per-packet
/// value to construct this from, so the disagreement cannot be expressed.
///
/// "Unrepresentable" has to mean it, though. The first version of this type read only the
/// outer case of the action, which left `.reconnect(reason: .underLoad)` — a value any caller
/// can write, because the action is public — as a working route to the branch it was closing.
/// See ``init(_:)`` for what replaced that.
///
/// ``ChainedDataPathPolicy`` is therefore the sole classifier, and this is the only door from
/// it to the reconnect policy.
/// pinned: ChainedReconnectPolicyTests.testPerPacketVerdictsCannotReachTheReconnectPolicy
public struct ChainedSessionEndCause: Equatable, Sendable {
    /// Where a cause came from, which is what says whether ``error`` is the whole story.
    ///
    /// It is not, for one origin, and that was a defect: a session that was never CONSTRUCTED
    /// reports `sessionCreationFailed` whatever went wrong, so the engine error carries none of
    /// the factory's diagnosis. Every build failure therefore read as the deterministic fault
    /// that case names, and one momentary gap between interfaces during a handoff ended chained
    /// mode for the rest of the tunnel lifecycle.
    /// pinned: ChainedReconnectPolicyTests.testABuildFailuresOriginDecidesItRatherThanItsEngineError
    public enum Origin: Equatable, Sendable {
        /// The engine ended a session that had been constructed, and ``error`` is its verdict.
        /// ``ChainedReconnectPolicy`` triages it case by case, in agreement with
        /// ``ChainedDataPathPolicy``.
        case engineVerdict
        /// The session was never constructed, and the fault was a property of the instant — a
        /// reading of the system that the next attempt takes again. Spends a ladder rung.
        case transientBuildFailure
        /// The session was never constructed, and a rebuild reaches the same refusal. Surrenders.
        case permanentBuildFailure
    }

    /// The engine error that ended the session. Read-only: the guard is the initializer.
    ///
    /// NOT sufficient on its own to classify a cause — see ``Origin``.
    public let error: WireGuardEngineError
    /// What produced this cause, and for a build failure the factory's own diagnosis of whether
    /// another attempt could do better.
    public let origin: Origin

    private init(unchecked error: WireGuardEngineError, origin: Origin) {
        self.error = error
        self.origin = origin
    }

    /// The cause carried by a session-ending action, or `nil` for a per-packet verdict.
    ///
    /// `nil` is not a failure the caller reports — a drain loop asks this of every action and
    /// escalates only when it gets a value.
    ///
    /// ## Why the outer case is not enough
    ///
    /// ``ChainedDataPathAction`` is public and its cases carry an arbitrary payload, so
    /// `.reconnect(reason: .underLoad)` and `.callerBug(reason: .protocolViolation)` are
    /// constructible by anyone. Reading only the outer case accepted both and handed the
    /// reconnect policy the very per-packet errors this type exists to keep away from it —
    /// the narrowing looked total while leaving a forged route wide open, and tests that
    /// only feed it classifier output could not see it.
    ///
    /// So the pairing is verified, not assumed: an action is admissible only if it is what
    /// ``ChainedDataPathPolicy`` itself produces for that error. Anything else is a forgery,
    /// including a well-intentioned one — `.callerBug(reason: .connectionExpired)` is
    /// rejected too, because a caller inventing a classification is the same defect as an
    /// attacker doing it.
    /// pinned: ChainedReconnectPolicyTests.testAForgedSessionEndingActionIsRejected
    public init?(_ action: ChainedDataPathAction) {
        let reason: WireGuardEngineError
        switch action {
        case .reconnect(let carried), .callerBug(let carried):
            reason = carried
        case .sendToPeer, .deliverIPv4, .dropIPv6, .idle, .dropPacket:
            return nil
        }
        guard ChainedDataPathPolicy.action(for: .failure(reason)) == action else { return nil }
        self.error = reason
        self.origin = .engineVerdict
    }

    /// A session that never started, for a reason another attempt cannot clear.
    ///
    /// `WireGuardSession.init` throws before any data-path action exists, so this origin
    /// cannot arrive through ``ChainedDataPathAction`` at all.
    public static let sessionCreationFailed = ChainedSessionEndCause(
        unchecked: .sessionCreationFailed, origin: .permanentBuildFailure)

    /// The end of an attempt whose session was never constructed, carrying the factory's
    /// diagnosis of whether the next one could do better.
    ///
    /// THE ONLY DOOR from a thrown build error to this type, and the reason it exists is that the
    /// driver used to have no door at all: it discarded the error and reported
    /// ``sessionCreationFailed``, which ``ChainedReconnectPolicy`` answers with
    /// `.fallBackToDNSOnly(.engineUnusable)`. So a `noEligibleInterface` — documented as transient
    /// in the same tree, thrown when a Wi-Fi/cellular handoff briefly leaves the factory with
    /// nothing to bind to — permanently disabled chained mode instead of costing one rung.
    ///
    /// An error this module cannot triage is PERMANENT, deliberately. Only
    /// ``ChainedSessionBuildFailure`` carries a transience claim
    /// (``ChainedSessionBuildFailure/warrantsAnotherAttempt``); anything else — a secret store's
    /// own error, most of all — is a fault nobody here has classified, and handing an unclassified
    /// fault the retry ladder spends the user's whole blackhole budget on a guess. Surrendering is
    /// the outcome that keeps working internet with DNS-only filtering, which is why it is the
    /// answer when we do not know.
    /// pinned: ChainedOutageDriverTests.testASessionThatFailsToBuildSurrendersInsteadOfSpendingARung
    public static func buildFailure(_ error: Error) -> ChainedSessionEndCause {
        guard let diagnosed = error as? ChainedSessionBuildFailure,
              diagnosed.warrantsAnotherAttempt
        else { return .sessionCreationFailed }
        return ChainedSessionEndCause(
            unchecked: .sessionCreationFailed, origin: .transientBuildFailure)
    }
}

/// How long the tunnel may keep claiming traffic it cannot carry.
///
/// Plan: lavasec-infra `plans/2026-07-22-vpn-upstream-chaining-implementation-plan.md`
/// (D5, fail-safe restart to DNS-only). Consumes ``ChainedDataPathAction/reconnect``:
/// that type decides *whether* the session is over, this one decides what happens next.
///
/// ## This is an outage budget, not a retry count
///
/// The framing matters more than the numbers. Chained mode claims `0.0.0.0/0` and `::/0`,
/// so while the session is down the user has no internet at all — packets enter the tunnel
/// and go nowhere. "Retry five times with exponential backoff" sounds prudent and quietly
/// spends a minute of the user's connectivity to find out something WireGuard usually knows
/// in seconds.
///
/// So the policy is expressed as the question a user would ask: how long may this go on?
/// ``maximumBlackholeSeconds`` is that answer, and the retry schedule is derived from it
/// rather than the other way round. Falling back is not a failure state — DNS-only still
/// filters, still protects, and still has working internet. It is strictly better than
/// continuing to hold traffic hostage to a handshake that is not completing.
///
/// ## Some causes are not worth one retry
///
/// A DETERMINISTIC fault cannot be repaired by trying again: a status code this wrapper does
/// not recognize means the Swift declarations and the engine binary disagree, and a construction
/// refused for a reason that does not depend on the moment refuses identically next time. A fresh
/// session runs the same code to the same answer, so retrying would burn the whole budget on an
/// operation that cannot succeed. `unrecognized` surrenders immediately, and so does a build
/// failure the factory diagnosed as permanent.
///
/// NOT EVERY refused construction is one, and this paragraph used to say otherwise. It read "a
/// refused construction refuses identically next time" unqualified, and the driver collapsed every
/// thrown build error to `sessionCreationFailed` to match — so a build refused because a handoff
/// had left no eligible interface FOR AN INSTANT, which the factory documents as transient in the
/// same tree, ended chained mode for the tunnel's whole lifecycle. Two comments contradicted each
/// other and the transient one lost. ``ChainedSessionBuildFailure/warrantsAnotherAttempt`` is now
/// the factory's own answer to that question, ``ChainedSessionEndCause/Origin`` carries it here,
/// and a transient build failure spends a rung exactly like a wire condition — no refund, no
/// extension, the same budget arithmetic as any other failed attempt.
///
/// A poisoned lock is NOT in that group, though it reads like it. `engineInternal` is fixed
/// by rebuilding, because a fresh session gets a fresh lock — so it earns the retry budget
/// like a wire condition. This paragraph used to lump the two together and describe the
/// surrender that no longer happens.
///
/// Our own contract violations — `invalidArgument`, `destinationBufferTooSmall`,
/// `packetTooLarge` — surrender too, under `callerContractViolation` rather than
/// `engineUnusable`, because rebuilding retains the malformed argument or undersized buffer
/// and the distinction tells a field log which code to look at.
///
/// Every one of these classifications must match `ChainedDataPathPolicy`'s
/// `warrantsAnotherAttempt`; `ChainedReconnectPolicyTests.testTheTwoPoliciesAgreeOnEveryEngineError`
/// fails the build if they drift apart. That test can only prove it for causes this policy is
/// reachable with, which is why the parameter is ``ChainedSessionEndCause`` and not a bare
/// engine error — the causes the two types genuinely disagreed about are the ones that no
/// longer type-check. The agreement is over ENGINE VERDICTS: a build failure never reached the
/// data-path classifier, so its counterpart is
/// ``ChainedSessionBuildFailure/warrantsAnotherAttempt`` instead, and the same test asserts that
/// pairing too rather than leaving the new origin outside every invariant.
public enum ChainedReconnectPolicy {
    /// Shared with app/provider startup reconciliation; the engine does not own recovery meaning.
    public typealias Surrender = ChainedSurrenderReason

    /// The longest the tunnel may hold traffic while unable to forward it.
    ///
    /// Fifteen seconds, not sixty. A WireGuard handshake that is going to complete normally
    /// completes in about one round trip, and the engine already retries internally on its
    /// own ~5 s cadence — so a session still down after three delays is not usually one
    /// delay away from working. What the extra time would buy is a longer stretch of a user
    /// staring at a dead connection while the VPN reports itself connected.
    ///
    /// The engine's internal cadence is why this number cannot be enforced from session
    /// boundaries alone. Those ~5 s retransmits continue for `REKEY_ATTEMPT_TIME` — 90
    /// seconds — before boringtun reports `connectionExpired`, so between two consultations
    /// of this policy the user can lose six times the whole budget. That is what
    /// ``ChainedReconnectDecision/retry(afterSeconds:attempt:attemptDeadlineSeconds:)``
    /// carries a deadline for.
    public static let maximumBlackholeSeconds = 15

    /// The least remaining budget worth starting a session with.
    ///
    /// Derived from the engine's retransmission cadence rather than picked, and the derivation
    /// has THREE terms, not one.
    ///
    /// 1. `REKEY_TIMEOUT` — **5 s**. boringtun sends the handshake initiation once and does not
    ///    retry before this. A window shorter than it buys exactly one initiation and zero
    ///    retransmits, so a single lost datagram — the ordinary reason a handshake fails — makes
    ///    the attempt unable to recover while it spends the rest of the outage budget.
    /// 2. **Clock flooring — up to 1 s.** `ChainedMonotonicClock.nowSeconds()` is an integer
    ///    division, so an attempt beginning at uptime 10.99 s is stamped 10 and its watchdog is
    ///    scheduled at absolute 16.0 s. The authorization says 6 seconds; the attempt gets 5.01.
    /// 3. **Pump quantisation — up to ~275 ms.** `update_timers` is the only thing that can emit
    ///    the retransmit, and it runs on the driver's pump: `outageTickInterval` 250 ms plus
    ///    `outageTickLeeway` 25 ms. The retransmit therefore lands up to 275 ms AFTER the 5 s
    ///    threshold, not at it.
    ///
    /// Terms 2 and 3 compose in the worst case — 5 + 1 + 0.275 = 6.275 — so 6 was not enough:
    /// an attempt starting late in a clock second could be torn down at 5.01 s of real time with
    /// the retransmit still 0.26 s away, which is the precise failure the constant exists to
    /// prevent. **7.** Caught by Codex on PR #488 while correcting the comment below.
    /// pinned: ChainedReconnectPolicyTests.testTheAttemptFloorClearsFlooringAndPumpQuantisation
    ///
    /// The comment this replaces read "5 seconds plus up to 333 ms of jitter". **There is no
    /// jitter.** `boringtun/src/noise/timers.rs:228` is a bare `if time_init_sent.elapsed() >=
    /// REKEY_TIMEOUT`; the 0–333 ms the WireGuard paper specifies survives in the lines directly
    /// ABOVE it as prose describing what the code does not do. wireguard-go implements it,
    /// boringtun does not, and we run boringtun. That the wrong term happened to be the same
    /// order of magnitude as the two real ones is why the number looked defensible for so long.
    ///
    /// This was 1 second before that, on the reasoning that any headroom beats none. That was
    /// wrong in the way the constant's own rationale warns about: it authorized retries with
    /// "some chance of succeeding" only if no packet was lost.
    public static let minimumUsefulAttemptSeconds = 7

    /// How much of the outage budget is left, given time already spent.
    ///
    /// THE WATCHDOG THIS FEEDS MUST BE ARMED BEFORE THE FIRST HANDSHAKE, not after the first
    /// failure. ``decision(completedAttempts:elapsedSeconds:cause:)`` is consulted only when
    /// a session ENDS, and the engine does not end one promptly: boringtun retransmits an
    /// in-flight handshake for `REKEY_ATTEMPT_TIME` — 90 seconds — before reporting
    /// `connectionExpired`. So on the very first loss of reachability the policy is not
    /// consulted at all for a minute and a half, and a per-attempt deadline attached to a
    /// REBUILT session never gets the chance to fire. The 15-second budget is only real if
    /// something outside this type is watching from the moment the outage starts.
    ///
    /// Call this at outage start to size that watchdog, and again immediately before each
    /// attempt begins — the value returned with a `.retry` was computed when the decision
    /// was made, and the delay before the attempt has been spent since.
    ///
    /// Saturates at zero rather than going negative, and never traps.
    /// pinned: ChainedReconnectPolicyTests.testTheBudgetIsEnforceableFromTheStartOfAnOutage
    public static func remainingBlackholeSeconds(elapsedSeconds: Int) -> Int {
        let spent = max(elapsedSeconds, 0)
        guard spent < maximumBlackholeSeconds else { return 0 }
        return maximumBlackholeSeconds - spent
    }

    /// Delay before the given 1-based attempt.
    ///
    /// Doubling from one second. The first retry is deliberately quick — the common cause
    /// is a network transition where the peer is reachable again almost immediately — and
    /// the growth keeps a genuinely unreachable peer from being hammered.
    public static func delaySeconds(forAttempt attempt: Int) -> Int {
        guard attempt >= 1 else { return 1 }
        return 1 << min(attempt - 1, 8)
    }

    /// Decides what happens after a session ends.
    ///
    /// This is consulted only at session BOUNDARIES, which is why it cannot enforce the
    /// budget by itself — see ``remainingBlackholeSeconds(elapsedSeconds:)``.
    ///
    /// - Parameters:
    ///   - completedAttempts: how many reconnects have already been made this lifecycle.
    ///   - elapsedSeconds: seconds since the OUTAGE began — the moment traffic stopped
    ///     flowing — not since the current session ended. Measuring from the session
    ///     boundary would restart the budget on every attempt and it would never expire.
    ///   - cause: what ended the session. Obtainable only from a session-ending
    ///     ``ChainedDataPathAction``, or from a build that failed
    ///     (``ChainedSessionEndCause/buildFailure(_:)``,
    ///     ``ChainedSessionEndCause/sessionCreationFailed``), so a per-packet verdict cannot be
    ///     routed here — see ``ChainedSessionEndCause``.
    public static func decision(
        completedAttempts: Int,
        elapsedSeconds: Int,
        cause: ChainedSessionEndCause
    ) -> ChainedReconnectDecision {
        switch cause.origin {
        case .permanentBuildFailure:
            // A construction the factory diagnosed as refusing identically next time: bad key
            // material, an unusable MTU, a store re-serving one read. Rebuilding runs the same
            // code to the same answer, so the budget would be spent proving it.
            return .fallBackToDNSOnly(reason: .engineUnusable)
        case .transientBuildFailure:
            // FALLS THROUGH TO THE BUDGET ARITHMETIC, which is the entire fix. A handoff that
            // left the factory with no interface to bind to for an instant costs one rung, like
            // any other attempt that failed — `elapsedSeconds` is the OUTAGE's and is untouched
            // here, so the failure neither refunds nor extends anything, and the ladder still
            // terminates at `maximumBlackholeSeconds`.
            break
        case .engineVerdict:
            switch cause.error {
            case .invalidArgument, .destinationBufferTooSmall, .packetTooLarge:
                // Contract violations, and ChainedDataPathPolicy already classifies all three as
                // `.callerBug` with `warrantsAnotherAttempt == false`. They fell through to the
                // retry path here, so a coordinator that centralized session-end handling in this
                // type would have spent the whole outage budget rebuilding a session around the
                // same malformed argument or undersized buffer. Rebuilding does not change either.
                return .fallBackToDNSOnly(reason: .callerContractViolation)
            case .unrecognized, .sessionCreationFailed:
                // Deterministic faults in the object, not the network. An unknown status code
                // means the wrapper and the engine binary disagree, and a construction refused on
                // fixed configuration refuses identically next time — a fresh session runs the
                // same code to the same answer, so spending the budget on it only lengthens the
                // outage. `sessionCreationFailed` reaching this branch is the engine's own
                // verdict on a session it was asked to build; a FAILED BUILD carries the
                // factory's diagnosis in `cause.origin` instead and is answered above.
                //
                // `engineInternal` used to sit here and does not belong: it is a POISONED LOCK,
                // and a fresh session gets a fresh lock. ChainedDataPathPolicy classifies it as
                // `.reconnect` — the one engine fault that earns another attempt — so surrendering
                // here contradicted the classifier and threw away a recoverable case.
                return .fallBackToDNSOnly(reason: .engineUnusable)
            case .connectionExpired, .engineInternal:
                // The two session-ending causes worth another attempt: a rekey that missed its
                // window, and a poisoned lock that a fresh session clears.
                break
            case .protocolViolation, .underLoad, .noCurrentSession, .oversizedDatagram:
                // NOT REACHABLE through `cause`. All four are per-packet verdicts —
                // `ChainedDataPathPolicy` maps them to `.dropPacket`, and `ChainedSessionEndCause`
                // refuses to be built from a drop — so no caller can select this branch. It is
                // written out rather than folded into the one above because these are exactly the
                // causes the two policies used to disagree about, and a future edit that made one
                // session-ending must land on a deliberate choice rather than inherit whichever
                // group it happened to be listed with.
                //
                // The choice, if that ever happens: retry. A per-packet condition is transient, so
                // surrendering chaining for the rest of the lifecycle over one would be the
                // LAV-80 outcome — a single hostile datagram permanently downgrading the user.
                // pinned: ChainedReconnectPolicyTests.testPerPacketVerdictsCannotReachTheReconnectPolicy
                break
            }
        }

        // Both of these saturate rather than trap. Swift's `+` and `-` trap on overflow, and
        // this is a PUBLIC entry point that already normalizes negative input — so it treated
        // hostile values as in scope on one side and crashed on the other. In a Network
        // Extension a trap is a tunnel abort, which drops the user to no protection at all
        // rather than to the DNS-only fallback this type exists to reach.
        //
        // Two separate expressions overflow, and fixing only the budget one leaves the other
        // live: `completedAttempts == Int.max` traps here, before the budget arithmetic is
        // ever reached.
        let attempt = max(completedAttempts, 0) == Int.max
            ? Int.max
            : max(completedAttempts, 0) + 1
        let delay = delaySeconds(forAttempt: attempt)

        // The budget is checked against the delay we are ABOUT to spend, not against time
        // already spent. Waiting past the deadline to discover we are past it would be the
        // same mistake in slower motion.
        //
        // It also has to reserve time for the session itself. The previous form only
        // required `elapsed + delay <= budget`, which authorized a retry with nothing left
        // to run in — and, worse, said nothing about how long that session could then last,
        // so the engine's own 90 s handshake retransmission ran unbounded underneath a
        // 15 s budget.
        let spent = max(elapsedSeconds, 0)
        // `spent + delay` overflows when elapsed is within `delay` of Int.max.
        let spentPlusDelay = spent.addingReportingOverflow(delay)
        let remainingAfterDelay = spentPlusDelay.overflow
            ? Int.min
            : maximumBlackholeSeconds - spentPlusDelay.partialValue
        guard remainingAfterDelay >= minimumUsefulAttemptSeconds else {
            return .fallBackToDNSOnly(reason: .budgetExhausted)
        }
        return .retry(
            afterSeconds: delay,
            attempt: attempt,
            attemptDeadlineSeconds: remainingAfterDelay
        )
    }
}

extension ChainedReconnectDecision {
    /// Whether this decision abandons chained mode for the rest of the lifecycle.
    public var surrendersChaining: Bool {
        switch self {
        case .fallBackToDNSOnly:
            return true
        case .retry:
            return false
        }
    }

    /// Stable identifier for device logs. Never user copy.
    public var logValue: String {
        switch self {
        case .retry(let seconds, let attempt, let deadline):
            // The deadline is in the log line because a field report of a long chained
            // outage has to be able to distinguish "we allowed that" from "the timer was
            // never armed".
            return "retry-\(attempt)-in-\(seconds)s-deadline-\(deadline)s"
        case .fallBackToDNSOnly(let reason):
            return "fall-back-dns-only-\(reason.rawValue)"
        }
    }
}
