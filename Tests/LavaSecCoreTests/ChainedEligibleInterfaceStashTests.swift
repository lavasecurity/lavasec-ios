import XCTest

@testable import LavaSecChainedUpstream

/// The path-monitor-to-engine-queue stash, and the identity-change signal it derives.
final class ChainedEligibleInterfaceStashTests: XCTestCase {
    private func bindable(_ name: String, _ kind: ChainedUpstreamLinkKind) -> ChainedBindableInterface {
        guard
            let interface = ChainedBindableInterface(
                ChainedUpstreamInterface(name: name, kind: kind))
        else {
            fatalError("test fixture built an ineligible interface: \(name)/\(kind)")
        }
        return interface
    }

    /// A settable clock so a test can age an absence without sleeping.
    ///
    /// NANOSECONDS, at full resolution: the boundary this type decides is a duration, and a
    /// whole-second fake could not express the sub-second interleavings that made the truncated
    /// implementation expire the grace window early (Codex, PR #576). The origin is deliberately
    /// NOT a whole second, so a test that accidentally reintroduces truncation sees the same
    /// straddled boundary a device would.
    private final class SteppableNanoseconds: @unchecked Sendable {
        private let lock = NSLock()
        private var nanoseconds: UInt64 = 1_000_990_000_000
        var read: @Sendable () -> UInt64 { { [self] in lock.withLock { nanoseconds } } }
        func advance(bySeconds amount: Double) {
            lock.withLock { nanoseconds &+= UInt64(amount * 1_000_000_000) }
        }
    }

    func testTheLatestReadReflectsTheLastUpdate() {
        let stash = ChainedEligibleInterfaceStash()
        XCTAssertNil(stash.latest(), "an empty stash must answer nil, not invent a binding")

        let wifi = bindable("en0", .wifi)
        stash.update(wifi)
        XCTAssertEqual(stash.latest(), wifi)

        stash.update(nil)
        XCTAssertNil(
            stash.latest(),
            "absence must be storable — a stale interface handed to a build after the path "
                + "lost every eligible interface binds a socket to a corpse")
    }

    func testOnlyAnIdentityChangeReportsAsChanged() {
        let stash = ChainedEligibleInterfaceStash()
        let wifi = bindable("en0", .wifi)
        let otherWifi = bindable("en1", .wifi)

        XCTAssertTrue(stash.update(wifi), "none-to-eligible is an identity change")
        XCTAssertFalse(
            stash.update(wifi),
            "a repeated satisfied callback with the same interface is NOT a change — "
                + "reporting it as one resets the silence clock on every callback and "
                + "postpones outage detection indefinitely")
        XCTAssertTrue(
            stash.update(otherWifi),
            "a same-kind interface REPLACEMENT (en0 to en1) is the change this signal "
                + "exists for — the bound socket is dead while kind and satisfied both "
                + "still match; a same-interface network roam stays the silence detector's")
        XCTAssertFalse(
            stash.update(nil),
            "eligible-to-none is NOT reported: the rebind it would trigger cannot build a "
                + "channel with no interface and falls through to a full outage on a link "
                + "that may not have moved — absence is stored for builds, never signalled")
        XCTAssertFalse(stash.update(nil), "none-to-none is not a change either")
    }

    func testATransientAbsenceFlipDoesNotReportAnIdentityChange() {
        let clock = SteppableNanoseconds()
        let stash = ChainedEligibleInterfaceStash(nowNanoseconds: clock.read)
        let wifi = bindable("en0", .wifi)

        stash.update(wifi)
        XCTAssertFalse(stash.update(nil), "the nil flank is never reported")
        clock.advance(bySeconds: Double(ChainedEligibleInterfaceStash.transientAbsenceGraceSeconds) - 1)
        XCTAssertFalse(
            stash.update(wifi),
            "the SAME interface restored inside the grace window is the path monitor "
                + "re-evaluating on stable Wi-Fi — reporting it spuriously rebinds a working "
                + "socket, the brief forwarding stall this hardening exists to remove")
        XCTAssertEqual(stash.latest(), wifi, "the restore is still stored for builds")
    }

