import XCTest
@testable import LavaSecCore
@testable import LavaSecKit

final class ShareableFilterConfigurationTests: XCTestCase {
    private func makeCustomSource() throws -> CustomBlocklistSource {
        try CustomBlocklistSource(
            id: "custom-family",
            displayName: "Family list",
            rawURL: "https://lists.example.com/family.txt"
        )
    }

    // MARK: Shareable slice excludes security-sensitive fields

    func testInitFromConfigurationKeepsOnlyBlockSideFields() throws {
        let custom = try makeCustomSource()
        let configuration = AppConfiguration(
            protectionEnabled: true,
            enabledBlocklistIDs: ["blocklistproject-basic", custom.id],
            allowedDomains: ["school.example", "bypass.example"],
            blockedDomains: ["casino.example"],
            resolverPresetID: DNSResolverPreset.cloudflareDoH.id,
            customResolverAddress: "10.0.0.1",
            customResolverName: "Home",
            fallbackToDeviceDNS: true,
            keepFilteringCounts: false,
            keepDomainDiagnostics: true,
            keepNetworkActivity: false,
            isPaid: true,
            qaProbeSet: nil,
            customBlocklists: [custom]
        )

        let shared = ShareableFilterConfiguration(configuration: configuration)

        XCTAssertEqual(shared.enabledBlocklistIDs, ["blocklistproject-basic", custom.id])
        XCTAssertEqual(shared.blockedDomains, ["casino.example"])
        XCTAssertEqual(shared.customBlocklists, [custom])
        // Allowlist exceptions and resolver details must never travel.
        let code = shared.encodedConfigurationCode()
        XCTAssertFalse(code.contains("school"))
        XCTAssertFalse(code.contains("bypass"))
        let decodedBack = try ShareableFilterConfiguration.decode(configurationCode: code)
        XCTAssertEqual(decodedBack.enabledBlocklistIDs, shared.enabledBlocklistIDs)
        XCTAssertEqual(decodedBack.blockedDomains, shared.blockedDomains)
        Self.assertSameSharedCustoms(decodedBack.customBlocklists, shared.customBlocklists)
    }

    func testInitFromConfigurationExcludesDisabledCustomBlocklists() throws {
        let enabledCustom = try CustomBlocklistSource(
            id: "custom-on",
            displayName: "On",
            rawURL: "https://lists.example.com/on.txt"
        )
        let disabledCustom = try CustomBlocklistSource(
            id: "custom-off",
            displayName: "Off",
            rawURL: "https://lists.example.com/off.txt"
        )
        let configuration = AppConfiguration(
            enabledBlocklistIDs: ["custom-on"],
            customBlocklists: [enabledCustom, disabledCustom]
        )

        let shared = ShareableFilterConfiguration(configuration: configuration)

        // Only the enabled custom list travels; the disabled one's URL/name stays.
        XCTAssertEqual(shared.customBlocklists, [enabledCustom])
    }

    func testInitFromFilterKeepsBlockSideAndDropsDisabledCustom() throws {
        let enabledCustom = try CustomBlocklistSource(
            id: "c-on",
            displayName: "On",
            rawURL: "https://lists.example.com/on.txt"
        )
        let disabledCustom = try CustomBlocklistSource(
            id: "c-off",
            displayName: "Off",
            rawURL: "https://lists.example.com/off.txt"
        )
        let filter = Filter(
            name: "Test",
            enabledBlocklistIDs: ["list-a", "c-on"],
            customBlocklists: [enabledCustom, disabledCustom],
            blockedDomains: ["bad.example"],
            allowedDomains: ["allow.example"]
        )

        let shared = ShareableFilterConfiguration(filter: filter)

        XCTAssertEqual(shared.enabledBlocklistIDs, ["list-a", "c-on"])
        XCTAssertEqual(shared.blockedDomains, ["bad.example"])
        // Only the enabled custom list travels; the disabled one is dropped. Allowlist
        // exceptions never leave the device (the share has no allowed field).
        XCTAssertEqual(shared.customBlocklists, [enabledCustom])
    }

