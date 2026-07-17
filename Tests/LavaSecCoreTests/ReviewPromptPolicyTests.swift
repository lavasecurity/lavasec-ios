import XCTest
@testable import LavaSecCore
@testable import LavaSecKit

/// Behavioral tests for the App Store review-prompt gate. Every anchor funnels through
/// `ReviewPromptPolicy.shouldRequest`, so these cover the shared rails (onboarding, frustration,
/// annual ceiling, self-cooldown) once and each anchor's own threshold.
/// Design: lavasec-infra/plans/2026-07-16-app-store-review-prompt-plan.md
final class ReviewPromptPolicyTests: XCTestCase {
    // A fixed reference instant so every relative timestamp below is deterministic.
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    private func daysAgo(_ days: Double) -> Date {
        now.addingTimeInterval(-days * 86_400)
    }

    // MARK: - Global rails

    func testRejectsEveryAnchorUntilOnboardingComplete() {
        // Even a fully-matured user is never asked mid-onboarding.
        let state = ReviewPromptState(successfulProtectionOns: 10)
        for moment in [ReviewAhaMoment.protectionOn, .filterUpdated, .viewingActivity(totalQueries: 100_000, blockRate: 0.9)] {
            XCTAssertFalse(
                ReviewPromptPolicy.shouldRequest(for: moment, state: state, hasCompletedOnboarding: false, now: now),
                "\(moment) must not ask before onboarding is complete."
            )
        }
    }

    func testSelfCooldownSuppressesARecentPrompt() {
        let base = ReviewPromptState(successfulProtectionOns: 5)

        var recentlyPrompted = base
        recentlyPrompted.promptTimestamps = [daysAgo(10)]
        XCTAssertFalse(
            ReviewPromptPolicy.shouldRequest(for: .protectionOn, state: recentlyPrompted, hasCompletedOnboarding: true, now: now),
            "A prompt 10 days ago is inside the 90-day self-cooldown — must not ask again."
        )

        var longAgoPrompted = base
        longAgoPrompted.promptTimestamps = [daysAgo(100)]
        XCTAssertTrue(
            ReviewPromptPolicy.shouldRequest(for: .protectionOn, state: longAgoPrompted, hasCompletedOnboarding: true, now: now),
            "A prompt 100 days ago is past the self-cooldown — asking again is allowed."
        )

        // Boundary: the cooldown check is strict (`elapsed < selfCooldown`), so a prompt EXACTLY 90
        // days ago has met the 90-day gap and asking is allowed, while one a hair inside (89 days) is
        // still suppressed. Pinning both sides guards the inequality against an off-by-one flip to
        // `<=` that would hold the gate a full extra day.
        var exactlyAtCooldown = base
        exactlyAtCooldown.promptTimestamps = [daysAgo(90)]
        XCTAssertTrue(
            ReviewPromptPolicy.shouldRequest(for: .protectionOn, state: exactlyAtCooldown, hasCompletedOnboarding: true, now: now),
            "A prompt exactly 90 days ago has met the self-cooldown gap — asking is allowed."
        )
        var justInsideCooldown = base
        justInsideCooldown.promptTimestamps = [daysAgo(89)]
        XCTAssertFalse(
            ReviewPromptPolicy.shouldRequest(for: .protectionOn, state: justInsideCooldown, hasCompletedOnboarding: true, now: now),
            "A prompt 89 days ago is still inside the 90-day self-cooldown — must not ask."
        )
    }

    func testAnnualCeilingCountsOnlyPromptsInsideTheRollingWindow() {
        // Three prompts inside the last year (and all past the cooldown) hit the ceiling.
        var atCeiling = ReviewPromptState(successfulProtectionOns: 5)
        atCeiling.promptTimestamps = [daysAgo(100), daysAgo(200), daysAgo(300)]
        XCTAssertFalse(
            ReviewPromptPolicy.shouldRequest(for: .protectionOn, state: atCeiling, hasCompletedOnboarding: true, now: now),
            "Three requests within 365 days is the annual ceiling — must not ask a fourth."
        )

        // Sliding the oldest out past a year drops the in-window count to two, so it may ask again.
        var oneAged = ReviewPromptState(successfulProtectionOns: 5)
        oneAged.promptTimestamps = [daysAgo(100), daysAgo(200), daysAgo(400)]
        XCTAssertTrue(
            ReviewPromptPolicy.shouldRequest(for: .protectionOn, state: oneAged, hasCompletedOnboarding: true, now: now),
            "A request older than the 365-day window must not count against the ceiling."
        )

        // Boundary: the window filter is strict (`elapsed < annualWindow`), so a prompt EXACTLY 365
        // days ago falls OUT of the window — the in-window count is two and a third ask is allowed —
        // while one a hair inside (364 days) still counts and holds the ceiling. Pinning both sides
        // guards the inequality against a `<=` flip that would keep a year-old prompt on the books an
        // extra day.
        var oldestExactlyAYear = ReviewPromptState(successfulProtectionOns: 5)
        oldestExactlyAYear.promptTimestamps = [daysAgo(100), daysAgo(200), daysAgo(365)]
        XCTAssertTrue(
            ReviewPromptPolicy.shouldRequest(for: .protectionOn, state: oldestExactlyAYear, hasCompletedOnboarding: true, now: now),
            "A request exactly 365 days ago is outside the rolling window — only two count, so a third is allowed."
        )
        var oldestJustInsideAYear = ReviewPromptState(successfulProtectionOns: 5)
        oldestJustInsideAYear.promptTimestamps = [daysAgo(100), daysAgo(200), daysAgo(364)]
        XCTAssertFalse(
            ReviewPromptPolicy.shouldRequest(for: .protectionOn, state: oldestJustInsideAYear, hasCompletedOnboarding: true, now: now),
            "A request 364 days ago is still inside the window — three counted requests is the annual ceiling."
        )
    }

