import XCTest

@testable import LavaSecKit

/// Every input combination, and what each term is for.
///
/// The latch is a five-term conjunction whose wrong answers are silent: resolving chained
/// when the upstream cannot forward blackholes the device, and resolving DNS-only when the
/// user asked for chaining looks like the feature simply not working. Neither shows up as a
/// crash, so the coverage here is exhaustive rather than representative.
final class TunnelDataPathLatchTests: XCTestCase {
    private static let eligibleMemory = ChainedAvailability.minimumPhysicalMemoryBytes
    private static let subFloorMemory = ChainedAvailability.minimumPhysicalMemoryBytes - 1

    /// The configuration a ready upstream hands the latch. A chained resolution carries it
    /// as the mode's payload (C7), so the expected mode below is built from the same value.
    private static let readyConfiguration = try! ChainedUpstreamConfiguration(
        endpointHost: "vpn.example.com",
        endpointPort: 51_820,
        peerPublicKey: Data(1...32).base64EncodedString(),
        clientAddress: "10.64.0.5",
        allowedIPs: ["0.0.0.0/0"])

    /// Every combination of the nine boolean-ish inputs, with memory taken at both sides of
    /// the floor. 1024 cases.
    private static func allInputs() -> [Inputs] {
        var cases: [Inputs] = []
        for unreadable in [false, true] {
            for enabled in [false, true] {
                for supported in [false, true] {
                    for plus in [false, true] {
                        for memory in [subFloorMemory, eligibleMemory] {
                            for stateUnavailable in [false, true] {
                                for override in [false, true] {
                                    for excluded in [false, true] {
                                        for surrendered in [false, true] {
                                            for ready in [false, true] {
                                                cases.append(Inputs(
                                                    unreadable: unreadable,
                                                    enabled: enabled,
                                                    supported: supported,
                                                    plus: plus,
                                                    memory: memory,
                                                    stateUnavailable: stateUnavailable,
                                                    override: override,
                                                    excluded: excluded,
                                                    surrendered: surrendered,
                                                    ready: ready
                                                ))
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
        return cases
    }

    private struct Inputs: CustomStringConvertible {
        var unreadable = false
        let enabled: Bool
        let supported: Bool
        let plus: Bool
        let memory: UInt64
        var stateUnavailable = false
        let override: Bool
        let excluded: Bool
        var surrendered = false
        let ready: Bool

        var resolution: TunnelDataPathLatch.Resolution {
            TunnelDataPathLatch.resolve(
                configurationIsUnreadable: unreadable,
                chainedUpstreamEnabled: enabled,
                buildSupportsChainedDataPath: supported,
                hasLavaSecurityPlus: plus,
                physicalMemoryBytes: memory,
                deviceLocalStateIsUnavailable: stateUnavailable,
                experimentalOverrideEnabled: override,
                hasStartupCrashLoopTripped: excluded,
                isSurrenderSuppressed: surrendered,
                readyUpstream: ready ? TunnelDataPathLatchTests.readyConfiguration : nil
            )
        }

        var description: String {
            "unreadable=\(unreadable) enabled=\(enabled) supported=\(supported) plus=\(plus) "
                + "memory=\(memory) stateUnavailable=\(stateUnavailable) override=\(override) "
                + "excluded=\(excluded) surrendered=\(surrendered) ready=\(ready)"
        }
    }

    // MARK: - The shape of the decision

    func testChainedRequiresEveryTermAndNothingLess() {
        for inputs in Self.allInputs() {
            let memoryOK = inputs.memory >= ChainedAvailability.minimumPhysicalMemoryBytes
            let expectChained = !inputs.unreadable
                && inputs.enabled
                && inputs.supported
                && !inputs.stateUnavailable
                && inputs.plus
                && (memoryOK || inputs.override)
                && !inputs.excluded
                && !inputs.surrendered
                && inputs.ready

            // Equality on the chained side compares the payload too, so this also proves
            // the resolution carries the configuration it was handed (C7) rather than a
            // mode with something else attached.
            XCTAssertEqual(
                inputs.resolution.mode,
                expectChained ? .chainedUpstream(Self.readyConfiguration) : .dnsOnly,
                "wrong mode for \(inputs)"
            )
        }
    }

    func testEveryDNSOnlyResolutionSaysWhyAndEveryChainedOneDoesNot() {
        for inputs in Self.allInputs() {
            let resolution = inputs.resolution
            switch resolution.mode {
            case .dnsOnly:
                XCTAssertNotNil(
                    resolution.refusal,
                    "a refusal with no reason cannot be reconciled by the app: \(inputs)"
                )
            case .chainedUpstream:
                XCTAssertNil(
                    resolution.refusal,
                    "a chained resolution has nothing to explain: \(inputs)"
                )
            }
        }
    }

    // MARK: - Inertness of an unsupported build

    func testAnUnsupportedBuildCanNeverLatchChainedNoMatterWhatElseIsTrue() {
        // The property that made the phase safe to ship pre-flip, kept as the latch's
        // guarantee about any UNSUPPORTED build (an older provider beside a newer app):
        // `supported == false` outranks every other input. Since the S8.8b flip the
        // shipping build passes true, and today's safety story is Phase-4 unreachability
        // (no config surface until C8's gate) plus the construction downgrade — see
        // INV-CHAIN-1. Every other input is free to vary.
        for inputs in Self.allInputs() where !inputs.supported {
            XCTAssertEqual(inputs.resolution.mode, .dnsOnly, "unsupported build latched chained: \(inputs)")
        }
    }

    func testAnUnsupportedBuildReportsTheBuildAndNotTheDevice() {
        // Ordering matters more than it looks. If device eligibility were checked first, a
        // perfectly capable phone running a provider without the data path would be told it
        // lacks memory — a false diagnosis the user cannot act on, for a cause that is not
        // theirs.
        let resolution = TunnelDataPathLatch.resolve(
            configurationIsUnreadable: false,
            chainedUpstreamEnabled: true,
            buildSupportsChainedDataPath: false,
            hasLavaSecurityPlus: false,
            physicalMemoryBytes: Self.subFloorMemory,
            deviceLocalStateIsUnavailable: false,
            experimentalOverrideEnabled: false,
            hasStartupCrashLoopTripped: true,
            isSurrenderSuppressed: false,
            readyUpstream: nil
        )

        XCTAssertEqual(resolution.refusal, .unsupportedByBuild)
    }

    // MARK: - Precedence between the remaining causes

    func testAnUnreadableConfigurationOutranksEveryOtherCauseIncludingTheFlag() {
        // The pre-first-unlock boot start (INV-PERSIST-1). The placeholder configuration
        // reports chaining off, so without this term the latch would report
        // `chainingDisabled` — a statement about a preference it never actually read, and the
        // one refusal the app deliberately does not reconcile. A device that wanted chaining
        // would then stay DNS-only until something unrelated restarted the tunnel.
        for inputs in Self.allInputs() where inputs.unreadable {
            XCTAssertEqual(inputs.resolution.mode, .dnsOnly, "unreadable config latched chained: \(inputs)")
            XCTAssertEqual(
                inputs.resolution.refusal,
                .configurationUnreadable,
                "an unread configuration must not be reported as a user preference: \(inputs)"
            )
        }
    }

    func testTheFlagBeingOffOutranksEveryOtherCause() {
        // A user who never asked for chaining must not generate reconcile-shaped refusals;
        // the app keys its reconcile on "flag on, latched DNS-only".
        let resolution = TunnelDataPathLatch.resolve(
            configurationIsUnreadable: false,
            chainedUpstreamEnabled: false,
            buildSupportsChainedDataPath: false,
            hasLavaSecurityPlus: false,
            physicalMemoryBytes: Self.subFloorMemory,
            deviceLocalStateIsUnavailable: false,
            experimentalOverrideEnabled: false,
            hasStartupCrashLoopTripped: true,
            isSurrenderSuppressed: false,
            readyUpstream: nil
        )

        XCTAssertEqual(resolution.refusal, .chainingDisabled)
    }

    func testDeviceIneligibilityOutranksAnUnreadableUpstream() {
        // The device cause is durable and the upstream cause is often transient (a boot
        // before first unlock). Reporting the transient one on an ineligible device would
        // invite a restart loop waiting for a cause that was never blocking.
        let resolution = TunnelDataPathLatch.resolve(
            configurationIsUnreadable: false,
            chainedUpstreamEnabled: true,
            buildSupportsChainedDataPath: true,
            hasLavaSecurityPlus: true,
            physicalMemoryBytes: Self.subFloorMemory,
            deviceLocalStateIsUnavailable: false,
            experimentalOverrideEnabled: false,
            hasStartupCrashLoopTripped: false,
            isSurrenderSuppressed: false,
            readyUpstream: nil
        )

        XCTAssertEqual(resolution.refusal, .deviceIneligible(.insufficientMemory))
    }

    func testTheDeviceRefusalCarriesTheSameCauseThePolicyReports() throws {
        for (plus, memory, override, excluded) in [
            (false, Self.eligibleMemory, false, false),
            (true, Self.subFloorMemory, false, false),
            (true, Self.eligibleMemory, false, true),
        ] {
            let expected = ChainedAvailability.ineligibilityReason(
                hasLavaSecurityPlus: plus,
                physicalMemoryBytes: memory,
                experimentalOverrideEnabled: override,
                hasStartupCrashLoopTripped: excluded
            )
            let resolution = TunnelDataPathLatch.resolve(
                configurationIsUnreadable: false,
                chainedUpstreamEnabled: true,
                buildSupportsChainedDataPath: true,
                hasLavaSecurityPlus: plus,
                physicalMemoryBytes: memory,
                deviceLocalStateIsUnavailable: false,
                experimentalOverrideEnabled: override,
                hasStartupCrashLoopTripped: excluded,
                isSurrenderSuppressed: false,
                readyUpstream: Self.readyConfiguration
            )

            XCTAssertEqual(resolution.refusal, .deviceIneligible(try XCTUnwrap(expected)))
        }
    }

    // MARK: - The two terms most easily dropped

    func testTheExperimentalOverrideIsHonouredByTheLatchAndNotOnlyByTheToggle() {
        // The plan calls this out explicitly: a latch that omits the override term restarts
        // a sub-floor device straight back into DNS-only, so the opt-in appears to work in
        // Settings and silently does nothing.
        let resolution = TunnelDataPathLatch.resolve(
            configurationIsUnreadable: false,
            chainedUpstreamEnabled: true,
            buildSupportsChainedDataPath: true,
            hasLavaSecurityPlus: true,
            physicalMemoryBytes: Self.subFloorMemory,
            deviceLocalStateIsUnavailable: false,
            experimentalOverrideEnabled: true,
            hasStartupCrashLoopTripped: false,
            isSurrenderSuppressed: false,
            readyUpstream: Self.readyConfiguration
        )

        XCTAssertEqual(resolution.mode, .chainedUpstream(Self.readyConfiguration))
    }

    func testJetsamExclusionBeatsTheExperimentalOverride() {
        // Otherwise the backoff cannot break the thrash loop it exists for: the override is
        // exactly what an excluded device has turned on.
        let resolution = TunnelDataPathLatch.resolve(
            configurationIsUnreadable: false,
            chainedUpstreamEnabled: true,
            buildSupportsChainedDataPath: true,
            hasLavaSecurityPlus: true,
            physicalMemoryBytes: Self.subFloorMemory,
            deviceLocalStateIsUnavailable: false,
            experimentalOverrideEnabled: true,
            hasStartupCrashLoopTripped: true,
            isSurrenderSuppressed: false,
            readyUpstream: Self.readyConfiguration
        )

        XCTAssertEqual(resolution.mode, .dnsOnly)
        XCTAssertEqual(resolution.refusal, .deviceIneligible(.startupCrashLoop))
    }

    /// An unreadable device-state store refuses with its own transient cause, never with an
    /// ineligibility computed from guessed terms.
    ///
    /// The load-bearing case is the sub-floor opted-in device on a pre-first-unlock boot:
    /// its override is unreadable, and reading it as `false` would refuse
    /// `.insufficientMemory` — the one cause `ChainedAvailabilityPolicy` treats as durable
    /// enough to CLEAR the stored preference. The user's opt-in would be deleted by a boot
    /// they slept through, presented as their own choice.
    func testUnavailableDeviceStateNeverReportsAnIneligibilityItDidNotRead() {
        for inputs in Self.allInputs()
        where inputs.stateUnavailable && !inputs.unreadable && inputs.enabled && inputs.supported {
            XCTAssertEqual(inputs.resolution.mode, .dnsOnly, "guessed terms latched: \(inputs)")
            XCTAssertEqual(
                inputs.resolution.refusal, .deviceStateUnavailable,
                "an unreadable device state was reported as something more specific — a "
                    + "statement about the device the tunnel never read: \(inputs)"
            )
        }
    }

    /// The build outranks the device state: a build with no data path never reads the store
    /// at all, so reporting the store's unavailability would describe a read that did not
    /// happen — and the build cause is the durable one.
    func testAnUnsupportedBuildOutranksUnavailableDeviceState() {
        for inputs in Self.allInputs() where inputs.stateUnavailable && !inputs.supported
            && !inputs.unreadable && inputs.enabled {
            XCTAssertEqual(inputs.resolution.refusal, .unsupportedByBuild, "\(inputs)")
        }
    }

    // MARK: - The surrender suppression (C4)

    func testASurrenderedDeviceStaysDNSOnlyUntilTheUserResets() {
        // The P2 proof at the latch: a second post-surrender lifecycle resolves dnsOnly on
        // an otherwise fully favourable device, and names the surrender — not the upstream,
        // whose transient readability must not decide when the Reset flow is offered.
        for inputs in Self.allInputs()
        where inputs.surrendered && !inputs.unreadable && inputs.enabled && inputs.supported
            && !inputs.stateUnavailable && inputs.plus
            && (inputs.memory >= ChainedAvailability.minimumPhysicalMemoryBytes || inputs.override)
            && !inputs.excluded {
            XCTAssertEqual(inputs.resolution.mode, .dnsOnly, "a surrendered device latched chained: \(inputs)")
            XCTAssertEqual(
                inputs.resolution.refusal, .chainedSurrendered,
                "the surrender must outrank the upstream's transient readability: \(inputs)")
        }
    }

    func testDeviceIneligibilityOutranksTheSurrender() {
        // The Reset control cannot make an unentitled or excluded device chain, so
        // reporting the surrender there sends the user to a button that fixes nothing.
        let resolution = TunnelDataPathLatch.resolve(
            configurationIsUnreadable: false,
            chainedUpstreamEnabled: true,
            buildSupportsChainedDataPath: true,
            hasLavaSecurityPlus: true,
            physicalMemoryBytes: Self.eligibleMemory,
            deviceLocalStateIsUnavailable: false,
            experimentalOverrideEnabled: false,
            hasStartupCrashLoopTripped: true,
            isSurrenderSuppressed: true,
            readyUpstream: Self.readyConfiguration
        )

        XCTAssertEqual(resolution.refusal, .deviceIneligible(.startupCrashLoop))
    }

    func testClearingTheSurrenderLetsAFreshResolutionSelectChained() {
        // The P4 proof's latch half: identical inputs, only the suppression flipped —
        // exactly what the user's Reset changes.
        func resolve(surrendered: Bool) -> TunnelDataPathLatch.Resolution {
            TunnelDataPathLatch.resolve(
                configurationIsUnreadable: false,
                chainedUpstreamEnabled: true,
                buildSupportsChainedDataPath: true,
                hasLavaSecurityPlus: true,
                physicalMemoryBytes: Self.eligibleMemory,
                deviceLocalStateIsUnavailable: false,
                experimentalOverrideEnabled: false,
                hasStartupCrashLoopTripped: false,
                isSurrenderSuppressed: surrendered,
                readyUpstream: Self.readyConfiguration
            )
        }

        XCTAssertEqual(resolve(surrendered: true).refusal, .chainedSurrendered)
        XCTAssertEqual(
            resolve(surrendered: false).mode, .chainedUpstream(Self.readyConfiguration))
    }

    func testAnUnreadableUpstreamRefusesEvenOnAFullyEligibleDevice() {
        // The pre-first-unlock case: the WireGuard secret is AfterFirstUnlockThisDeviceOnly,
        // so a Connect-On-Demand boot start cannot read it. Claiming the default route here
        // would blackhole the device until first unlock.
        let resolution = TunnelDataPathLatch.resolve(
            configurationIsUnreadable: false,
            chainedUpstreamEnabled: true,
            buildSupportsChainedDataPath: true,
            hasLavaSecurityPlus: true,
            physicalMemoryBytes: Self.eligibleMemory,
            deviceLocalStateIsUnavailable: false,
            experimentalOverrideEnabled: false,
            hasStartupCrashLoopTripped: false,
            isSurrenderSuppressed: false,
            readyUpstream: nil
        )

        XCTAssertEqual(resolution.mode, .dnsOnly)
        XCTAssertEqual(resolution.refusal, .upstreamUnavailable)
    }

    // MARK: - Log identifiers

    func testRefusalLogValuesAreDistinctAndStable() {
        let values = [
            TunnelDataPathLatch.Refusal.configurationUnreadable,
            .chainingDisabled,
            .unsupportedByBuild,
            .deviceStateUnavailable,
            .deviceIneligible(.notEntitled),
            .deviceIneligible(.insufficientMemory),
            .deviceIneligible(.startupCrashLoop),
            .chainedSurrendered,
            .upstreamUnavailable,
        ].map(\.logValue)

        XCTAssertEqual(Set(values).count, values.count, "two refusals share a log identifier")
        XCTAssertEqual(
            values,
            [
                "configuration-unreadable",
                "chaining-disabled",
                "unsupported-by-build",
                "device-state-unavailable",
                "device-notEntitled",
                "device-insufficientMemory",
                "device-startup-crash-loop",
                "chained-surrendered",
                "upstream-unavailable",
            ]
        )
    }

    func testTheChainedAccessorAnswersForTheCaseNotTheConfiguration() {
        // `isChainedUpstream` is what every provider comparison site reads now that the
        // case carries a payload, and the provider is not constructible here — an inverted
        // accessor would pass the entire executable suite while flipping every latch
        // consult in the tunnel. So the accessor gets its own executable pin.
        XCTAssertTrue(
            TunnelDataPathMode.chainedUpstream(Self.readyConfiguration).isChainedUpstream)
        XCTAssertFalse(TunnelDataPathMode.dnsOnly.isChainedUpstream)
    }

    func testModeLogValuesAreDistinct() {
        XCTAssertEqual(TunnelDataPathMode.dnsOnly.logValue, "dns-only")
        XCTAssertEqual(
            TunnelDataPathMode.chainedUpstream(Self.readyConfiguration).logValue,
            "chained-upstream")
    }
}
