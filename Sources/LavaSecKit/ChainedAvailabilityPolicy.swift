import Foundation

/// Decides whether chained WireGuard upstream may run on this device.
///
/// Plan: lavasec-infra `plans/2026-07-22-vpn-upstream-chaining-implementation-plan.md`
/// (D2, as rewritten by the 2026-07-25 device-gate pivot). The type is named for the
/// plan's `ChainedAvailability`; the file carries the `Policy` suffix so it sits with the
/// other pure policy value types.
///
/// ## Why a device gate and not a rule cap
///
/// The pivot deleted the 1M chained-mode rule carve-out. Where chaining is available the
/// full Plus cap applies unchanged, so nothing here inspects rule counts — a filter the
/// user can hold is by definition within their tier. What the on-device measurement
/// actually showed (ios-internal #442) is that 2M + engine + load lands near the jetsam
/// cliff *on low-RAM devices*, so the axis is the device, not the filter.
///
/// ## Why RAM is a coarse cut, and what makes it safe
///
/// The NE memory ceiling is per-device-**model**, not RAM-scaled: it lives in
/// `com.apple.jetsamproperties.{Board}.plist`. RAM is therefore a proxy, and the pivot
/// required it to be backed by validated per-model limits before being trusted. That
/// backing exists: every A12 4 GB board (D321/D331/D331p, the oldest eligible hardware)
/// was measured at the standard 50 MB packet-tunnel limit, so no eligible device sits
/// under a lower ceiling than the engineering budget assumes.
///
/// ## Memory is the whole gate — do not add a model or SoC term
///
/// Settled by the founder on 2026-07-26, after the alternative was considered and rejected.
/// A generation floor is incoherent at the edges: this app targets iPhone *and* iPad, and
/// A12-class at iOS 18 includes 4 GB and 6 GB iPad Pros, so an "A13 or newer" rule would
/// exclude a 6 GB iPad Pro while admitting a 4 GB iPhone 11. It is also a rot surface —
/// there is no SoC API, so it means hardcoded `hw.machine` identifiers, a policy for every
/// future identifier, and a predicate that misbehaves in the simulator. `physicalMemory` is
/// forward-compatible by construction.
///
/// What protects hardware we have never measured is not a longer predicate: it is the
/// Phase-4 jetsam safety net, which decides from that device's own behaviour. If you are
/// here because you suspect a specific board misbehaves, the answer is field evidence and
/// the exclusion marker, not a new term above.
public enum ChainedAvailability {
    /// Physical-memory floor for chained mode, in bytes.
    ///
    /// Sits deliberately in the empty band between the two hardware clusters rather than
    /// on a marketing number: a "3 GB" device reports roughly 2.96 GB and a "4 GB" device
    /// roughly 3.89 GB, because `physicalMemory` excludes what firmware reserves. Any
    /// value between those two figures classifies identically; this one is stated in
    /// decimal GB to stay readable next to the reported values.
    public static let minimumPhysicalMemoryBytes: UInt64 = 3_400_000_000

    /// Why chained mode is unavailable, for logging and health state. Never user copy —
    /// the Phase-4/5 UI maps these to localized strings.
    public enum Ineligibility: String, Equatable, Sendable {
        /// Chaining is a Plus feature; the account is not entitled.
        case notEntitled
        /// The device is below the memory floor and the experimental override is off.
        case insufficientMemory
        /// Repeated same-build exits before chained forwarding was proven tripped the startup
        /// crash-loop breaker. A deliberate Guard start clears it.
        case startupCrashLoop = "startup-crash-loop"
    }

    /// The base hardware/tier check: `Plus ∧ (RAM ≥ floor ∨ experimental override)`.
    ///
    /// The override term is load-bearing, not decorative. It is what lets a user opt a
    /// sub-floor device in; omitting it anywhere the latch consults would restart such a
    /// device straight back into DNS-only and silently defeat the opt-in.
    ///
    /// - Parameters:
    ///   - hasLavaSecurityPlus: Entitlement from the shared configuration.
    ///   - physicalMemoryBytes: `ProcessInfo.processInfo.physicalMemory`.
    ///   - experimentalOverrideEnabled: The **device-local** opt-in. It is deliberately not
    ///     part of the synced configuration — a memory override is a property of one
    ///     device, so it must default off on every other device the account restores to.
    public static func satisfiesBaseCheck(
        hasLavaSecurityPlus: Bool,
        physicalMemoryBytes: UInt64,
        experimentalOverrideEnabled: Bool
    ) -> Bool {
        guard hasLavaSecurityPlus else { return false }
        return physicalMemoryBytes >= minimumPhysicalMemoryBytes || experimentalOverrideEnabled
    }

