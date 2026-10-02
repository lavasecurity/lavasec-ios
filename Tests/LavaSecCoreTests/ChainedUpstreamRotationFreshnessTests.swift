import XCTest

@testable import LavaSecKit

/// Whether the live chained session is running the upstream rotation the store now holds.
///
/// Real behavioural tests rather than pins, because the subject is a pure value type — the repo
/// rule for policy logic. It is also the half of task #21 that has to be right for the panel to
/// be right: PR #607 tried four UI shapes against a missing signal and every one of them failed,
/// so the signal's own semantics get tested before anything renders them.
final class ChainedUpstreamRotationFreshnessTests: XCTestCase {
    private func verdict(
        latched: UInt64,
        stored: ChainedUpstreamRotationFreshness.StoredRotation
    ) -> ChainedUpstreamRotationFreshness.Verdict {
        ChainedUpstreamRotationFreshness.verdict(
            runningGeneration: latched, storedRotation: stored)
    }

    /// The whole point: a session running what is stored is current.
    func testASessionRunningTheStoredRotationIsCurrent() {
        XCTAssertEqual(verdict(latched: 7, stored: .present(generation: 7)), .current)
    }

    /// The case nothing could report before the generation was published.
    ///
    /// `resolverSelectionFingerprint` is deliberately unmoved by a rotation that replaces only
    /// the endpoint and keys, so every existing surface reported agreement while the session
    /// handshaked against a peer the stored configuration no longer named.
    func testAMovedStoredRotationAwaitsARestart() {
        XCTAssertEqual(
            verdict(latched: 7, stored: .present(generation: 8)),
            .awaitingRestart(latched: 7, stored: 8))
    }

    /// INEQUALITY, NOT ORDERING. The generation is drawn from eight random bytes, not counted,
    /// so a later rotation is as likely to be numerically smaller as larger — a `>` comparison
    /// would call a freshly saved rotation "current" about half the time (Codex P3, PR #613).
    /// This case is that half.
    func testAStoredRotationThatWentBackwardsIsStillAChange() {
        XCTAssertEqual(
            verdict(latched: 9, stored: .present(generation: 4)),
            .awaitingRestart(latched: 9, stored: 4))
    }

    /// Removal does not stop a live session, so it is a definite change and not an unknown —
    /// the same call `ChainedFallbackFreshness.StoredConfiguration.absent` makes.
    func testARemovedStoreLeavesTheSessionRunningTheRotationItLatched() {
        XCTAssertEqual(
            verdict(latched: 7, stored: .absent), .runningRemovedRotation(latched: 7))
    }

    /// A locked Keychain is ignorance, never agreement and never a change.
    func testAnUnreadableStoreIsUnknownRatherThanEitherVerdict() {
        XCTAssertEqual(verdict(latched: 7, stored: .unreadable), .unknown)
    }

    /// `0` IS "NONE OR UNKNOWN", and it has to short-circuit before the store is consulted.
    ///
    /// This is the regression that would put a restart warning on the configuration screen of
    /// every DNS-only session — the feature not even running — about a change nobody made.
    func testNoLatchedRotationIsSilentWhateverTheStoreHolds() {
        XCTAssertEqual(verdict(latched: 0, stored: .present(generation: 8)), .noChainedSession)
        XCTAssertEqual(verdict(latched: 0, stored: .absent), .noChainedSession)
        XCTAssertEqual(verdict(latched: 0, stored: .unreadable), .noChainedSession)
    }

    /// A snapshot decoded from a build that predates the field carries `0`, so an upgrade must
    /// not manufacture a warning out of a field the old session never wrote.
    func testASnapshotFromABuildWithoutTheFieldSurfacesNothing() {
        let decoded = TunnelHealthSnapshot()
        XCTAssertEqual(decoded.runningChainedUpstreamGeneration, 0)
        XCTAssertFalse(
            verdict(latched: decoded.runningChainedUpstreamGeneration,
                    stored: .present(generation: 3)).deservesSurfacing)
    }

    /// SILENT WHEN NOTHING IS WRONG, and specifically silent on `unknown`: a pre-first-unlock
    /// Keychain is the ordinary condition, and rendering it would warn every user who opens
    /// Settings before unlocking about a change that has not happened.
    func testOnlyTheTwoActionableVerdictsSurface() {
        XCTAssertTrue(verdict(latched: 7, stored: .present(generation: 8)).deservesSurfacing)
        XCTAssertTrue(verdict(latched: 7, stored: .absent).deservesSurfacing)
        XCTAssertFalse(verdict(latched: 7, stored: .present(generation: 7)).deservesSurfacing)
        XCTAssertFalse(verdict(latched: 7, stored: .unreadable).deservesSurfacing)
        XCTAssertFalse(verdict(latched: 0, stored: .absent).deservesSurfacing)
    }

    /// Every surfacing verdict must actually have copy, or the panel renders an empty card.
    func testEverySurfacingVerdictCarriesCopy() {
        for verdict: ChainedUpstreamRotationFreshness.Verdict in [
            .awaitingRestart(latched: 7, stored: 8), .runningRemovedRotation(latched: 7),
        ] {
            XCTAssertFalse(verdict.title.isEmpty)
            XCTAssertFalse(verdict.detail.isEmpty)
            XCTAssertTrue(verdict.isActionable)
        }
    }

    /// The silent verdicts carry none, so a future caller that renders without checking
    /// `deservesSurfacing` produces an empty panel rather than a confident wrong sentence.
    func testTheSilentVerdictsCarryNoCopy() {
        for verdict: ChainedUpstreamRotationFreshness.Verdict in [
            .noChainedSession, .current, .unknown,
        ] {
            XCTAssertTrue(verdict.title.isEmpty)
            XCTAssertTrue(verdict.detail.isEmpty)
        }
    }

    /// THE REMOVED-STORE COPY MUST NOT SAY "RESTART". There is nothing to restart into: the
    /// store is empty, so following that instruction ends in a DNS-only tunnel the user did not
    /// ask for. The two verdicts exist separately precisely to keep these remedies apart.
    func testTheRemovedRotationCopyDoesNotTellTheUserToRestartIntoNothing() {
        let removed = ChainedUpstreamRotationFreshness.Verdict
            .runningRemovedRotation(latched: 7).detail
        XCTAssertTrue(removed.contains("Turn protection off"))
        XCTAssertTrue(removed.contains("import"))
        XCTAssertFalse(removed.lowercased().contains("off and on"))

        let moved = ChainedUpstreamRotationFreshness.Verdict
            .awaitingRestart(latched: 7, stored: 8).detail
        XCTAssertTrue(moved.lowercased().contains("off and on"))
    }

    /// NEITHER STRING NAMES THE GENERATION. The numbers decide the verdict and mean nothing to
    /// the reader; they belong in the health snapshot and the `data-path-latched` log, which is
    /// where the diagnostic consumer reads them.
    func testTheCopyNeverShowsTheUserAGenerationNumber() {
        for verdict: ChainedUpstreamRotationFreshness.Verdict in [
            .awaitingRestart(latched: 7, stored: 8), .runningRemovedRotation(latched: 7),
        ] {
            XCTAssertFalse(verdict.detail.contains("7"))
            XCTAssertFalse(verdict.detail.contains("8"))
            XCTAssertFalse(verdict.title.contains("7"))
            XCTAssertFalse(verdict.title.contains("8"))
        }
    }
}
