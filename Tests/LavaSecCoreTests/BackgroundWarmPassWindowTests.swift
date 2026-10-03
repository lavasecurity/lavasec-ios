import XCTest

@testable import LavaSecCore
@testable import LavaSecKit

/// The two background windows differ by more than an order of magnitude, and the warm pass was
/// written when there was only one of them. These pin the differences that matter.
final class BackgroundWarmPassWindowTests: XCTestCase {
    private let freeCap = 500_000
    private let plusCap = 2_000_000

    // MARK: - Budget

    /// The long window keeps the whole tier cap. Sizing it to the free ceiling would skip every
    /// legitimately-large filter on every run — the feature would never warm the filters it exists
    /// for.
    func testTheProcessingWindowBudgetsTheUsersActualTierCap() {
        XCTAssertEqual(
            BackgroundWarmPassWindow.processing.perRunRuleBudget(tierRuleCap: plusCap), plusCap)
    }

    /// The fetch window cannot: a 2M-rule filter is far past it at any measured compile rate, so
    /// admitting one guarantees a discarded run.
    func testTheAppRefreshWindowCapsWellBelowAPlusTierFilter() {
        let budget = BackgroundWarmPassWindow.appRefresh.perRunRuleBudget(tierRuleCap: plusCap)
        XCTAssertEqual(budget, BackgroundWarmPassWindow.appRefreshRuleBudget)
        XCTAssertLessThan(budget, plusCap)
    }

    /// ...but never ABOVE the user's own cap: a free-tier filter can't compile more than the free
    /// ceiling, so a larger budget would be a number that cannot be reached.
    func testTheAppRefreshBudgetNeverExceedsTheTierCap() {
        XCTAssertEqual(
            BackgroundWarmPassWindow.appRefresh.perRunRuleBudget(tierRuleCap: 100_000), 100_000)
    }

    // MARK: - The livelock this exists to prevent

    /// THE FAILURE THIS WINDOW SPLIT IS FOR. The coldest candidate sorts first (never-warmed ⇒
    /// `.distantPast`), so on the short window an oversized filter is attempted first, cannot
    /// finish, and its expiration discards the whole run's sidecar write — then the next fetch
    /// window picks the same filter and does it again, forever, while the smaller filters behind it
    /// are never reached (review, PR #646).
    func testTheAppRefreshWindowRefusesAnOversizedColdestCandidate() {
        XCTAssertFalse(
            BackgroundWarmPassWindow.appRefresh.admitsCandidate(
                estimatedRuleCount: plusCap, rulesCompiled: 0, tierRuleCap: plusCap),
            "admitting it first is what makes the short window never make progress")
    }

    /// ...and the smaller filter behind it IS reached, which is the other half of the fix: refusing
    /// the oversized one must not stop the run.
    func testTheAppRefreshWindowStillAdmitsASmallerCandidate() {
        XCTAssertTrue(
            BackgroundWarmPassWindow.appRefresh.admitsCandidate(
                estimatedRuleCount: 50_000, rulesCompiled: 0, tierRuleCap: plusCap))
    }

    /// The long window keeps the concession deliberately: a heavy-overlap filter whose dedup-free
    /// estimate overshoots would otherwise be starved forever, and its post-compile break still
    /// bounds the run.
    func testTheProcessingWindowStillAdmitsAnOversizedColdestCandidate() {
        XCTAssertTrue(
            BackgroundWarmPassWindow.processing.admitsCandidate(
                estimatedRuleCount: plusCap * 3, rulesCompiled: 0, tierRuleCap: plusCap),
            "the first candidate of a long-window run always fits, by design")
    }

    /// The concession is only for the FIRST candidate. Once the budget is partly spent, an
    /// overshooting estimate is skipped so a smaller later filter can still use what remains.
    func testTheProcessingWindowSkipsAnOversizedCandidateOnceBudgetIsSpent() {
        XCTAssertFalse(
            BackgroundWarmPassWindow.processing.admitsCandidate(
                estimatedRuleCount: plusCap, rulesCompiled: 1, tierRuleCap: plusCap))
    }

    /// Both windows skip a candidate that does not fit what REMAINS, rather than breaking out —
    /// a smaller later filter can still use the rest.
    func testBothWindowsSkipACandidateThatDoesNotFitTheRemainder() {
        for window in BackgroundWarmPassWindow.allCases {
            let budget = window.perRunRuleBudget(tierRuleCap: freeCap)
            XCTAssertFalse(
                window.admitsCandidate(
                    estimatedRuleCount: budget, rulesCompiled: budget / 2, tierRuleCap: freeCap),
                "\(window.rawValue) admitted a candidate that cannot fit the remaining budget")
        }
    }

    // MARK: - Contention

    /// The short window hands its work to the holder: it has no budget to wait, and its top-up is
    /// something the next window can repeat.
    func testTheAppRefreshWindowDefersToTheHolder() {
        XCTAssertTrue(BackgroundWarmPassWindow.appRefresh.mayDeferToTheHolderOnContention)
        XCTAssertNil(BackgroundWarmPassWindow.appRefresh.contentionWaitBudget)
    }

