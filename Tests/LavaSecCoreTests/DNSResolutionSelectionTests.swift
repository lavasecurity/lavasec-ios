import XCTest
import LavaSecKit
import LavaSecDNS
import LavaSecAppServices

final class DNSResolutionSelectionTests: XCTestCase {
    func testEffectivePrimaryRetainsItsSavedTierWhenTheFirstRowIsDisabled() throws {
        var configuration = AppConfiguration()
        try configuration.applyDNSResolutionSelections([
            .init(id: DNSResolverPreset.quad9UnfilteredDoH.id, isEnabled: false),
            .init(id: DNSResolverPreset.device.id)
        ], allowsCustom: false)
        XCTAssertEqual(configuration.configuredPrimaryDNSResolverTier, .tierTwo)
        XCTAssertEqual(configuration.resolverLadderInputs.configuredPrimaryTier, .tierTwo)
        let restored = try JSONDecoder().decode(AppConfiguration.self, from: JSONEncoder().encode(configuration))
        XCTAssertEqual(restored.configuredPrimaryDNSResolverTier, .tierTwo)

        // A legacy direct setter makes the old saved selection obsolete, so the
        // fresh effective ladder starts at T1 instead of inheriting an old T2 label.
        configuration.resolverPresetID = DNSResolverPreset.googleDoH.id
        XCTAssertEqual(configuration.configuredPrimaryDNSResolverTier, .tierOne)
        XCTAssertEqual(configuration.dnsResolutionSelections.first?.id, DNSResolverPreset.googleDoH.id)
    }

    func testLegacyFallbackActivationInvalidatesAnObsoleteSavedTierOrigin() throws {
        var configuration = AppConfiguration()
        try configuration.applyDNSResolutionSelections([
            .init(id: DNSResolverPreset.quad9UnfilteredDoH.id, isEnabled: false),
            .init(id: DNSResolverPreset.device.id)
        ], allowsCustom: false)
        XCTAssertEqual(configuration.configuredPrimaryDNSResolverTier, .tierTwo)
        configuration.usesEncryptedDeviceDNSFallback = true
        XCTAssertEqual(configuration.configuredPrimaryDNSResolverTier, .tierOne)
        XCTAssertEqual(configuration.dnsResolutionSelections.count, 2)
        XCTAssertEqual(configuration.dnsResolutionSelections.first?.id, DNSResolverPreset.device.id)
    }

    func testExpiredCustomDNSCanBeDisabledButNotReenabled() throws {
        var c = AppConfiguration()
        try c.applyDNSResolutionSelections([.init(id: DNSResolverPreset.customID, primary: "https://dns.example/dns-query"), .init(id: DNSResolverPreset.device.id)], allowsCustom: true)
        try c.setDNSResolutionEnabled(false, index: 0)
        XCTAssertEqual(c.dnsResolutionSelections.map(\.isEnabled), [false, true])
        XCTAssertEqual(c.resolverPresetID, DNSResolverPreset.device.id)
        let disabled = c
        XCTAssertThrowsError(try c.setDNSResolutionEnabled(true, index: 0)) { XCTAssertEqual($0 as? DNSSelectionError, .customRequiresPlus) }
        XCTAssertEqual(c, disabled)
    }

