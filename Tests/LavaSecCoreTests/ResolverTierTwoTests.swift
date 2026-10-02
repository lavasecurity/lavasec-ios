import XCTest

import LavaSecDNS
import LavaSecKit

/// T2 is one tier — "what answers the names T1 could not" — and the plan builder used to
/// implement it as two independent boolean legs, `shouldFallbackToDeviceDNS` and
/// `shouldFallbackToEncrypted`, computed from opposite sides of the same term. They were
/// mutually exclusive by construction, but nothing said so and nothing named the tier
/// (`docs/architecture/dns-tiers.md`).
///
/// These tests hold the tier, not the legs: which kind of fallback T2 is, when there is none, and
/// that routing both legs through one answer changed no behaviour.
final class ResolverTierTwoTests: XCTestCase {
    private func tierTwo(
        primary: DNSResolverTransport,
        effective: DNSResolverTransport? = nil,
        fallbackToDeviceDNS: Bool = true,
        usesEncryptedDeviceDNSFallback: Bool = false,
        encryptedFallbackResolver: DNSResolverPreset = .quad9UnfilteredDoH,
        allowsQueryFallback: Bool = true,
        hasDeviceDNSAddresses: Bool = true
    ) -> ResolverTierTwo {
        ResolverTierTwo.resolve(
            primaryTransport: primary,
            effectiveTransport: effective ?? primary,
            fallbackToDeviceDNS: fallbackToDeviceDNS,
            usesEncryptedDeviceDNSFallback: usesEncryptedDeviceDNSFallback,
            encryptedFallbackResolver: encryptedFallbackResolver,
            allowsQueryFallback: allowsQueryFallback,
            hasDeviceDNSAddresses: hasDeviceDNSAddresses)
    }