    func testFrustrationWindowSuppressesNearbyRequests() {
        var justFrustrated = ReviewPromptState(successfulProtectionOns: 5)
        justFrustrated.lastFrustrationAt = daysAgo(7)
        XCTAssertFalse(
            ReviewPromptPolicy.shouldRequest(for: .protectionOn, state: justFrustrated, hasCompletedOnboarding: true, now: now),
            "A rage-shake 7 days ago is inside the frustration window — must not ask."
        )

        var frustrationFaded = ReviewPromptState(successfulProtectionOns: 5)
        frustrationFaded.lastFrustrationAt = daysAgo(20)
        XCTAssertTrue(
            ReviewPromptPolicy.shouldRequest(for: .protectionOn, state: frustrationFaded, hasCompletedOnboarding: true, now: now),
            "A rage-shake 20 days ago is past the frustration window — asking is allowed."
        )

        // Boundary: the window check is strict (`elapsed < frustrationWindow`), so a rage-shake
        // EXACTLY 14 days ago has aged out and asking is allowed, while one a hair inside (13 days)
        // still suppresses. Pinning both sides guards the inequality against a `<=` flip.
        var frustrationExactlyAtEdge = ReviewPromptState(successfulProtectionOns: 5)
        frustrationExactlyAtEdge.lastFrustrationAt = daysAgo(14)
        XCTAssertTrue(
            ReviewPromptPolicy.shouldRequest(for: .protectionOn, state: frustrationExactlyAtEdge, hasCompletedOnboarding: true, now: now),
            "A rage-shake exactly 14 days ago has aged out of the frustration window — asking is allowed."
        )
        var frustrationJustInside = ReviewPromptState(successfulProtectionOns: 5)
        frustrationJustInside.lastFrustrationAt = daysAgo(13)
        XCTAssertFalse(
            ReviewPromptPolicy.shouldRequest(for: .protectionOn, state: frustrationJustInside, hasCompletedOnboarding: true, now: now),
            "A rage-shake 13 days ago is still inside the 14-day frustration window — must not ask."
        )
    }

    // MARK: - Per-anchor thresholds

    func testProtectionOnNeedsThreeSuccessfulTurnOns() {
        XCTAssertFalse(
            ReviewPromptPolicy.shouldRequest(
                for: .protectionOn,
                state: ReviewPromptState(successfulProtectionOns: 2),
                hasCompletedOnboarding: true,
                now: now
            ),
            "Two turn-ons is not yet mature — the protection-on anchor waits for the third."
        )
        XCTAssertTrue(
            ReviewPromptPolicy.shouldRequest(
                for: .protectionOn,
                state: ReviewPromptState(successfulProtectionOns: 3),
                hasCompletedOnboarding: true,
                now: now
            ),
            "The third user-initiated turn-on is eligible for the protection-on anchor."
        )
    }

    func testFilterUpdatedNeedsAtLeastOnePriorSession() {
        XCTAssertFalse(
            ReviewPromptPolicy.shouldRequest(
                for: .filterUpdated,
                state: ReviewPromptState(successfulProtectionOns: 0),
                hasCompletedOnboarding: true,
                now: now
            ),
            "A filter edit before the first protection session must not ask."
        )
        XCTAssertTrue(
            ReviewPromptPolicy.shouldRequest(
                for: .filterUpdated,
                state: ReviewPromptState(successfulProtectionOns: 1),
                hasCompletedOnboarding: true,
                now: now
            ),
            "After the first session, a qualifying foreground filter add is eligible."
        )
    }

