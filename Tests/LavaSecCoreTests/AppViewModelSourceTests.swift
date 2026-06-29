import XCTest

final class AppViewModelSourceTests: XCTestCase {
    func testNotifierUsesPreClearHistoryAndOnlyProblemsAdvanceThrottle() throws {
        let source = try Self.source(named: "AppViewModel.swift", in: "LavaSecApp")

        // The app notifier must evaluate notification(for:) against the captured
        // pre-clear `history`, not a re-read (which would have dropped the
        // unresolved-problem marker the silent banner-clear keys off).
        let scheduleBlock = try Self.sourceBlock(
            in: source,
            startingAt: "func scheduleIfNeeded(",
            endingBefore: "func requestAuthorization()"
        )
        XCTAssertTrue(
            scheduleBlock.contains("clearResolvedProblemNotifications(")
                && scheduleBlock.contains("resolvedNotificationIdentifiers,")
                && scheduleBlock.contains("cooldownAnchor: ProtectionConnectivityNotificationPolicy.deliveryCooldownAnchorAfterClear("),
            "The clear must pass the encrypted-fallback cooldown anchor so a covered-then-lapsed wedge re-posts."
        )
        XCTAssertFalse(
            scheduleBlock.contains("history: notificationHistory,"),
            "The notifier must use the pre-clear `history`, not a re-read."
        )

        // The 600s problem throttle keys off the delivered-at timestamp, so only a
        // problem delivery may advance it. (Only actionable problem banners are
        // delivered now — no recovery acknowledgement.)
        let recordBlock = try Self.sourceBlock(
            in: source,
            startingAt: "private func recordDelivery(of notification:",
            endingBefore: "private func removeSupersededNotifications("
        )
        let prefix = try Self.sourceBlock(
            in: recordBlock,
            startingAt: "defaults.set(",
            endingBefore: "if notification.kind.isProblem {"
        )
        XCTAssertFalse(prefix.contains("protectionLastDeliveredNotificationAtDefaultsKey"))
        let problemBranch = try Self.sourceBlock(
            in: source,
            startingAt: "if notification.kind.isProblem {",
            endingBefore: "private func removeSupersededNotifications("
        )
        XCTAssertTrue(problemBranch.contains("protectionLastDeliveredNotificationAtDefaultsKey"))
        // No recovery-acknowledgement delivery path remains in recordDelivery.
        XCTAssertFalse(recordBlock.contains(".reconnected"))
    }

    func testEncryptedFallbackSilentClearAlsoLiftsTheDuplicateGuardID() throws {
        let source = try Self.source(named: "AppViewModel.swift", in: "LavaSecApp")
        // Back-dating `lastDeliveredAt` alone is not enough: the silent supersede removed
        // the reconnect banner, so the persisted last-delivered *id* must also be cleared.
        // Otherwise a lapse back to `.needsReconnect` with the same event id is suppressed by
        // notification(for:)'s exact-id duplicate guard until a later probe shifts the id,
        // defeating the back-dated cooldown. The clear must live in the cooldown branch so a
        // real `.healthy` recovery (cooldownAnchor == nil) keeps its duplicate guard intact.
        let cooldownBranch = try Self.sourceBlock(
            in: source,
            startingAt: "if let cooldownAnchor {",
            endingBefore: "let requestIdentifiers = identifiers.map {"
        )
        XCTAssertTrue(
            cooldownBranch.contains("removeObject(forKey: LavaSecAppGroup.protectionLastDeliveredNotificationIDDefaultsKey)"),
            "The encrypted-fallback silent clear must also clear the duplicate-guard id so a lapsed wedge re-posts."
        )
    }

    func testEncryptedFallbackCoverageLiftsDuplicateGuardWithNoOutstandingBanner() throws {
        let source = try Self.source(named: "AppViewModel.swift", in: "LavaSecApp")
        let scheduleBlock = try Self.sourceBlock(
            in: source,
            startingAt: "func scheduleIfNeeded(",
            endingBefore: "func requestAuthorization()"
        )
        // When coverage engages with no problem banner outstanding (the resolved-ids list is
        // empty so clearResolvedProblemNotifications never runs), the duplicate-guard id must
        // still be lifted, else a later lapse to a same-second reconnect id is suppressed.
        let coverageBranch = try Self.sourceBlock(
            in: scheduleBlock,
            startingAt: "} else if assessment.severity == .usingEncryptedFallback {",
            endingBefore: "// Use the pre-clear"
        )
        XCTAssertTrue(
            coverageBranch.contains("removeObject(forKey: LavaSecAppGroup.protectionLastDeliveredNotificationIDDefaultsKey)"),
            "Coverage with no outstanding banner must lift the duplicate-guard id so a lapsed reconnect can re-post."
        )
    }

    func testLiveDNSSmokeCanForceResolverPresetFromLaunchArguments() throws {
        let source = try Self.source(named: "AppViewModel.swift", in: "LavaSecApp")
        let runtimeSupportBlock = try Self.sourceBlock(
            in: source,
            startingAt: "private static let protectionStopWaitTimeout",
            endingBefore: "#if DEBUG || LAVA_QA_TOOLS"
        )
        let launchArgumentBlock = try Self.sourceBlock(
            in: source,
            startingAt: "static let liveDNSSmokeTestLaunchArgument",
            endingBefore: "#endif"
        )
        let configurationBlock = try Self.sourceBlock(
            in: source,
            startingAt: "private func applyLiveDNSSmokeTestConfigurationIfRequested",
            endingBefore: "#endif"
        )

        XCTAssertTrue(launchArgumentBlock.contains("static let liveDNSSmokeResolverPresetIDLaunchArgument = \"-lava-live-dns-smoke-resolver-preset-id\""))
        XCTAssertTrue(launchArgumentBlock.contains("static let liveDNSSmokeCustomResolverLaunchArgument = \"-lava-live-dns-smoke-custom-resolver\""))
        XCTAssertTrue(runtimeSupportBlock.contains("static let supportsDNSOverQUICRuntime = true"))
        XCTAssertFalse(launchArgumentBlock.contains("static var supportsDNSOverQUICRuntime: Bool"))
        XCTAssertTrue(launchArgumentBlock.contains("private static var liveDNSSmokeResolverPresetIDOverride: String?"))
        XCTAssertTrue(launchArgumentBlock.contains("private static var liveDNSSmokeCustomResolverOverride: String?"))
        XCTAssertTrue(launchArgumentBlock.contains("DNSResolverPreset.allPresets.contains"))
        XCTAssertTrue(launchArgumentBlock.contains("DNSResolverPreset.customValidationMessage("))
        XCTAssertTrue(launchArgumentBlock.contains("supportsDNSOverQUIC: supportsDNSOverQUICRuntime"))
        XCTAssertTrue(configurationBlock.contains("if let customResolverAddress = Self.liveDNSSmokeCustomResolverOverride"))
        XCTAssertTrue(configurationBlock.contains("configuration.resolverPresetID = DNSResolverPreset.customID"))
        XCTAssertTrue(configurationBlock.contains("configuration.customResolverAddress = customResolverAddress"))
        XCTAssertTrue(configurationBlock.contains("configuration.customResolverSecondaryAddress = nil"))
        XCTAssertTrue(configurationBlock.contains("let liveDNSSmokeResolverPresetID = Self.liveDNSSmokeResolverPresetIDOverride ?? DNSResolverPreset.google.id"))
        XCTAssertTrue(configurationBlock.contains("configuration.resolverPresetID = liveDNSSmokeResolverPresetID"))
        XCTAssertTrue(configurationBlock.contains("try? persistConfigurationOnly()"))
        XCTAssertTrue(configurationBlock.contains("logVPNDebugEvent(\"live-dns-smoke-configuration-persisted\""))
        XCTAssertFalse(configurationBlock.contains("configuration.resolverPresetID = DNSResolverPreset.google.id"))
    }

    func testLiveDNSSmokeDebugProbeAlwaysRestartsTunnelAfterPersistingResolverOverride() throws {
        let source = try Self.source(named: "AppViewModel.swift", in: "LavaSecApp")
        let probeBlock = try Self.sourceBlock(
            in: source,
            startingAt: "private func runVPNStartupDebugProbe() async",
            endingBefore: "private func logVPNDebugEvent"
        )

        XCTAssertTrue(probeBlock.contains("if Self.isLiveDNSSmokeTestRequested"))
        XCTAssertTrue(probeBlock.contains("logVPNDebugEvent(\"probe-live-dns-smoke-force-reconnect\""))
        XCTAssertTrue(probeBlock.contains("await reconnectProtectionNow(playsOutcomeHaptic: false)"))
        XCTAssertTrue(probeBlock.contains("return"))
    }