    func testFitsShareableCodeCapacityGatesOversizedSetups() throws {
        // A normal setup fits the shareable code capacity (the higher QR/code limit).
        let normal = ShareableFilterConfiguration(
            enabledBlocklistIDs: ["a-list", "b-list"],
            blockedDomains: ["bad.example", "worse.example"]
        )
        XCTAssertTrue(normal.fitsShareableCodeCapacity())

        // Tens of thousands of high-entropy manual blocks can't fit a decodable code →
        // too big to share. Deterministic scramble (no Math.random / hashValue) so the
        // payload doesn't just compress away.
        func scrambled(_ i: Int) -> String {
            let mixed = UInt64(bitPattern: Int64(i)) &* 0x9E3779B97F4A7C15 &+ 0xD1B54A32D192ED03
            return String(mixed, radix: 36)
        }
        let huge = ShareableFilterConfiguration(
            blockedDomains: Set((0..<20_000).map { "\(scrambled($0))-\($0).example" })
        )
        XCTAssertFalse(huge.fitsShareableCodeCapacity())

        // Highly compressible but huge: an overlong custom-list name deflates to a tiny
        // code, yet the uncompressed JSON blows the recipient's inflate limit — so it's
        // still too big to share even though the code length is small (Codex).
        let overlongName = try CustomBlocklistSource(
            id: "huge",
            displayName: String(repeating: "x", count: 600_000),
            rawURL: "https://lists.example.com/x.txt"
        )
        let compressibleHuge = ShareableFilterConfiguration(
            enabledBlocklistIDs: ["huge"],
            customBlocklists: [overlongName]
        )
        XCTAssertLessThan(
            compressibleHuge.encodedConfigurationCode().count,
            16 * 1024,
            "The overlong name should compress to a short code (isolating the inflate-size gate)."
        )
        XCTAssertFalse(compressibleHuge.fitsShareableCodeCapacity())
    }

    // MARK: Code round-trip

    func testEncodeDecodeRoundTrip() throws {
        let custom = try makeCustomSource()
        let shared = ShareableFilterConfiguration(
            enabledBlocklistIDs: ["a-list", "b-list"],
            blockedDomains: ["bad.example", "worse.example"],
            customBlocklists: [custom]
        )

        let code = shared.encodedConfigurationCode()
        XCTAssertTrue(code.hasPrefix("LF1-"))

        let decoded = try ShareableFilterConfiguration.decode(configurationCode: code)
        XCTAssertEqual(decoded.enabledBlocklistIDs, shared.enabledBlocklistIDs)
        XCTAssertEqual(decoded.blockedDomains, shared.blockedDomains)
        Self.assertSameSharedCustoms(decoded.customBlocklists, shared.customBlocklists)
    }

    func testLargeSetupStaysCompactAndRoundTrips() throws {
        // A big, repetitive setup should compress well and still round-trip.
        let domains = (0..<200).map { "blocked-domain-number-\($0).example.com" }
        let shared = ShareableFilterConfiguration(
            enabledBlocklistIDs: ["a-list", "b-list", "c-list"],
            blockedDomains: Set(domains)
        )

        let code = shared.encodedConfigurationCode()

        // Compression keeps the code far smaller than the raw payload it encodes.
        let rawApproxLength = domains.joined(separator: ",").count
        XCTAssertLessThan(code.count, rawApproxLength)

        let decoded = try ShareableFilterConfiguration.decode(configurationCode: code)
        XCTAssertEqual(decoded.blockedDomains, shared.blockedDomains)
        XCTAssertEqual(decoded.enabledBlocklistIDs, shared.enabledBlocklistIDs)
    }

    func testEncodingIsDeterministicRegardlessOfSetOrdering() {
        let first = ShareableFilterConfiguration(
            enabledBlocklistIDs: ["a", "b", "c"],
            blockedDomains: ["x.example", "y.example"]
        )
        let second = ShareableFilterConfiguration(
            enabledBlocklistIDs: ["c", "a", "b"],
            blockedDomains: ["y.example", "x.example"]
        )

        XCTAssertEqual(first.encodedConfigurationCode(), second.encodedConfigurationCode())
    }

