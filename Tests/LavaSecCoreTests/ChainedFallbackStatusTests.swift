import XCTest

@testable import LavaSecKit

/// The T1 fallback's settings-surface status: which of the two invisible failures is
/// happening, and which machine the user has to go fix.
final class ChainedFallbackStatusTests: XCTestCase {
    private static func admitted(_ a: String) -> ChainedFallbackAddressOutcome {
        ChainedFallbackAddressOutcome(address: a, disposition: .admitted)
    }
    private static func alreadyPrimary(_ a: String) -> ChainedFallbackAddressOutcome {
        ChainedFallbackAddressOutcome(address: a, disposition: .alreadyPrimary)
    }
    private static func unusable(_ a: String) -> ChainedFallbackAddressOutcome {
        ChainedFallbackAddressOutcome(address: a, disposition: .unusable)
    }
    private func admitted(_ a: String) -> ChainedFallbackAddressOutcome { Self.admitted(a) }
    private func alreadyPrimary(_ a: String) -> ChainedFallbackAddressOutcome { Self.alreadyPrimary(a) }
    private func unusable(_ a: String) -> ChainedFallbackAddressOutcome { Self.unusable(a) }
    private func notRouted(_ a: String) -> ChainedFallbackAddressOutcome {
        ChainedFallbackAddressOutcome(address: a, disposition: .notRoutedBySplitTunnel)
    }

    private func status(
        isEnabled: Bool = true,
        hasEvaluated: Bool = true,
        outcomes: [ChainedFallbackAddressOutcome] = [admitted("1.1.1.1")],
        isChainedSessionLive: Bool = true,
        isLatchedSelectionCurrent: Bool = true,
        attemptCount: Int = 0,
        answerCount: Int = 0,
        rescueCount: Int = 0,
        unansweredStreak: Int = 0,
        unhelpfulReplyStreak: Int = 0
    ) -> ChainedFallbackStatus {
        ChainedFallbackStatus.status(
            isEnabled: isEnabled, hasEvaluated: hasEvaluated, outcomes: outcomes,
            isChainedSessionLive: isChainedSessionLive,
            isLatchedSelectionCurrent: isLatchedSelectionCurrent,
            attemptCount: attemptCount, answerCount: answerCount, rescueCount: rescueCount,
            unansweredStreak: unansweredStreak, unhelpfulReplyStreak: unhelpfulReplyStreak)
    }

    /// A FULL-TUNNEL session says so, instead of reporting "Ready — not needed yet" forever.
    ///
    /// Every address carries `.unavailableInFullTunnel`, so nothing is admitted and no counter
    /// can ever move. Before this the outcomes said `.admitted`, and zero attempts against an
    /// admitted set is precisely the `.readyUnused` condition — so the panel promised a fallback
    /// that could not fire, for the life of the session (Codex, PR #590).
    ///
    /// Asserted as three separate properties because each one is a distinct way to get this
    /// wrong: the verdict, that it is NOT tinted as a fault, and that its copy does not send the
    /// user off to pick a different resolver — the `.noneUsable` remedy, which would not help.
    func testAFullTunnelSessionReportsNoTierOneRatherThanReady() {
        let outcomes = [
            ChainedFallbackAddressOutcome(
                address: "1.1.1.1", disposition: .unavailableInFullTunnel),
            ChainedFallbackAddressOutcome(
                address: "1.0.0.1", disposition: .unavailableInFullTunnel)
        ]

        let verdict = status(outcomes: outcomes)

        XCTAssertEqual(verdict, .unavailableInFullTunnel)
        XCTAssertFalse(
            verdict.isActionable,
            "a VPN carrying all traffic is what the user configured — not a fault to fix")
        let detail = verdict.detail(resolver: "1.1.1.1")
        XCTAssertFalse(
            detail.contains("Pick a different"),
            "another resolver fares identically — the remedy would be false advice")
        XCTAssertTrue(detail.contains("carries all your traffic"))
    }