    /// The authoritative predicate for the start latch and the Settings toggle:
    /// `base ∧ ¬startupCrashLoop`.
    ///
    /// The exclusion term must be applied everywhere eligibility is decided. Without it an
    /// otherwise-eligible device would restart into the same pre-forwarding crash loop.
    public static func isEligible(
        hasLavaSecurityPlus: Bool,
        physicalMemoryBytes: UInt64,
        experimentalOverrideEnabled: Bool,
        hasStartupCrashLoopTripped: Bool
    ) -> Bool {
        ineligibilityReason(
            hasLavaSecurityPlus: hasLavaSecurityPlus,
            physicalMemoryBytes: physicalMemoryBytes,
            experimentalOverrideEnabled: experimentalOverrideEnabled,
            hasStartupCrashLoopTripped: hasStartupCrashLoopTripped
        ) == nil
    }

    /// The first reason chained mode is unavailable, or `nil` when the device is eligible.
    ///
    /// Order is entitlement → memory → startup loop, so the reported cause is the most
    /// durable one.
    public static func ineligibilityReason(
        hasLavaSecurityPlus: Bool,
        physicalMemoryBytes: UInt64,
        experimentalOverrideEnabled: Bool,
        hasStartupCrashLoopTripped: Bool
    ) -> Ineligibility? {
        guard hasLavaSecurityPlus else { return .notEntitled }
        guard physicalMemoryBytes >= minimumPhysicalMemoryBytes || experimentalOverrideEnabled else {
            return .insufficientMemory
        }
        guard !hasStartupCrashLoopTripped else { return .startupCrashLoop }
        return nil
    }

    // MARK: - Reconciling a stored preference

    /// What the app should do with a stored `chainedUpstreamEnabled` flag.
    public enum Reconcile: Equatable, Sendable {
        /// Leave the stored flag alone.
        case noChange
        /// Clear the stored flag; the device or account no longer qualifies.
        case disable(Ineligibility)
    }

    /// Whether an ineligibility cause should revoke the user's *stored preference*, as
    /// opposed to merely refusing to act on it this session.
    ///
    /// The two are deliberately different. Refusing is the latch's job and costs the user
    /// nothing — the next start re-evaluates. Clearing the flag is destructive: it forgets
    /// what they asked for, and only the user can ask again.
    ///
    /// - `notEntitled` and `insufficientMemory` clear it. Both are durable properties of the
    ///   account or the hardware, so leaving the flag set would leave a preference that can
    ///   never be honoured and a Settings toggle that reads on while nothing happens.
    /// - `startupCrashLoop` does **not**. A deliberate Guard start clears the device-local
    ///   breaker; clearing the saved setting would hide the mismatch instead of retrying it.
    public static func revokesStoredPreference(_ reason: Ineligibility) -> Bool {
        switch reason {
        case .notEntitled, .insufficientMemory:
            return true
        case .startupCrashLoop:
            return false
        }
    }

    /// The reconcile decision for a stored flag on this device.
    ///
    /// Returns `.noChange` when the flag is already off, so the caller can run this on every
    /// eligibility event without it ever being a write.
    public static func reconcile(
        chainedUpstreamEnabled: Bool,
        hasLavaSecurityPlus: Bool,
        physicalMemoryBytes: UInt64,
        experimentalOverrideEnabled: Bool,
        hasStartupCrashLoopTripped: Bool
    ) -> Reconcile {
        guard chainedUpstreamEnabled else { return .noChange }
        guard let reason = ineligibilityReason(
            hasLavaSecurityPlus: hasLavaSecurityPlus,
            physicalMemoryBytes: physicalMemoryBytes,
            experimentalOverrideEnabled: experimentalOverrideEnabled,
            hasStartupCrashLoopTripped: hasStartupCrashLoopTripped
        ) else {
            return .noChange
        }
        return revokesStoredPreference(reason) ? .disable(reason) : .noChange
    }
}