    func testASustainedAbsenceReportsAChangeWhenTheInterfaceReturns() {
        let clock = SteppableNanoseconds()
        let stash = ChainedEligibleInterfaceStash(nowNanoseconds: clock.read)
        let wifi = bindable("en0", .wifi)

        stash.update(wifi)
        stash.update(nil)
        clock.advance(bySeconds: Double(ChainedEligibleInterfaceStash.transientAbsenceGraceSeconds))
        XCTAssertTrue(
            stash.update(wifi),
            "an interface that was genuinely gone for the whole grace window may have a "
                + "dead socket bound to it — the restore must rebind rather than wait out "
                + "the 21 s silence detector")
    }

    func testARepeatedNilKeepsTheOriginalAbsenceFlank() {
        let clock = SteppableNanoseconds()
        let stash = ChainedEligibleInterfaceStash(nowNanoseconds: clock.read)
        let wifi = bindable("en0", .wifi)

        stash.update(wifi)
        stash.update(nil)
        clock.advance(bySeconds: Double(ChainedEligibleInterfaceStash.transientAbsenceGraceSeconds) - 1)
        stash.update(nil)
        clock.advance(bySeconds: 1)
        XCTAssertTrue(
            stash.update(wifi),
            "the absence began at the FIRST nil — a repeated nil callback must not restart "
                + "the grace window, or a monitor re-delivering absence keeps a dead "
                + "interface's restore forever unreported")
    }

    func testAnAbsenceJustUnderTheGraceIsSuppressedAcrossASecondBoundary() {
        // CODEX'S CASE (PR #576), and the reason this comparison is not allowed to truncate.
        // With both ends floored to whole seconds, an absence beginning at uptime 1000.99 and
        // restoring at 1003.01 reads as 1003 - 1000 = 3 and EXPIRES a window that really covered
        // 2.02 s — so the sub-three-second transient this type exists to suppress gets reported,
        // and fires exactly the spurious rebind the slice removes. The fake's origin straddles a
        // second boundary on purpose, so a reintroduced truncation reddens here.
        let clock = SteppableNanoseconds()  // origin 1000.99 s
        let stash = ChainedEligibleInterfaceStash(nowNanoseconds: clock.read)
        let wifi = bindable("en0", .wifi)

        stash.update(wifi)
        stash.update(nil)
        clock.advance(bySeconds: 2.02)  // → 1003.01: floors to 3, measures 2.02
        XCTAssertFalse(
            stash.update(wifi),
            "a 2.02 s absence was reported as an identity change — the grace window is being "
                + "measured on truncated seconds, so it expires up to a second early and lets "
                + "through the transient flip it exists to suppress")
    }

    func testAnAbsenceJustOverTheGraceStillReportsAcrossASecondBoundary() {
        // The other side of the same boundary, so the fix cannot be "never report": 3.01 s of
        // real absence must still rebind, whatever the second boundaries do.
        let clock = SteppableNanoseconds()
        let stash = ChainedEligibleInterfaceStash(nowNanoseconds: clock.read)
        let wifi = bindable("en0", .wifi)

        stash.update(wifi)
        stash.update(nil)
        clock.advance(bySeconds: 3.01)
        XCTAssertTrue(
            stash.update(wifi),
            "a genuinely sustained absence stopped reporting — suppressing it leaves a dead "
                + "socket bound until the 21 s silence detector")
    }

    func testADifferentIdentityAfterAnAbsenceReportsImmediately() {
        let clock = SteppableNanoseconds()
        let stash = ChainedEligibleInterfaceStash(nowNanoseconds: clock.read)

        stash.update(bindable("en0", .wifi))
        stash.update(nil)
        XCTAssertTrue(
            stash.update(bindable("pdp_ip0", .cellular)),
            "a REPLACEMENT arriving out of an absence is a real identity change however "
                + "fresh the absence is — delaying it would add the grace window to every "
                + "roam recovery")
    }
}