    /// ...and a MIXED list is not swallowed by it: only an all-full-tunnel set is the shape, so a
    /// genuine per-address failure still reaches `.noneUsable` and keeps its remedy.
    func testAMixedOutcomeListStillReportsThePerAddressFailure() {
        let verdict = status(outcomes: [
            ChainedFallbackAddressOutcome(
                address: "1.1.1.1", disposition: .unavailableInFullTunnel),
            ChainedFallbackAddressOutcome(address: "224.0.0.1", disposition: .unusable)
        ])

        guard case .noneUsable = verdict else {
            return XCTFail("a mixed list is not the full-tunnel shape; got \(verdict)")
        }
        XCTAssertTrue(verdict.isActionable)
    }

    func testAReplyingFallbackIsNotReportedAsANonForwardingPeer() {
        // A SERVFAIL/REFUSED/truncated reply PROVES the peer forwarded the query — the resolver
        // answered. Counting it as a bare attempt made the panel tell a user whose resolver had
        // just answered them that their VPN was not forwarding, sending them to configure an exit
        // node they did not need (Codex, PR #575).
        let verdict = status(attemptCount: 3, answerCount: 3, rescueCount: 0)
        XCTAssertEqual(verdict, .answeringWithoutResolving(answers: 3))
        let detail = verdict.detail(resolver: "1.1.1.1")
        XCTAssertFalse(
            detail.contains("exit node"),
            "a resolver that replied must never be reported as a forwarding failure")
        XCTAssertTrue(
            detail.contains("reachable on your normal connection"),
            "the rung goes out on the physical path, so that is what a reply proves is working")
    }

    /// Silence is still the distinct verdict — but it is no longer about the peer.
    ///
    /// While T1 rode the tunnel, nothing coming back meant the far end was not forwarding,
    /// and the remedy was an exit node or a subnet route. The rung now goes out on the normal
    /// connection, where the peer is not involved at all: that advice would send the user to
    /// reconfigure a machine the query never touches (Codex, PR #590).
    func testSilenceIsAResolverThatIsNotAnsweringNotAPeerThatIsNotForwarding() {
        // The other side of the same split: tried, and nothing of any kind came back.
        let verdict = status(attemptCount: 3, answerCount: 0, rescueCount: 0)
        XCTAssertEqual(verdict, .notForwarded(attempts: 3))
        let detail = verdict.detail(resolver: "1.1.1.1")
        XCTAssertTrue(
            detail.contains("on your normal connection"),
            "the copy must name the path the query actually took")
        XCTAssertFalse(
            detail.contains("exit node"),
            "the peer forwards nothing here — an exit node is not the remedy")
        XCTAssertFalse(
            detail.contains("subnet route"),
            "nor is a subnet route; neither is on the path any more")
        // A remedy the user can act on SURVIVES the rewrite. The verdict is actionable, so the
        // copy has to end somewhere other than a dead end.
        XCTAssertTrue(detail.contains("try a different one"))
    }

    func testAStaleLatchIsReportedBeforeAnyCounterIsRead() {
        // Every counter describes the LATCHED address. Changing the setting mid-session leaves
        // them describing a resolver the user is no longer looking at — so a fresh address could
        // be condemned by the old one's silence, or credited with its rescues. The disagreement
        // is reported before any of them is read.
        XCTAssertEqual(
            status(isLatchedSelectionCurrent: false, attemptCount: 9, rescueCount: 4),
            .awaitingRestart,
            "a stale latch must not let one resolver's evidence be shown under another's name")
        XCTAssertEqual(
            status(outcomes: [unusable("224.0.0.1")], isLatchedSelectionCurrent: false), .awaitingRestart,
            "the old latch's admission verdict is equally not about the new address")
        XCTAssertFalse(
            ChainedFallbackStatus.awaitingRestart.isActionable,
            "restarting protection is a next step, not a fault to flag")
    }

    func testTheToggleWinsOverEverythingElse() {
        XCTAssertEqual(
            status(isEnabled: false, outcomes: [unusable("224.0.0.1")], attemptCount: 9, rescueCount: 3), .off,
            "counters from a previous session must not make a disabled fallback look alive")
    }

