import Foundation

/// What the chained T1 DNS fallback is actually doing, as a settings surface can state it.
///
/// ## Why this is a status and not a checkbox
///
/// The fallback has a failure mode with no local symptom: the user turns it on, picks a resolver,
/// and nothing happens — no error, no retry, every failing lookup keeps failing. Nothing in the
/// setting itself distinguishes that from working.
///
/// **BOTH FAILURE MODES BELOW ARE SUPERSEDED and are recorded as history.** They are properties
/// of a T1 resolver reached THROUGH the peer, and it no longer is: the rung egresses on the
/// physical interface, so the tunnel neither routes the resolver nor needs the peer to forward to
/// it (PR #590).
///
/// AN EARLIER VERSION OF THIS PARAGRAPH SAID THE VERDICTS BELOW STOP BEING PRODUCED. That was
/// true for exactly one commit. The physical rung now records its own attempts and answers
/// (`ResolverOrchestrator.TierOneRungEvidence`), so `notForwarded` and
/// `answeringWithoutResolving` are produced again — from the PHYSICAL path, about the user's
/// alternative resolver, with no peer involved (Codex, PR #590). Their copy is written for that
/// path now; a diagnosis naming the VPN's far end, or a remedy recommending an exit node, would
/// be advice about a machine the query never touches.
///
/// There were two such failures, and they needed different fixes on different machines.
///
/// The first is local and knowable in advance: a SPLIT tunnel may not route the chosen resolver
/// at all, so the query cannot even leave through the tunnel.
/// ``ChainedFallbackDisposition/notRoutedBySplitTunnel`` is the per-address state that says so.
/// The requirement is that the VPN ROUTE the resolver — a full tunnel always does, and a split
/// tunnel covering it does too (Codex, PR #575). Carrying the address in the data path was tried and reverted:
/// it made the REPLY acceptable without making the QUERY routable (Codex, PR #575).
///
/// The second is the half no device can fix by itself: **the peer may not forward it.** A
/// resolver only answers if the machine at the other end of the tunnel actually forwards to it
/// and NATs the reply back. A plain tailnet node with no exit node does not; an exit node or
/// subnet router does. Nothing here can determine that in advance and nothing here can change it
/// — so the only honest way to report it is to try and count what came back, which is why
/// ``notForwarded(attempts:)`` and ``readyUnused`` are told apart by OBSERVED attempts rather
/// than by configuration.
public enum ChainedFallbackStatus: Equatable, Sendable {
    /// Consecutive unanswered fallback attempts that overrule a cumulative success.
    ///
    /// Three, not one: a lost datagram is ordinary, and a panel that flipped to "broken" on the
    /// first timeout would be noisy exactly when it needs to be trusted. Three consecutive
    /// attempts vanishing is no longer a blip — the fallback's own retry path has already had its
    /// chances by then.
    public static let consecutiveUnansweredFailureThreshold = 3

