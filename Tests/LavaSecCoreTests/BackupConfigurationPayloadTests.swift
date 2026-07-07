import XCTest
@testable import LavaSecCore
@testable import LavaSecKit

final class BackupConfigurationPayloadTests: XCTestCase {
    func testPayloadIncludesCompactConfigOnly() throws {
        let customSource = try CustomBlocklistSource(
            id: "custom-sensitive",
            displayName: "Sensitive",
            rawURL: "https://sensitive.example.com/private-list.txt",
            lastAcceptedHash: String(repeating: "a", count: 64)
        )
        let configuration = AppConfiguration(
            protectionEnabled: true,
            enabledBlocklistIDs: ["blocklistproject-basic", customSource.id],
            allowedDomains: ["school.example"],
            blockedDomains: ["casino.example"],
            resolverPresetID: DNSResolverPreset.cloudflareDoH.id,
            fallbackToDeviceDNS: true,
            keepFilteringCounts: false,
            keepDomainDiagnostics: true,
            keepNetworkActivity: false,
            keepLavaGuardProgress: false,
            isPaid: true,
            qaProbeSet: .hosted,
            customBlocklists: [customSource],
            lavaGuardUnlocks: LavaGuardAchievementLedger(records: [
                LavaGuardUnlockRecord(
                    guardID: "obsidian",
                    unlockedAt: Date(timeIntervalSinceReferenceDate: 1_500)
                )
            ])
        )

        let payload = BackupConfigurationPayload(configuration: configuration)

        XCTAssertEqual(payload.schemaVersion, 1)
        XCTAssertEqual(payload.enabledBlocklistIDs, ["blocklistproject-basic", customSource.id])
        XCTAssertEqual(payload.allowedDomains, ["school.example"])
        XCTAssertEqual(payload.blockedDomains, ["casino.example"])
        XCTAssertEqual(payload.resolverPresetID, DNSResolverPreset.cloudflareDoH.id)
        XCTAssertTrue(payload.fallbackToDeviceDNS)
        XCTAssertFalse(payload.keepFilteringCounts)
        XCTAssertTrue(payload.keepDomainDiagnostics)
        XCTAssertFalse(payload.keepNetworkActivity)
        XCTAssertFalse(payload.keepLavaGuardProgress)
        XCTAssertTrue(payload.lavaGuardUnlocks.isUnlocked(guardID: "obsidian"))
        XCTAssertTrue(payload.protectionEnabledHint)
        XCTAssertEqual(payload.customBlocklists, [customSource])
    }

    func testPayloadDoesNotPersistPaidOrQAState() throws {
        let configuration = AppConfiguration(isPaid: true, qaProbeSet: .hosted)
        let data = try JSONEncoder().encode(BackupConfigurationPayload(configuration: configuration))
        let json = String(decoding: data, as: UTF8.self)

        XCTAssertFalse(json.contains("isPaid"))
        XCTAssertFalse(json.contains("qaProbeSet"))
        XCTAssertFalse(json.contains("diagnostics"))
        XCTAssertFalse(json.contains("snapshot"))
        XCTAssertFalse(json.contains("qualifiedUsageDay"))
        XCTAssertFalse(json.contains("usageDayCount"))
        XCTAssertFalse(json.contains("lavaGuardProgress"))
        XCTAssertFalse(json.contains("playsHapticFeedback"))
    }

    func testConfigurationRestoreKeepsLocalOnlyFieldsDefault() throws {
        let customSource = try CustomBlocklistSource(
            id: "custom-restore",
            displayName: "Restore",
            rawURL: "https://restore.example.com/list.txt",
            lastAcceptedHash: String(repeating: "b", count: 64)
        )
        let payload = BackupConfigurationPayload(
            schemaVersion: 1,
            enabledBlocklistIDs: ["blocklistproject-basic", customSource.id],
            allowedDomains: ["school.example"],
            blockedDomains: ["casino.example"],
            resolverPresetID: DNSResolverPreset.quad9SecureDoH.id,
            fallbackToDeviceDNS: true,
            keepFilteringCounts: false,
            keepDomainDiagnostics: false,
            keepNetworkActivity: false,
            keepLavaGuardProgress: false,
            lavaGuardUnlocks: LavaGuardAchievementLedger(records: [
                LavaGuardUnlockRecord(
                    guardID: "purpleObsidian",
                    unlockedAt: Date(timeIntervalSinceReferenceDate: 1_600)
                )
            ]),
            protectionEnabledHint: true,
            catalogVersionHint: "catalog-1",
            customBlocklists: [customSource]
        )

        let configuration = payload.restoredConfiguration()

        XCTAssertEqual(configuration.enabledBlocklistIDs, ["blocklistproject-basic", customSource.id])
        XCTAssertEqual(configuration.allowedDomains, ["school.example"])
        XCTAssertEqual(configuration.blockedDomains, ["casino.example"])
        XCTAssertEqual(configuration.resolverPresetID, DNSResolverPreset.quad9SecureDoH.id)
        XCTAssertTrue(configuration.fallbackToDeviceDNS)
        XCTAssertFalse(configuration.keepFilteringCounts)
        XCTAssertFalse(configuration.keepDomainDiagnostics)
        XCTAssertFalse(configuration.keepNetworkActivity)
        XCTAssertFalse(configuration.keepLavaGuardProgress)
        XCTAssertTrue(configuration.lavaGuardUnlocks.isUnlocked(guardID: "purpleObsidian"))
        XCTAssertTrue(configuration.protectionEnabled)
        XCTAssertEqual(configuration.customBlocklists, [customSource])
        XCTAssertFalse(configuration.isPaid)
        XCTAssertNil(configuration.qaProbeSet)
    }