    func testTurningItOffMidSessionReportsThatTheTunnelHasNotStoppedYet() {
        // The latch is per-session by design, so the toggle does not reach a running session:
        // failed lookups keep going to the latched resolver until protection restarts. Reporting
        // `.off` there states the user's INTENT as though it were the tunnel's behaviour — the
        // silent disagreement this whole panel exists to remove (Codex, PR #575).
        let verdict = status(
            isEnabled: false, isLatchedSelectionCurrent: false, attemptCount: 4, rescueCount: 1)
        XCTAssertEqual(verdict, .pendingDisable)
        XCTAssertEqual(verdict.title, "Off after you restart")
        XCTAssertTrue(
            verdict.detail(resolver: "1.1.1.1").contains("still retrying through 1.1.1.1"),
            "the copy must name the resolver STILL IN USE, which is the latched one")
        XCTAssertFalse(
            verdict.isActionable,
            "the user just did the correct thing — a restart clears it, so it is not a fault")
    }

    func testAStoppedTunnelStopsClaimingItIsStillRetrying() {
        // Teardown clears `isChainedUpstreamActive` and NOTHING else — the fallback lifecycle
        // fields survive so a bug report can still read a stopped session's final values. Without
        // consulting the live flag, a disabled fallback whose tunnel then stopped kept reporting
        // `.pendingDisable` forever: the panel told a user with protection OFF that their VPN was
        // still retrying through a resolver (Codex, PR #575).
        XCTAssertEqual(
            status(isEnabled: false, isChainedSessionLive: false, isLatchedSelectionCurrent: false),
            .off,
            "a stale latch from a stopped session is not a pending disable")
        // The same staleness on the enabled side: a stopped session's counters are not evidence
        // about anything running, so the honest answer is the one that says nothing is.
        XCTAssertEqual(
            status(isChainedSessionLive: false, attemptCount: 7, rescueCount: 3), .awaitingSession,
            "a stopped session's rescues must not be reported as a working fallback")
    }

    func testAPendingDisableRequiresSomethingToHaveBeenRunning() {
        // A selection whose every address was REFUSED never became a T1 resolver, so there is
        // nothing still running to keep running. Reporting `.pendingDisable` there invents an
        // active resolver: the panel told the user their VPN was retrying through an address it
        // had refused at admission (Codex, PR #575).
        for refused in [notRouted("1.1.1.1"), unusable("224.0.0.1"), alreadyPrimary("1.1.1.1")] {
            XCTAssertEqual(
                status(isEnabled: false, outcomes: [refused], isLatchedSelectionCurrent: false),
                .off,
                "\(refused.disposition) was never a T1 resolver — nothing is pending")
        }
        // One admitted member is enough: that address WAS running and still is.
        XCTAssertEqual(
            status(
                isEnabled: false, outcomes: [admitted("1.1.1.1"), unusable("1.0.0.1")],
                isLatchedSelectionCurrent: false),
            .pendingDisable,
            "a partially-refused selection still had a live T1 resolver")
    }

    func testAFallbackThatGoesDarkStopsReadingAsWorking() {
        // Every other counter is CUMULATIVE, so once a rescue lands they can only make the
        // fallback look healthier. A resolver that served one lookup and then went dark — the
        // exit node's forwarding changing mid-session — kept reporting `.working` while every
        // subsequent attempt vanished (Codex, PR #575).
        let threshold = ChainedFallbackStatus.consecutiveUnansweredFailureThreshold
        XCTAssertEqual(
            status(attemptCount: 12, answerCount: 2, rescueCount: 2, unansweredStreak: threshold),
            .notForwarded(attempts: threshold),
            "a present run of silence must overrule a past rescue")
        // An answer resets the streak, so a recovered fallback goes back to reading working
        // rather than staying condemned by history — the same argument in reverse.
        XCTAssertEqual(
            status(attemptCount: 12, answerCount: 3, rescueCount: 2, unansweredStreak: 0),
            .working(rescues: 2))
    }