    func testDecodeToleratesSurroundingWhitespaceAndCasingOfPrefix() throws {
        let shared = ShareableFilterConfiguration(enabledBlocklistIDs: ["a-list"])
        let code = shared.encodedConfigurationCode()
        let messy = "  \n" + code.replacingOccurrences(of: "LF1-", with: "lf1-") + "\n "

        let decoded = try ShareableFilterConfiguration.decode(configurationCode: messy)
        XCTAssertEqual(decoded, shared)
    }

    // MARK: Partial payloads

    func testPartialPayloadDecodesMissingFieldsAsEmpty() throws {
        // Only the blocked-domains key present.
        let json = #"{"v":1,"blocked":["only.example"]}"#
        let decoder = JSONDecoder()
        let decoded = try decoder.decode(ShareableFilterConfiguration.self, from: Data(json.utf8))

        XCTAssertEqual(decoded.blockedDomains, ["only.example"])
        XCTAssertTrue(decoded.enabledBlocklistIDs.isEmpty)
        XCTAssertTrue(decoded.customBlocklists.isEmpty)
        XCTAssertEqual(decoded.schemaVersion, 1)
    }

    func testEmptyObjectDecodesToEmptyConfiguration() throws {
        let decoder = JSONDecoder()
        let decoded = try decoder.decode(ShareableFilterConfiguration.self, from: Data("{}".utf8))
        XCTAssertTrue(decoded.isEmpty)
    }

    // MARK: Tamper / corruption detection

    func testTamperedCodeFailsIntegrityCheck() throws {
        let shared = ShareableFilterConfiguration(blockedDomains: ["bad.example"])
        var code = Array(shared.encodedConfigurationCode())
        // Flip a character in the payload body (after the "LF1-" prefix).
        let index = code.count - 3
        code[index] = code[index] == "A" ? "B" : "A"
        let tampered = String(code)

        XCTAssertThrowsError(try ShareableFilterConfiguration.decode(configurationCode: tampered)) { error in
            guard let codeError = error as? ShareableFilterConfigurationCodeError else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertTrue(
                codeError == .integrityCheckFailed
                    || codeError == .unrecognizedFormat
                    || codeError == .malformedPayload,
                "Tampering should be rejected, got \(codeError)"
            )
        }
    }

    func testUnrecognizedFormatIsRejected() {
        XCTAssertThrowsError(try ShareableFilterConfiguration.decode(configurationCode: "totally not a code")) { error in
            XCTAssertEqual(error as? ShareableFilterConfigurationCodeError, .unrecognizedFormat)
        }
    }

    func testRejectsOversizedCodeBeforeDecoding() {
        // Guards against a compression-bomb / huge paste from an untrusted party.
        let oversized = "LF1-" + String(repeating: "A", count: 20_000)
        XCTAssertThrowsError(try ShareableFilterConfiguration.decode(configurationCode: oversized)) { error in
            XCTAssertEqual(error as? ShareableFilterConfigurationCodeError, .payloadTooLarge)
        }
    }

    // MARK: Replace semantics

    func testApplyingImportedConfigurationReplacesBlockSideAndPreservesRest() throws {
        let importedCustom = try makeCustomSource()
        let existing = AppConfiguration(
            protectionEnabled: true,
            enabledBlocklistIDs: ["old-list"],
            allowedDomains: ["keepme.example"],
            blockedDomains: ["old.example"],
            resolverPresetID: DNSResolverPreset.cloudflareDoH.id,
            fallbackToDeviceDNS: false,
            keepFilteringCounts: true,
            keepDomainDiagnostics: true,
            keepNetworkActivity: true,
            isPaid: true,
            qaProbeSet: nil,
            customBlocklists: []
        )
        let applied = ShareableFilterConfiguration(
            enabledBlocklistIDs: ["new-list", importedCustom.id],
            blockedDomains: ["new.example"],
            customBlocklists: [importedCustom]
        )

        let result = existing.applyingImportedShareableConfiguration(applied)

        XCTAssertEqual(result.enabledBlocklistIDs, ["new-list", importedCustom.id])
        XCTAssertEqual(result.blockedDomains, ["new.example"])
        XCTAssertEqual(result.customBlocklists, [importedCustom])
        // Untouched, security-relevant fields:
        XCTAssertEqual(result.allowedDomains, ["keepme.example"])
        XCTAssertEqual(result.resolverPresetID, DNSResolverPreset.cloudflareDoH.id)
        XCTAssertFalse(result.fallbackToDeviceDNS)
        XCTAssertTrue(result.protectionEnabled)
    }