    func testEncryptedFallbackSelectionRoundTripsThroughBackupPayload() throws {
        let configuration = AppConfiguration(
            resolverPresetID: DNSResolverPreset.device.id,
            usesEncryptedDeviceDNSFallback: true,
            fallbackResolverPresetID: DNSResolverPreset.cloudflareDoH.id
        )

        // Encode + decode the payload (not just the in-memory copy) to prove the new
        // keys persist, then restore and confirm the selection survives end to end.
        let payload = BackupConfigurationPayload(configuration: configuration)
        let decodedPayload = try JSONDecoder().decode(
            BackupConfigurationPayload.self,
            from: try JSONEncoder().encode(payload)
        )
        let restored = decodedPayload.restoredConfiguration()

        XCTAssertTrue(restored.usesEncryptedDeviceDNSFallback)
        XCTAssertEqual(restored.fallbackResolverPresetID, DNSResolverPreset.cloudflareDoH.id)
        XCTAssertEqual(restored.fallbackResolverPreset, .cloudflareDoH)
    }

    func testLegacyPayloadHapticFeedbackPreferenceIsIgnored() throws {
        let data = Data("""
        {
          "schemaVersion": 1,
          "enabledBlocklistIDs": [],
          "allowedDomains": [],
          "blockedDomains": [],
          "resolverPresetID": "google-public-dns",
          "fallbackToDeviceDNS": true,
          "keepFilteringCounts": true,
          "keepDomainDiagnostics": false,
          "keepNetworkActivity": true,
          "playsHapticFeedback": false,
          "protectionEnabledHint": false
        }
        """.utf8)

        let payload = try JSONDecoder().decode(BackupConfigurationPayload.self, from: data)
        let restored = payload.restoredConfiguration()
        let encodedPayload = String(decoding: try JSONEncoder().encode(payload), as: UTF8.self)
        let encodedConfiguration = String(decoding: try JSONEncoder().encode(restored), as: UTF8.self)

        XCTAssertFalse(encodedPayload.contains("playsHapticFeedback"))
        XCTAssertFalse(encodedConfiguration.contains("playsHapticFeedback"))
    }

    func testPayloadPreservesCustomResolverAddressAndName() throws {
        let configuration = AppConfiguration(
            resolverPresetID: DNSResolverPreset.customID,
            customResolverAddress: "https://dns.example/dns-query",
            customResolverSecondaryAddress: "https://backup.example/dns-query",
            customResolverName: "Home DNS",
            keepDomainDiagnostics: true
        )

        let payload = BackupConfigurationPayload(configuration: configuration)
        let restored = payload.restoredConfiguration()

        XCTAssertEqual(payload.resolverPresetID, DNSResolverPreset.customID)
        XCTAssertEqual(payload.customResolverAddress, "https://dns.example/dns-query")
        XCTAssertEqual(payload.customResolverSecondaryAddress, "https://backup.example/dns-query")
        XCTAssertEqual(payload.customResolverName, "Home DNS")
        XCTAssertEqual(restored.resolverPresetID, DNSResolverPreset.customID)
        XCTAssertEqual(restored.customResolverAddress, "https://dns.example/dns-query")
        XCTAssertEqual(restored.customResolverSecondaryAddress, "https://backup.example/dns-query")
        XCTAssertEqual(restored.customResolverName, "Home DNS")
        XCTAssertEqual(restored.resolverPreset.displayName, "Home DNS")
        XCTAssertEqual(restored.resolverPreset.dohEndpoints.map { $0.url.absoluteString }, [
            "https://dns.example/dns-query",
            "https://backup.example/dns-query"
        ])
    }

    func testRestoreMigratesKnownCustomBlocklistURLToCatalogSource() throws {
        let customOISD = try CustomBlocklistSource(
            id: "custom-oisd",
            displayName: "OISD as Custom",
            rawURL: DefaultCatalog.oisdSmall.sourceURL.absoluteString
        )
        let payload = BackupConfigurationPayload(
            schemaVersion: 1,
            enabledBlocklistIDs: ["blocklistproject-basic", customOISD.id],
            allowedDomains: [],
            blockedDomains: [],
            resolverPresetID: DNSResolverPreset.google.id,
            keepDomainDiagnostics: true,
            protectionEnabledHint: true,
            customBlocklists: [customOISD]
        )

        let configuration = payload.restoredConfiguration()

        XCTAssertEqual(
            configuration.enabledBlocklistIDs,
            ["blocklistproject-basic", DefaultCatalog.oisdSmall.id]
        )
        XCTAssertTrue(configuration.customBlocklists.isEmpty)
    }