    func testVPNLifecycleSmokeDebugProbeExercisesPauseResumeCommandPath() throws {
        let source = try Self.source(named: "AppViewModel.swift", in: "LavaSecApp")
        let launchArgumentBlock = try Self.sourceBlock(
            in: source,
            startingAt: "static let liveDNSSmokeTestLaunchArgument",
            endingBefore: "#endif"
        )
        let lifecycleProbeBlock = try Self.sourceBlock(
            in: source,
            startingAt: "private func runVPNLifecycleSmokeProbe() async",
            endingBefore: "private func logVPNDebugEvent"
        )

        XCTAssertTrue(launchArgumentBlock.contains("static let vpnLifecycleSmokeTestLaunchArgument = \"-lava-vpn-lifecycle-smoke-test\""))
        XCTAssertTrue(launchArgumentBlock.contains("private static var isVPNLifecycleSmokeTestRequested: Bool"))
        XCTAssertTrue(lifecycleProbeBlock.contains("await waitForProtectionToConnectForDebugProbe()"))
        XCTAssertTrue(lifecycleProbeBlock.contains("try await LavaProtectionCommandService.perform(.pauseFiveMinutes)"))
        XCTAssertTrue(lifecycleProbeBlock.contains("try await LavaProtectionCommandService.perform(.pauseTenMinutes)"))
        XCTAssertTrue(lifecycleProbeBlock.contains("try await LavaProtectionCommandService.perform(.resume)"))
        // The probe must drive the tunnel through the production provider-message
        // path (reloadProtectionPauseMessage) so the tunnel emits
        // `pause-state-refreshed`; the command service alone only posts the
        // Darwin signal, which the packet-tunnel extension never observes.
        XCTAssertTrue(lifecycleProbeBlock.contains("await notifyTunnelProtectionPauseUpdated()"))
        XCTAssertTrue(lifecycleProbeBlock.contains("logVPNDebugEvent(\"probe-lifecycle-after-pause\""))
        XCTAssertTrue(lifecycleProbeBlock.contains("logVPNDebugEvent(\"probe-lifecycle-after-resume\""))
    }

    func testProviderMessagesRecordLatencySpanRequestReplyAndErrors() throws {
        let source = try Self.source(named: "AppViewModel.swift", in: "LavaSecApp")
        let sendTunnelMessageBlock = try Self.sourceBlock(
            in: source,
            startingAt: "private func sendTunnelMessage(",
            endingBefore: "private func requestTunnelHealthFlush() async"
        )

        XCTAssertTrue(sendTunnelMessageBlock.contains("let operationID = operationID ?? LatencyOperationID.make()"))
        XCTAssertTrue(sendTunnelMessageBlock.contains("operationID: operationID"))
        XCTAssertTrue(sendTunnelMessageBlock.contains("LatencyTrace("))
        XCTAssertTrue(sendTunnelMessageBlock.contains("LatencyDebugLogEventSink(operationKind: \"providerMessage\""))
        XCTAssertTrue(sendTunnelMessageBlock.contains("trace.record(\"provider.message.request\""))
        XCTAssertTrue(sendTunnelMessageBlock.contains("let span = trace.beginSpan(\"provider.message.reply\""))
        XCTAssertTrue(sendTunnelMessageBlock.contains("let messageData = LavaSecProviderMessageCodec.encode(kind: message, operationID: operationID.rawValue)"))
        XCTAssertTrue(sendTunnelMessageBlock.contains("try session.sendProviderMessage(messageData)"))
        XCTAssertTrue(sendTunnelMessageBlock.contains("span.end(details: [\"status\": \"reply\"])"))
        XCTAssertTrue(sendTunnelMessageBlock.contains("span.end(details: [\"status\": \"timeout\"])"))
        XCTAssertTrue(sendTunnelMessageBlock.contains("details[\"status\"] = \"send-error\""))
        XCTAssertTrue(sendTunnelMessageBlock.contains("span.end(details: details)"))
        XCTAssertTrue(sendTunnelMessageBlock.contains("\"kind\": message"))
        XCTAssertFalse(sendTunnelMessageBlock.contains("domain"))
    }

    func testProtectionActionsRecordRootLatencySpansAndPropagateOperationIDs() throws {
        let source = try Self.source(named: "AppViewModel.swift", in: "LavaSecApp")
        let enableBlock = try Self.sourceBlock(
            in: source,
            startingAt: "private func enableProtection(",
            endingBefore: "private func disableProtection("
        )
        let disableBlock = try Self.sourceBlock(
            in: source,
            startingAt: "private func disableProtection(",
            endingBefore: "private func reconnectProtectionNow"
        )
        let refreshBlock = try Self.sourceBlock(
            in: source,
            startingAt: "private func performCatalogSync(",
            endingBefore: "func syncCatalogIfStale()"
        )
        let pauseBlock = try Self.sourceBlock(
            in: source,
            startingAt: "func pauseProtectionTemporarily(for option: ProtectionPauseDuration)",
            endingBefore: "func resumeProtectionNow()"
        )
        let resumeBlock = try Self.sourceBlock(
            in: source,
            startingAt: "private func restoreFiltersAfterTemporaryProtectionPause(",
            endingBefore: "private func clearTemporaryProtectionPause()"
        )
        let notifySnapshotBlock = try Self.sourceBlock(
            in: source,
            startingAt: "private func notifyTunnelSnapshotUpdated(",
            endingBefore: "private func notifyTunnelProtectionPauseUpdated("
        )
        let notifyPauseBlock = try Self.sourceBlock(
            in: source,
            startingAt: "private func notifyTunnelProtectionPauseUpdated(",
            endingBefore: "private func restoreProtectionIfNeeded"
        )
        let cachedRefreshFallbackBlock = try Self.sourceBlock(
            in: source,
            startingAt: "private func loadCachedCatalogAfterSyncFailure(",
            endingBefore: "private func rebuildEnabledBlockRules()"
        )
        let latencyHelperBlock = try Self.sourceBlock(
            in: source,
            startingAt: "private func makeLatencyTrace(",
            endingBefore: "private func makeBugReportBundle"
        )

        XCTAssertTrue(latencyHelperBlock.contains("LatencyDebugLogEventSink(operationKind: operationKind)"))
        XCTAssertTrue(latencyHelperBlock.contains("logVPNDebugEvent(event, details: details)"))
        XCTAssertTrue(latencyHelperBlock.contains("LatencyTrace(operationID: operationID)"))

        XCTAssertTrue(enableBlock.contains("operationID: LatencyOperationID = .make()"))
        XCTAssertTrue(enableBlock.contains("makeLatencyTrace(operationID: operationID, operationKind: \"turnOn\")"))
        XCTAssertTrue(enableBlock.contains("trace.beginSpan(\"action.turnOn\""))
        XCTAssertTrue(enableBlock.contains("startVPNTunnel(options: ["))
        XCTAssertTrue(enableBlock.contains("LavaSecAppGroup.latencyOperationIDOptionKey: operationID.rawValue as NSString"))
        XCTAssertTrue(enableBlock.contains("span.end(details: [\"status\": actionStatus"))

        XCTAssertTrue(disableBlock.contains("operationID: LatencyOperationID = .make()"))
        XCTAssertTrue(disableBlock.contains("makeLatencyTrace(operationID: operationID, operationKind: \"turnOff\")"))
        XCTAssertTrue(disableBlock.contains("trace.beginSpan(\"action.turnOff\""))

        XCTAssertTrue(refreshBlock.contains("operationID: LatencyOperationID = .make()"))
        XCTAssertTrue(refreshBlock.contains("makeLatencyTrace(operationID: operationID, operationKind: \"refreshLists\")"))
        XCTAssertTrue(refreshBlock.contains("trace.beginSpan(\"action.refreshLists\""))
        XCTAssertTrue(refreshBlock.contains("notifyTunnelSnapshotUpdated(operationID: operationID)"))
        XCTAssertTrue(refreshBlock.contains("loadCachedCatalogAfterSyncFailure("))
        XCTAssertTrue(refreshBlock.contains("operationID: operationID"))
        XCTAssertTrue(cachedRefreshFallbackBlock.contains("operationID: LatencyOperationID"))
        XCTAssertTrue(cachedRefreshFallbackBlock.contains("notifyTunnelSnapshotUpdated(operationID: operationID)"))

        XCTAssertTrue(pauseBlock.contains("let operationID = LatencyOperationID.make()"))
        XCTAssertTrue(pauseBlock.contains("makeLatencyTrace(operationID: operationID, operationKind: \"pause\")"))
        XCTAssertTrue(pauseBlock.contains("trace.beginSpan(\"action.pause\""))
        XCTAssertTrue(pauseBlock.contains("notifyTunnelProtectionPauseUpdated(operationID: operationID)"))

        XCTAssertTrue(resumeBlock.contains("operationID: LatencyOperationID = .make()"))
        XCTAssertTrue(resumeBlock.contains("makeLatencyTrace(operationID: operationID, operationKind: \"resume\")"))
        XCTAssertTrue(resumeBlock.contains("trace.beginSpan(\"action.resume\""))
        XCTAssertTrue(resumeBlock.contains("notifyTunnelProtectionPauseUpdated(operationID: operationID)"))
        XCTAssertTrue(resumeBlock.contains("notifyTunnelSnapshotUpdated(operationID: operationID)"))

        XCTAssertTrue(notifySnapshotBlock.contains("operationID: LatencyOperationID? = nil"))
        XCTAssertTrue(notifySnapshotBlock.contains("operationID: operationID"))
        XCTAssertTrue(notifyPauseBlock.contains("operationID: LatencyOperationID? = nil"))
        XCTAssertTrue(notifyPauseBlock.contains("operationID: operationID"))
    }

