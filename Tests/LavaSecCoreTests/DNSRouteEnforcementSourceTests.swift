import XCTest

final class DNSRouteEnforcementSourceTests: XCTestCase {
    func testEverySavedProfileUsesTheLiveRoutingPolicyAndIncludesLocalRoutes() throws {
        let source = try readSource(.appViewModelSupport)
        let apply = try sourceBlock(in: source,
            startingAt: "func applyConfiguration(to manager:",
            endingBefore: "func saveAndReload(")
        XCTAssertTrue(apply.contains("provider.enforceRoutes = enforcesDNSRoutes()"))
        XCTAssertTrue(apply.contains("provider.includeAllNetworks = includesAllNetworks()"))
        XCTAssertTrue(apply.contains("provider.excludeLocalNetworks = false"))
        XCTAssertTrue(try readSource(.appViewModelCore).contains(
            "enforcesDNSRoutes: { [weak self] in self?.shouldEnforceDNSRoutes ?? false }"))
        XCTAssertTrue(source.contains("store.loadStoredConfigurationRecord()?.configuration.activeConfiguration"))
        XCTAssertTrue(source.contains("DNSRouteEnforcementPolicy.shouldEnforce("))
    }

    func testFullTunnelExperimentIsDisabledInShippingBuildsAndUsesFencedApply() throws {
        let support = try readSource(.appViewModelSupport)
        let policy = try sourceBlock(in: support,
            startingAt: "var shouldIncludeAllNetworksForQA:",
            endingBefore: "var storedChainedRoutingPolicyForEnforcement:")
        XCTAssertTrue(sourceContainsInOrder([
            "#if DEBUG || LAVA_QA_TOOLS", "DNSRouteEnforcementPolicy.shouldIncludeAllNetworks(",
            "#else", "return false", "#endif"
        ], in: policy))
        let source = try readAppViewModelSource()
        let hook = try sourceBlock(in: source,
            startingAt: "if defaults.object(forKey: \"LavaQAIncludeAllNetworks\") != nil",
            endingBefore: "// Sustained non-DNS demand")
        XCTAssertTrue(sourceContainsInOrder([
            "let accepted = !requested || DNSRouteEnforcementPolicy.shouldIncludeAllNetworks(",
            "if accepted", "defaults.set(requested", "qaRoutingProfileChanged = true",
            "if qaRoutingProfileChanged { await applyQARoutingProfile() }"
        ], in: hook))
        XCTAssertFalse(hook.contains("startVPNTunnel"))
    }

    func testQARoutingRollbackCanRewriteADisconnectedProfileWhilePreservingOff() throws {
        let source = try readAppViewModelSource()
        let helper = try sourceBlock(in: source, startingAt: "private func applyQARoutingProfile()",
                                     endingBefore: "/// Drives sustained GENERAL")
        for guardText in ["hasCompletedOnboarding, userProtectionIntent.isEnabled",
                          "protectionActionOrchestrator.claim(.reconnect)",
                          "self.userProtectionIntent.revision == revision",
                          "captureExternalRestartGeneration()) == generation",
                          "ProtectionRestoreIntentStore.read(containerURL: container)",
                          "requiresActiveSession: false"] {
            XCTAssertTrue(helper.contains(guardText), guardText)
        }
        XCTAssertFalse(helper.contains("persistsExplicitIntent: true"))
        XCTAssertFalse(helper.contains("startVPNTunnel"))
    }

    func testLegacyConnectedProfileMigrationPreservesOffAndRestartIntent() throws {
        let source = try readSource(.appViewModelTunnelHealth)
        let migration = try sourceBlock(in: source,
            startingAt: "func reconcileDNSRouteEnforcementIfNeeded()",
            endingBefore: "func notifyTunnelSnapshotUpdated(")
        for boundary in [
            "!isHeadless, hasCompletedOnboarding, userProtectionIntent.isEnabled",
            "!didAttemptDNSRouteEnforcementMigration",
            "vpnStatus == .connected",
            "shouldEnforceDNSRoutes",
            "!provider.includeAllNetworks",
            "!provider.enforceRoutes || provider.excludeLocalNetworks",
            "protectionActionOrchestrator.claim(.reconnect)",
            "defer { protectionActionOrchestrator.release(.reconnect) }",
            "self.userProtectionIntent.revision == intentRevision",
            "LavaProtectionCommandService.captureExternalRestartGeneration()) == generation",
            "ProtectionRestoreIntentStore.read(containerURL: containerURL)",
            "requiresActiveSession: true"
        ] {
            XCTAssertTrue(migration.contains(boundary), boundary)
        }
        XCTAssertFalse(migration.contains("persistsExplicitIntent: true"))
        XCTAssertFalse(migration.contains("saveToPreferences"))
        let lifecycle = try readSource(.appViewModelProtectionLifecycle)
        let refresh = try sourceBlock(in: lifecycle,
            startingAt: "func refreshProtectionStatus(force:", endingBefore: "\n}\n")
        XCTAssertTrue(refresh.contains("await reconcileDNSRouteEnforcementIfNeeded()"))
    }
}