    // MARK: Import planning (robust against device differences)

    func testImportPlanKeepsEverythingWhenFullyCapable() throws {
        let custom = try makeCustomSource()
        let shared = ShareableFilterConfiguration(
            enabledBlocklistIDs: ["a", "b", custom.id],
            blockedDomains: ["one.example", "two.example"],
            customBlocklists: [custom]
        )
        let capabilities = ShareableFilterImportCapabilities(
            availableCuratedBlocklistIDs: ["a", "b"],
            allowsCustomBlocklists: true,
            maxBlockedDomains: 500
        )

        let plan = shared.importPlan(capabilities: capabilities)

        XCTAssertFalse(plan.hasUnsupportedEntries)
        XCTAssertEqual(plan.applied, shared)
    }

    func testImportPlanDropsUnavailableCuratedLists() {
        let shared = ShareableFilterConfiguration(
            enabledBlocklistIDs: ["known-list", "mystery-list"]
        )
        let capabilities = ShareableFilterImportCapabilities(
            availableCuratedBlocklistIDs: ["known-list"],
            allowsCustomBlocklists: true,
            maxBlockedDomains: 500
        )

        let plan = shared.importPlan(capabilities: capabilities)

        XCTAssertEqual(plan.applied.enabledBlocklistIDs, ["known-list"])
        XCTAssertEqual(plan.droppedCount(of: .unavailableBlocklist), 1)
        XCTAssertEqual(plan.dropped.first?.label, "mystery-list")
    }

    func testImportPlanGatesCustomBlocklistsBehindUpgrade() throws {
        let custom = try makeCustomSource()
        let shared = ShareableFilterConfiguration(
            enabledBlocklistIDs: ["a", custom.id],
            customBlocklists: [custom]
        )
        let capabilities = ShareableFilterImportCapabilities(
            availableCuratedBlocklistIDs: ["a"],
            allowsCustomBlocklists: false,
            maxBlockedDomains: 10
        )

        let plan = shared.importPlan(capabilities: capabilities)

        XCTAssertTrue(plan.applied.customBlocklists.isEmpty)
        // The custom source's ID must not linger in the enabled set.
        XCTAssertEqual(plan.applied.enabledBlocklistIDs, ["a"])
        XCTAssertEqual(plan.droppedCount(of: .requiresUpgrade), 1)
        // The gated custom ID is not double-reported as an unavailable list.
        XCTAssertEqual(plan.droppedCount(of: .unavailableBlocklist), 0)
    }

    func testImportPlanCapsBlockedDomainsAtPlanLimit() {
        let shared = ShareableFilterConfiguration(
            blockedDomains: ["a.example", "b.example", "c.example"]
        )
        let capabilities = ShareableFilterImportCapabilities(
            availableCuratedBlocklistIDs: [],
            allowsCustomBlocklists: true,
            maxBlockedDomains: 2
        )

        let plan = shared.importPlan(capabilities: capabilities)

        XCTAssertEqual(plan.applied.blockedDomains.count, 2)
        XCTAssertEqual(plan.droppedCount(of: .exceedsLimit), 1)
        // Deterministic: keeps the lexicographically-first domains.
        XCTAssertEqual(plan.applied.blockedDomains, ["a.example", "b.example"])
    }

