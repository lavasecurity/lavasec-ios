import XCTest

import LavaSecKit

/// Slice 1 of `lavasec-infra/plans/2026-09-01-chained-enablement-supervised-not-latched.md`:
/// name the states once, so every surface derives from the same answer instead of maintaining its
/// own decision table.
final class ChainedSurfaceStateTests: XCTestCase {
    private func inputs(
        hasEntitlement: Bool = true,
        preferenceEnabled: Bool = true,
        deviceStateIsUnreadable: Bool = false,
        ineligibility: ChainedAvailability.Ineligibility? = nil,
        isSurrenderSuppressed: Bool = false,
        storeIsUnreadable: Bool = false,
        hasStoredConfiguration: Bool = true,
        storedConfigurationIsMissingKey: Bool = false
    ) -> ChainedSurfaceInputs {
        ChainedSurfaceInputs(
            hasEntitlement: hasEntitlement,
            preferenceEnabled: preferenceEnabled,
            deviceStateIsUnreadable: deviceStateIsUnreadable,
            ineligibility: ineligibility,
            isSurrenderSuppressed: isSurrenderSuppressed,
            storeIsUnreadable: storeIsUnreadable,
            hasStoredConfiguration: hasStoredConfiguration,
            storedConfigurationIsMissingKey: storedConfigurationIsMissingKey)
    }