    func testAFallbackThatKeepsReplyingButStopsResolvingSurfaces() {
        // ONE STREAK WAS NOT ENOUGH (Codex, PR #575). The unanswered streak resets on ANY answer,
        // SERVFAIL and REFUSED included, so a fallback that served once and then soft-fails every
        // retry keeps clearing it while the cumulative rescue count holds `.working` in place —
        // and `.answeringWithoutResolving` became unreachable after any rescue at all.
        //
        // Reaching that arm means replies ARE landing (short unanswered streak) while nothing is
        // being served, which is exactly what the state describes.
        let threshold = ChainedFallbackStatus.consecutiveUnansweredFailureThreshold
        XCTAssertEqual(
            status(
                attemptCount: 20, answerCount: 19, rescueCount: 1,
                unansweredStreak: 0, unhelpfulReplyStreak: threshold),
            .answeringWithoutResolving(answers: threshold),
            "sustained soft failures must overrule a single old rescue")
        // A rescue resets it, so a recovered fallback reads working again rather than staying
        // condemned — the same argument as the silence streak, one rung narrower.
        XCTAssertEqual(
            status(attemptCount: 20, answerCount: 19, rescueCount: 2, unhelpfulReplyStreak: 0),
            .working(rescues: 2))
    }

    func testTheSoftFailureCountNeverIncludesARescue() {
        // The number in the copy is a claim: "replied to N retries but couldn't resolve the name
        // either". A LIFETIME answer total includes the rescues, so one rescue followed by three
        // soft failures reported four — a sentence with a rescue counted inside it (Codex,
        // PR #575). The streak counts replies that did not serve, so it cannot contain one.
        let verdict = status(
            attemptCount: 4, answerCount: 4, rescueCount: 1, unhelpfulReplyStreak: 3)
        XCTAssertEqual(verdict, .answeringWithoutResolving(answers: 3))
        let detail = verdict.detail(resolver: "1.1.1.1")
        XCTAssertTrue(
            detail.contains("replied to 3 retries"),
            "the copy must count only the replies that failed to resolve")
        // BOTH SHAPES, because this state covers both. A TC-bit reply is the resolver having an
        // answer that does not fit UDP — and this tunnel path deliberately carries no TCP rung to
        // retry it on — so "just doesn't have the answer" reported a transport limit as the
        // resolver's ignorance (Codex, PR #575).
        // The distinction survives the path change; only its wording moved. "Too big to send
        // this way" named the TUNNELLED loop's deliberate lack of a TCP rung, and the physical
        // rung has one — so the honest second shape is now the answer not arriving rather than
        // the transport refusing to carry it (Codex, PR #590).
        XCTAssertTrue(
            detail.contains("either it has no answer for that name"),
            "the SERVFAIL/REFUSED shape must still be named")
        XCTAssertTrue(
            detail.contains("didn't come through"),
            "and so must the shape where a reply never resolves — one is not the other")
        XCTAssertFalse(
            detail.contains("too big to send this way"),
            "that named the tunnelled loop's missing TCP rung; the physical rung retries")
    }

    func testSilenceStillOutranksSoftFailure() {
        // Both streaks long means nothing is coming back at all — the exit-node case, not the
        // resolver-declining case. Order matters: silence is the narrower, more actionable fact.
        let threshold = ChainedFallbackStatus.consecutiveUnansweredFailureThreshold
        XCTAssertEqual(
            status(
                attemptCount: 20, answerCount: 5, rescueCount: 1,
                unansweredStreak: threshold, unhelpfulReplyStreak: threshold + 4),
            .notForwarded(attempts: threshold),
            "when nothing is replying either, the peer is the story")
    }

    func testASingleLostDatagramDoesNotCondemnAWorkingFallback() {
        // Thresholded rather than `> 0`: one timeout is ordinary, and a panel that flipped to
        // "broken" on the first would be noisy exactly when it needs to be trusted.
        XCTAssertEqual(
            status(
                attemptCount: 9, answerCount: 4, rescueCount: 2,
                unansweredStreak: ChainedFallbackStatus.consecutiveUnansweredFailureThreshold - 1),
            .working(rescues: 2),
            "below the threshold the cumulative reading still wins")
    }

    func testAFreshSilentFallbackIsUnaffectedByTheThreshold() {
        // Regression: the streak arm must not RAISE the bar for the original exit-node case. A
        // first attempt that vanishes still reports the forwarding failure at once, from the
        // cumulative arm below, exactly as before the streak existed.
        XCTAssertEqual(
            status(attemptCount: 1, answerCount: 0, rescueCount: 0, unansweredStreak: 1),
            .notForwarded(attempts: 1))
    }

