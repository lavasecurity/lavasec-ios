import XCTest
@testable import LavaSecCore

/// Behavioural harness for the configuration-replacement supersession invariant.
///
/// `AppViewModel`'s filter switch, backup restore, and shared-config import each replace the
/// live configuration + filter library wholesale and suspend at an `await` mid-flight. The
/// gate is what stops the operation that *resumes last* from silently reverting whatever
/// committed while it was suspended. These tests drive the gate through the exact begin /
/// suspend / re-check orderings those operations interleave in — converting the invariant
/// from a source-introspection assertion into executed behaviour.
final class ExclusiveReplacementGateTests: XCTestCase {

    /// Models one wholesale replacer: it claims a token (`begin`), later reaches its commit
    /// gate, and either COMMITS (still the current owner) or BAILS (a newer replacement
    /// superseded it) — exactly the `guard configurationReplacementGate.isCurrent(token)` gate
    /// in `switchToFilter` / `restoreEncryptedBackup` / `applyImportedShareableConfiguration`.
    private struct Replacer {
        let token: Int
        func wouldCommit(against gate: ExclusiveReplacementGate) -> Bool {
            gate.isCurrent(token)
        }
    }

    private func begin(_ gate: inout ExclusiveReplacementGate) -> Replacer {
        Replacer(token: gate.begin())
    }

    // MARK: - Epoch mechanics

    func testBeginAdvancesEpochMonotonically() {
        var gate = ExclusiveReplacementGate()
        XCTAssertEqual(gate.epoch, 0)
        XCTAssertEqual(gate.begin(), 1)
        XCTAssertEqual(gate.begin(), 2)
        XCTAssertEqual(gate.begin(), 3)
        XCTAssertEqual(gate.epoch, 3)
    }

    func testFreshlyClaimedTokenIsCurrent() {
        var gate = ExclusiveReplacementGate()
        let token = gate.begin()
        XCTAssertTrue(gate.isCurrent(token))
    }

    func testEpochZeroIsCurrentForNoReplacement() {
        // No replacer has run; nothing should ever have claimed token 0, but the initial epoch
        // is 0 so an (impossible) token-0 holder reads as current. Real callers always begin()
        // first, so they hold >= 1; this just documents the initial state.
        let gate = ExclusiveReplacementGate()
        XCTAssertEqual(gate.epoch, 0)
    }

    // MARK: - Overlapping switches (the original race)

    func testLaterSwitchSupersedesEarlierOverlappingSwitch() {
        var gate = ExclusiveReplacementGate()
        // switch A claims, then suspends at prepare.
        let switchA = begin(&gate)
        // switch B (a second rapid `Use` tap) claims while A is suspended.
        let switchB = begin(&gate)

        // A resumes: superseded, so it must NOT commit or roll back.
        XCTAssertFalse(switchA.wouldCommit(against: gate))
        // B resumes: still the owner, commits.
        XCTAssertTrue(switchB.wouldCommit(against: gate))
    }

    // MARK: - Switch vs restore (the headline P1)

    func testRestoreCompletingDuringSuspendedSwitchIsNotReverted() {
        var gate = ExclusiveReplacementGate()
        // A switch claims and suspends at `await prepareFilterSnapshot`.
        let switchOp = begin(&gate)
        // A restore starts in Settings while the switch is suspended: it claims the token at
        // entry (superseding the suspended switch) and runs to completion.
        let restoreOp = begin(&gate)
        XCTAssertTrue(restoreOp.wouldCommit(against: gate), "Restore owns the configuration and commits.")

        // The switch's prepare returns and it reaches its commit gate: superseded → bails,
        // so the just-completed restore survives instead of being reverted.
        XCTAssertFalse(switchOp.wouldCommit(against: gate), "Resuming switch must bail, not clobber the restore.")
    }

    func testSwitchStartingDuringSuspendedRestoreSupersedesRestore() {
        var gate = ExclusiveReplacementGate()
        // A restore claims at entry and suspends at `await loadAvailableEncryptedBackupEnvelope`.
        let restoreOp = begin(&gate)
        // A switch starts while the restore awaits its envelope/unlock and suspends at prepare.
        let switchOp = begin(&gate)

        // The restore's unlock returns and it reaches its re-check before any disk write:
        // superseded → it aborts (throws supersededByConcurrentConfigurationChange) instead of
        // writing a stale configuration the switch would then have to fight.
        XCTAssertFalse(restoreOp.wouldCommit(against: gate), "Resuming restore must abort under a newer switch.")
        // The switch is the current owner and commits.
        XCTAssertTrue(switchOp.wouldCommit(against: gate))
    }

