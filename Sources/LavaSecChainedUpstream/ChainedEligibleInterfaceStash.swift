import Foundation

/// The latest eligible physical interface, stashed by the path monitor for the engine queue.
///
/// One of the deliberate cracks in the queue story, like `ChainedAdmissionGauge`: the
/// provider's path handler runs on `dnsStateQueue`, while the factory's `currentInterface`
/// closure runs inline on the engine queue mid-build — and neither may hop to the other's
/// queue (`INV-QUEUE-1`; an engine-queue read that waits on `dnsStateQueue` can deadlock
/// against a path-change hop waiting on the engine queue). Fields behind an `NSLock`
/// instead, checked on the caller's thread.
///
/// `update` answers whether the interface IDENTITY changed — identity being the name+kind
/// pair `ChainedBindableInterface` equality compares — which is the `interfacesChanged`
/// signal `ChainedOutageDriver.pathChanged(satisfied:interfacesChanged:)` asks the wiring
/// for: interface REPLACEMENT (`en0` to `en1`, a kind change) that kind/satisfied
/// comparisons cannot see. What no identity comparison can see is a same-interface network
/// roam — a different Wi-Fi network on the same `en0` — which stays the 21 s silence
/// detector's job, exactly as `ChainedUpstreamSocketLifecycle` records.
///
/// ## A transient absence is NOT an identity change, and that is a field lesson
///
/// The first version reported eligible-to-none and none-to-back-to-eligible as two identity
/// changes each. On stable Wi-Fi the path monitor can deliver a satisfied callback whose
/// interface list momentarily carries no eligible physical interface — the used interface
/// re-evaluating, or a virtual interface briefly heading the list — and then restore the SAME
/// `en0` on the next callback. Each flank fired `pathChanged(interfacesChanged: true)` into a
/// working tunnel: the nil flank's `attemptRebind` cannot build a channel with no interface,
/// so it fell through to `beginOutage` — a full session teardown on a link that never moved —
/// and the restore flank swapped the socket again. Both present as a brief forwarding stall
/// the 60 s counters cannot attribute (brief-stall investigation, 2026-08-24).
///
/// So absence is stored (builds must refuse against it — see `latest()`) but never REPORTED,
/// and a restore is compared against the last non-nil identity: the same interface coming
/// back inside ``transientAbsenceGraceSeconds`` is the monitor re-evaluating, not a
/// replacement. A restore after a LONGER absence still reports a change — an interface that
/// was genuinely gone for seconds may have a dead socket bound to it, and one spurious
/// keepalive-priced rebind is cheaper than waiting out the silence detector.
///
/// A loss that UNSATISFIES the path is unaffected either way: it flips `satisfied`, and the
/// driver's offline latch owns that transition regardless of this signal
/// (`ChainedOutageDriver.pathChanged` recovers on `wasOffline || interfacesChanged`, so the
/// suppressed flank cannot suppress an offline recovery). What this DOES cost is stated rather
/// than glossed, because it is a real interval and the sentence here used to claim otherwise:
/// an interface that genuinely dies and returns under the SAME name+kind inside the grace
/// window, while the path stays satisfied through some other interface, is no longer torn down
/// promptly — its dead socket is caught by the 21 s silence/wedge detector instead of by an
/// immediate `beginOutage`, so recovery is up to ~15 s later than before. That is the same
/// class as the same-interface network roam this type already delegates to the silence
/// detector, it is bounded by the grace window, and it is bought with the thing the old
/// behaviour cost every stable-Wi-Fi flap: a full session teardown and a spent outage rung.
/// pinned: ChainedEligibleInterfaceStashTests.testATransientAbsenceFlipDoesNotReportAnIdentityChange
/// pinned: ChainedEligibleInterfaceStashTests.testASustainedAbsenceReportsAChangeWhenTheInterfaceReturns
///
/// SINGLE WRITER, by obligation rather than mechanism: updates come from the path monitor's
/// one serial queue. The `NSLock` prevents torn reads; it cannot order two writer queues,
/// so a second writer would let an older path callback overwrite a newer one.
public final class ChainedEligibleInterfaceStash: @unchecked Sendable {
    /// How long an eligible-to-none flip may last and still be treated as the path monitor
    /// re-evaluating rather than the interface going away.
    ///
    /// Three seconds, mirroring `ChainedOutageDriver.pathRecoverySettleSeconds`: flips faster
    /// than the driver's own settle window are exactly the burst that window exists to
    /// coalesce, so reporting them as identity changes hands the driver work its own rate
    /// bound says is churn. Not a cross-type constant reference because the two are separate
    /// judgements that happen to share a magnitude — the settle window bounds SOCKET work per
    /// transition, this bounds what counts as a transition at all.
    public static let transientAbsenceGraceSeconds = 3