    func testADisabledFallbackWithNothingRunningIsPlainlyOff() {
        // The other side of the same guard, and the reason `.off` is not simply retired: with no
        // live session (or one that latched nothing) the latch and the empty selection AGREE, so
        // there is nothing pending and nothing to warn about.
        XCTAssertEqual(
            status(isEnabled: false, isLatchedSelectionCurrent: true, attemptCount: 9), .off,
            "a disabled fallback with no live latch is off, not pending")
        XCTAssertEqual(
            status(isEnabled: false, hasEvaluated: false, isLatchedSelectionCurrent: false), .off,
            "before any session has evaluated it there is no live latch to still be using")
    }

    func testNothingIsClaimedBeforeASessionHasEvaluatedIt() {
        XCTAssertEqual(
            status(hasEvaluated: false), .awaitingSession,
            "before a chained session applies the selection every counter is zero, which is "
                + "indistinguishable from 'enabled and idle' — claiming ready there is a guess")
        XCTAssertEqual(
            status(hasEvaluated: false, outcomes: [unusable("224.0.0.1")]), .awaitingSession,
            "admission is also unknown before evaluation; reporting a bad address would accuse "
                + "the user's setting of a fault nothing has checked")
    }

    func testANonAdmittedSelectionIsNamedRatherThanReportedAsIdle() {
        // A selection that contributed nothing can never accrue attempts, so a use-based check
        // would report it as merely idle — the same silent-failure class this panel removes.
        let verdict = status(outcomes: [unusable("224.0.0.1")], attemptCount: 0, rescueCount: 0)
        XCTAssertEqual(verdict, .noneUsable(outcomes: [unusable("224.0.0.1")]))
        XCTAssertTrue(verdict.isActionable)
        XCTAssertFalse(
            verdict.detail(resolver: nil).contains("AllowedIPs"),
            "a refused ADDRESS is not a routing problem — naming AllowedIPs here would send the "
                + "user to edit a config that is not the cause")
    }

    func testAFallbackTheConfAlreadyCarriesIsNotSlanderedAsUnusable() {
        // Dedup into T0 happens AFTER every usability gate, so the address is fine — calling
        // it reserved or colliding was false (Codex, PR #575).
        let verdict = status(outcomes: [alreadyPrimary("1.1.1.1")])
        XCTAssertEqual(verdict, .noneUsable(outcomes: [alreadyPrimary("1.1.1.1")]))
        XCTAssertEqual(verdict.title, "Same as your VPN's own resolver")
        let detail = verdict.detail(resolver: nil)
        XCTAssertTrue(detail.contains("1.1.1.1 is already your VPN's own resolver"))
        XCTAssertFalse(
            detail.contains("reserved") || detail.contains("multicast"),
            "the address passed every gate — only its redundancy is the problem")
    }

    func testAGenuinelyUnusableAddressStillReadsAsUnusable() {
        let verdict = status(outcomes: [unusable("224.0.0.1")])
        XCTAssertEqual(verdict.title, "That address can't be used")
        XCTAssertTrue(verdict.detail(resolver: nil).contains("224.0.0.1 can't be a resolver"))
    }