    /// The current selection cannot be a rung AND no live session is still running one.
    /// Nothing to report.
    ///
    /// "Enabled" was a TOGGLE until the plan's S4 deleted it. There is no second setting now: the
    /// user's one resolver serves both modes.
    ///
    /// CURRENTLY UNPRODUCIBLE, because every selection is eligible — Device DNS included since
    /// PR #592, where refusing it was found to leave a chained user worse off than running their
    /// VPN's own client. Kept rather than deleted because the question it answers is real and a
    /// future selection type could answer no; `isEnabled` is still a predicate at the call site
    /// rather than a hardcoded true, for the same reason.
    case off
    /// The current selection cannot be a rung, but a chained session is still using the resolver
    /// it latched at start. Unproducible today, for the reason ``off`` gives.
    ///
    /// The latch is per-session BY DESIGN — the rung's resolver must not change under a session
    /// already running one — so moving the DNS page to Device DNS does not reach into a running
    /// session. Reporting `.off` there states the user's intent as though it were
    /// the tunnel's behaviour, which is the exact silent disagreement this panel exists to remove:
    /// failed lookups keep going to a resolver the user believes they just switched off.
    ///
    /// Distinct from ``awaitingRestart``, which is a DIFFERENT resolver pending rather than the
    /// absence of one. Same remedy, different sentence — "restart to switch to X" reads as
    /// nonsense when there is no X (Codex, PR #575).
    case pendingDisable
    /// Enabled, but no chained session has evaluated it yet — protection is off, or is running
    /// DNS-only. Deliberately distinct from ``readyUnused``: nothing has been checked, so
    /// claiming it is ready would be a guess.
    case awaitingSession
    /// NOTHING the user chose was admitted as T1, carrying WHY for each address rather than
    /// one blanket cause.
    ///
    /// The addresses can fail differently in the same session — one already present in the
    /// configuration's `DNS =` and deduped into T0, another refused by a usability gate — and
    /// four review rounds were spent discovering that any single summary claim is wrong for some
    /// arrangement of them (see ``ChainedFallbackDisposition``). So this states the facts per
    /// address and lets the copy enumerate.
    case noneUsable(outcomes: [ChainedFallbackAddressOutcome])
    /// Admitted by the tunnel, and no lookup has needed it yet. The primary resolver has not
    /// failed, which is the ordinary healthy case — NOT evidence that a failover would work.
    case readyUnused
    /// The session carries ALL traffic through the upstream, so there is no T1 rung.
    ///
    /// NOT A FAULT and not actionable: the fallback exists to reach a resolver the upstream's own
    /// cannot serve, over the physical interface — and a full tunnel has no physical-interface
    /// path to offer it. The honest thing to report is the shape, not a defect.
    ///
    /// Distinct from ``noneUsable``, which is about the ADDRESSES the user picked and always has
    /// a remedy ("pick a different resolver"). Here every address fares identically and the only
    /// thing that would change it is the user's own VPN profile — which this surface does not
    /// tell them to edit.
    /// pinned: ChainedFallbackStatusTests.testAFullTunnelSessionReportsNoTierOneRatherThanReady
    case unavailableInFullTunnel
    /// The user changed the fallback setting while a chained session was already running. The
    /// tunnel keeps the selection it latched at session start, so the counters below describe a
    /// DIFFERENT address than the one on screen — reporting them under the new name would credit
    /// one resolver with another's evidence, or condemn it for another's failure.
    case awaitingRestart
    /// Tried, and the resolver REPLIED, but it could not serve the name either — SERVFAIL,
    /// REFUSED, or a reply that never resolved. The resolver is reachable, so this is emphatically
    /// NOT the silence case; the fallback simply is not helping.
    ///
    /// NO PEER IS INVOLVED. This doc said "the peer forwarded", which was true while T1 rode
    /// the tunnel and is not now: the rung goes out on the physical interface, so what a reply
    /// proves is that the resolver is reachable on the NORMAL connection (PR #590).
    case answeringWithoutResolving(answers: Int)
    /// Admitted and actually tried, and nothing ever came back — no reply of any kind.
    ///
    /// ONCE THE EXIT-NODE CASE, and no longer. This doc said "the tunnel carried the query and the
    /// far end did not answer it", which described T1 riding the tunnel to a peer that had to
    /// forward it. The rung now leaves on the physical interface, so silence means the chosen
    /// resolver is not answering from this network — a fault with a remedy the user holds, rather
    /// than one belonging to a machine at the other end of their VPN (PR #590).
    case notForwarded(attempts: Int)
    /// Admitted, tried, and it served answers the primary could not.
    case working(rescues: Int)