    func testFutureSchemaVersionPayloadIsRejectedBeforeAnyRestore() throws {
        // A vN+1 backup restored on a vN device must be REFUSED at decode time. If it were
        // accepted, `restoredConfiguration()` would decode a lossy subset and a later re-seal
        // would upload a downgraded schema-1 envelope OVER the newer single-envelope backup,
        // permanently clobbering it. So decode itself has to throw before any state mutation.
        let futureSchema = BackupConfigurationPayload.currentSupportedSchemaVersion + 1
        let data = Data("""
        {
          "schemaVersion": \(futureSchema),
          "enabledBlocklistIDs": [],
          "allowedDomains": [],
          "blockedDomains": [],
          "resolverPresetID": "google-public-dns",
          "fallbackToDeviceDNS": true,
          "keepFilteringCounts": true,
          "keepDomainDiagnostics": false,
          "keepNetworkActivity": true,
          "protectionEnabledHint": false,
          "someFutureField": "ignored"
        }
        """.utf8)

        XCTAssertThrowsError(
            try JSONDecoder().decode(BackupConfigurationPayload.self, from: data)
        ) { error in
            XCTAssertEqual(
                error as? BackupConfigurationPayloadError,
                .unsupportedSchemaVersion(futureSchema)
            )
        }
    }

    func testCurrentSchemaVersionPayloadStillDecodesAndRestores() throws {
        // The ceiling must accept the current (and by extension older) schema — the reject
        // is strictly `schemaVersion > currentSupportedSchemaVersion`, never `==` or below.
        let data = Data("""
        {
          "schemaVersion": \(BackupConfigurationPayload.currentSupportedSchemaVersion),
          "enabledBlocklistIDs": ["blocklistproject-basic"],
          "allowedDomains": ["school.example"],
          "blockedDomains": ["casino.example"],
          "resolverPresetID": "google-public-dns",
          "fallbackToDeviceDNS": true,
          "keepFilteringCounts": true,
          "keepDomainDiagnostics": false,
          "keepNetworkActivity": true,
          "protectionEnabledHint": true
        }
        """.utf8)

        let payload = try JSONDecoder().decode(BackupConfigurationPayload.self, from: data)
        XCTAssertEqual(payload.schemaVersion, BackupConfigurationPayload.currentSupportedSchemaVersion)

        let restored = payload.restoredConfiguration()
        XCTAssertEqual(restored.enabledBlocklistIDs, ["blocklistproject-basic"])
        XCTAssertEqual(restored.blockedDomains, ["casino.example"])
        XCTAssertTrue(restored.protectionEnabled)
    }

    func testMissingSchemaVersionDefaultsToOneAndRestores() throws {
        // A legacy payload with no `schemaVersion` key defaults to 1, which is <= the ceiling,
        // so it must still restore rather than be treated as an unknown/future schema.
        let data = Data("""
        {
          "enabledBlocklistIDs": ["blocklistproject-basic"],
          "allowedDomains": [],
          "blockedDomains": [],
          "resolverPresetID": "google-public-dns",
          "keepDomainDiagnostics": false,
          "protectionEnabledHint": true
        }
        """.utf8)

        let payload = try JSONDecoder().decode(BackupConfigurationPayload.self, from: data)
        XCTAssertEqual(payload.schemaVersion, 1)
        XCTAssertEqual(payload.restoredConfiguration().enabledBlocklistIDs, ["blocklistproject-basic"])
    }

    func testBackupNeverIncludesDownloadedCustomBlocklistContents() throws {
        let customSource = try CustomBlocklistSource(
            id: "custom-sensitive",
            displayName: "Sensitive",
            rawURL: "https://sensitive.example.com/private-list.txt",
            lastAcceptedHash: String(repeating: "a", count: 64)
        )
        let configuration = AppConfiguration(
            enabledBlocklistIDs: [customSource.id],
            customBlocklists: [customSource]
        )

        let data = try JSONEncoder().encode(BackupConfigurationPayload(configuration: configuration))
        let decodedPayload = try JSONDecoder().decode(BackupConfigurationPayload.self, from: data)
        let json = String(decoding: data, as: UTF8.self)

        XCTAssertEqual(decodedPayload.customBlocklists, [customSource])
        XCTAssertFalse(json.contains("ads.example.com"))
        XCTAssertFalse(json.contains("0.0.0.0"))
        XCTAssertFalse(json.contains("latest.txt"))
    }
}