    /// Every combination, exhaustively. This is the invariant PR #636 had to enforce by editing
    /// string literals: a preference the user left ON is never summarised with the disabled token,
    /// and a preference they turned OFF is never summarised as on.
    func testTheSummaryNeverContradictsTheUsersSetting() {
        let ineligibilities: [ChainedAvailability.Ineligibility?] = [
            nil, .notEntitled, .insufficientMemory, .startupCrashLoop,
        ]
        var seen = Set<ChainedOperationalState>()
        for hasEntitlement in [true, false] {
            for preferenceEnabled in [true, false] {
                for deviceStateIsUnreadable in [true, false] {
                    for ineligibility in ineligibilities {
                        for isSurrenderSuppressed in [true, false] {
                            for storeIsUnreadable in [true, false] {
                                for hasStoredConfiguration in [true, false] {
                                    for missingKey in [true, false] {
                                        let input = inputs(
                                            hasEntitlement: hasEntitlement,
                                            preferenceEnabled: preferenceEnabled,
                                            deviceStateIsUnreadable: deviceStateIsUnreadable,
                                            ineligibility: ineligibility,
                                            isSurrenderSuppressed: isSurrenderSuppressed,
                                            storeIsUnreadable: storeIsUnreadable,
                                            hasStoredConfiguration: hasStoredConfiguration,
                                            storedConfigurationIsMissingKey: missingKey)
                                        let state = ChainedOperationalState.resolve(input)
                                        seen.insert(state)
                                        switch ChainedSurfaceSummary(state) {
                                        case .settingOn:
                                            XCTAssertTrue(
                                                preferenceEnabled,
                                                "summarised the setting as ON for a preference the "
                                                    + "user turned off: \(state)")
                                        case .settingOff:
                                            XCTAssertFalse(
                                                preferenceEnabled,
                                                "summarised the setting as OFF while the "
                                                    + "preference was on: \(state)")
                                        case .unavailable:
                                            // Availability statements claim nothing either way.
                                            break
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
        // Every state must be reachable, or the enum is describing something the resolver cannot
        // produce and a surface is carrying dead copy for it.
        for state: ChainedOperationalState in [
            .notEntitled, .unsupportedDevice, .deviceStateUnreadable, .preferenceOff,
            .suspendedAfterStartupFailure, .suspendedAfterSurrender, .storeUnreadable,
            .noUpstreamConfigured, .upstreamKeyMissing, .ready,
        ] {
            XCTAssertTrue(seen.contains(state), "\(state) is unreachable from any input")
        }
    }

    /// 🔴 The disagreement this slice exists to end. The Settings row tested the preference EARLY
    /// and the toggle's detail line tested it LATE, so a user with chaining off and a stale
    /// surrender still recorded read "Off" in one place and "Guard stopped because VPN chaining
    /// could not keep forwarding" in the other. One state, one answer.
    ///
    /// The preference outranks every condition the user can still change it despite — those are
    /// operational detail about a feature they switched off.
    func testAPreferenceThatIsOffOutranksTheConditionsItCanStillBeChangedDespite() {
        XCTAssertEqual(
            ChainedOperationalState.resolve(
                inputs(preferenceEnabled: false, isSurrenderSuppressed: true)),
            .preferenceOff)
        XCTAssertEqual(
            ChainedOperationalState.resolve(
                inputs(preferenceEnabled: false, hasStoredConfiguration: false)),
            .preferenceOff)
        XCTAssertEqual(
            ChainedOperationalState.resolve(
                inputs(preferenceEnabled: false, storeIsUnreadable: true)),
            .preferenceOff)
        XCTAssertEqual(
            ChainedOperationalState.resolve(
                inputs(preferenceEnabled: false, storedConfigurationIsMissingKey: true)),
            .preferenceOff)
    }

    /// 🔴 …and does NOT outrank a condition that stops them changing it.
    ///
    /// Reporting the preference over one of these leaves a disabled switch with no reason and no
    /// remedy: "requests go straight to your DNS resolver", a dead control, and no mention of the
    /// unlock that would fix it. An earlier draft ordered the preference second, for cost, and
    /// produced exactly that (Codex, PR #637).
    func testAPreferenceThatIsOffNeverMasksAConditionThatStopsItBeingChanged() {
        XCTAssertEqual(
            ChainedOperationalState.resolve(
                inputs(preferenceEnabled: false, deviceStateIsUnreadable: true)),
            .deviceStateUnreadable)
        XCTAssertEqual(
            ChainedOperationalState.resolve(
                inputs(preferenceEnabled: false, ineligibility: .insufficientMemory)),
            .unsupportedDevice)
        XCTAssertEqual(
            ChainedOperationalState.resolve(
                inputs(preferenceEnabled: false, ineligibility: .startupCrashLoop)),
            .suspendedAfterStartupFailure)
        XCTAssertEqual(
            ChainedOperationalState.resolve(
                inputs(hasEntitlement: false, preferenceEnabled: false)), .notEntitled)
    }

    /// Entitlement outranks the preference in both directions — it is a statement about
    /// availability, and a row reading "Off" over an account that cannot chain answers the wrong
    /// question.
    func testEntitlementOutranksThePreference() {
        XCTAssertEqual(
            ChainedOperationalState.resolve(
                inputs(hasEntitlement: false, preferenceEnabled: true)), .notEntitled)
        XCTAssertEqual(
            ChainedOperationalState.resolve(
                inputs(hasEntitlement: false, preferenceEnabled: false)), .notEntitled)
    }

    /// THE ORDERING RULE, stated as an equivalence rather than a list: the states that outrank the
    /// preference are exactly the states in which the preference cannot be changed.
    ///
    /// Both halves matter. A state that outranks the preference WITHOUT disabling the control
    /// hides the user's own setting behind operational noise. A state that disables the control
    /// WITHOUT outranking the preference leaves a dead switch the copy never explains. Deriving
    /// both from one enum is what keeps the two in step; this asserts they are in step.
    func testTheStatesThatOutrankThePreferenceAreTheOnesThatDisableIt() {
        let ineligibilities: [ChainedAvailability.Ineligibility?] = [
            nil, .notEntitled, .insufficientMemory, .startupCrashLoop,
        ]
        for hasEntitlement in [true, false] {
            for deviceStateIsUnreadable in [true, false] {
                for ineligibility in ineligibilities {
                    // Resolve the SAME inputs with the preference on and off. If the answer does
                    // not move with the preference, something above it won — and that something
                    // must be a state the user cannot change out of.
                    let on = ChainedOperationalState.resolve(
                        inputs(
                            hasEntitlement: hasEntitlement, preferenceEnabled: true,
                            deviceStateIsUnreadable: deviceStateIsUnreadable,
                            ineligibility: ineligibility))
                    let off = ChainedOperationalState.resolve(
                        inputs(
                            hasEntitlement: hasEntitlement, preferenceEnabled: false,
                            deviceStateIsUnreadable: deviceStateIsUnreadable,
                            ineligibility: ineligibility))
                    if off == .preferenceOff {
                        XCTAssertFalse(
                            on.preventsChangingThePreference,
                            "\(on) let the preference through, so it must not disable the control")
                    } else {
                        XCTAssertEqual(
                            off, on,
                            "a state that outranks the preference must not depend on it")
                        XCTAssertTrue(
                            off.preventsChangingThePreference,
                            "\(off) outranked the preference, so it must disable the control")
                    }
                }
            }
        }
    }

    /// An availability statement says nothing about the setting, so it must be reachable for
    /// exactly the states the user cannot change out of — no wider, no narrower.
    ///
    /// Narrower was the live bug: `suspendedAfterStartupFailure` mapped to `settingOn`, and the
    /// breaker OUTLIVES the preference — a user whose chained starts failed can switch chaining
    /// off and the marker stays — so the row read "On — startup failed" for someone who had
    /// turned it off (Codex, PR #637).
    func testAvailabilityStatementsAreExactlyTheUnchangeableStates() {
        for state: ChainedOperationalState in [
            .notEntitled, .unsupportedDevice, .deviceStateUnreadable, .preferenceOff,
            .suspendedAfterStartupFailure, .suspendedAfterSurrender, .storeUnreadable,
            .noUpstreamConfigured, .upstreamKeyMissing, .ready,
        ] {
            switch ChainedSurfaceSummary(state) {
            case .unavailable:
                XCTAssertTrue(
                    state.preventsChangingThePreference,
                    "\(state) claims nothing about the setting, so the control must be disabled")
            case .settingOff, .settingOn:
                XCTAssertFalse(
                    state.preventsChangingThePreference,
                    "\(state) speaks for the user's setting, so they must be able to change it")
            }
        }
    }

    func testAvailabilityIsReportedWhenThePreferenceIsOn() {
        XCTAssertEqual(
            ChainedOperationalState.resolve(inputs(ineligibility: .insufficientMemory)),
            .unsupportedDevice)
        // BEFORE eligibility, mirroring `TunnelDataPathLatch.resolve`'s own order.
        XCTAssertEqual(
            ChainedOperationalState.resolve(
                inputs(deviceStateIsUnreadable: true, ineligibility: .insufficientMemory)),
            .deviceStateUnreadable)
    }

    func testBlockingConditionsResolveInTheTunnelsOwnOrder() {
        XCTAssertEqual(
            ChainedOperationalState.resolve(inputs(isSurrenderSuppressed: true)),
            .suspendedAfterSurrender)
        XCTAssertEqual(
            ChainedOperationalState.resolve(inputs(storeIsUnreadable: true)), .storeUnreadable)
        XCTAssertEqual(
            ChainedOperationalState.resolve(inputs(hasStoredConfiguration: false)),
            .noUpstreamConfigured)
        XCTAssertEqual(
            ChainedOperationalState.resolve(inputs(storedConfigurationIsMissingKey: true)),
            .upstreamKeyMissing)
        XCTAssertEqual(ChainedOperationalState.resolve(inputs()), .ready)
        // An unreadable store is not an empty one, so it must not be reported as "nothing stored".
        XCTAssertEqual(
            ChainedOperationalState.resolve(
                inputs(storeIsUnreadable: true, hasStoredConfiguration: false)),
            .storeUnreadable)
    }

    /// `settingOff` is reachable from exactly one state. That is what makes the invariant
    /// structural rather than a convention every surface has to remember.
    func testOnlyThePreferenceOffStateMayRenderTheDisabledToken() {
        for state: ChainedOperationalState in [
            .notEntitled, .unsupportedDevice, .deviceStateUnreadable,
            .suspendedAfterStartupFailure, .suspendedAfterSurrender, .storeUnreadable,
            .noUpstreamConfigured, .upstreamKeyMissing, .ready,
        ] {
            XCTAssertNotEqual(
                ChainedSurfaceSummary(state), .settingOff,
                "\(state) must not be able to render the disabled token")
        }
        XCTAssertEqual(ChainedSurfaceSummary(.preferenceOff), .settingOff)
    }
    func testDNSConfigurationAvailabilityKeepsOffAndFullTunnelDistinctFromUnknown() {
        for consent in [false, true] {
            let full = ChainedDNSSettingsPresentation(chainingEnabled: true,
                fallbackPreference: consent, storedIsSplitTunnel: false)
            XCTAssertEqual(full.fallbackEnabled, false)
            XCTAssertFalse(full.canChangeFallback)
            XCTAssertFalse(full.canEditDNS)
            let off = ChainedDNSSettingsPresentation(chainingEnabled: false,
                fallbackPreference: consent, storedIsSplitTunnel: false)
            XCTAssertTrue(off.canEditDNS, "A saved full-tunnel profile cannot disable ordinary DNS when chaining is off.")
        }
        let unknown = ChainedDNSSettingsPresentation(chainingEnabled: true,
            fallbackPreference: true, storedIsSplitTunnel: nil)
        XCTAssertNil(unknown.fallbackEnabled)
        XCTAssertTrue(unknown.canEditDNS)
        XCTAssertTrue(unknown.canChangeFallback)
        let disabled = ChainedDNSSettingsPresentation(chainingEnabled: true,
            fallbackPreference: false, storedIsSplitTunnel: nil)
        XCTAssertEqual(disabled.fallbackEnabled, false)
        XCTAssertFalse(disabled.canEditDNS)
    }

    func testReplacingAFullTunnelWithSplitTunnelRestoresTheSameSavedFallbackPreference() {
        let consent = true
        let full = ChainedDNSSettingsPresentation(chainingEnabled: true, fallbackPreference: consent, storedIsSplitTunnel: false)
        let split = ChainedDNSSettingsPresentation(chainingEnabled: true, fallbackPreference: consent, storedIsSplitTunnel: true)
        XCTAssertEqual(full.fallbackEnabled, false)
        XCTAssertEqual(split.fallbackEnabled, true)
        XCTAssertTrue(split.canEditDNS)
        XCTAssertTrue(split.canChangeFallback)
        XCTAssertFalse(ChainedDNSSettingsPresentation(chainingEnabled: true,
            fallbackPreference: false, storedIsSplitTunnel: true).canEditDNS)
    }

}