    /// Derives the status from what the tunnel observed.
    ///
    /// - Parameters:
    ///   - isEnabled: whether the fallback may run at all
    ///     (`AppConfiguration.chainedTierOneResolverConfiguration != nil`), which now folds TWO
    ///     questions: the user's `chainedTierOneFallbackEnabled` toggle, and whether the current
    ///     selection could be a rung. They share one answer deliberately — see that property.
    ///   - hasEvaluated: whether a chained session has actually applied the selection. False
    ///     before the first chained start, and in DNS-only mode — the counters below are all
    ///     zero then, which is indistinguishable from "enabled and idle" without this flag.
    ///   - outcomes: what became of EACH chosen address. Replaces the pair of booleans this
    ///     used to take: a Bool cannot describe a list whose members differ, which is the defect
    ///     four review rounds kept re-finding in new arrangements.
    ///   - isChainedSessionLive: whether a chained session is running RIGHT NOW
    ///     (`TunnelHealthSnapshot.isChainedUpstreamActive`). Every field below survives teardown
    ///     by design — the snapshot keeps a stopped session's final values so a bug report can
    ///     read them — and the standing convention is that surfaces hide them while this is
    ///     false. Without it, a disabled fallback whose tunnel had since STOPPED kept reporting
    ///     `.pendingDisable` forever, telling the user their VPN was still retrying through a
    ///     resolver while protection was off entirely (Codex, PR #575).
    ///   - isLatchedSelectionCurrent: whether the address the live session latched is the one
    ///     currently selected. False means the counters describe a different resolver.
    ///   - attemptCount: times a chosen fallback address was actually queried.
    ///   - answerCount: times one REPLIED at all (SERVFAIL/REFUSED/truncated included).
    ///   - rescueCount: times one of them served an answer the client received.
    ///   - unansweredStreak: attempts since the last answer of any kind
    ///     (`TunnelHealthSnapshot.chainedFallbackUnansweredStreak`). One of the two terms here
    ///     that can FALL, which is what lets a present failure overrule a past success — every
    ///     COUNT is cumulative and can therefore only ever make the fallback look better.
    ///   - unhelpfulReplyStreak: consecutive REPLIES that did not serve the name
    ///     (`TunnelHealthSnapshot.chainedFallbackUnhelpfulReplyStreak`). The second falling term,
    ///     necessary because the first resets on a SERVFAIL/REFUSED reply — "replied" and "helped"
    ///     are different questions — and it doubles as the honest payload for
    ///     ``answeringWithoutResolving``, which a lifetime answer total cannot be.
    ///
    /// pinned: ChainedFallbackStatusTests.testAServedAnswerOutranksTheAttemptsItWasCountedIn
    public static func status(
        isEnabled: Bool,
        hasEvaluated: Bool,
        outcomes: [ChainedFallbackAddressOutcome],
        isChainedSessionLive: Bool = true,
        isLatchedSelectionCurrent: Bool = true,
        attemptCount: Int,
        answerCount: Int = 0,
        rescueCount: Int,
        unansweredStreak: Int = 0,
        unhelpfulReplyStreak: Int = 0
    ) -> ChainedFallbackStatus {
        // Moving to a selection with no rung does NOT stop a session already running the one it
        // latched, so `.off` is only honest when nothing is still using one. A live session whose
        // latch disagrees with the current selection is exactly the pending-disable case; with no
        // session (or an empty latch) the two agree and `.off` is true (Codex, PR #575).
        guard isEnabled else {
            // ADMITTED, not merely latched. A selection whose every address was refused or
            // deduped into T0 never became a T1 resolver, so there is nothing still
            // running to keep running — `.pendingDisable` there invents an active resolver and
            // tells the user their VPN is retrying through an address it never used
            // (Codex, PR #575).
            let wasActive = outcomes.contains { $0.disposition == .admitted }
            return isChainedSessionLive && hasEvaluated && wasActive && !isLatchedSelectionCurrent
                ? .pendingDisable : .off
        }
        // A STOPPED session's fields survive in the snapshot by design, so every verdict below
        // would otherwise be the last session's evidence reported as though it were live. The
        // honest answer while nothing is running is the one that says so.
        guard isChainedSessionLive, hasEvaluated else { return .awaitingSession }
        // BEFORE any verdict derived from the counters, because every one of them describes the
        // latched address rather than the selected one.
        guard isLatchedSelectionCurrent else { return .awaitingRestart }
        // ONE admitted address is enough for the counters to mean something — they aggregate the
        // whole effective set, and the states below describe that set's behaviour. Only when
        // NOTHING was admitted do the per-address reasons become the story.
        guard outcomes.contains(where: { $0.disposition == .admitted }) else {
            // BEFORE `.noneUsable`, because this is not a fault and `.noneUsable` is. Every
            // address carries the same disposition here by construction — the routing policy is
            // a property of the session, not of any address — so `allSatisfy` on a non-empty
            // list is exactly the condition. Reaching `.noneUsable` instead would tint the panel
            // as a problem and tell the user to pick a different resolver, which would not help
            // and is not true (Codex, PR #590).
            if !outcomes.isEmpty,
                outcomes.allSatisfy({ $0.disposition == .unavailableInFullTunnel }) {
                return .unavailableInFullTunnel
            }
            return .noneUsable(outcomes: outcomes)
        }
        // CURRENT failure outranks past success. Every counter below is cumulative for the
        // session, so `rescueCount > 0` alone latches `.working` for the session's whole life:
        // a fallback that served one lookup and then went dark — the exit node's forwarding
        // changing mid-session is exactly that — keeps reporting healthy while every subsequent
        // attempt vanishes (Codex, PR #575). The two streaks are the terms that can fall as well
        // as rise, so they are what can un-say a verdict; this arm reads the one that asks whether
        // anything is coming back at all.
        //
        // Thresholded rather than `> 0`, because a single timeout is ordinary: flipping a working
        // fallback to "broken" on one lost datagram would make the panel noisy exactly when it
        // needs to be trusted. Below the threshold the cumulative reading still wins.
        if unansweredStreak >= consecutiveUnansweredFailureThreshold {
            return .notForwarded(attempts: unansweredStreak)
        }
        // STILL REPLYING, STILL NOT HELPING — and the run of replies IS the number to report.
        // This was unreachable after any rescue: soft-failure replies kept resetting the only
        // recency signal while the cumulative rescue count held `working` in place forever
        // (Codex, PR #575).
        //
        // The payload is the STREAK, never `answerCount`. A lifetime total includes the rescues,
        // so one rescue then three soft failures reported four retries that "couldn't resolve the
        // name either" — a sentence with a rescue counted inside it (Codex, PR #575).
        if unhelpfulReplyStreak >= consecutiveUnansweredFailureThreshold {
            return .answeringWithoutResolving(answers: unhelpfulReplyStreak)
        }
        // Narrowest fact first: a rescue is a subset of an answer, which is a subset of an
        // attempt. Reading them the other way round would report a working fallback as broken.
        if rescueCount > 0 { return .working(rescues: rescueCount) }
        if answerCount > 0 { return .answeringWithoutResolving(answers: answerCount) }
        if attemptCount > 0 { return .notForwarded(attempts: attemptCount) }
        return .readyUnused
    }