    func testSwitchingResolversKeepsSavedCustomDNSEntry() throws {
        let source = try Self.source(named: "AppViewModel.swift", in: "LavaSecApp")
        let setResolverBlock = try Self.sourceBlock(
            in: source,
            startingAt: "func setResolver(_ preset: DNSResolverPreset)",
            endingBefore: "func setCustomResolverAddresses(primary rawPrimaryValue: String, secondary rawSecondaryValue: String)"
        )

        XCTAssertFalse(setResolverBlock.contains("configuration.customResolverAddress = nil"))
        XCTAssertFalse(setResolverBlock.contains("configuration.customResolverSecondaryAddress = nil"))
        XCTAssertFalse(setResolverBlock.contains("configuration.customResolverName = nil"))
        XCTAssertFalse(setResolverBlock.contains("preset.id != DNSResolverPreset.customID"))
    }

    func testSavingCustomResolverPersistsPrimaryAndSecondaryAddressesTogether() throws {
        let source = try Self.source(named: "AppViewModel.swift", in: "LavaSecApp")
        let customResolverBlock = try Self.sourceBlock(
            in: source,
            startingAt: "func setCustomResolverAddresses(primary rawPrimaryValue: String, secondary rawSecondaryValue: String)",
            endingBefore: "func setCustomResolverAddress(_ rawValue: String)"
        )

        XCTAssertTrue(customResolverBlock.contains("DNSResolverPreset.customValidationMessage("))
        XCTAssertTrue(customResolverBlock.contains("primaryRawValue: trimmedPrimaryValue"))
        XCTAssertTrue(customResolverBlock.contains("secondaryRawValue: trimmedSecondaryValue"))
        XCTAssertTrue(customResolverBlock.contains("supportsDNSOverQUIC: supportsDNSOverQUIC"))
        XCTAssertTrue(customResolverBlock.contains("configuration.customResolverAddress = trimmedPrimaryValue"))
        XCTAssertTrue(customResolverBlock.contains("configuration.customResolverSecondaryAddress = normalizedSecondaryValue"))
        XCTAssertTrue(customResolverBlock.contains("configuration.resolverPresetID = DNSResolverPreset.customID"))
        XCTAssertTrue(customResolverBlock.contains("persistResolverSettings(activity: .changeResolver)"))
    }

    func testClearingCustomResolverRemovesSavedEntryAndKeepsActiveResolverValid() throws {
        let source = try Self.source(named: "AppViewModel.swift", in: "LavaSecApp")
        let clearCustomResolverBlock = try Self.sourceBlock(
            in: source,
            startingAt: "func clearCustomResolver(fallback preset: DNSResolverPreset)",
            endingBefore: "func setCustomResolverAddress(_ rawValue: String)"
        )

        XCTAssertTrue(clearCustomResolverBlock.contains("configuration.customResolverAddress = nil"))
        XCTAssertTrue(clearCustomResolverBlock.contains("configuration.customResolverSecondaryAddress = nil"))
        XCTAssertTrue(clearCustomResolverBlock.contains("configuration.customResolverName = nil"))
        XCTAssertTrue(clearCustomResolverBlock.contains("if configuration.resolverPresetID == DNSResolverPreset.customID"))
        XCTAssertTrue(clearCustomResolverBlock.contains("configuration.resolverPresetID = fallbackPreset.id"))
        XCTAssertTrue(clearCustomResolverBlock.contains("persistResolverSettings(activity: .changeResolver)"))
    }

    func testFallbackResolverSettersMirrorPrimaryAndTargetFallbackFields() throws {
        let source = try Self.source(named: "AppViewModel.swift", in: "LavaSecApp")

        let toggleBlock = try Self.sourceBlock(
            in: source,
            startingAt: "func setUsesEncryptedDeviceDNSFallback(_ usesEncryptedDeviceDNSFallback: Bool)",
            endingBefore: "func setFallbackResolver(_ preset: DNSResolverPreset)"
        )
        XCTAssertTrue(toggleBlock.contains("guard configuration.usesEncryptedDeviceDNSFallback != usesEncryptedDeviceDNSFallback else"))
        XCTAssertTrue(toggleBlock.contains("configuration.usesEncryptedDeviceDNSFallback = usesEncryptedDeviceDNSFallback"))
        XCTAssertTrue(toggleBlock.contains("try persistConfigurationOnly()"))
        XCTAssertTrue(toggleBlock.contains("appendAppNetworkActivity(.toggleDeviceDNSFallback)"))
        XCTAssertTrue(toggleBlock.contains("sendTunnelMessage(LavaSecAppGroup.reloadConfigurationMessage)"))

        let setResolverBlock = try Self.sourceBlock(
            in: source,
            startingAt: "func setFallbackResolver(_ preset: DNSResolverPreset)",
            endingBefore: "func setFallbackCustomResolverAddresses(primary rawPrimaryValue: String, secondary rawSecondaryValue: String)"
        )
        XCTAssertTrue(setResolverBlock.contains("guard configuration.fallbackResolverPresetID != preset.id else"))
        XCTAssertTrue(setResolverBlock.contains("configuration.fallbackResolverPresetID = preset.id"))
        XCTAssertTrue(setResolverBlock.contains("persistResolverSettings(activity: .changeResolver)"))

        let setAddressesBlock = try Self.sourceBlock(
            in: source,
            startingAt: "func setFallbackCustomResolverAddresses(primary rawPrimaryValue: String, secondary rawSecondaryValue: String)",
            endingBefore: "func clearFallbackCustomResolver(fallback preset: DNSResolverPreset)"
        )
        XCTAssertTrue(setAddressesBlock.contains("supportsDNSOverQUIC: supportsDNSOverQUIC"))
        XCTAssertTrue(setAddressesBlock.contains("configuration.fallbackResolverPresetID = DNSResolverPreset.customID"))
        XCTAssertTrue(setAddressesBlock.contains("configuration.fallbackCustomResolverAddress = trimmedPrimaryValue"))
        XCTAssertTrue(setAddressesBlock.contains("configuration.fallbackCustomResolverSecondaryAddress = normalizedSecondaryValue"))
        XCTAssertTrue(setAddressesBlock.contains("persistResolverSettings(activity: .changeResolver)"))

        let clearBlock = try Self.sourceBlock(
            in: source,
            startingAt: "func clearFallbackCustomResolver(fallback preset: DNSResolverPreset)",
            endingBefore: "func setFallbackCustomResolverAddress(_ rawValue: String)"
        )
        XCTAssertTrue(clearBlock.contains("configuration.fallbackCustomResolverAddress = nil"))
        XCTAssertTrue(clearBlock.contains("configuration.fallbackCustomResolverSecondaryAddress = nil"))
        XCTAssertTrue(clearBlock.contains("configuration.fallbackCustomResolverName = nil"))
        XCTAssertTrue(clearBlock.contains("if configuration.fallbackResolverPresetID == DNSResolverPreset.customID"))
        XCTAssertTrue(clearBlock.contains("configuration.fallbackResolverPresetID = fallbackPreset.id"))
        XCTAssertTrue(clearBlock.contains("persistResolverSettings(activity: .changeResolver)"))

        let nameBlock = try Self.sourceBlock(
            in: source,
            startingAt: "func setFallbackCustomResolverName(_ rawValue: String)",
            endingBefore: "#if DEBUG || LAVA_QA_TOOLS"
        )
        XCTAssertTrue(nameBlock.contains("configuration.fallbackCustomResolverName = nextValue"))
        XCTAssertTrue(nameBlock.contains("try persistConfigurationOnly()"))
        XCTAssertFalse(nameBlock.contains("persistResolverSettings(activity: .changeResolver)"))
        XCTAssertFalse(nameBlock.contains("sendTunnelMessage(LavaSecAppGroup.reloadConfigurationMessage)"))
    }

    func testCustomBlocklistDisplayKeepsSavedSourcesWhileEditing() throws {
        let source = try Self.source(named: "AppViewModel.swift", in: "LavaSecApp")
        let displayedCustomBlocklistsBlock = try Self.sourceBlock(
            in: source,
            startingAt: "private var displayedCustomBlocklists: [CustomBlocklistSource]",
            endingBefore: "var allowlistConfigured: Bool"
        )

        // While editing, the draft is authoritative. It copies the saved custom
        // blocklists and keeps disabled ("pending-removal") sources — disabling only
        // drops the ID from `enabledBlocklistIDs`, not the source — so they still
        // render with their saved name/metadata. Only a trash → Delete removes the
        // source from the draft. Merging the draft back with `configuration` (the old
        // implementation) resurrected trash-deleted sources, leaving a stale row.
        XCTAssertTrue(displayedCustomBlocklistsBlock.contains("if let filterEditDraft"))
        XCTAssertTrue(displayedCustomBlocklistsBlock.contains("return filterEditDraft.customBlocklists"))
        // The no-draft fallback is the detail baseline (the active filter, or a non-active
        // "View" target) — not always the live `configuration`.
        XCTAssertTrue(displayedCustomBlocklistsBlock.contains("return filterDetailBaseline.customBlocklists"))
        XCTAssertFalse(
            displayedCustomBlocklistsBlock.contains("mergedByID"),
            "A trash-deleted custom blocklist must not be resurrected by merging the draft back with configuration."
        )
    }