    func testAnUnroutedFallbackNeverTellsTheUserToEditTheirVPN() {
        // THE COPY THIS REPLACES, verbatim: "Your VPN doesn't route it — pick a resolver your VPN
        // does route, or use one that carries all your traffic." It shipped, and a device log from
        // 2026-08-25 shows it standing over a Tailscale profile with Cloudflare selected while the
        // routes read `100.64.0.0/10, 10.255.0.0/24 (DNS), rest direct`.
        //
        // That copy was a correct description of a product that had not implemented its own
        // setting. The answer turned out not to be carrying the resolver through the peer — that
        // was tried, and `AllowedIPs` cannot make a peer forward — but running the rung on the
        // PHYSICAL interface, where the tunnel's routes have nothing to say about it (PR #590).
        // The disposition is unproducible now and survives only to decode older snapshots, so
        // this test is a pin on the COPY: were it ever produced again, it must still not send the
        // user to hand-edit their profile.
        let outcomes = [notRouted("1.1.1.1"), notRouted("1.0.0.1")]
        let verdict = status(outcomes: outcomes)

        XCTAssertEqual(verdict, .noneUsable(outcomes: outcomes))
        XCTAssertEqual(verdict.title, "Not being used")

        let detail = verdict.detail(resolver: nil)
        XCTAssertTrue(detail.contains("1.1.1.1 can't be added without changing how your VPN routes"))
        // The remedy is a control inside this app. It is NOT "restart", which shipped for one
        // commit and was an endless loop — the decision is deterministic, so every restart
        // declines identically (Codex, PR #584).
        XCTAssertTrue(detail.contains("Pick a different resolver."))
        XCTAssertFalse(detail.localizedCaseInsensitiveContains("restart"))

        // And the user's WireGuard profile is never something this panel may send them to edit.
        for banned in [
            "doesn't route", "does route", "carries all your traffic", "AllowedIPs", "full tunnel"
        ] {
            XCTAssertFalse(
                detail.localizedCaseInsensitiveContains(banned),
                "the panel must not send the user to their VPN config: found \(banned)")
        }
    }

    func testAMixedRejectionAndDeduplicationNamesBothCauses() {
        // THE DEFECT THAT FORCED THE RESTRUCTURE (Codex, PR #575). Cloudflare with
        // `DNS = 1.1.1.1` and a client address of 1.0.0.1: the first dedupes, the second is
        // refused, and every summary claim about the pair is wrong for one of them. Four review
        // rounds were spent finding new arrangements of exactly this, which is why the status now
        // enumerates instead of asserting.
        let outcomes = [alreadyPrimary("1.1.1.1"), unusable("1.0.0.1")]
        let verdict = status(outcomes: outcomes)
        XCTAssertEqual(verdict, .noneUsable(outcomes: outcomes))
        XCTAssertEqual(
            verdict.title, "Not being used",
            "a mixed set must not borrow either member's headline")
        let detail = verdict.detail(resolver: nil)
        XCTAssertTrue(
            detail.contains("1.1.1.1 is already your VPN's own resolver"),
            "the deduped address must be named as deduped")
        XCTAssertTrue(
            detail.contains("1.0.0.1 can't be a resolver"),
            "the refused address must be named as refused — not folded into the other's cause")
    }

    func testOneAdmittedAddressIsEnoughToReadTheCounters() {
        // The counters aggregate the whole effective set, so a single admitted member makes them
        // meaningful — a partially-refused selection is still a working fallback.
        let verdict = status(
            outcomes: [admitted("1.1.1.1"), unusable("1.0.0.1")], rescueCount: 2)
        XCTAssertEqual(verdict, .working(rescues: 2))
    }

    func testAdmittedAndUntriedIsNotAFault() {
        let verdict = status(attemptCount: 0)
        XCTAssertEqual(verdict, .readyUnused)
        XCTAssertFalse(
            verdict.isActionable,
            "a fallback that has never been needed means the PRIMARY is healthy — flagging it "
                + "would train the user to ignore the panel")
    }

    func testTriedWithNothingComingBackIsStillActionable() {
        let verdict = status(attemptCount: 4, rescueCount: 0)
        XCTAssertEqual(verdict, .notForwarded(attempts: 4))
        XCTAssertTrue(verdict.isActionable)
        // It USED to be the one failure the user could not fix on this device, because it was the
        // peer's to fix. On the physical path it is the opposite: picking another resolver is a
        // control the user has right here (Codex, PR #590).
        XCTAssertTrue(
            verdict.detail(resolver: "1.1.1.1").contains("try a different one"),
            "an actionable verdict must name an action the user can actually take")
    }

    func testAServedAnswerOutranksTheAttemptsItWasCountedIn() {
        // A rescue is a strict subset of an attempt, so a working fallback always has both
        // counters up. Reporting the attempt arm first would call a working fallback broken.
        let verdict = status(attemptCount: 7, rescueCount: 2)
        XCTAssertEqual(verdict, .working(rescues: 2))
        XCTAssertFalse(verdict.isActionable)
    }