    func testRowSwitchesRetainOrderAndNeverDisableTheLastResolver() throws {
        var c = AppConfiguration()
        let rows: [DNSResolutionSelection] = [.init(id: DNSResolverPreset.cloudflareDoH.id, name: "Cloudflare"), .init(id: DNSResolverPreset.quad9UnfilteredDoT.id, name: "Quad9")]
        try c.applyDNSResolutionSelections(rows, allowsCustom: false)
        try c.setDNSResolutionEnabled(false, index: 0)
        XCTAssertEqual(c.dnsResolutionSelections.map(\.id), rows.map(\.id))
        XCTAssertEqual(c.dnsResolutionSelections.map(\.isEnabled), [false, true])
        XCTAssertEqual(c.resolverPresetID, rows[1].id)
        XCTAssertFalse(c.resolverLadderInputs.isConfiguredFallbackEnabled)
        let before = c
        XCTAssertThrowsError(try c.setDNSResolutionEnabled(false, index: 1))
        XCTAssertEqual(c, before)
        c = try JSONDecoder().decode(AppConfiguration.self, from: JSONEncoder().encode(c))
        XCTAssertEqual(c.dnsResolutionSelections.map(\.isEnabled), [false, true])
        let backup = BackupConfigurationPayload(configuration: c)
        XCTAssertEqual(backup.schemaVersion, 3)
        let restored = try JSONDecoder().decode(BackupConfigurationPayload.self, from: JSONEncoder().encode(backup)).restoredConfiguration()
        XCTAssertEqual(restored.dnsResolutionSelections, c.dnsResolutionSelections)
        try c.setDNSResolutionEnabled(true, index: 0)
        XCTAssertEqual(c.resolverPresetID, rows[0].id)
        XCTAssertTrue(c.resolverLadderInputs.isConfiguredFallbackEnabled)
        try c.setDNSResolutionEnabled(false, index: 1)
        XCTAssertEqual(c.dnsResolutionSelections.map(\.isEnabled), [true, false])
        XCTAssertFalse(c.resolverLadderInputs.isConfiguredFallbackEnabled)
    }

    func testDisabledDNSRowTravelsWithItsChoiceWhenSwappedAndLegacyChangesStayAuthoritative() throws {
        var c = AppConfiguration()
        try c.applyDNSResolutionSelections([.init(id: DNSResolverPreset.device.id, isEnabled: false), .init(id: DNSResolverPreset.cloudflareDoH.id)], allowsCustom: false)
        try c.applyDNSResolutionSelections(c.dnsResolutionSelections.reversed(), allowsCustom: false)
        XCTAssertEqual(c.dnsResolutionSelections.map(\.isEnabled), [true, false])
        XCTAssertEqual(c.resolverPresetID, DNSResolverPreset.cloudflareDoH.id)
        c.resolverPresetID = DNSResolverPreset.googleDoH.id
        XCTAssertEqual(c.dnsResolutionSelections.first?.id, DNSResolverPreset.googleDoH.id)
        let old = try JSONDecoder().decode(DNSResolutionSelection.self, from: Data("{\"id\":\"device\"}".utf8))
        XCTAssertTrue(old.isEnabled)
    }

    func testTwoAlternativesPersistAndBuildOneFallback() throws {
        var configuration = AppConfiguration()
        try configuration.applyDNSResolutionSelections([
            .init(id: DNSResolverPreset.cloudflareDoH.id), .init(id: DNSResolverPreset.quad9UnfilteredDoT.id)
        ], allowsCustom: false)
        let restored = try JSONDecoder().decode(AppConfiguration.self, from: JSONEncoder().encode(configuration))
        XCTAssertEqual(restored.dnsResolutionSelections.map(\.id), [DNSResolverPreset.cloudflareDoH.id, DNSResolverPreset.quad9UnfilteredDoT.id])
        let plan = DNSResolverRuntimePlan.make(configuration: restored, deviceDNSAddresses: ["192.168.1.1"], networkKind: .wifi, deviceDNSFallbackModeActive: false)
        XCTAssertFalse(plan.shouldFallbackToDeviceDNS)
        XCTAssertTrue(plan.shouldFallbackToEncrypted)
        XCTAssertEqual(plan.encryptedFallback?.plan.transport, .dnsOverTLS)
        XCTAssertFalse(plan.encryptedFallback?.plan.shouldFallbackToEncrypted ?? true)
    }

    func testLegacyDormantAlternativeDoesNotBecomeEnabled() throws {
        let configuration = AppConfiguration(resolverPresetID: DNSResolverPreset.cloudflareDoH.id,
            fallbackToDeviceDNS: false, usesEncryptedDeviceDNSFallback: true)
        XCTAssertEqual(configuration.dnsResolutionSelections.count, 1)
        let plan = DNSResolverRuntimePlan.make(configuration: configuration, deviceDNSAddresses: ["192.168.1.1"], networkKind: .wifi, deviceDNSFallbackModeActive: false)
        XCTAssertFalse(plan.shouldFallbackToEncrypted)
    }