    /// Whether this state is worth putting on screen at all.
    ///
    /// The panel used to render for every state but ``off``, so the ordinary healthy case sat
    /// there permanently saying "Ready — not needed yet" — a full-width card restating that
    /// nothing has happened. Four states have nothing a reader needs: ``off`` (the user turned it
    /// off and the toggle beside it already says so), ``readyUnused`` and ``working`` (both
    /// healthy), and ``awaitingSession`` (no chained session has run yet, which the connect state
    /// already shows).
    ///
    /// Everything else earns the space, INCLUDING the states that are not faults:
    /// ``unavailableInFullTunnel`` tells a user why a setting they switched on is doing nothing,
    /// and ``pendingDisable`` / ``awaitingRestart`` tell them a change needs a restart. Those are
    /// not `isActionable` — they are not the user's to fix — but silence about them is worse than
    /// a card, which is why this is a separate question from that one.
    /// pinned: ChainedFallbackStatusTests.testOnlyStatesWorthReadingAreSurfaced
    public var deservesSurfacing: Bool {
        switch self {
        case .off, .readyUnused, .working, .awaitingSession:
            return false
        case .pendingDisable, .awaitingRestart, .unavailableInFullTunnel, .notForwarded,
            .answeringWithoutResolving, .noneUsable:
            return true
        }
    }

    /// Whether this state is a fault the user can act on — the panel's tint, and the reason
    /// ``readyUnused`` is NOT one: a fallback that has never been needed is a healthy primary.
    public var isActionable: Bool {
        switch self {
        case .notForwarded, .answeringWithoutResolving, .noneUsable:
            return true
        // `pendingDisable` is NOT a fault — the user's next protection restart clears it, exactly
        // like `awaitingRestart`. Flagging it would put a warning on the screen of a user who just
        // did the correct thing.
        // `unavailableInFullTunnel` is NOT a fault: the user's VPN is carrying everything, which
        // is what they configured it to do. There is nothing here for them to act on.
        case .off, .pendingDisable, .awaitingSession, .awaitingRestart, .readyUnused, .working,
            .unavailableInFullTunnel:
            return false
        }
    }

    /// Short headline for the settings panel. Not localized here — the chained settings surface
    /// is QA-only (`#if DEBUG || LAVA_QA_TOOLS`), so these never reach a shipped build.
    public var title: String {
        switch self {
        case .off: return "Off"
        case .pendingDisable: return "Off after you restart"
        case .awaitingSession: return "Not checked yet"
        case .awaitingRestart: return "Restart protection to apply"
        case .answeringWithoutResolving: return "Answering, but not resolving"
        case .noneUsable(let outcomes):
            // Named for the SHAPE of the failure where every address failed the same way, and
            // generically where they did not — rather than picking one member's cause and
            // asserting it over the rest.
            if outcomes.allSatisfy({ $0.disposition == .alreadyPrimary }) {
                return "Same as your VPN's own resolver"
            }
            if outcomes.allSatisfy({ $0.disposition == .unusable }) {
                return "That address can't be used"
            }
            return "Not being used"
        case .readyUnused: return "Ready — not needed yet"
        case .unavailableInFullTunnel: return "Not used by this VPN"
        case .notForwarded: return "No answers coming back"
        case .working: return "Working"
        }
    }