    func testCustomBlocklistDraftKeepsSourcesWhenDisabledAndDeletesOnlyFromTrash() throws {
        let source = try Self.source(named: "AppViewModel.swift", in: "LavaSecApp")
        let setDraftBlocklistsBlock = try Self.sourceBlock(
            in: source,
            startingAt: "func setDraftBlocklists(_ sourceIDs: Set<String>)",
            endingBefore: "func addCustomBlocklistToDraft"
        )
        let removeBlocklistBlock = try Self.sourceBlock(
            in: source,
            startingAt: "func removeBlocklistFromDraft(_ sourceID: String)",
            endingBefore: "func deleteCustomBlocklistFromDraft"
        )
        let deleteCustomBlocklistBlock = try Self.sourceBlock(
            in: source,
            startingAt: "func deleteCustomBlocklistFromDraft(_ sourceID: String)",
            endingBefore: "func undoBlocklistDraftChange"
        )
        let undoBlocklistBlock = try Self.sourceBlock(
            in: source,
            startingAt: "func undoBlocklistDraftChange(_ sourceID: String)",
            endingBefore: "func addBlockedDomainToDraft"
        )

        XCTAssertTrue(source.contains("func stagedCustomBlocklistsForPicker() -> [CustomBlocklistSource]"))
        XCTAssertTrue(source.contains("func isCustomBlocklist(_ sourceID: String) -> Bool"))
        XCTAssertTrue(setDraftBlocklistsBlock.contains("let updatedIDs = sourceIDs"))
        XCTAssertFalse(setDraftBlocklistsBlock.contains("intersection(customSourceIDs)"))
        XCTAssertTrue(removeBlocklistBlock.contains("draft.enabledBlocklistIDs.remove(sourceID)"))
        XCTAssertFalse(removeBlocklistBlock.contains("draft.customBlocklists.removeAll"))
        XCTAssertTrue(deleteCustomBlocklistBlock.contains("draft.enabledBlocklistIDs.remove(sourceID)"))
        XCTAssertTrue(deleteCustomBlocklistBlock.contains("draft.customBlocklists.removeAll { $0.id == sourceID }"))
        XCTAssertFalse(undoBlocklistBlock.contains("draft.customBlocklists.removeAll { $0.id == sourceID }"))
    }

    func testCustomBlocklistMetadataShowsPendingRefreshUntilCompiled() throws {
        let source = try Self.source(named: "AppViewModel.swift", in: "LavaSecApp")
        let metadataBlock = try Self.sourceBlock(
            in: source,
            startingAt: "func blocklistMetadataText(for sourceID: String) -> String?",
            endingBefore: "func syncCatalogIfNeeded() async"
        )
        let nameBlock = try Self.sourceBlock(
            in: source,
            startingAt: "func blocklistName(for sourceID: String) -> String",
            endingBefore: "func isBlocklistPendingRemoval"
        )

        XCTAssertTrue(source.contains("func customBlocklistEntryCount(for source: CustomBlocklistSource) -> Int?"))
        XCTAssertTrue(metadataBlock.contains("return \"%@ rules · Custom List\".lavaLocalizedFormat(rules.count.formatted())"))
        XCTAssertTrue(metadataBlock.contains("return \"Pending refresh · Custom List\""))
        XCTAssertFalse(metadataBlock.contains("return \"Custom Pi-hole URL\""))
        XCTAssertTrue(nameBlock.contains("return customBlocklistPickerTitle(for: customSource)"))
    }

    func testCustomBlocklistDraftRejectsOnlyCustomDisplayNameConflicts() throws {
        let source = try Self.source(named: "AppViewModel.swift", in: "LavaSecApp")
        let draftAddBlock = try Self.sourceBlock(
            in: source,
            startingAt: "func addCustomBlocklistToDraft(displayName: String, rawURL: String) -> String?",
            endingBefore: "func removeBlocklistFromDraft"
        )
        let immediateAddBlock = try Self.sourceBlock(
            in: source,
            startingAt: "func addCustomBlocklist(displayName: String, rawURL: String) -> String?",
            endingBefore: "func removeCustomBlocklist"
        )

        XCTAssertTrue(source.contains("private func customBlocklistDisplayKey(for source: CustomBlocklistSource) -> String"))
        XCTAssertTrue(draftAddBlock.contains("let displayKey = customBlocklistDisplayKey(for: source)"))
        XCTAssertTrue(draftAddBlock.contains("draft.customBlocklists.contains"))
        XCTAssertTrue(draftAddBlock.contains("customBlocklistDisplayKey(for: existingSource) == displayKey"))
        XCTAssertTrue(draftAddBlock.contains("existingSource.sourceURL != source.sourceURL"))
        XCTAssertTrue(draftAddBlock.contains("return \"A custom list with that name already exists.\""))
        XCTAssertFalse(
            draftAddBlock.contains("blocklists.contains"),
            "Custom display-name conflicts should be scoped to custom sources so a custom list can share a curated list name."
        )
        XCTAssertTrue(immediateAddBlock.contains("let displayKey = customBlocklistDisplayKey(for: source)"))
        XCTAssertTrue(immediateAddBlock.contains("configuration.customBlocklists.contains"))
        XCTAssertTrue(immediateAddBlock.contains("customBlocklistDisplayKey(for: existingSource) == displayKey"))
        XCTAssertTrue(immediateAddBlock.contains("existingSource.sourceURL != source.sourceURL"))
        XCTAssertTrue(immediateAddBlock.contains("return \"A custom list with that name already exists.\""))
        XCTAssertFalse(
            immediateAddBlock.contains("blocklists.contains"),
            "The direct add path should keep the same custom-only conflict scope."
        )
    }

    func testReconnectOnlyRunsFromExplicitUserOrDebugActions() throws {
        let source = try Self.source(named: "AppViewModel.swift", in: "LavaSecApp")
        let refreshTunnelHealthBlock = try Self.sourceBlock(
            in: source,
            startingAt: "func refreshTunnelHealth(force: Bool = false)",
            endingBefore: "func sampleTunnelHealth() async"
        )
        let notificationBlock = try Self.sourceBlock(
            in: source,
            startingAt: "private func scheduleProtectionNotificationIfNeeded()",
            endingBefore: "private func appendAppNetworkActivity"
        )
        let primaryActionBlock = try Self.sourceBlock(
            in: source,
            startingAt: "func performProtectionPrimaryAction()",
            endingBefore: "func turnOffProtection()"
        )

        XCTAssertFalse(refreshTunnelHealthBlock.contains("reconnectProtection"))
        XCTAssertFalse(notificationBlock.contains("reconnectProtection"))
        XCTAssertTrue(primaryActionBlock.contains("protectionConnectivityAssessment.primaryAction == .reconnect"))
        XCTAssertTrue(primaryActionBlock.contains("reconnectProtection()"))
        XCTAssertTrue(source.contains("private static var isVPNDebugProbeRequested"))
        XCTAssertTrue(source.contains("processInfo.arguments.contains(\"--lava-debug-vpn\")"))
        XCTAssertTrue(source.contains("processInfo.environment[\"LAVA_DEBUG_VPN\"] == \"1\""))
    }