    func testActivityViewingNeedsBothVolumeAndBlockRate() {
        let state = ReviewPromptState(successfulProtectionOns: 5)

        // Maturity floor: like the other two anchors, the Activity anchor needs at least one prior
        // user-initiated protection session, so a first-run user with a large restored or on-demand
        // query history can't earn a display before turning protection on once (OCR review on #69).
        XCTAssertFalse(
            ReviewPromptPolicy.shouldRequest(
                for: .viewingActivity(totalQueries: 100_000, blockRate: 0.9),
                state: ReviewPromptState(successfulProtectionOns: 0),
                hasCompletedOnboarding: true, now: now
            ),
            "A huge, heavily-blocked volume on the very first session (zero turn-ons) must not qualify."
        )
        XCTAssertTrue(
            ReviewPromptPolicy.shouldRequest(
                for: .viewingActivity(totalQueries: 5_001, blockRate: 0.11),
                state: ReviewPromptState(successfulProtectionOns: 1),
                hasCompletedOnboarding: true, now: now
            ),
            "After one protection session, a qualifying-magnitude Activity view is eligible."
        )

        // Volume boundary is strict (> 5000).
        XCTAssertFalse(
            ReviewPromptPolicy.shouldRequest(
                for: .viewingActivity(totalQueries: 5_000, blockRate: 0.5),
                state: state, hasCompletedOnboarding: true, now: now
            ),
            "Exactly 5000 queries does not clear the strictly-greater-than volume threshold."
        )
        XCTAssertTrue(
            ReviewPromptPolicy.shouldRequest(
                for: .viewingActivity(totalQueries: 5_001, blockRate: 0.11),
                state: state, hasCompletedOnboarding: true, now: now
            ),
            "5001 queries at an 11% block rate clears both activity thresholds."
        )

        // Block-rate boundary is strict (> 0.10).
        XCTAssertFalse(
            ReviewPromptPolicy.shouldRequest(
                for: .viewingActivity(totalQueries: 50_000, blockRate: 0.10),
                state: state, hasCompletedOnboarding: true, now: now
            ),
            "Exactly a 10% block rate does not clear the strictly-greater-than rate threshold."
        )
        XCTAssertTrue(
            ReviewPromptPolicy.shouldRequest(
                for: .viewingActivity(totalQueries: 50_000, blockRate: 0.1001),
                state: state, hasCompletedOnboarding: true, now: now
            ),
            "A block rate just above 10% on a high-volume page clears both activity thresholds."
        )
    }

    // MARK: - Storage

    func testStorageRoundTripsAndRecordsFrustration() throws {
        let suite = "ReviewPromptPolicyTests.storage"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        // Absent key → fresh-install default.
        XCTAssertEqual(ReviewPromptStateStorage.load(from: defaults), ReviewPromptState())

        let saved = ReviewPromptState(successfulProtectionOns: 4, promptTimestamps: [daysAgo(30)])
        ReviewPromptStateStorage.save(saved, to: defaults)
        XCTAssertEqual(ReviewPromptStateStorage.load(from: defaults), saved)

        // recordFrustration stamps the signal without disturbing the rest.
        ReviewPromptStateStorage.recordFrustration(now: now, in: defaults)
        let after = ReviewPromptStateStorage.load(from: defaults)
        XCTAssertEqual(after.successfulProtectionOns, 4)
        XCTAssertEqual(after.promptTimestamps, [daysAgo(30)])
        XCTAssertEqual(after.lastFrustrationAt, now)
    }

    func testRecordFrustrationOverwritesWithTheLatestSignal() throws {
        let suite = "ReviewPromptPolicyTests.frustrationOverwrite"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        // Seed a state that already carries an OLD frustration stamp plus unrelated bookkeeping.
        let seeded = ReviewPromptState(
            successfulProtectionOns: 4,
            promptTimestamps: [daysAgo(30)],
            lastFrustrationAt: daysAgo(50)
        )
        ReviewPromptStateStorage.save(seeded, to: defaults)

        // recordFrustration is last-write-wins: each call REPLACES lastFrustrationAt with the moment
        // passed, rather than keeping the earliest or accumulating — a fresh rage-shake must reset the
        // suppression window from now, and the untracked fields must survive untouched.
        ReviewPromptStateStorage.recordFrustration(now: daysAgo(20), in: defaults)
        let afterFirst = ReviewPromptStateStorage.load(from: defaults)
        XCTAssertEqual(afterFirst.lastFrustrationAt, daysAgo(20), "the newer stamp must replace the older one")
        XCTAssertEqual(afterFirst.successfulProtectionOns, 4)
        XCTAssertEqual(afterFirst.promptTimestamps, [daysAgo(30)])

        ReviewPromptStateStorage.recordFrustration(now: now, in: defaults)
        let afterSecond = ReviewPromptStateStorage.load(from: defaults)
        XCTAssertEqual(afterSecond.lastFrustrationAt, now, "the latest stamp wins — record overwrites, never accumulates")
        XCTAssertEqual(afterSecond.successfulProtectionOns, 4)
        XCTAssertEqual(afterSecond.promptTimestamps, [daysAgo(30)])
    }
}