    /// 🔴 THE TIER, ASSERTED AS ONE ANSWER — and equal to the two legs it replaces, exhaustively.
    ///
    /// The second half is the point: the legs are reproduced from the ORIGINAL formulas, so this
    /// fails if consolidating them changed any outcome. A refactor that quietly moves a rung is
    /// worse than the split it tidied.
    func testTheTwoLegsAreTheSameTierAndNeverArmTogether() {
        let transports: [DNSResolverTransport] = [
            .deviceDNS, .plainDNS, .dnsOverHTTPS, .dnsOverTLS, .dnsOverQUIC,
        ]
        let fallbackResolvers: [DNSResolverPreset] = [.quad9UnfilteredDoH, .device]

        for primary in transports {
            for effective in transports {
                // REACHABLE PAIRS ONLY. `DNSResolverRuntimePlan.make` sets `effectiveTransport`
                // to `.deviceDNS` whenever the SELECTION is device DNS, so a device-DNS primary
                // with some other effective transport is not a configuration the builder can
                // produce. Asserting over it would fail this test on a state that cannot exist —
                // and an unreachable counterexample is not a defect.
                if primary == .deviceDNS && effective != .deviceDNS { continue }
                for toDevice in [true, false] {
                    for toEncrypted in [true, false] {
                        for resolver in fallbackResolvers {
                            for allows in [true, false] {
                                for hasAddresses in [true, false] {
                                    let tier = tierTwo(
                                        primary: primary,
                                        effective: effective,
                                        fallbackToDeviceDNS: toDevice,
                                        usesEncryptedDeviceDNSFallback: toEncrypted,
                                        encryptedFallbackResolver: resolver,
                                        allowsQueryFallback: allows,
                                        hasDeviceDNSAddresses: hasAddresses)

                                    // The formulas as they stood before the consolidation.
                                    let legacyDevice =
                                        toDevice && allows && effective != .deviceDNS
                                        && hasAddresses
                                    let legacyEncrypted =
                                        toEncrypted && allows && primary == .deviceDNS

                                    XCTAssertFalse(
                                        legacyDevice && legacyEncrypted,
                                        "the legs were never meant to arm together")
                                    XCTAssertEqual(
                                        tier == .deviceDNS, legacyDevice,
                                        "device leg moved for \(primary)/\(effective)")
                                    XCTAssertEqual(
                                        tier.isResolver, legacyEncrypted,
                                        "resolver leg moved for \(primary)/\(effective)")
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    /// The user's SELECTION decides which kind of fallback T2 is — the same discriminator the
    /// settings page keys its single toggle on. Keying the tier on anything else would let the
    /// ladder offer a rung the settings page never did.
    func testTheSelectionDecidesWhichKindOfFallbackTierTwoIs() {
        XCTAssertEqual(
            tierTwo(primary: .dnsOverHTTPS, fallbackToDeviceDNS: true), .deviceDNS,
            "under an encrypted T1 the control offers Device DNS, so that is T2")
        XCTAssertEqual(
            tierTwo(
                primary: .deviceDNS, usesEncryptedDeviceDNSFallback: true,
                encryptedFallbackResolver: .quad9SecureDoH),
            .resolver(.quad9SecureDoH),
            "under a Device-DNS T1 the control offers an alternative resolver, so that is T2")
    }

    /// Declining the fallback is a stated choice too, and it ends the ladder: T1 refuses and
    /// nothing beneath it answers (`INV-DNS-1` — a refusal, never a bypass).
    func testDecliningTheFallbackLeavesNoTierTwo() {
        XCTAssertEqual(tierTwo(primary: .dnsOverHTTPS, fallbackToDeviceDNS: false), .none)
        XCTAssertEqual(
            tierTwo(primary: .deviceDNS, usesEncryptedDeviceDNSFallback: false), .none)
    }

    /// Two runtime facts can empty a tier the user did choose, and neither is a preference:
    /// a probe that must measure T1 alone, and a device rung with no captured resolver to ask.
    func testRuntimeFactsThatEmptyATierTheUserChose() {
        XCTAssertEqual(
            tierTwo(primary: .dnsOverHTTPS, allowsQueryFallback: false), .none,
            "the smoke probe measures T1, so it must carry no tier beneath it")
        XCTAssertEqual(
            tierTwo(
                primary: .deviceDNS, usesEncryptedDeviceDNSFallback: true,
                allowsQueryFallback: false),
            .none,
            "and that holds for either kind of T2")
        XCTAssertEqual(
            tierTwo(primary: .dnsOverHTTPS, hasDeviceDNSAddresses: false), .none,
            "a device rung with nothing to ask is not a rung")
        // The device-DNS fallback MODE already puts the device resolvers in T1, so a device rung
        // beneath it would be the same resolver twice.
        XCTAssertEqual(
            tierTwo(primary: .dnsOverHTTPS, effective: .deviceDNS), .none)
    }

    /// A fallback selection that is ITSELF Device DNS is still a chosen T2 — what it cannot do is
    /// produce an encrypted plan to route through. The tier and the plan are separate questions,
    /// and collapsing them would silently drop `treatsResolverRejectionAsFallbackTrigger` for
    /// that user.
    func testAFallbackSelectionOfDeviceDNSIsStillAChosenTier() {
        XCTAssertEqual(
            tierTwo(
                primary: .deviceDNS, usesEncryptedDeviceDNSFallback: true,
                encryptedFallbackResolver: .device),
            .resolver(.device))

        let plan = DNSResolverRuntimePlan.make(
            resolver: .device,
            fallbackToDeviceDNS: true,
            usesEncryptedDeviceDNSFallback: true,
            deviceDNSAddresses: ["192.168.1.1"],
            networkKind: .wifi,
            deviceDNSFallbackModeActive: false,
            encryptedFallbackResolver: .device)
        XCTAssertTrue(
            plan.shouldFallbackToEncrypted,
            "the tier was chosen, so the trigger it gates stays armed")
        XCTAssertEqual(
            plan.encryptedFallbackEndpoints, [],
            "but there is no encrypted plan to route it through")
    }

    /// The plan builder still reads exactly one leg per configuration, which is what the tier
    /// buys: the legs cannot disagree because they are derived from one answer.
    func testThePlanArmsExactlyOneLeg() {
        let encryptedPrimary = DNSResolverRuntimePlan.make(
            resolver: .quad9UnfilteredDoH,
            fallbackToDeviceDNS: true,
            usesEncryptedDeviceDNSFallback: true,
            deviceDNSAddresses: ["192.168.1.1"],
            networkKind: .wifi,
            deviceDNSFallbackModeActive: false,
            encryptedFallbackResolver: .quad9SecureDoH)
        XCTAssertTrue(encryptedPrimary.shouldFallbackToDeviceDNS)
        XCTAssertFalse(encryptedPrimary.shouldFallbackToEncrypted)

        let devicePrimary = DNSResolverRuntimePlan.make(
            resolver: .device,
            fallbackToDeviceDNS: true,
            usesEncryptedDeviceDNSFallback: true,
            deviceDNSAddresses: ["192.168.1.1"],
            networkKind: .wifi,
            deviceDNSFallbackModeActive: false,
            encryptedFallbackResolver: .quad9SecureDoH)
        XCTAssertFalse(devicePrimary.shouldFallbackToDeviceDNS)
        XCTAssertTrue(devicePrimary.shouldFallbackToEncrypted)
        XCTAssertEqual(
            devicePrimary.encryptedFallbackEndpoints,
            DNSResolverPreset.quad9SecureDoH.dohEndpoints,
            "the rung is routed through the resolver the user picked")
    }
}