    func testProtectionHapticsAreOutcomeDrivenAndSkipAutomaticRestores() throws {
        let source = try Self.source(named: "AppViewModel.swift", in: "LavaSecApp")
        let hapticBlock = try Self.sourceBlock(
            in: source,
            startingAt: "enum ProtectionHapticFeedback",
            endingBefore: "final class AppViewModel"
        )
        let updateStatusBlock = try Self.sourceBlock(
            in: source,
            startingAt: "private func updateProtectionStatus(from manager: NETunnelProviderManager?)",
            endingBefore: "private func scheduleProtectionNotificationIfNeeded()"
        )
        let enableBlock = try Self.sourceBlock(
            in: source,
            startingAt: "private func enableProtection(",
            endingBefore: "private func disableProtection("
        )
        let disableBlock = try Self.sourceBlock(
            in: source,
            startingAt: "private func disableProtection(",
            endingBefore: "private func reconnectProtectionNow"
        )
        let reconnectBlock = try Self.sourceBlock(
            in: source,
            startingAt: "private func reconnectProtectionNow(playsOutcomeHaptic: Bool = true) async",
            endingBefore: "private func waitForProtectionToStop(timeout:"
        )
        let restoreBlock = try Self.sourceBlock(
            in: source,
            startingAt: "private func restoreProtectionIfNeeded(wasEnabled: Bool) async",
            endingBefore: "private func sendTunnelMessage"
        )
        let successHapticBlock = try Self.sourceBlock(
            in: source,
            startingAt: "private func playProtectionOnSucceededHapticIfNeeded",
            endingBefore: "private func playProtectionStartFailedHaptic()"
        )
        let failureHapticFeedbackBlock = try Self.sourceBlock(
            in: hapticBlock,
            startingAt: "case .protectionStartFailed:",
            endingBefore: "case .protectionTurnedOff:"
        )
        let failureHapticBlock = try Self.sourceBlock(
            in: source,
            startingAt: "private func playProtectionStartFailedHaptic()",
            endingBefore: "private func scheduleProtectionNotificationIfNeeded()"
        )
        let turnedOffHapticBlock = try Self.sourceBlock(
            in: hapticBlock,
            startingAt: "case .protectionTurnedOff:",
            endingBefore: "}"
        )

        XCTAssertFalse(hapticBlock.contains("private enum ProtectionHapticFeedback"))
        XCTAssertTrue(source.contains("private var awaitsProtectionOnHaptic = false"))
        XCTAssertFalse(source.contains("playsHapticFeedback"))
        XCTAssertFalse(source.contains("setHapticFeedback"))
        XCTAssertTrue(hapticBlock.contains("case protectionOnSucceeded"))
        XCTAssertTrue(hapticBlock.contains("case protectionStartFailed"))
        XCTAssertTrue(hapticBlock.contains("case protectionTurnedOff"))
        XCTAssertTrue(failureHapticFeedbackBlock.contains("UINotificationFeedbackGenerator()"))
        XCTAssertTrue(failureHapticFeedbackBlock.contains("notificationOccurred(.error)"))

        XCTAssertTrue(updateStatusBlock.contains("let previousStatus = vpnStatus"))
        XCTAssertTrue(updateStatusBlock.contains("playProtectionOnSucceededHapticIfNeeded(previousStatus: previousStatus, currentStatus: currentStatus)"))
        XCTAssertTrue(enableBlock.contains("if playsOutcomeHaptic"))
        XCTAssertTrue(enableBlock.contains("awaitsProtectionOnHaptic = true"))
        XCTAssertTrue(enableBlock.contains("playProtectionStartFailedHaptic()"))
        XCTAssertTrue(successHapticBlock.contains("ProtectionHapticFeedback.play(.protectionOnSucceeded)"))
        XCTAssertTrue(failureHapticBlock.contains("ProtectionHapticFeedback.play(.protectionStartFailed)"))
        XCTAssertTrue(disableBlock.contains("ProtectionHapticFeedback.play(.protectionTurnedOff)"))
        XCTAssertTrue(turnedOffHapticBlock.contains("UINotificationFeedbackGenerator()"))
        XCTAssertTrue(turnedOffHapticBlock.contains("notificationOccurred(.warning)"))
        XCTAssertTrue(reconnectBlock.contains("await enableProtection(logUserAction: false, playsOutcomeHaptic: playsOutcomeHaptic)"))
        XCTAssertTrue(reconnectBlock.contains("playProtectionStartFailedHaptic()"))
        XCTAssertTrue(restoreBlock.contains("await enableProtection(logUserAction: false, playsOutcomeHaptic: false)"))
    }

    func testLavaHapticsToggleGatesEveryPlaybackAndOutcomeSurfaces() throws {
        let source = try Self.source(named: "AppViewModel.swift", in: "LavaSecApp")
        let hapticBlock = try Self.sourceBlock(
            in: source,
            startingAt: "enum ProtectionHapticFeedback",
            endingBefore: "final class AppViewModel"
        )
        let setterBlock = try Self.sourceBlock(
            in: source,
            startingAt: "func setUsesLavaHaptics(_ isEnabled: Bool)",
            endingBefore: "var protectionTitle: String"
        )

        // The single choke point reads the toggle so disabling it silences protection,
        // guardian-tap, and every outcome haptic at once. Default-on preserves the
        // prior always-on behavior for a missing key.
        XCTAssertTrue(hapticBlock.contains("static let preferenceDefaultsKey = \"lavasec.customization.lavaHaptics\""))
        XCTAssertTrue(hapticBlock.contains("static var isEnabled: Bool"))
        XCTAssertTrue(hapticBlock.contains("UserDefaults.standard.object(forKey: preferenceDefaultsKey) as? Bool ?? true"))
        XCTAssertTrue(hapticBlock.contains("guard isEnabled else {"))

        // New outcome cases reuse the four physical feedback patterns.
        XCTAssertTrue(hapticBlock.contains("case actionSucceeded"))
        XCTAssertTrue(hapticBlock.contains("case actionFailed"))
        XCTAssertTrue(hapticBlock.contains("case selectionRejected"))
        XCTAssertTrue(hapticBlock.contains("case selectionConfirmed"))

        // Setter persists, early-returns on no-op, and previews the feel on enable.
        XCTAssertTrue(setterBlock.contains("guard usesLavaHaptics != isEnabled else {"))
        XCTAssertTrue(setterBlock.contains("defaults.set(isEnabled, forKey: usesLavaHapticsDefaultsKey)"))
        XCTAssertTrue(setterBlock.contains("if isEnabled {"))
        XCTAssertTrue(setterBlock.contains("ProtectionHapticFeedback.play(.selectionConfirmed)"))

        // Representative outcome surfaces are wired to the new cases.
        XCTAssertTrue(source.contains("ProtectionHapticFeedback.play(.actionSucceeded)"))
        XCTAssertTrue(source.contains("ProtectionHapticFeedback.play(.actionFailed)"))
        XCTAssertTrue(source.contains("ProtectionHapticFeedback.play(.selectionRejected)"))

        // The removed configuration-backed haptics preference stays gone.
        XCTAssertFalse(source.contains("playsHapticFeedback"))
        XCTAssertFalse(source.contains("setHapticFeedback"))
    }

    func testCatalogSyncAndReconnectWaitWithoutBusyPolling() throws {
        let source = try Self.source(named: "AppViewModel.swift", in: "LavaSecApp")
        let enableBlock = try Self.sourceBlock(
            in: source,
            startingAt: "private func enableProtection(",
            endingBefore: "private func disableProtection("
        )
        let syncBlock = try Self.sourceBlock(
            in: source,
            startingAt: "func syncCatalog(isBackgroundRefresh: Bool = false) async",
            endingBefore: "func syncCatalogIfStale() async"
        )
        let performSyncBlock = try Self.sourceBlock(
            in: source,
            startingAt: "private func performCatalogSync(",
            endingBefore: "func syncCatalogIfStale() async"
        )
        let waitBlock = try Self.sourceBlock(
            in: source,
            startingAt: "private func waitForProtectionToStop(timeout:",
            endingBefore: "private func resumeTemporaryProtectionIfExpired"
        )

        XCTAssertTrue(source.contains("private var catalogSyncTask: Task<Void, Never>?"))
        XCTAssertTrue(syncBlock.contains("catalogSyncTask = task"))
        XCTAssertTrue(syncBlock.contains("await task.value"))
        XCTAssertTrue(enableBlock.contains("await waitForCatalogSyncToFinish()"))
        XCTAssertFalse(enableBlock.contains("while isSyncingCatalog"))
        XCTAssertFalse(enableBlock.contains("Task.sleep(nanoseconds: 100_000_000)"))

        let finishIndex = try XCTUnwrap(
            performSyncBlock.range(of: "finishCatalogSyncTask()\n        if shouldAttemptProtectionRestore")?.lowerBound
        )
        let restoreIndex = try XCTUnwrap(performSyncBlock.range(of: "await restoreProtectionIfNeeded")?.lowerBound)
        XCTAssertLessThan(
            finishIndex,
            restoreIndex,
            "Catalog sync must clear its task handle before protection restore can re-enter enableProtection()."
        )

        XCTAssertTrue(source.contains("private final class ProtectionStopNotificationWaiter"))
        XCTAssertTrue(source.contains("NotificationCenter.default.addObserver("))
        XCTAssertTrue(source.contains("forName: .NEVPNStatusDidChange"))
        // Deadline, polling, and pending-reload behavior moved into
        // VPNLifecycleController and is covered by VPNLifecycleControllerTests;
        // the app pins notification-driven (not busy-poll) waiting plus the
        // delegation wiring.
        XCTAssertTrue(source.contains("ProtectionStopNotificationWaiter().wait(timeout: timeout)"))
        XCTAssertTrue(waitBlock.contains("vpnLifecycleController.waitForStop(timeout: timeout, initialManager: tunnelManager)"))
        XCTAssertTrue(source.contains("statusPollInterval: Self.protectionStopStatusRefreshInterval"))
        XCTAssertFalse(waitBlock.contains("for _ in 0..<12"))
        XCTAssertFalse(waitBlock.contains("Task.sleep(nanoseconds: 250_000_000)"))
    }