    /// The same window in the denomination the comparison actually runs in.
    ///
    /// MEASURED IN NANOSECONDS, NOT WHOLE SECONDS, and that is a correctness fix rather than a
    /// precision preference. Both ends used to be truncated to whole seconds, so the interval
    /// between them could read a full second short: an absence beginning at uptime 1000.99
    /// recorded 1000, a restore at 1003.01 recorded 1003, and the difference of 3 expired a
    /// grace window that had really covered 2.02 s — reporting an identity change for exactly
    /// the sub-three-second transient this type exists to suppress, and firing the spurious
    /// rebind with it. Truncation is harmless for a heuristic that only has to be roughly
    /// right; this one decides a boundary, so it is measured exactly (Codex, PR #576).
    /// pinned: ChainedEligibleInterfaceStashTests.testAnAbsenceJustUnderTheGraceIsSuppressedAcrossASecondBoundary
    static let transientAbsenceGraceNanoseconds =
        UInt64(transientAbsenceGraceSeconds) &* 1_000_000_000

    private let lock = NSLock()
    private var stored: ChainedBindableInterface?
    /// The last non-nil identity ever stored — what a restore is compared against, so a
    /// nil-then-same flip is recognizable as no change at all.
    private var lastEligible: ChainedBindableInterface?
    /// When the current absence began, on `nowNanoseconds`'s clock. Set on the eligible-to-none
    /// flank only (a repeated nil keeps the ORIGINAL flank — the absence started when it
    /// started); cleared by any non-nil update.
    private var absenceBeganAtNanoseconds: UInt64?
    /// Injected so a test can age an absence without sleeping. The default is the device
    /// UPTIME base — the same base the driver's clock and settle window run on, so an absence
    /// spanning a suspension reads as short and defers to the wake path's own rebuild
    /// machinery rather than double-triggering it. Read at full resolution; see
    /// ``transientAbsenceGraceNanoseconds`` for why the truncated form was wrong.
    private let nowNanoseconds: @Sendable () -> UInt64

    public init(
        nowNanoseconds: @escaping @Sendable () -> UInt64 = {
            DispatchTime.now().uptimeNanoseconds
        }
    ) {
        self.nowNanoseconds = nowNanoseconds
    }

    /// Stores the latest eligible binding — or its absence — and reports an identity change.
    ///
    /// Same-to-same is never a change: `NWPathMonitor` delivers repeated satisfied updates
    /// for reasons that are not transitions, and reporting each as a change would
    /// re-handshake — and reset the silence clock — on every callback, postponing outage
    /// detection indefinitely (the driver's `testAnUnpairedWakeDoesNotPostponeDetection`
    /// class, through the door beside it).
    /// pinned: ChainedEligibleInterfaceStashTests.testOnlyAnIdentityChangeReportsAsChanged
    ///
    /// Absence is stored but not reported, and a same-identity restore inside the grace
    /// window is not reported either — see the type doc for the stable-Wi-Fi stall this
    /// prevents. A DIFFERENT identity always reports immediately, absence or no: delaying a
    /// real replacement would add its delay to every roam recovery.
    @discardableResult
    public func update(_ interface: ChainedBindableInterface?) -> Bool {
        lock.withLock {
            guard let interface else {
                if stored != nil { absenceBeganAtNanoseconds = nowNanoseconds() }
                stored = nil
                return false
            }
            let changed: Bool
            if interface != lastEligible {
                changed = true
            } else if let began = absenceBeganAtNanoseconds {
                // `&-` for the reason the clock file gives: a trap inside a Network Extension is
                // a tunnel abort, and this base is monotonic so the subtraction cannot legitimately
                // go backwards anyway.
                changed = nowNanoseconds() &- began >= Self.transientAbsenceGraceNanoseconds
            } else {
                changed = false
            }
            stored = interface
            lastEligible = interface
            absenceBeganAtNanoseconds = nil
            return changed
        }
    }

    /// The per-build read, from any queue. `nil` means no eligible physical interface —
    /// the factory maps that to its transient `.noEligibleInterface`. Absence stays HONEST
    /// here even though `update` does not report it: a stale interface handed to a build
    /// after the path lost every eligible interface would bind a socket to a corpse.
    public func latest() -> ChainedBindableInterface? {
        lock.withLock { stored }
    }
}
