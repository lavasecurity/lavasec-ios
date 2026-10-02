import XCTest
@testable import LavaSecCore
@testable import LavaSecAppServices
@testable import LavaSecKit

final class BackupRestorePlanTests: XCTestCase {
    private func prepare(
        _ incoming: AppConfiguration,
        current: AppConfiguration = AppConfiguration(),
        library: FilterLibrary? = nil,
        incomingLibrary: FilterLibrary? = nil,
        supportsDNSOverQUIC: Bool = true
    ) throws -> BackupRestorePlan {
        try BackupRestorePlan(
            payload: BackupConfigurationPayload(configuration: incoming, filterLibrary: incomingLibrary),
            currentConfiguration: current,
            currentLibrary: library ?? FilterLibrary(migratingLegacy: current),
            supportsDNSOverQUIC: supportsDNSOverQUIC
        )
    }

    func testDNSPatchOptInRemainsLocalToTheDevice() throws {
        for enabled in [true, false] {
            let result = try prepare(AppConfiguration(dnsPatchEnabled: !enabled),
                current: AppConfiguration(dnsPatchEnabled: enabled))
            XCTAssertEqual(result.configuration.dnsPatchEnabled, enabled)
        }
    }

    func testParsingFormatChangeAppearsInCustomDefinitionChanges() throws {
        let original = try CustomBlocklistSource(id: "custom-format", displayName: "My list",
            rawURL: "https://lists.example/list.txt", parseFormat: .auto, createdAt: .distantPast)
        let replacement = try CustomBlocklistSource(id: original.id, displayName: original.displayName,
            rawURL: original.sourceURL.absoluteString, parseFormat: .hosts, createdAt: original.createdAt)
        var current = AppConfiguration()
        current.customBlocklists = [original]
        var incoming = current
        incoming.customBlocklists = [replacement]
        let change = try XCTUnwrap(prepare(incoming, current: current).filterChanges.first)
        XCTAssertTrue(change.hasChanges)
        XCTAssertEqual(change.removedCustomBlocklists.map(\.parseFormat), [.auto])
        XCTAssertEqual(change.addedCustomBlocklists.map(\.parseFormat), [.hosts])
    }

    func testCustomContentVersionChangeIsDisclosedWithoutDependingOnNamesOrURLs() throws {
        let original = try CustomBlocklistSource(id: "custom-one", displayName: "My list",
            rawURL: "https://lists.example/list.txt", createdAt: .distantPast, lastAcceptedHash: "version-a")
        for hash in ["version-a", "version-b", nil] {
            let replacement = try CustomBlocklistSource(id: original.id, displayName: original.displayName,
                rawURL: original.sourceURL.absoluteString, createdAt: original.createdAt, lastAcceptedHash: hash)
            let current = AppConfiguration(customBlocklists: [original])
            let incoming = AppConfiguration(customBlocklists: [replacement])
            let plan = try prepare(incoming, current: current)
            XCTAssertEqual(plan.filterChanges.flatMap(\.changedCustomContentVersionIDs), hash == "version-a" ? [] : [original.id])
        }
    }

    func testUnchangedResolverStillExposesFilterWeakening() throws {
        let current = AppConfiguration(protectionEnabled: true, enabledBlocklistIDs: ["one", "two"],
                                       blockedDomains: ["blocked.example"])
        var incoming = current
        incoming.protectionEnabled = false
        incoming.enabledBlocklistIDs = []
        incoming.blockedDomains = []
        let plan = try prepare(incoming, current: current)
        XCTAssertFalse(plan.requiresResolverConfirmation)
        XCTAssertTrue(plan.previousConfiguration.protectionEnabled)
        XCTAssertTrue(plan.configuration.protectionEnabled)
        let change = try XCTUnwrap(plan.filterChanges.first)
        XCTAssertEqual(change.selectionDiff.removedBlocklistIDs, ["one", "two"])
        XCTAssertEqual(change.selectionDiff.removedBlockedDomains, ["blocked.example"])
    }