    func testCacheFirstTurnOnSkipsSyncWaitWhenArtifactReusable() throws {
        let source = try Self.source(named: "AppViewModel.swift", in: "LavaSecApp")
        let enableBlock = try Self.sourceBlock(
            in: source,
            startingAt: "private func enableProtection(",
            endingBefore: "private func disableProtection("
        )
        let gateBlock = try Self.sourceBlock(
            in: source,
            startingAt: "private func hasReusableArtifactForCurrentConfiguration() async -> Bool",
            endingBefore: "private func loadPreparedFilterSummaryForCurrentConfiguration()"
        )

        // Cache-first: turn-on only blocks on an in-flight catalog sync when no
        // reusable artifact exists for the current configuration. A valid cached
        // artifact lets the VPN start immediately; the background sync reconciles
        // the running tunnel on completion (notifyTunnelSnapshotUpdated +
        // restoreProtectionIfNeeded, which single-flights against this turn-on).
        XCTAssertTrue(enableBlock.contains("if await hasReusableArtifactForCurrentConfiguration()"))
        XCTAssertTrue(enableBlock.contains("await waitForCatalogSyncToFinish()"))

        let syncTaskGuardIndex = try XCTUnwrap(enableBlock.range(of: "if catalogSyncTask != nil {")?.lowerBound)
        let gateIndex = try XCTUnwrap(
            enableBlock.range(of: "if await hasReusableArtifactForCurrentConfiguration()")?.lowerBound
        )
        let waitIndex = try XCTUnwrap(enableBlock.range(of: "await waitForCatalogSyncToFinish()")?.lowerBound)
        let beginSessionIndex = try XCTUnwrap(enableBlock.range(of: "beginFreshProtectionVPNSession()")?.lowerBound)
        XCTAssertLessThan(
            syncTaskGuardIndex,
            gateIndex,
            "The reusable-artifact gate must sit inside the in-flight-sync check."
        )
        XCTAssertLessThan(
            gateIndex,
            waitIndex,
            "The cache-first gate must decide before falling through to the sync wait."
        )
        XCTAssertLessThan(
            waitIndex,
            beginSessionIndex,
            "Any sync wait must still resolve before the fresh VPN session begins."
        )

        // The gate is a manifest-only reuse check (no prepared-snapshot decode) so
        // it stays cheap on the critical path, reusing the same authority
        // (FilterArtifactManifest.reuseRejectionReason) as the full reuse load.
        XCTAssertTrue(gateBlock.contains("FilterArtifactStore(directoryURL: containerURL)"))
        XCTAssertTrue(gateBlock.contains("loadCachedCatalogMetadata()"))
        XCTAssertTrue(gateBlock.contains("manifest.reuseRejectionReason("))
        XCTAssertTrue(gateBlock.contains(") == nil"))
        XCTAssertFalse(
            gateBlock.contains("JSONDecoder().decode(PreparedFilterSnapshot.self"),
            "The cache-first gate must stay manifest-only; decoding the prepared snapshot belongs to the authoritative reuse load."
        )
    }

    func testVPNStopAndStartWaitThroughIOSDisconnectingState() throws {
        let source = try Self.source(named: "AppViewModel.swift", in: "LavaSecApp")
        let rootSource = try Self.source(named: "RootView.swift", in: "LavaSecApp")
        let guardSource = try Self.source(named: "GuardView.swift", in: "LavaSecApp")
        let initBlock = try Self.sourceBlock(
            in: source,
            startingAt: "if loadVPNState {",
            endingBefore: "#if DEBUG\n            logVPNDebugEvent"
        )
        let enableBlock = try Self.sourceBlock(
            in: source,
            startingAt: "private func enableProtection(",
            endingBefore: "private func disableProtection("
        )
        let disableBlock = try Self.sourceBlock(
            in: source,
            startingAt: "private func disableProtection(",
            endingBefore: "private func reconnectProtectionNow"
        )
        let waitBlock = try Self.sourceBlock(
            in: source,
            startingAt: "private func waitForProtectionToStop(timeout:",
            endingBefore: "private func resumeTemporaryProtectionIfExpired"
        )
        let stopPendingStatusBlock = try Self.sourceBlock(
            in: source,
            startingAt: "private func isProtectionStopPendingStatus",
            endingBefore: "private func isLocalProtectionUptimeStatus"
        )

        XCTAssertTrue(
            initBlock.contains("self.updateProtectionStatusFromCachedManager()"),
            "The status-change observer must read the cached manager's live connection."
        )
        XCTAssertFalse(
            initBlock.contains("await self?.refreshProtectionStatus(force: true)"),
            "The status-change observer must not unconditionally force a manager reload: loadAllFromPreferences re-posts NEVPNStatusDidChange and the forced refresh fed a self-sustaining storm (the 2026-06-12 heat regression)."
        )
        XCTAssertTrue(source.contains("var protectionPrimaryActionIsDisabled: Bool"))
        XCTAssertTrue(source.contains("ProtectionLifecyclePolicy.shouldDisablePrimaryAction"))
        XCTAssertTrue(source.contains("private static let protectionRestartStopWaitTimeout: TimeInterval = 15"))
        XCTAssertTrue(source.contains("private static let protectionStartWaitTimeout: TimeInterval = 15"))
        XCTAssertTrue(guardSource.contains(".disabled(viewModel.protectionPrimaryActionIsDisabled)"))
        XCTAssertTrue(rootSource.contains("await viewModel.refreshProtectionStatus(force: true)"))
        XCTAssertTrue(enableBlock.contains("manager.connection.status == .disconnecting"))
        XCTAssertTrue(enableBlock.contains("await waitForProtectionToStop(timeout: Self.protectionRestartStopWaitTimeout)"))
        XCTAssertTrue(enableBlock.contains("await waitForProtectionToConnect(timeout: Self.protectionStartWaitTimeout)"))
        XCTAssertTrue(disableBlock.contains("manager?.connection.stopVPNTunnel()"))
        XCTAssertTrue(disableBlock.contains("endProtectionVPNSession()"))
        XCTAssertTrue(disableBlock.contains("await waitForProtectionToStop()"))
        XCTAssertTrue(
            waitBlock.contains("vpnLifecycleController.waitForStop(timeout: timeout, initialManager: tunnelManager)"),
            "Stop waiting must delegate to VPNLifecycleController (begin/finished/timeout events and pending checks are behavior-tested there)."
        )
        XCTAssertTrue(waitBlock.contains("self?.updateProtectionStatus(from: manager)"))
        XCTAssertTrue(stopPendingStatusBlock.contains("ProtectionLifecyclePolicy.isStopPending"))
    }

    func testVPNStopTimeoutLeavesActionableStatusInsteadOfClearingTheMessage() throws {
        let source = try Self.source(named: "AppViewModel.swift", in: "LavaSecApp")
        let disableBlock = try Self.sourceBlock(
            in: source,
            startingAt: "private func disableProtection(",
            endingBefore: "private func reconnectProtectionNow"
        )
        let waitBlock = try Self.sourceBlock(
            in: source,
            startingAt: "private func waitForProtectionToStop(timeout:",
            endingBefore: "private func resumeTemporaryProtectionIfExpired"
        )

        // On a stuck stop, turn-off now attempts profile-removal recovery
        // (UR-31/UR-32) and only throws the actionable vpnStillStopping error if
        // that recovery also fails — it must never silently clear the message.
        XCTAssertTrue(disableBlock.contains("await waitForProtectionToStop() == false"))
        XCTAssertTrue(disableBlock.contains("guard await forceRemoveStuckProtectionProfile() else"))
        XCTAssertTrue(disableBlock.contains("throw LavaSecAppError.vpnStillStopping"))
        XCTAssertTrue(disableBlock.contains("vpnMessage = Self.vpnErrorMessage(prefix: \"Could not stop protection\", error: error)"))
        // The timeout-path manager reload (wait-for-stop-timeout-manager-reloaded)
        // is behavior-tested in VPNLifecycleControllerTests; here we pin that the
        // observation callback keeps the cached manager and published status fresh.
        XCTAssertTrue(waitBlock.contains("self?.tunnelManager = manager"))
        XCTAssertTrue(waitBlock.contains("self?.updateProtectionStatus(from: manager)"))
        XCTAssertFalse(disableBlock.contains("await waitForProtectionToStop()\n            }\n            lastProtectionStatusRefresh"))
    }

    func testVPNLifecycleActionsClaimConfiguringBeforeLaunchingAsyncWork() throws {
        let source = try Self.source(named: "AppViewModel.swift", in: "LavaSecApp")
        let actionBlock = try Self.sourceBlock(
            in: source,
            startingAt: "func turnOffProtection()",
            endingBefore: "func installLocalVPNProfileForOnboarding() async -> Bool"
        )
        let reconnectBlock = try Self.sourceBlock(
            in: source,
            startingAt: "private func reconnectProtectionNow(playsOutcomeHaptic: Bool = true) async",
            endingBefore: "@discardableResult"
        )

        // Single-flight is owned by ProtectionActionOrchestrator: entries claim a
        // kind synchronously (so a second tap is rejected before any await) and
        // release when the spawned flow finishes. isConfiguringVPN is a published
        // mirror with no manual writers; claim/release semantics are behavior-
        // tested in ProtectionActionOrchestratorTests.
        XCTAssertTrue(actionBlock.contains("guard protectionActionOrchestrator.claim(.turnOff) else"))
        XCTAssertTrue(actionBlock.contains("await disableProtection()\n            protectionActionOrchestrator.release(.turnOff)"))
        XCTAssertTrue(actionBlock.contains("guard protectionActionOrchestrator.claim(.reconnect) else"))
        XCTAssertTrue(actionBlock.contains("guard protectionActionOrchestrator.claim(.toggle) else"))
        XCTAssertTrue(actionBlock.contains("let shouldDisableProtection = isProtectionEnabledStatus(vpnStatus)"))
        XCTAssertTrue(actionBlock.contains("if shouldDisableProtection"))
        XCTAssertFalse(
            source.contains("isConfiguringVPN = true"),
            "isConfiguringVPN is the orchestrator's published mirror; manual claims would bypass single-flight."
        )
        XCTAssertFalse(reconnectBlock.contains("isConfiguringVPN = false\n            await enableProtection"))
    }