    // MARK: - Switch rollback is guarded too

    func testSwitchRollbackBailsWhenRestoreInterleavesBeforeIt() {
        var gate = ExclusiveReplacementGate()
        // A switch claims, passes its commit gate, then its persist THROWS.
        let switchOp = begin(&gate)
        XCTAssertTrue(switchOp.wouldCommit(against: gate))
        // Before the switch's catch block rolls back, a restore starts and claims the token.
        let restoreOp = begin(&gate)
        // The rollback gate (`isCurrent`) now fails, so the switch does NOT restore its
        // pre-switch config/library over the restore.
        XCTAssertFalse(switchOp.wouldCommit(against: gate), "Switch rollback must not clobber an interleaved restore.")
        XCTAssertTrue(restoreOp.wouldCommit(against: gate))
    }

    // MARK: - Import participates in the same epoch

    func testImportSwitchRestoreShareOneEpoch() {
        var gate = ExclusiveReplacementGate()
        let importOp = begin(&gate)    // import claims, suspends at prepare
        let switchOp = begin(&gate)    // switch supersedes import
        let restoreOp = begin(&gate)   // restore supersedes switch

        XCTAssertFalse(importOp.wouldCommit(against: gate))
        XCTAssertFalse(switchOp.wouldCommit(against: gate))
        XCTAssertTrue(restoreOp.wouldCommit(against: gate), "Only the newest replacement commits.")
    }

    // MARK: - Cover ownership (the stuck-spinner fix)

    func testCoverOwnershipTracksTheCurrentOwner() {
        var gate = ExclusiveReplacementGate()
        XCTAssertFalse(gate.currentOwnerOwnsPreparationCover)
        _ = gate.begin(ownsPreparationCover: true)    // a switch / draft apply
        XCTAssertTrue(gate.currentOwnerOwnsPreparationCover)
        _ = gate.begin(ownsPreparationCover: false)   // a restore / import supersedes
        XCTAssertFalse(gate.currentOwnerOwnsPreparationCover, "A non-cover-driver taking ownership clears it.")
        _ = gate.begin(ownsPreparationCover: true)    // a switch supersedes again
        XCTAssertTrue(gate.currentOwnerOwnsPreparationCover)
    }

    func testSupersededCoverDriverDismissesOnlyWhenNewOwnerIsNonCoverDriver() {
        // Switch superseded by a restore/import (non-cover-driver): the restore never drives the
        // preparation cover, so the superseded switch must dismiss the cover it put up itself.
        var byRestore = ExclusiveReplacementGate()
        let switchA = byRestore.begin(ownsPreparationCover: true)
        _ = byRestore.begin(ownsPreparationCover: false) // restore
        XCTAssertFalse(byRestore.isCurrent(switchA))
        XCTAssertFalse(byRestore.currentOwnerOwnsPreparationCover, "Superseded switch must dismiss its own cover.")

        // Switch superseded by another switch (cover-driver): the newer switch owns the cover and
        // will manage it, so the superseded one leaves it alone.
        var bySwitch = ExclusiveReplacementGate()
        let switchB = bySwitch.begin(ownsPreparationCover: true)
        _ = bySwitch.begin(ownsPreparationCover: true)   // another switch
        XCTAssertFalse(bySwitch.isCurrent(switchB))
        XCTAssertTrue(bySwitch.currentOwnerOwnsPreparationCover, "Superseded switch leaves the cover to the newer switch.")
    }

    // MARK: - Non-interleaved sequential operations both commit

    func testSequentialNonOverlappingReplacersEachCommit() {
        var gate = ExclusiveReplacementGate()
        // First replacer runs start-to-finish with no overlap.
        let first = begin(&gate)
        XCTAssertTrue(first.wouldCommit(against: gate))
        // Then a second, fully after the first: also the current owner at its own commit.
        let second = begin(&gate)
        XCTAssertTrue(second.wouldCommit(against: gate))
    }
}