    /// The long window must NOT hand its work over. It is the post-publish pass — the commit it
    /// follows is what invalidated every warm artifact — and the holder it would hand to may be the
    /// short window, which can expire mid-pass and take the queued rerun with it. The requester has
    /// already returned past its only warm call by then, so the newly published catalog would have
    /// no warm coverage at all (review, PR #646).
    func testTheProcessingWindowWaitsRatherThanHandingOverItsPass() {
        XCTAssertFalse(BackgroundWarmPassWindow.processing.mayDeferToTheHolderOnContention)
        let budget = try? XCTUnwrap(BackgroundWarmPassWindow.processing.contentionWaitBudget)
        XCTAssertNotNil(budget)
        XCTAssertGreaterThan(budget ?? 0, 0, "a zero wait is the same as giving up")
    }

    /// A QUEUED RERUN MUST RUN IN THE WINDOW THAT ASKED FOR IT.
    ///
    /// The holder services a queued request, and the holder is often the SHORT window — that is
    /// precisely why a processing caller's wait expired. Servicing it under the holder's own window
    /// would run the post-publish refill at the fetch window's budget and with its
    /// oversized-candidate refusal: the high-value pass executed under the policy chosen for the
    /// cheap one (review, PR #646). The wider window wins, because running it also satisfies what
    /// the narrower one would have done.
    func testTheWiderWindowWinsWhenTwoRerunRequestsOverlap() {
        // Mirrors AppViewModel.widerWarmWindow; pinned there by the source test.
        func wider(
            _ lhs: BackgroundWarmPassWindow?, _ rhs: BackgroundWarmPassWindow
        ) -> BackgroundWarmPassWindow {
            guard let lhs else { return rhs }
            return (lhs == .processing || rhs == .processing) ? .processing : rhs
        }

        XCTAssertEqual(wider(nil, .appRefresh), .appRefresh)
        XCTAssertEqual(wider(nil, .processing), .processing)
        XCTAssertEqual(wider(.appRefresh, .processing), .processing)
        XCTAssertEqual(
            wider(.processing, .appRefresh), .processing,
            "a pending processing request must not be narrowed by a later fetch-window one")
        XCTAssertEqual(wider(.appRefresh, .appRefresh), .appRefresh)
    }

    /// A PENDING REQUEST IS CONSUMED ONLY BY A WINDOW THAT CAN SATISFY IT.
    ///
    /// `wider(pending, mine) == mine` is the satisfies-test the pass uses. Both ways of getting it
    /// wrong were shipped and caught on this PR: consuming unconditionally discards a `.processing`
    /// request retained by a cancelled owner as soon as a fetch task acquires next; running it
    /// under the requested window regardless has a fetch task execute tier-cap policy in a ~30 s
    /// window, which is the livelock the split exists to prevent (review, PR #646).
    func testOnlyAWindowThatCanSatisfyARequestConsumesIt() {
        func wider(
            _ lhs: BackgroundWarmPassWindow?, _ rhs: BackgroundWarmPassWindow
        ) -> BackgroundWarmPassWindow {
            guard let lhs else { return rhs }
            return (lhs == .processing || rhs == .processing) ? .processing : rhs
        }
        func satisfies(_ mine: BackgroundWarmPassWindow, _ pending: BackgroundWarmPassWindow?) -> Bool {
            wider(pending, mine) == mine
        }

        XCTAssertTrue(satisfies(.processing, .processing))
        XCTAssertTrue(satisfies(.processing, .appRefresh), "the wider pass covers the narrower ask")
        XCTAssertTrue(satisfies(.appRefresh, .appRefresh))
        XCTAssertFalse(
            satisfies(.appRefresh, .processing),
            "a fetch task must neither run a processing request nor discard it — it leaves it "
                + "standing for the next processing window")
        for window in BackgroundWarmPassWindow.allCases {
            XCTAssertTrue(satisfies(window, nil), "no request is trivially satisfied")
        }
    }

    /// The wait stays well inside a processing window — waiting is not free even where there is
    /// room for it.
    func testTheContentionWaitIsBounded() {
        XCTAssertLessThanOrEqual(BackgroundWarmPassWindow.processing.contentionWaitBudget ?? .infinity, 60)
    }

    /// A WAIT SHORTER THAN THE HOLDER IS A WAIT THAT ALWAYS EXPIRES.
    ///
    /// The only in-process holder a `.processing` pass can be waiting on is an `.appRefresh` pass —
    /// there is no third caller, and iOS does not re-enter one BGTask identifier, so two processing
    /// passes cannot overlap. An earlier revision waited a flat 15 s, below that holder's own design
    /// ceiling, so a processing caller contending with a full-budget app-refresh pass timed out
    /// every time: it queued a `.processing` request and returned, and nothing in that cycle can run
    /// one (the `.appRefresh` holder correctly refuses to drain it, and the next processing pass
    /// needs another `bg-published` cycle). The post-publish refill was lost for the whole cycle
    /// (review, PR #646).
    func testTheContentionWaitOutlastsTheOnlyHolderItCanBeWaitingFor() throws {
        let budget = try XCTUnwrap(BackgroundWarmPassWindow.processing.contentionWaitBudget)
        XCTAssertGreaterThan(
            budget, BackgroundWarmPassWindow.appRefreshWindowSystemCeiling,
            "expiring at or before the holder's own ceiling makes the wait decorative in exactly "
                + "the case it exists for")
        XCTAssertEqual(
            budget,
            BackgroundWarmPassWindow.appRefreshWindowSystemCeiling
                + BackgroundWarmPassWindow.contentionWaitUnwindMargin,
            "DERIVED, not picked: the margin covers the cancelled holder unwinding through its "
                + "defer. Waiting beyond that cannot help — a flag still set then is not being "
                + "released on any bounded schedule")
    }
}