    /// The explanation, including what to do about it where there is something to do.
    ///
    /// `resolver` is the address the user picked, so the remedy can name it exactly rather than
    /// describing it. The status type does not hold it: this enum is derived from counters the
    /// tunnel reports, while the address is the app's own setting, and threading it through the
    /// tunnel only to read it back would be two sources for one fact.
    public func detail(resolver: String?) -> String {
        let name = resolver ?? "this resolver"
        switch self {
        case .off:
            return "Failed lookups won't be retried anywhere else."
        case .pendingDisable:
            // Names the resolver STILL IN USE (the latched set), not the selection — which is
            // empty here, and would render as "this resolver" and say nothing.
            return
                "Your VPN is still retrying through \(name) until you restart protection."
        case .awaitingSession:
            return "Lava checks this when protection starts."
        case .awaitingRestart:
            return
                "Your VPN is still using the resolver it started with. Restart protection to "
                + "switch to \(name)."
        case .answeringWithoutResolving(let answers):
            // REWRITTEN FOR THE PHYSICAL RUNG (Codex, PR #590). Two claims here were about the
            // tunnelled path and are now false: "your VPN is carrying the query fine" — it is not
            // carrying it at all — and "too big to send this way", which named the tunnelled
            // loop's deliberate lack of a TCP rung. The physical rung HAS a TCP retry
            // (`resolveOverTCP` takes the same egress interface), so a truncated reply there is
            // retried rather than surrendered. BOTH SHAPES ARE STILL COVERED, because this
            // state still covers both: SERVFAIL/REFUSED is the resolver having no answer, and a
            // reply that never resolves after the TCP retry is the answer not arriving. Reporting
            // only the first would misdiagnose the second as the resolver's ignorance — the
            // distinction PR #575 established and which survives the path change intact.
            return
                "\(name) replied to \(answers) retr\(answers == 1 ? "y" : "ies") but couldn't "
                + "give a usable answer. It's reachable on your normal connection — either it "
                + "has no answer for that name, or the answer didn't come through."
        case .noneUsable(let outcomes):
            // ENUMERATED, because the addresses can have failed for different reasons and a
            // single sentence covering all of them is wrong for some arrangement — the defect
            // four rounds of review kept re-finding.
            let reasons = outcomes.compactMap(\.refusalReason)
            guard !reasons.isEmpty else {
                return "None of the resolvers you picked is being used. Pick a different one."
            }
            // ONE REMEDY, and it is a control inside this app. Lava adds the resolver to the
            // tunnel's routes itself when protection starts; the only reason it declines is that
            // this particular address would change the tunnel's routing shape, which is a
            // property of that address and not of the user's setup. Picking another one works.
            //
            // "Restart protection to apply it" was wrong and shipped for one commit: the decision
            // is deterministic, so every restart declines identically and the user restarts
            // forever (Codex, PR #584). Sending them to hand-edit their WireGuard `AllowedIPs`
            // was wronger still, and is what this whole PR exists to delete.
            return reasons.joined(separator: "; ") + ". Pick a different resolver."
        case .readyUnused:
            return
                "Ready. Your main resolver hasn't failed a lookup yet, so there's been nothing "
                + "to retry."
        case .unavailableInFullTunnel:
            // States the shape and stops. No remedy, because the only one is for the user to
            // re-shape their VPN profile, and sending them to hand-edit `AllowedIPs` to satisfy
            // an implementation detail is the instruction this whole surface exists to avoid.
            return
                "Your VPN carries all your traffic, so lookups already go through it. The "
                + "alternative resolver is only used when your VPN carries just some of it."
        case .notForwarded(let attempts):
            // NOT ABOUT THE PEER ANY MORE. This said the far end of the VPN wasn't forwarding and
            // recommended an exit node or subnet route — true while T1 rode the tunnel, and
            // advice about a machine the query no longer touches now that the rung goes out on
            // the normal connection (Codex, PR #590). What a silent rung actually means is that
            // the resolver did not answer over that connection.
            return
                "Lava retried \(attempts) lookup\(attempts == 1 ? "" : "s") through \(name) on "
                + "your normal connection and nothing came back. That resolver isn't answering "
                + "from this network — try a different one."
        case .working(let rescues):
            return
                "\(name) answered \(rescues) lookup\(rescues == 1 ? "" : "s") your main resolver "
                + "couldn't."
        }
    }
}