    func testProtectionConnectedNetworkActivityIsLoggedOnStatusTransition() throws {
        let source = try Self.source(named: "AppViewModel.swift", in: "LavaSecApp")
        let updateStatusBlock = try Self.sourceBlock(
            in: source,
            startingAt: "private func updateProtectionStatus(from manager: NETunnelProviderManager?)",
            endingBefore: "private func playProtectionOnSucceededHapticIfNeeded"
        )

        XCTAssertTrue(updateStatusBlock.contains("previousStatus != .connected"))
        XCTAssertTrue(updateStatusBlock.contains("currentStatus == .connected"))
        XCTAssertTrue(updateStatusBlock.contains("appendNetworkActivity(.protectionConnected)"))
    }

    func testNonCriticalAppGroupDefaultsDoNotForceSynchronousFlushes() throws {
        let source = try Self.source(named: "AppViewModel.swift", in: "LavaSecApp")
        let persistLookBlock = try Self.sourceBlock(
            in: source,
            startingAt: "private func persistLavaGuardLook(_ look: GuardianShieldStyle)",
            endingBefore: "private func syncAppIcon(to look: GuardianShieldStyle)"
        )
        let loadPauseBlock = try Self.sourceBlock(
            in: source,
            startingAt: "private func loadTemporaryProtectionPause()",
            endingBefore: "private func beginFreshProtectionVPNSession()"
        )

        XCTAssertTrue(persistLookBlock.contains("appGroupDefaults.set(look.rawValue, forKey: lavaGuardLookDefaultsKey)"))
        XCTAssertFalse(persistLookBlock.contains("appGroupDefaults.synchronize()"))
        XCTAssertTrue(loadPauseBlock.contains("pauseController.currentPauseUntil()"))
        XCTAssertFalse(loadPauseBlock.contains("appGroupDefaults.synchronize()"))
    }

    func testTemporaryProtectionPausePersistsAndResumesRobustly() throws {
        let source = try Self.source(named: "AppViewModel.swift", in: "LavaSecApp")
        let rootSource = try Self.source(named: "RootView.swift", in: "LavaSecApp")
        let pauseBlock = try Self.sourceBlock(
            in: source,
            startingAt: "func pauseProtectionTemporarily(for option: ProtectionPauseDuration)",
            endingBefore: "func resumeProtectionNow()"
        )
        let resumeBlock = try Self.sourceBlock(
            in: source,
            startingAt: "private func resumeTemporaryProtectionIfExpired(now: Date = Date()) async",
            endingBefore: "private func restoreFiltersAfterTemporaryProtectionPause("
        )
        let restoreBlock = try Self.sourceBlock(
            in: source,
            startingAt: "private func restoreFiltersAfterTemporaryProtectionPause(",
            endingBefore: "private func clearTemporaryProtectionPause()"
        )

        // The @Published mirror + pause/resume orchestration stay in AppViewModel;
        // the resume timer and legacy pause-key cleanup moved to
        // TemporaryProtectionPauseController.
        let pauseController = try Self.source(named: "TemporaryProtectionPauseController.swift", in: "LavaSecApp")
        XCTAssertTrue(source.contains("@Published private(set) var temporaryProtectionPauseUntil: Date?"))
        XCTAssertTrue(pauseController.contains("private var resumeTask: Task<Void, Never>?"))
        XCTAssertTrue(pauseController.contains("LavaSecAppGroup.protectionTemporaryPauseUntilDefaultsKey"))
        XCTAssertTrue(source.contains("loadTemporaryProtectionPause()"))
        XCTAssertTrue(pauseController.contains("resumeTask?.cancel()"))

        XCTAssertTrue(source.contains("var protectionCommandRequest: LavaLiveActivityActionRequest"))
        XCTAssertTrue(source.contains(".pauseFifteenMinutes"))
        // The fixed-length entry point delegates to a shared request-based flow
        // that also serves the Live Activity's configured-length Pause button.
        XCTAssertTrue(pauseBlock.contains("pauseProtectionTemporarily(request: option.protectionCommandRequest)"))
        XCTAssertTrue(pauseBlock.contains("private func pauseProtectionTemporarily(request: LavaLiveActivityActionRequest)"))
        XCTAssertTrue(pauseBlock.contains("try await LavaProtectionCommandService.perform(request, commandID: operationID.rawValue)"))
        XCTAssertTrue(pauseBlock.contains("loadTemporaryProtectionPause()"))
        XCTAssertTrue(pauseBlock.contains("scheduleTemporaryProtectionResume()"))
        XCTAssertTrue(pauseBlock.contains("await notifyTunnelProtectionPauseUpdated(operationID: operationID)"))
        XCTAssertFalse(pauseBlock.contains("persistTemporaryProtectionPauseUntil(until)"))
        XCTAssertFalse(source.contains("persistTemporaryPassThroughSnapshot"))
        XCTAssertFalse(pauseBlock.contains("disableProtection"))

        XCTAssertTrue(resumeBlock.contains("guard now >= until"))
        XCTAssertTrue(
            resumeBlock.contains("guard protectionActionOrchestrator.claim(.resume) else"),
            "The scheduled expiry resume must claim the action so it cannot interleave with user-initiated lifecycle work."
        )
        XCTAssertTrue(resumeBlock.contains("await restoreFiltersAfterTemporaryProtectionPause(configurationAlreadyClaimed: true)"))
        XCTAssertTrue(restoreBlock.contains("try await LavaProtectionCommandService.perform(.resume, commandID: operationID.rawValue)"))
        XCTAssertTrue(restoreBlock.contains("loadTemporaryProtectionPause()"))
        XCTAssertTrue(restoreBlock.contains("try await preparedSnapshotForProtectionStartup()"))
        XCTAssertTrue(restoreBlock.contains("try await persistPreparedSnapshotArtifacts(preparedSnapshot)"))
        XCTAssertFalse(restoreBlock.contains("clearTemporaryProtectionPause()"))
        XCTAssertTrue(restoreBlock.contains("await notifyTunnelProtectionPauseUpdated(operationID: operationID)"))
        XCTAssertTrue(restoreBlock.contains("await notifyTunnelSnapshotUpdated(operationID: operationID)"))
        XCTAssertFalse(restoreBlock.contains("enableProtection"))

        // Resume must NOT rewrite artifacts or reload the tunnel snapshot when the
        // snapshot was reused (configuration identity unchanged) — the tunnel kept
        // its snapshot loaded during pause. Pin that the rewrite/reload is gated.
        let reuseGateIndex = try XCTUnwrap(restoreBlock.range(of: "if !startup.reusedPersistedArtifacts {")?.lowerBound)
        let resumeRewriteIndex = try XCTUnwrap(
            restoreBlock.range(of: "try await persistPreparedSnapshotArtifacts(preparedSnapshot)")?.lowerBound
        )
        let resumeReloadIndex = try XCTUnwrap(
            restoreBlock.range(of: "await notifyTunnelSnapshotUpdated(operationID: operationID)")?.lowerBound
        )
        XCTAssertLessThan(reuseGateIndex, resumeRewriteIndex)
        XCTAssertLessThan(reuseGateIndex, resumeReloadIndex)

        XCTAssertFalse(source.contains("temporaryPassThroughPreparedSnapshot"))
        XCTAssertTrue(source.contains("func reconcileTemporaryProtectionPause()"))
        XCTAssertTrue(rootSource.contains("@Environment(\\.scenePhase) private var scenePhase"))
        XCTAssertTrue(rootSource.contains("viewModel.reconcileTemporaryProtectionPause()"))
    }

    func testTemporaryPauseControlsAreHiddenWhenNoNetworkPath() throws {
        let source = try Self.source(named: "AppViewModel.swift", in: "LavaSecApp")
        let controlsBlock = try Self.sourceBlock(
            in: source,
            startingAt: "var showsTemporaryProtectionPauseControls: Bool",
            endingBefore: "var formattedTemporaryProtectionResumeTime"
        )

        // Pause is meaningless with no network path, so the in-app controls hide
        // it just as the Dynamic Island no longer maps Network Lost to .on.
        XCTAssertTrue(controlsBlock.contains("protectionConnectivityAssessment.severity != .networkUnavailable"))
        XCTAssertTrue(controlsBlock.contains("protectionConnectivityAssessment.primaryAction != .reconnect"))
        XCTAssertTrue(controlsBlock.contains("!isProtectionTemporarilyPaused"))

        // The action entry point shares the same guard, so a stale pause intent
        // cannot pause protection while Network Lost is showing.
        let pauseBlock = try Self.sourceBlock(
            in: source,
            startingAt: "func pauseProtectionTemporarily(for option: ProtectionPauseDuration)",
            endingBefore: "func resumeProtectionNow()"
        )
        XCTAssertTrue(pauseBlock.contains("guard showsTemporaryProtectionPauseControls else"))
    }