    func testImportPlanDropsListsOverRuleBudget() {
        let shared = ShareableFilterConfiguration(
            enabledBlocklistIDs: ["small", "big"]
        )
        let capabilities = ShareableFilterImportCapabilities(
            availableCuratedBlocklistIDs: ["small", "big"],
            allowsCustomBlocklists: true,
            maxBlockedDomains: 500,
            maxFilterRules: 1_000,
            blocklistRuleCounts: ["small": 100, "big": 5_000]
        )

        let plan = shared.importPlan(capabilities: capabilities)

        // "small" fits the 1k budget; "big" (5k) is trimmed rather than failing
        // at compile time after the user confirms.
        XCTAssertEqual(plan.applied.enabledBlocklistIDs, ["small"])
        XCTAssertEqual(plan.droppedCount(of: .exceedsRuleBudget), 1)
        XCTAssertEqual(plan.dropped.first { $0.kind == .exceedsRuleBudget }?.label, "big")
    }

    func testImportPlanCountsPreservedAllowlistTowardBudget() {
        let shared = ShareableFilterConfiguration(enabledBlocklistIDs: ["list"])
        // The list alone (60) fits a 100 budget, but with 50 preserved allowlist
        // rules the total (110) exceeds it — matching what snapshot prep enforces.
        let capabilities = ShareableFilterImportCapabilities(
            availableCuratedBlocklistIDs: ["list"],
            allowsCustomBlocklists: true,
            maxBlockedDomains: 500,
            maxFilterRules: 100,
            blocklistRuleCounts: ["list": 60],
            preservedRuleCount: 50
        )

        let plan = shared.importPlan(capabilities: capabilities)

        XCTAssertTrue(plan.applied.enabledBlocklistIDs.isEmpty)
        XCTAssertEqual(plan.droppedCount(of: .exceedsRuleBudget), 1)
    }

    func testImportPlanNormalizesAndDropsInvalidBlockedDomains() {
        let shared = ShareableFilterConfiguration(
            blockedDomains: ["Valid.Example", "1.2.3.4", "single"]
        )
        let capabilities = ShareableFilterImportCapabilities(
            availableCuratedBlocklistIDs: [],
            allowsCustomBlocklists: true,
            maxBlockedDomains: 500
        )

        let plan = shared.importPlan(capabilities: capabilities)

        // Case-folded to canonical form; the IP and single-label entries (which
        // the rule builder would silently drop) never count toward the import.
        XCTAssertEqual(plan.applied.blockedDomains, ["valid.example"])
    }

    func testImportPlanCollapsesDuplicateCustomIDs() throws {
        // A crafted code with two custom entries sharing an ID must not persist
        // duplicate IDs (which would later trap Dictionary(uniqueKeysWithValues:)).
        let first = try CustomBlocklistSource(
            id: "custom-dup",
            displayName: "First",
            rawURL: "https://lists.example.com/first.txt"
        )
        let second = try CustomBlocklistSource(
            id: "custom-dup",
            displayName: "Second",
            rawURL: "https://lists.example.com/second.txt"
        )
        let shared = ShareableFilterConfiguration(
            enabledBlocklistIDs: ["custom-dup"],
            customBlocklists: [first, second]
        )
        let capabilities = ShareableFilterImportCapabilities(
            availableCuratedBlocklistIDs: [],
            allowsCustomBlocklists: true,
            maxBlockedDomains: 500
        )

        let plan = shared.importPlan(capabilities: capabilities)

        XCTAssertEqual(plan.applied.customBlocklists.count, 1)
        XCTAssertEqual(plan.applied.customBlocklists.first?.id, "custom-dup")
        XCTAssertEqual(Set(plan.applied.customBlocklists.map(\.id)).count, 1)
    }

    func testImportPlanIgnoresInactiveCustomSources() throws {
        // A crafted code can carry a custom source whose ID isn't enabled; it
        // would compile to nothing, so it must not count toward the import.
        let inactive = try CustomBlocklistSource(
            id: "custom-inactive",
            displayName: "Inactive",
            rawURL: "https://lists.example.com/x.txt"
        )
        let shared = ShareableFilterConfiguration(
            enabledBlocklistIDs: [],
            customBlocklists: [inactive]
        )
        let capabilities = ShareableFilterImportCapabilities(
            availableCuratedBlocklistIDs: [],
            allowsCustomBlocklists: true,
            maxBlockedDomains: 500
        )

        let plan = shared.importPlan(capabilities: capabilities)

        XCTAssertTrue(plan.applied.customBlocklists.isEmpty)
        XCTAssertTrue(plan.applied.isEmpty)
        XCTAssertEqual(plan.droppedCount(of: .requiresUpgrade), 0)
    }