    func testDeletionPromotesSecondaryAndCannotRemoveLastOrDuplicate() throws {
        var configuration = AppConfiguration()
        let secondary = DNSResolutionSelection(id: DNSResolverPreset.cloudflareDoT.id)
        try configuration.applyDNSResolutionSelections([.init(id: DNSResolverPreset.device.id), secondary], allowsCustom: false)
        try configuration.applyDNSResolutionSelections(Array(configuration.dnsResolutionSelections.dropFirst()), allowsCustom: false)
        XCTAssertEqual(configuration.resolverPresetID, secondary.id)
        XCTAssertFalse(configuration.resolverLadderInputs.isConfiguredFallbackEnabled)
        let previous = configuration
        XCTAssertThrowsError(try configuration.applyDNSResolutionSelections([], allowsCustom: false))
        XCTAssertThrowsError(try configuration.applyDNSResolutionSelections([secondary, secondary], allowsCustom: false))
        XCTAssertEqual(configuration, previous)
    }

    func testCustomDraftRequiresEntitlementAndPromotesWithEndpoints() throws {
        var configuration = AppConfiguration()
        let custom = DNSResolutionSelection(id: DNSResolverPreset.customID, name: "My resolver", primary: "https://dns.example/dns-query")
        XCTAssertThrowsError(try configuration.applyDNSResolutionSelections([custom], allowsCustom: false))
        try configuration.applyDNSResolutionSelections([.init(id: DNSResolverPreset.cloudflareDoT.id), custom], allowsCustom: true)
        try configuration.applyDNSResolutionSelections(Array(configuration.dnsResolutionSelections.dropFirst()), allowsCustom: true)
        XCTAssertEqual(configuration.customResolverAddress, custom.primary)
        XCTAssertEqual(configuration.customResolverName, custom.name)
    }

    func testBackupPreservesExplicitAlternativePair() throws {
        var configuration = AppConfiguration()
        try configuration.applyDNSResolutionSelections([.init(id: DNSResolverPreset.cloudflareDoH.id), .init(id: DNSResolverPreset.googleDoT.id)], allowsCustom: false)
        let payload = BackupConfigurationPayload(configuration: configuration)
        XCTAssertEqual(payload.schemaVersion, 2)
        let encoded = try JSONEncoder().encode(payload)
        let restored = try JSONDecoder().decode(BackupConfigurationPayload.self, from: encoded).restoredConfiguration()
        // Pre-tier clients reject this schema before decoding any lossy settings.
        let wire = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        XCTAssertGreaterThan(try XCTUnwrap(wire["schemaVersion"] as? Int), 1)
        // Early QA backups advertised schema 1; reading them must preserve the pair
        // and upgrade subsequent writes so an older client cannot clobber it.
        var legacyWire = wire
        legacyWire["schemaVersion"] = 1
        let recovered = try JSONDecoder().decode(BackupConfigurationPayload.self,
            from: JSONSerialization.data(withJSONObject: legacyWire))
        XCTAssertEqual(recovered.schemaVersion, 2)
        XCTAssertEqual(recovered.restoredConfiguration().dnsResolutionSelections, configuration.dnsResolutionSelections)
        XCTAssertTrue(restored.usesExplicitDNSTiers)
        XCTAssertEqual(restored.dnsResolutionSelections, configuration.dnsResolutionSelections)
    }

    func testHTTPSProfileContractChecksExactTransportAndURL() throws {
        let contract = try XCTUnwrap(DNSPatchProviderCatalog.contract(for: DNSResolverPreset.cloudflareDoH.id))
        XCTAssertNotNil(contract.serverURL)
        XCTAssertFalse(contract.matchesManagedSettings(serverName: contract.serverName, servers: contract.serverAddresses,
            matchDomains: nil, allowsFailover: false, hasUniversalConnectRule: true))
        XCTAssertTrue(contract.matchesManagedSettings(serverName: contract.serverName, servers: contract.serverAddresses,
            matchDomains: nil, allowsFailover: false, hasUniversalConnectRule: true, serverURL: contract.serverURL))
    }
}