    func testTemporaryProtectionPauseIsBoundToCurrentVPNSession() throws {
        let source = try Self.source(named: "AppViewModel.swift", in: "LavaSecApp")
        let enableBlock = try Self.sourceBlock(
            in: source,
            startingAt: "private func enableProtection(",
            endingBefore: "private func disableProtection("
        )
        let disableBlock = try Self.sourceBlock(
            in: source,
            startingAt: "private func disableProtection(",
            endingBefore: "private func reconnectProtectionNow(playsOutcomeHaptic: Bool = true) async"
        )
        let loadPauseBlock = try Self.sourceBlock(
            in: source,
            startingAt: "private func loadTemporaryProtectionPause()",
            endingBefore: "private func beginFreshProtectionVPNSession()"
        )
        let clearPauseBlock = try Self.sourceBlock(
            in: source,
            startingAt: "private func clearTemporaryProtectionPause()",
            endingBefore: "private func loadExistingTunnelManager() async throws"
        )

        // Session binding + legacy-key cleanup moved into the controller; the
        // store-routing contract is now enforced there.
        let pauseController = try Self.source(named: "TemporaryProtectionPauseController.swift", in: "LavaSecApp")
        XCTAssertTrue(pauseController.contains("LavaSecAppGroup.protectionTemporaryPauseSessionIDDefaultsKey"))

        let beginSessionIndex = try XCTUnwrap(enableBlock.range(of: "beginFreshProtectionVPNSession()")?.lowerBound)
        let snapshotIndex = try XCTUnwrap(enableBlock.range(of: "preparedSnapshotForProtectionStartup(")?.lowerBound)
        XCTAssertLessThan(
            beginSessionIndex,
            snapshotIndex,
            "Starting protection must clear stale pause state before writing the startup snapshot."
        )
        XCTAssertTrue(disableBlock.contains("endProtectionVPNSession()"))

        // Session binding and expiry are enforced by ProtectionPauseStore
        // (covered behaviorally in ProtectionPauseStoreTests); the app must
        // route pause reads, session boundaries, and cleanup through the stores.
        XCTAssertTrue(loadPauseBlock.contains("pauseController.currentPauseUntil()"))
        XCTAssertFalse(
            loadPauseBlock.contains("temporaryProtectionPauseUntil = appGroupPauseUntil ?? legacyPauseUntil"),
            "Loading pause state must ignore pause dates that are not bound to the active VPN session."
        )
        XCTAssertTrue(source.contains("protectionSessionStore.beginFreshSession()"))
        XCTAssertTrue(source.contains("protectionSessionStore.clearActiveSessionID()"))
        XCTAssertTrue(clearPauseBlock.contains("pauseController.clear()"))
        XCTAssertTrue(pauseController.contains("store.clearStoredPause()"))
        XCTAssertTrue(
            pauseController.contains("pausedSessionIDDefaultsKey"),
            "Legacy standard-defaults pause keys must still be cleared for upgraded installs."
        )
    }

    func testPreparedSnapshotsOnlyPersistWhenSelectedBlocklistsAreCovered() throws {
        let source = try Self.source(named: "AppViewModel.swift", in: "LavaSecApp")
        let summaryBlock = try Self.sourceBlock(
            in: source,
            startingAt: "private func preparedSummary(for snapshot: FilterSnapshot)",
            endingBefore: "private func preparedSnapshotForCurrentConfiguration()"
        )
        let prepareBlock = try Self.sourceBlock(
            in: source,
            startingAt: "private func prepareFilterSnapshot(",
            endingBefore: "private func reportFilterPreparationProgress"
        )
        let persistBlock = try Self.sourceBlock(
            in: source,
            startingAt: "private func persistSharedState(",
            endingBefore: "private func persistConfigurationOnly("
        )

        XCTAssertTrue(summaryBlock.contains("preparedBlocklistSourceRuleCounts()"))
        XCTAssertTrue(summaryBlock.contains("guard let rules = cachedBlockRuleSets[sourceID]"))
        XCTAssertTrue(
            prepareBlock.contains("service.prepare("),
            "Preparation (sync ladder, validation, merge, build) must route through FilterSnapshotPreparationService; its behavior is covered by FilterSnapshotPreparationServiceTests."
        )
        XCTAssertTrue(persistBlock.contains("summary.coversEnabledBlocklists(in: configuration)"))
        XCTAssertTrue(persistBlock.contains("persistPreparedSnapshotArtifacts(")
                        && persistBlock.contains("snapshotToPersist,"),
                      "The artifact publish must route through persistPreparedSnapshotArtifacts(snapshotToPersist, …).")
        // The rewrite is gated on rewritesRuleArtifacts AND coverage, hoisted into a
        // `didRewriteArtifacts` flag (multi-filter reuses the same flag to decide
        // whether to record the active filter's compiled token). Same guarantee:
        // reused or configuration-only persists must not rewrite identical rule
        // artifacts (warm turn-on cost).
        XCTAssertTrue(
            persistBlock.contains("let didRewriteArtifacts = rewritesRuleArtifacts")
                && persistBlock.contains("&& snapshotToPersist.summary.coversEnabledBlocklists(in: configuration)")
                && persistBlock.contains("if didRewriteArtifacts {"),
            "Reused or configuration-only persists must not rewrite identical rule artifacts (warm turn-on cost)."
        )
    }

    func testClearAndDisableBackupDivergeOnLocalEnvelopeHandling() throws {
        let source = try Self.source(named: "AppViewModel.swift", in: "LavaSecApp")
        let clearBlock = try Self.sourceBlock(
            in: source,
            startingAt: "func clearEncryptedBackup() async {",
            endingBefore: "func disableEncryptedBackup() async {"
        )
        let disableBlock = try Self.sourceBlock(
            in: source,
            startingAt: "func disableEncryptedBackup() async {",
            endingBefore: "private enum RemoteBackupDeletionOutcome {"
        )

        // Clear keeps the local envelope (only forgets the upload marker), so backup
        // stays configured and can re-upload a fresh copy.
        XCTAssertTrue(clearBlock.contains("backupEnvelopeStore.clearUploadMarker()"))
        XCTAssertFalse(clearBlock.contains("backupEnvelopeStore.deleteEnvelope()"))
        XCTAssertFalse(clearBlock.contains("setAutomaticBackupEnabled(false)"))

        // Disable tears the local envelope down and stops automatic backup.
        XCTAssertTrue(disableBlock.contains("backupEnvelopeStore.deleteEnvelope()"))
        XCTAssertTrue(disableBlock.contains("setAutomaticBackupEnabled(false)"))
        XCTAssertFalse(disableBlock.contains("backupEnvelopeStore.clearUploadMarker()"))

        // Both hard-delete the server copy first and only mutate local state when it
        // is confirmed gone — never claim a deletion that could not be verified.
        XCTAssertTrue(clearBlock.contains("await deleteRemoteEncryptedBackup()"))
        XCTAssertTrue(disableBlock.contains("await deleteRemoteEncryptedBackup()"))
        XCTAssertTrue(clearBlock.contains("case .unconfirmed:"))
        XCTAssertTrue(disableBlock.contains("case .unconfirmed:"))
    }

    func testBackupMaintenanceAndUploadsAreMutuallyExclusive() throws {
        let source = try Self.source(named: "AppViewModel.swift", in: "LavaSecApp")
        let uploadBlock = try Self.sourceBlock(
            in: source,
            startingAt: "private func uploadEncryptedBackup(",
            endingBefore: "private func uploadPendingEncryptedBackupIfPossible("
        )
        let clearBlock = try Self.sourceBlock(
            in: source,
            startingAt: "func clearEncryptedBackup() async {",
            endingBefore: "func disableEncryptedBackup() async {"
        )
        let disableBlock = try Self.sourceBlock(
            in: source,
            startingAt: "func disableEncryptedBackup() async {",
            endingBefore: "private enum RemoteBackupDeletionOutcome {"
        )

        // Uploads refuse to run while a Clear/Disable is in progress, so an in-flight
        // upload can never re-create the row maintenance just deleted.
        XCTAssertTrue(uploadBlock.contains("guard !isBackupMaintenanceInProgress else {"))
        XCTAssertTrue(uploadBlock.contains("isUploadingEncryptedBackup = true"))
        // And maintenance refuses to run while any upload is in flight.
        XCTAssertTrue(clearBlock.contains("!isBackingUpNow, !isUploadingEncryptedBackup"))
        XCTAssertTrue(disableBlock.contains("!isBackingUpNow, !isUploadingEncryptedBackup"))
    }

    private static func source(named fileName: String, in directoryName: String) throws -> String {
        let testFileURL = URL(fileURLWithPath: #filePath)
        let packageRootURL = testFileURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let sourceURL = packageRootURL
            .appendingPathComponent(directoryName)
            .appendingPathComponent(fileName)

        return try String(contentsOf: sourceURL, encoding: .utf8)
    }

    private static func sourceBlock(
        in source: String,
        startingAt startMarker: String,
        endingBefore endMarker: String
    ) throws -> String {
        let start = try XCTUnwrap(source.range(of: startMarker)?.lowerBound)
        let suffix = source[start...]
        let end = try XCTUnwrap(suffix.range(of: endMarker)?.lowerBound)
        return String(suffix[..<end])
    }
}