    func testBackupProtectionHintPreservesThisDevicesIntent() throws {
        for currentProtection in [false, true] {
            for backupProtection in [false, true] {
                let current = AppConfiguration(protectionEnabled: currentProtection)
                let incoming = AppConfiguration(protectionEnabled: backupProtection)
                let plan = try prepare(incoming, current: current)
                XCTAssertEqual(plan.configuration.protectionEnabled, currentProtection)
                XCTAssertEqual(plan.previousConfiguration.protectionEnabled, currentProtection)
            }
        }
    }

    func testUnlockLedgerChangesAreAvailableEvenWhenRecordingPreferenceIsUnchanged() throws {
        for enabled in [false, true] {
            let ledger = LavaGuardAchievementLedger(records: [
                LavaGuardUnlockRecord(guardID: "emerald", unlockedAt: .distantPast)
            ])
            let current = AppConfiguration(keepLavaGuardProgress: enabled, lavaGuardUnlocks: ledger)
            let incoming = AppConfiguration(keepLavaGuardProgress: enabled)
            let plan = try prepare(incoming, current: current)
            XCTAssertEqual(plan.previousConfiguration.lavaGuardUnlocks, ledger)
            XCTAssertTrue(plan.configuration.lavaGuardUnlocks.records.isEmpty)
            XCTAssertEqual(plan.configuration.keepLavaGuardProgress, enabled)
        }
    }

    func testRecordingPreferencesAreExplicitOnBothSidesOfReview() throws {
        for enabled in [false, true] {
            let current = AppConfiguration(keepFilteringCounts: enabled, keepDomainDiagnostics: enabled,
                                           keepNetworkActivity: enabled, keepLavaGuardProgress: enabled)
            let incoming = AppConfiguration(keepFilteringCounts: !enabled, keepDomainDiagnostics: !enabled,
                                            keepNetworkActivity: !enabled, keepLavaGuardProgress: !enabled)
            let plan = try prepare(incoming, current: current)
            XCTAssertEqual(plan.previousConfiguration.keepDomainDiagnostics, enabled)
            XCTAssertEqual(plan.configuration.keepDomainDiagnostics, !enabled)
            XCTAssertEqual(plan.configuration.keepFilteringCounts, !enabled)
            XCTAssertEqual(plan.configuration.keepNetworkActivity, !enabled)
            XCTAssertEqual(plan.configuration.keepLavaGuardProgress, !enabled)
        }
    }