    func testNoStateEverTellsTheUserToEditAllowedIPs() {
        // `AllowedIPs` is WireGuard config jargon, and no state here has a remedy that is served by
        // it. Even the split-tunnel case — the one state that IS about routing — names the tunnel's
        // shape in the user's own terms ("your VPN doesn't route 1.1.1.1") rather than sending them
        // to hand-edit a config file to make a Lava setting work.
        //
        // The split state is in this list deliberately: it is the one most able to regrow the
        // jargon, being the only state whose cause really is a routing table.
        let states: [ChainedFallbackStatus] = [
            status(isEnabled: false), status(hasEvaluated: false),
            status(outcomes: [unusable("224.0.0.1")]),
            status(outcomes: [alreadyPrimary("1.1.1.1")]),
            status(outcomes: [notRouted("1.1.1.1")]),
            status(attemptCount: 0), status(attemptCount: 3), status(attemptCount: 3, rescueCount: 1),
        ]
        for state in states {
            XCTAssertFalse(
                state.detail(resolver: "1.1.1.1").contains("AllowedIPs"),
                "\(state) still tells the user to edit AllowedIPs")
        }
    }

    func testDetailSurvivesAnUnknownResolverAddress() {
        XCTAssertFalse(
            status(outcomes: [unusable("224.0.0.1")]).detail(resolver: nil).isEmpty,
            "the panel must still render when the address is momentarily unavailable")
    }

    func testSingularAndPluralCountsRead() {
        // Panel copy is read by a founder mid-incident; "retried 1 lookups" is the kind of
        // thing that makes a diagnostic look untrustworthy.
        XCTAssertTrue(
            status(attemptCount: 1).detail(resolver: "9.9.9.9").contains("1 lookup through"))
        XCTAssertTrue(
            status(attemptCount: 2).detail(resolver: "9.9.9.9").contains("2 lookups through"))
        XCTAssertTrue(
            status(attemptCount: 1, rescueCount: 1).detail(resolver: "9.9.9.9")
                .contains("1 lookup your"))
        XCTAssertTrue(
            status(attemptCount: 5, rescueCount: 3).detail(resolver: "9.9.9.9")
                .contains("3 lookups your"))
    }
    /// Only states worth reading reach the screen.
    ///
    /// The panel used to render for every state but `.off`, so a healthy fallback sat there
    /// permanently saying "Ready — not needed yet" — a full-width card whose content is that
    /// nothing has happened (founder, 2026-08-27).
    ///
    /// The split is deliberately NOT `isActionable`. Three surfaced states are not faults and
    /// never will be: `unavailableInFullTunnel` explains why a switched-on setting does nothing,
    /// and `pendingDisable` / `awaitingRestart` say a change needs a restart. None is the user's
    /// to fix, and silence about all three is worse than a card — which is exactly why this is a
    /// second question rather than a reuse of the first.
    func testOnlyStatesWorthReadingAreSurfaced() {
        let silent: [ChainedFallbackStatus] = [
            .off, .readyUnused, .working(rescues: 3), .awaitingSession
        ]
        for status in silent {
            XCTAssertFalse(
                status.deservesSurfacing,
                "\(status) says nothing a reader needs — the toggle and the connect state cover it")
        }

        let surfaced: [ChainedFallbackStatus] = [
            .pendingDisable,
            .awaitingRestart,
            .unavailableInFullTunnel,
            .notForwarded(attempts: 2),
            .answeringWithoutResolving(answers: 4),
            .noneUsable(outcomes: [])
        ]
        for status in surfaced {
            XCTAssertTrue(status.deservesSurfacing, "\(status) is why the panel exists")
        }

        // NOT the same question as `isActionable`, and this is the pair that proves it: both are
        // surfaced, only one is a fault. Collapsing them would either hide the full-tunnel
        // explanation or put a warning tint on it.
        XCTAssertTrue(ChainedFallbackStatus.unavailableInFullTunnel.deservesSurfacing)
        XCTAssertFalse(ChainedFallbackStatus.unavailableInFullTunnel.isActionable)
        XCTAssertTrue(ChainedFallbackStatus.notForwarded(attempts: 2).deservesSurfacing)
        XCTAssertTrue(ChainedFallbackStatus.notForwarded(attempts: 2).isActionable)
    }
}
