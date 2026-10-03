import XCTest

@testable import LavaSecKit

/// `EntitlementApplicationPolicy` decides the paid-plan flag to persist from a freshly-read entitlement.
/// The one rule under test: a previously-entitled user is demoted ONLY by a `.confirmed` reading — a
/// bare, possibly-cold `Transaction.currentEntitlements` pass (`.unconfirmed`) that comes back empty must
/// keep the stored entitlement, so a transient StoreKit cache miss cannot silently strip a paying
/// subscriber. Pure → behavioral.
final class EntitlementApplicationPolicyTests: XCTestCase {
    private func resolve(
        computed: Bool, persisted: Bool, _ confidence: EntitlementReadingConfidence
    ) -> Bool {
        EntitlementApplicationPolicy.resolvedHasLavaSecurityPlus(
            computed: computed, persisted: persisted, confidence: confidence)
    }

    // MARK: - The fix: an unconfirmed empty reading never demotes a paid user

    func testAnUnconfirmedEmptyReadingKeepsAPaidUser() {
        // persisted Plus + a bare currentEntitlements pass that came back empty (cold/unsynced cache) →
        // KEEP Plus. This is the whole bug: without it, a single transient empty read at cold start
        // freezes over-cap filters, drops the Plus UI to Free, and (post-Phase-4) destructively clears
        // the chaining preference that no re-grant restores.
        XCTAssertTrue(resolve(computed: false, persisted: true, .unconfirmed))
    }

    func testAConfirmedEmptyReadingDemotesAPaidUser() {
        // An authoritative negative (restore after AppStore.sync, or a Transaction.updates push) IS a
        // real lapse — the confirmed-lapse contract must still demote.
        XCTAssertFalse(resolve(computed: false, persisted: true, .confirmed))
    }

    // MARK: - Positive readings always apply (you cannot spuriously BECOME entitled)

    func testAnUnconfirmedActiveReadingUpgradesAFreeUser() {
        XCTAssertTrue(resolve(computed: true, persisted: false, .unconfirmed))
    }

    func testAConfirmedActiveReadingUpgradesAFreeUser() {
        XCTAssertTrue(resolve(computed: true, persisted: false, .confirmed))
    }

    // MARK: - No-change cases pass the computed value through unchanged (caller's guard suppresses the write)

    func testAlreadyPaidStaysPaidRegardlessOfConfidence() {
        XCTAssertTrue(resolve(computed: true, persisted: true, .unconfirmed))
        XCTAssertTrue(resolve(computed: true, persisted: true, .confirmed))
    }

    func testAlreadyFreeStaysFreeRegardlessOfConfidence() {
        XCTAssertFalse(resolve(computed: false, persisted: false, .unconfirmed))
        XCTAssertFalse(resolve(computed: false, persisted: false, .confirmed))
    }

    // MARK: - Confidence escalation must re-deliver a same-valued confirmed reading

    private func deliver(
        _ valueChanged: Bool,
        new: EntitlementReadingConfidence,
        previous: EntitlementReadingConfidence
    ) -> Bool {
        EntitlementApplicationPolicy.shouldDeliverReading(
            valueChanged: valueChanged, newConfidence: new, previousConfidence: previous)
    }

    func testAConfirmedReadingSupersedesAnUnconfirmedSameValueReading() {
        // The P1: an unconfirmed empty read (kept, not demoted) has set the value to inactive; a later
        // confirmed inactive from Transaction.updates is value-identical, so a value-only guard would
        // swallow it and the real lapse would never demote. It MUST be delivered.
        XCTAssertTrue(deliver(false, new: .confirmed, previous: .unconfirmed))
    }

    func testASameValueReadingIsDedupedOnceItsConfidenceIsAlreadyConfirmed() {
        XCTAssertFalse(deliver(false, new: .confirmed, previous: .confirmed))
    }

    func testASameValueUnconfirmedReadingIsAlwaysDeduped() {
        XCTAssertFalse(deliver(false, new: .unconfirmed, previous: .unconfirmed))
        // A lower-confidence re-read of a value already confirmed is not worth re-delivering.
        XCTAssertFalse(deliver(false, new: .unconfirmed, previous: .confirmed))
    }

    func testAValueChangeAlwaysDelivers() {
        XCTAssertTrue(deliver(true, new: .unconfirmed, previous: .unconfirmed))
        XCTAssertTrue(deliver(true, new: .confirmed, previous: .confirmed))
    }

    // MARK: - Full truth table (mutation guard: every cell pinned to a literal)

    func testTheFullTruthTable() {
        // (computed, persisted, confidence) -> expected persisted flag.
        // Only ONE cell differs from `computed`: demote-from-entitled on an unconfirmed read.
        XCTAssertEqual(resolve(computed: false, persisted: true, .unconfirmed), true, "keep")
        XCTAssertEqual(resolve(computed: false, persisted: true, .confirmed), false, "confirmed demote")
        XCTAssertEqual(resolve(computed: true, persisted: false, .unconfirmed), true, "upgrade")
        XCTAssertEqual(resolve(computed: true, persisted: false, .confirmed), true, "upgrade")
        XCTAssertEqual(resolve(computed: true, persisted: true, .unconfirmed), true, "no-op")
        XCTAssertEqual(resolve(computed: true, persisted: true, .confirmed), true, "no-op")
        XCTAssertEqual(resolve(computed: false, persisted: false, .unconfirmed), false, "no-op")
        XCTAssertEqual(resolve(computed: false, persisted: false, .confirmed), false, "no-op")
    }
}