    func testReviewedGenerationCannotOverwriteANewerExtensionCommit() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let configURL = directory.appendingPathComponent("configuration.json")
        let libraryURL = directory.appendingPathComponent("library.json")
        let initial = try SharedFilterStatePersistence.writeConfigurationAndLibrary(
            configuration: AppConfiguration(), library: FilterLibrary(migratingLegacy: AppConfiguration()),
            configurationURL: configURL, filterLibraryURL: libraryURL
        )
        let plan = try prepare(AppConfiguration(protectionEnabled: true), current: initial.configuration,
                               library: initial.library)
        var newer = initial.configuration
        newer.blockedDomains = ["newer.example"]
        _ = try SharedFilterStatePersistence.writeConfigurationAndLibrary(
            configuration: newer, library: initial.library, configurationURL: configURL, filterLibraryURL: libraryURL
        )
        let configBefore = try Data(contentsOf: configURL)
        let libraryBefore = try Data(contentsOf: libraryURL)
        XCTAssertThrowsError(try SharedFilterStatePersistence.writeConfigurationAndLibrary(
            configuration: plan.configuration, library: plan.library,
            configurationURL: configURL, filterLibraryURL: libraryURL,
            prioritizesConfigurationDurability: true,
            rejectsAdvancedBeyond: plan.previousConfiguration.configurationGeneration
        )) { XCTAssertTrue($0 is SharedFilterStatePersistence.StaleBaseGenerationError) }
        XCTAssertEqual(try Data(contentsOf: configURL), configBefore)
        XCTAssertEqual(try Data(contentsOf: libraryURL), libraryBefore)
    }

    func testChangedValidResolverNeedsSeparateAcknowledgement() throws {
        let current = AppConfiguration(isPaid: true)
        let library = FilterLibrary(migratingLegacy: current)
        var incoming = current
        incoming.resolverPresetID = DNSResolverPreset.customID
        incoming.customResolverAddress = "192.168.1.53"
        let plan = try prepare(incoming, current: current, library: library)
        XCTAssertEqual(plan.configuration.customResolverAddress, "192.168.1.53")
        XCTAssertThrowsError(try plan.validateConfirmation(
            currentConfiguration: current, currentLibrary: library, resolverChangeConfirmed: false
        )) { XCTAssertEqual($0 as? BackupRestorePlanError, .resolverConfirmationRequired) }
        XCTAssertNoThrow(try plan.validateConfirmation(
            currentConfiguration: current, currentLibrary: library, resolverChangeConfirmed: true
        ))
    }

    func testInvalidPrimarySecondaryAndDormantFallbackAreRejected() {
        let current = AppConfiguration(isPaid: true)
        var candidates: [AppConfiguration] = []
        var primary = current
        primary.resolverPresetID = DNSResolverPreset.customID
        primary.customResolverAddress = "http://resolver.example/dns-query"
        candidates.append(primary)
        primary.customResolverAddress = "192.168.1.53"
        primary.customResolverSecondaryAddress = "127.0.0.1"
        candidates.append(primary)
        primary.customResolverSecondaryAddress = "https://resolver.example/dns-query"
        candidates.append(primary) // Transport mismatch.
        var dormant = current
        dormant.fallbackCustomResolverAddress = "http://resolver.example/dns-query"
        candidates.append(dormant)
        dormant.fallbackCustomResolverAddress = nil
        dormant.fallbackCustomResolverSecondaryAddress = "192.168.1.54"
        candidates.append(dormant) // Secondary alone cannot become a valid pair later.
        var empty = current
        empty.resolverPresetID = DNSResolverPreset.customID
        candidates.append(empty)
        for incoming in candidates {
            XCTAssertThrowsError(try prepare(incoming, current: current)) { error in
                guard case .invalidResolver = error as? BackupRestorePlanError else {
                    return XCTFail("Expected resolver validation, got \(error)")
                }
            }
        }
    }

    func testDormantPrimaryAndFallbackNamesAreReviewedDNSChanges() throws {
        let current = AppConfiguration(isPaid: true)
        for fallback in [false, true] {
            var incoming = current
            if fallback { incoming.fallbackCustomResolverName = "Different provider" }
            else { incoming.customResolverName = "Different provider" }
            let plan = try prepare(incoming, current: current)
            XCTAssertTrue(plan.requiresResolverConfirmation)
            XCTAssertThrowsError(try plan.validateConfirmation(currentConfiguration: current,
                currentLibrary: plan.previousLibrary, resolverChangeConfirmed: false)) {
                XCTAssertEqual($0 as? BackupRestorePlanError, .resolverConfirmationRequired)
            }
        }
    }

    func testFallbackChangeAndDormantSavedAddressRequireAcknowledgement() throws {
        let current = AppConfiguration(isPaid: true)
        var incoming = current
        incoming.fallbackCustomResolverAddress = "192.168.1.53"
        XCTAssertTrue(try prepare(incoming, current: current).requiresResolverConfirmation)
        incoming.fallbackCustomResolverAddress = nil
        incoming.fallbackToDeviceDNS.toggle()
        XCTAssertTrue(try prepare(incoming, current: current).requiresResolverConfirmation)
    }

    func testCustomResolverRequiresCurrentTierForPrimaryAndFallback() {
        for fallback in [false, true] {
            var incoming = AppConfiguration(isPaid: true)
            if fallback {
                incoming.fallbackResolverPresetID = DNSResolverPreset.customID
                incoming.fallbackCustomResolverAddress = "192.168.1.53"
            } else {
                incoming.resolverPresetID = DNSResolverPreset.customID
                incoming.customResolverAddress = "192.168.1.53"
            }
            XCTAssertThrowsError(try prepare(incoming)) {
                XCTAssertEqual($0 as? BackupRestorePlanError, .customDNSRequiresPlus)
            }
        }
    }

    func testUnsupportedDoQIsRejectedUsingInteractiveCapability() {
        var incoming = AppConfiguration(isPaid: true)
        incoming.customResolverAddress = "quic://dns.example"
        incoming.resolverPresetID = DNSResolverPreset.customID
        XCTAssertThrowsError(try prepare(incoming, current: incoming, supportsDNSOverQUIC: false))
    }

    func testLocalEntitlementChainingAndGenerationSurviveRestore() throws {
        let current = AppConfiguration(isPaid: true, configurationGeneration: 42,
                                       chainedUpstreamEnabled: true, chainedTierOneFallbackEnabled: false)
        let plan = try prepare(AppConfiguration(), current: current)
        XCTAssertTrue(plan.configuration.isPaid)
        XCTAssertTrue(plan.configuration.wireGuardSetupEnabled)
        XCTAssertTrue(plan.configuration.chainedUpstreamEnabled)
        XCTAssertFalse(plan.configuration.chainedTierOneFallbackEnabled)
        XCTAssertEqual(plan.configuration.configurationGeneration, 42)
    }

    func testNormalizedLibraryIsAuthoritativeAndAllRemovalsAreReviewed() throws {
        let current = AppConfiguration(blockedDomains: ["old.example"])
        let old = FilterLibrary(filters: [Filter(id: "old", name: "Old", blockedDomains: ["old.example"])],
                                activeFilterID: "old")
        let incoming = FilterLibrary(filters: [Filter(id: "new", name: "New", blockedDomains: ["new.example"],
                                                     lastCompiledToken: "foreign-device-token")],
                                     activeFilterID: "missing", schemaVersion: 1)
        let plan = try prepare(AppConfiguration(blockedDomains: ["ignored.example"]),
                               current: current, library: old, incomingLibrary: incoming)
        XCTAssertEqual(plan.configuration.blockedDomains, ["new.example"])
        XCTAssertEqual(plan.library.activeFilterID, "new")
        XCTAssertEqual(plan.library.schemaVersion, FilterLibrary.currentSchemaVersion)
        XCTAssertNil(plan.library.activeFilter.lastCompiledToken)
        XCTAssertEqual(plan.filterChanges.count, 2)
        XCTAssertEqual(plan.filterChanges.first { $0.after == nil }?.before?.name, "Old")
    }

    func testConfirmationRejectsConfigurationTierGenerationAndLibraryChanges() throws {
        let current = AppConfiguration()
        let library = FilterLibrary(migratingLegacy: current)
        let plan = try prepare(current, current: current, library: library)
        var changedConfigurations: [AppConfiguration] = []
        var changed = current
        changed.protectionEnabled.toggle()
        changedConfigurations.append(changed)
        changed = current
        changed.isPaid.toggle()
        changedConfigurations.append(changed)
        changed = current
        changed.configurationGeneration += 1
        changedConfigurations.append(changed)
        for configuration in changedConfigurations {
            XCTAssertThrowsError(try plan.validateConfirmation(
                currentConfiguration: configuration, currentLibrary: library, resolverChangeConfirmed: true
            )) { XCTAssertEqual($0 as? BackupRestorePlanError, .staleReview) }
        }
        var changedLibrary = library
        changedLibrary.append(Filter(id: "new"))
        XCTAssertThrowsError(try plan.validateConfirmation(
            currentConfiguration: current, currentLibrary: changedLibrary, resolverChangeConfirmed: true
        )) { XCTAssertEqual($0 as? BackupRestorePlanError, .staleReview) }
    }

    func testFilterSummaryDetectsReplacedURLWithSameIDAndIgnoresLocalCache() throws {
        let beforeSource = try CustomBlocklistSource(id: "custom", displayName: "Private list",
                                                    rawURL: "https://old.example/list.txt")
        let afterSource = try CustomBlocklistSource(id: "custom", displayName: "Private list",
                                                   rawURL: "https://new.example/list.txt")
        let before = Filter(customBlocklists: [beforeSource], lastCompiledToken: "local-cache")
        var after = before.strippingLocalCacheState()
        XCTAssertFalse(FilterReplacementSummary(before: before, after: after).hasChanges)
        after.customBlocklists = [afterSource]
        let summary = FilterReplacementSummary(before: before, after: after)
        XCTAssertEqual(summary.removedCustomBlocklists, [beforeSource])
        XCTAssertEqual(summary.addedCustomBlocklists, [afterSource])
        XCTAssertTrue(summary.hasChanges)
    }
}