    // MARK: Untrusted custom blocklist hardening

    func testImportPlanRejectsCustomBlocklistThatShadowsReservedID() throws {
        // A crafted custom source claiming a curated list's ID would otherwise
        // override that trusted list with its own URL.
        let shadow = try CustomBlocklistSource(
            id: "blocklistproject-phishing",
            displayName: "Sneaky",
            rawURL: "https://evil.example/list.txt"
        )
        let shared = ShareableFilterConfiguration(
            enabledBlocklistIDs: ["blocklistproject-phishing"],
            customBlocklists: [shadow]
        )
        let capabilities = ShareableFilterImportCapabilities(
            availableCuratedBlocklistIDs: ["blocklistproject-phishing"],
            reservedBlocklistIDs: ["blocklistproject-phishing"],
            allowsCustomBlocklists: true,
            maxBlockedDomains: 500
        )

        let plan = shared.importPlan(capabilities: capabilities)

        XCTAssertTrue(plan.applied.customBlocklists.isEmpty)
        XCTAssertEqual(plan.droppedCount(of: .unsafeSource), 1)
        // The curated ID itself still resolves to the trusted curated list.
        XCTAssertEqual(plan.applied.enabledBlocklistIDs, ["blocklistproject-phishing"])
    }

    func testImportPlanRejectsUnsafeDecodedCustomBlocklistURL() throws {
        // Simulate a decoded source that bypassed the validating initializer
        // (e.g. a private-network URL smuggled in through the JSON payload).
        let unsafe = try Self.decodedSource(overridingSourceURL: "http://10.0.0.1/list.txt")
        let shared = ShareableFilterConfiguration(
            enabledBlocklistIDs: [unsafe.id],
            customBlocklists: [unsafe]
        )
        let capabilities = ShareableFilterImportCapabilities(
            availableCuratedBlocklistIDs: [],
            allowsCustomBlocklists: true,
            maxBlockedDomains: 500
        )

        let plan = shared.importPlan(capabilities: capabilities)

        XCTAssertTrue(plan.applied.customBlocklists.isEmpty)
        XCTAssertTrue(plan.applied.enabledBlocklistIDs.isEmpty)
        XCTAssertEqual(plan.droppedCount(of: .unsafeSource), 1)
    }

    /// Custom lists round-trip by their shareable identity (id/URL/name/format);
    /// local-only `createdAt`/`lastAcceptedHash` are intentionally not shared.
    private static func assertSameSharedCustoms(
        _ lhs: [CustomBlocklistSource],
        _ rhs: [CustomBlocklistSource],
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(lhs.map(\.id), rhs.map(\.id), file: file, line: line)
        XCTAssertEqual(lhs.map(\.sourceURL), rhs.map(\.sourceURL), file: file, line: line)
        XCTAssertEqual(lhs.map(\.displayName), rhs.map(\.displayName), file: file, line: line)
        XCTAssertEqual(lhs.map(\.parseFormat), rhs.map(\.parseFormat), file: file, line: line)
    }

    /// Builds a `CustomBlocklistSource` whose `sourceURL` was replaced post-hoc,
    /// mimicking a value decoded straight from JSON without the failable init's
    /// HTTPS/public-host/no-credentials checks.
    private static func decodedSource(overridingSourceURL urlString: String) throws -> CustomBlocklistSource {
        let valid = try CustomBlocklistSource(
            id: "custom-unsafe",
            displayName: "Unsafe",
            rawURL: "https://lists.example.com/ok.txt"
        )
        let data = try JSONEncoder().encode(valid)
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        object["sourceURL"] = urlString
        let tampered = try JSONSerialization.data(withJSONObject: object)
        return try JSONDecoder().decode(CustomBlocklistSource.self, from: tampered)
    }
}
