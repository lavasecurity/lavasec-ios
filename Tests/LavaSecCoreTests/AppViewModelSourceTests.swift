import XCTest

final class AppViewModelSourceTests: XCTestCase {

    /// Collapse a source block to one line so a pin can assert an EXPRESSION without also
    /// asserting the formatter's line breaks and continuation indent.
    private func normalizedPersistBlockForCoverage(_ block: String) -> String {
        block.split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .joined(separator: " ")
    }

    func testNotifierUsesSharedAtomicHistoryAndCleansRecoveryBeforePreferences() throws {
        let source = try readSource(.protectionUserNotificationController)
        let block = try sourceBlock(in: source, startingAt: "func scheduleIfNeeded(", endingBefore: "func requestAuthorization()")
        let reconcile = try XCTUnwrap(block.range(of: "ProtectionConnectivityNotificationStore.reconcile("))
        let cleanup = try XCTUnwrap(block.range(of: "removeProblemNotifications(reconciliation.resolvedIdentifiers)"))
        let preference = try XCTUnwrap(block.range(of: "guard LavaNotificationPreferences.isEnabled"))
        XCTAssertLessThan(reconcile.lowerBound, cleanup.lowerBound)
        XCTAssertLessThan(cleanup.lowerBound, preference.lowerBound)
        XCTAssertFalse(block.contains("defaults.set("))
        XCTAssertFalse(block.contains("defaults.removeObject("))
    }

    func testAppNotificationUsesSharedDeliveryStateAcrossSuspensionPoints() throws {
        let block = try sourceBlock(in: try readSource(.protectionUserNotificationController), startingAt: "func scheduleIfNeeded(", endingBefore: "func requestAuthorization()")
        let auth = try XCTUnwrap(block.range(of: "await Self.canSendNotifications"))
        let authorized = try XCTUnwrap(block.range(of: "delivery.authorized(attempt"))
        let add = try XCTUnwrap(block.range(of: "try await notificationCenter.add(request)"))
        let submitted = try XCTUnwrap(block.range(of: "delivery.submitted(submission"))
        let claim = try XCTUnwrap(block.range(of: "ProtectionConnectivityNotificationStore.claimDelivery("))
        XCTAssertLessThan(auth.lowerBound, authorized.lowerBound)
        XCTAssertLessThan(authorized.lowerBound, add.lowerBound)
        XCTAssertLessThan(add.lowerBound, submitted.lowerBound)
        XCTAssertLessThan(submitted.lowerBound, claim.lowerBound)
        XCTAssertTrue(block.contains("delivery.update(.init(assessment: assessment, health: health))"))
        XCTAssertTrue(block.contains("assessment: posture.assessment, health: posture.health)"))
        XCTAssertTrue(block.contains("delivery.retryDeadline == deadline"))
        XCTAssertTrue(block.contains("reevaluateLatestPosture()"))
        XCTAssertTrue(block.contains("protectionNotificationRequestIdentifier(for: submission.requestIdentifier)"))
        XCTAssertTrue(block.contains("removeProblemNotifications([submission.requestIdentifier])"))
    }

    func testLiveDNSSmokeCanForceResolverPresetFromLaunchArguments() throws {
        let source = try readAppViewModelSource()
        let runtimeSupportBlock = try sourceBlock(
            in: source,
            startingAt: "static let protectionStopWaitTimeout",
            endingBefore: "#if DEBUG || LAVA_QA_TOOLS"
        )
        let launchArgumentBlock = try sourceBlock(
            in: source,
            startingAt: "static let liveDNSSmokeTestLaunchArgument",
            endingBefore: "#endif"
        )
        let configurationBlock = try sourceBlock(
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
        // Canary: the negative pins above key on these identifiers - if a rename removes
        // one from the pinned source, those pins pass vacuously. Fail here instead, then
        // re-anchor both sides to the new name.
        XCTAssertTrue(source.contains("supportsDNSOverQUICRuntime"))
    }

    func testLiveDNSSmokeDebugProbeAlwaysRestartsTunnelAfterPersistingResolverOverride() throws {
        let source = try readAppViewModelSource()
        let probeBlock = try sourceBlock(
            in: source,
            startingAt: "func runVPNStartupDebugProbe() async",
            endingBefore: "func logVPNDebugEvent"
        )

        XCTAssertTrue(probeBlock.contains("if Self.isLiveDNSSmokeTestRequested"))
        XCTAssertTrue(probeBlock.contains("logVPNDebugEvent(\"probe-live-dns-smoke-force-reconnect\""))
        XCTAssertTrue(probeBlock.contains("await reconnectProtectionNow(playsOutcomeHaptic: false)"))
        XCTAssertTrue(probeBlock.contains("return"))
    }

    func testVPNLifecycleSmokeDebugProbeExercisesPauseResumeCommandPath() throws {
        let source = try readAppViewModelSource()
        let launchArgumentBlock = try sourceBlock(
            in: source,
            startingAt: "static let liveDNSSmokeTestLaunchArgument",
            endingBefore: "#endif"
        )
        let lifecycleProbeBlock = try sourceBlock(
            in: source,
            startingAt: "private func runVPNLifecycleSmokeProbe() async",
            endingBefore: "func logVPNDebugEvent"
        )

        XCTAssertTrue(launchArgumentBlock.contains("static let vpnLifecycleSmokeTestLaunchArgument = \"-lava-vpn-lifecycle-smoke-test\""))
        XCTAssertTrue(launchArgumentBlock.contains("static var isVPNLifecycleSmokeTestRequested: Bool"))
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
        let source = try readAppViewModelSource()
        let sendTunnelMessageBlock = try sourceBlock(
            in: source,
            startingAt: "func sendTunnelMessage(",
            endingBefore: "func requestTunnelHealthFlush() async"
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
        let source = try readAppViewModelSource()
        let catalogController = try readSource(.catalogController)
        let enableBlock = try sourceBlock(
            in: source,
            startingAt: "func enableProtection(",
            endingBefore: "func disableProtection("
        )
        let disableBlock = try sourceBlock(
            in: source,
            startingAt: "func disableProtection(",
            endingBefore: "func reconnectProtectionNow"
        )
        let refreshBlock = try sourceBlock(
            in: source,
            startingAt: "func performCatalogSyncTransaction(",
            endingBefore: "private struct BackgroundCatalogCacheSupersededError"
        )
        let pauseBlock = try sourceBlock(
            in: source,
            startingAt: "func pauseProtectionTemporarily(for option: ProtectionPauseDuration)",
            endingBefore: "func resumeProtectionNow()"
        )
        let resumeBlock = try sourceBlock(
            in: source,
            startingAt: "func restoreFiltersAfterTemporaryProtectionPause(",
            endingBefore: "func clearTemporaryProtectionPause()"
        )
        let notifySnapshotBlock = try sourceBlock(
            in: source,
            startingAt: "func notifyTunnelSnapshotUpdated(",
            endingBefore: "func notifyTunnelProtectionPauseUpdated("
        )
        let notifyPauseBlock = try sourceBlock(
            in: source,
            startingAt: "func notifyTunnelProtectionPauseUpdated(",
            endingBefore: "func restoreProtectionIfNeeded"
        )
        let cachedRefreshFallbackBlock = try sourceBlock(
            in: source,
            startingAt: "func loadCachedCatalogAfterSyncFailure(",
            endingBefore: "func rebuildEnabledBlockRules()"
        )
        // The bug-report machinery that used to follow makeLatencyTrace moved to
        // DiagnosticsController (Phase D4); the next hub member is the status mapper.
        let latencyHelperBlock = try sourceBlock(
            in: source,
            startingAt: "func makeLatencyTrace(",
            endingBefore: "func vpnStatusReportDescription"
        )

        XCTAssertTrue(latencyHelperBlock.contains("LatencyDebugLogEventSink(operationKind: operationKind)"))
        XCTAssertTrue(latencyHelperBlock.contains("logVPNDebugEvent(event, details: details)"))
        XCTAssertTrue(latencyHelperBlock.contains("LatencyTrace(operationID: operationID)"))

        XCTAssertTrue(enableBlock.contains("operationID: LatencyOperationID = .make()"))
        XCTAssertTrue(enableBlock.contains("makeLatencyTrace(operationID: operationID, operationKind: \"turnOn\")"))
        XCTAssertTrue(enableBlock.contains("trace.beginSpan(\"action.turnOn\""))
        XCTAssertTrue(enableBlock.contains("startVPNTunnel(options: ["))
        XCTAssertTrue(enableBlock.contains("LavaSecAppGroup.latencyOperationIDOptionKeyName: operationID.rawValue as NSString"))
        XCTAssertTrue(enableBlock.contains("span.end(details: [\"status\": actionStatus"))

        XCTAssertTrue(disableBlock.contains("operationID: LatencyOperationID = .make()"))
        XCTAssertTrue(disableBlock.contains("makeLatencyTrace(operationID: operationID, operationKind: \"turnOff\")"))
        XCTAssertTrue(disableBlock.contains("trace.beginSpan(\"action.turnOff\""))

        XCTAssertTrue(refreshBlock.contains("operationID: LatencyOperationID"))
        XCTAssertTrue(catalogController.contains("isBackgroundRefresh: isBackgroundRefresh, operationID: operationID"))
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
        let source = try readAppViewModelSource()
        let setResolverBlock = try sourceBlock(
            in: source,
            startingAt: "func setResolver(_ preset: DNSResolverPreset)",
            endingBefore: "func setCustomResolverAddresses(primary rawPrimaryValue: String, secondary rawSecondaryValue: String)"
        )

        XCTAssertFalse(setResolverBlock.contains("configuration.customResolverAddress = nil"))
        XCTAssertFalse(setResolverBlock.contains("configuration.customResolverSecondaryAddress = nil"))
        XCTAssertFalse(setResolverBlock.contains("configuration.customResolverName = nil"))
        XCTAssertFalse(setResolverBlock.contains("preset.id != DNSResolverPreset.customID"))
        // Canary: the negative pins above key on these identifiers - if a rename removes
        // one from the pinned source, those pins pass vacuously. Fail here instead, then
        // re-anchor both sides to the new name.
        XCTAssertTrue(source.contains("customResolverAddress"))
        XCTAssertTrue(source.contains("customResolverSecondaryAddress"))
        XCTAssertTrue(source.contains("customResolverName"))
        XCTAssertTrue(source.contains("customID"))
    }

    func testSavingCustomResolverPersistsPrimaryAndSecondaryAddressesTogether() throws {
        let source = try readAppViewModelSource()
        let customResolverBlock = try sourceBlock(
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
        let source = try readAppViewModelSource()
        let clearCustomResolverBlock = try sourceBlock(
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
        let source = try readAppViewModelSource()

        let toggleBlock = try sourceBlock(
            in: source,
            startingAt: "func setUsesEncryptedDeviceDNSFallback(_ usesEncryptedDeviceDNSFallback: Bool)",
            endingBefore: "func setFallbackResolver(_ preset: DNSResolverPreset)"
        )
        XCTAssertTrue(toggleBlock.contains("guard configuration.usesEncryptedDeviceDNSFallback != usesEncryptedDeviceDNSFallback else"))
        XCTAssertTrue(toggleBlock.contains("configuration.usesEncryptedDeviceDNSFallback = usesEncryptedDeviceDNSFallback"))
        XCTAssertTrue(toggleBlock.contains("try persistConfigurationOnly()"))
        XCTAssertTrue(toggleBlock.contains("appendAppNetworkActivity(.toggleDeviceDNSFallback)"))
        XCTAssertTrue(toggleBlock.contains("sendTunnelMessage(LavaSecAppGroup.reloadConfigurationMessage)"))

        let setResolverBlock = try sourceBlock(
            in: source,
            startingAt: "func setFallbackResolver(_ preset: DNSResolverPreset)",
            endingBefore: "func setFallbackCustomResolverAddresses(primary rawPrimaryValue: String, secondary rawSecondaryValue: String)"
        )
        XCTAssertTrue(setResolverBlock.contains("guard configuration.fallbackResolverPresetID != preset.id else"))
        XCTAssertTrue(setResolverBlock.contains("configuration.fallbackResolverPresetID = preset.id"))
        XCTAssertTrue(setResolverBlock.contains("persistResolverSettings(activity: .changeResolver)"))

        let setAddressesBlock = try sourceBlock(
            in: source,
            startingAt: "func setFallbackCustomResolverAddresses(primary rawPrimaryValue: String, secondary rawSecondaryValue: String)",
            endingBefore: "func clearFallbackCustomResolver(fallback preset: DNSResolverPreset)"
        )
        XCTAssertTrue(setAddressesBlock.contains("supportsDNSOverQUIC: supportsDNSOverQUIC"))
        XCTAssertTrue(setAddressesBlock.contains("configuration.fallbackResolverPresetID = DNSResolverPreset.customID"))
        XCTAssertTrue(setAddressesBlock.contains("configuration.fallbackCustomResolverAddress = trimmedPrimaryValue"))
        XCTAssertTrue(setAddressesBlock.contains("configuration.fallbackCustomResolverSecondaryAddress = normalizedSecondaryValue"))
        XCTAssertTrue(setAddressesBlock.contains("persistResolverSettings(activity: .changeResolver)"))

        let clearBlock = try sourceBlock(
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

        let nameBlock = try sourceBlock(
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
        let source = try readAppViewModelSource()
        let displayedCustomBlocklistsBlock = try sourceBlock(
            in: source,
            startingAt: "var displayedCustomBlocklists: [CustomBlocklistSource]",
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
        let source = try readAppViewModelSource()
        let setDraftBlocklistsBlock = try sourceBlock(
            in: try readSource(.filterDraftController),
            startingAt: "func setDraftBlocklists(_ sourceIDs: Set<String>)",
            endingBefore: "func addCustomBlocklistToDraft"
        )
        let removeBlocklistBlock = try sourceBlock(
            in: try readSource(.filterDraftController),
            startingAt: "func removeBlocklistFromDraft(_ sourceID: String)",
            endingBefore: "func deleteCustomBlocklistFromDraft"
        )
        let deleteCustomBlocklistBlock = try sourceBlock(
            in: try readSource(.filterDraftController),
            startingAt: "func deleteCustomBlocklistFromDraft(_ sourceID: String)",
            endingBefore: "func undoBlocklistDraftChange"
        )
        let undoBlocklistBlock = try sourceBlock(
            in: try readSource(.filterDraftController),
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
        let source = try readAppViewModelSource()
        let metadataBlock = try sourceBlock(
            in: source,
            startingAt: "func blocklistMetadataText(for sourceID: String) -> String?",
            endingBefore: "func syncCatalogIfNeeded() async"
        )
        let nameBlock = try sourceBlock(
            in: source,
            startingAt: "func blocklistName(for sourceID: String) -> String",
            endingBefore: "func isBlocklistPendingRemoval"
        )

        XCTAssertTrue(source.contains("func customBlocklistEntryCount(for source: CustomBlocklistSource) -> Int?"))
        XCTAssertTrue(metadataBlock.contains("return \"%@ rules · Custom List\".lavaLocalizedFormat(count.formatted())"))
        XCTAssertTrue(metadataBlock.contains("return \"Pending refresh · Custom List\""))
        XCTAssertFalse(metadataBlock.contains("return \"Custom Pi-hole URL\""))
        XCTAssertTrue(nameBlock.contains("return customBlocklistPickerTitle(for: customSource)"))
    }

    func testCustomBlocklistDraftRejectsOnlyCustomDisplayNameConflicts() throws {
        let source = try readAppViewModelSource()
        let draftAddBlock = try sourceBlock(
            in: try readSource(.filterDraftController),
            startingAt: "func addCustomBlocklistToDraft(displayName: String, rawURL: String) -> String?",
            endingBefore: "func removeBlocklistFromDraft"
        )
        let immediateAddBlock = try sourceBlock(
            in: source,
            startingAt: "func addCustomBlocklist(displayName: String, rawURL: String) -> String?",
            endingBefore: "func removeCustomBlocklist"
        )

        XCTAssertTrue(source.contains("func customBlocklistDisplayKey(for source: CustomBlocklistSource) -> String"))
        XCTAssertTrue(draftAddBlock.contains("let displayKey = context.draftCustomBlocklistDisplayKey(for: source)"))
        XCTAssertTrue(draftAddBlock.contains("draft.customBlocklists.contains"))
        XCTAssertTrue(draftAddBlock.contains("draftCustomBlocklistDisplayKey(for: existingSource) == displayKey"))
        XCTAssertTrue(draftAddBlock.contains("existingSource.sourceURL != source.sourceURL"))
        XCTAssertTrue(draftAddBlock.contains("return \"A custom list with that name already exists.\""))
        let draftNameCheck = try sourceBlock(in: draftAddBlock,
            startingAt: "let displayKey = context.draftCustomBlocklistDisplayKey(for: source)",
            endingBefore: "let updatedIDs")
        XCTAssertFalse(
            draftNameCheck.contains("blocklists.contains"),
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
        let source = try readAppViewModelSource()
        let refreshTunnelHealthBlock = try sourceBlock(
            in: source,
            startingAt: "func refreshTunnelHealth(force: Bool = false)",
            endingBefore: "func sampleTunnelHealth(force: Bool = false) async"
        )
        let notificationBlock = try sourceBlock(
            in: source,
            startingAt: "func scheduleProtectionNotificationIfNeeded()",
            endingBefore: "func appendAppNetworkActivity"
        )
        let primaryActionBlock = try sourceBlock(
            in: source,
            startingAt: "func performProtectionPrimaryAction()",
            endingBefore: "func turnOffProtection()"
        )

        XCTAssertFalse(refreshTunnelHealthBlock.contains("reconnectProtection"))
        XCTAssertFalse(notificationBlock.contains("reconnectProtection"))
        XCTAssertTrue(primaryActionBlock.contains("performProtectionPrimaryAction(guardStatusPresentation.primaryAction)"))
        XCTAssertTrue(primaryActionBlock.contains("switch capturedAction"))
        XCTAssertTrue(primaryActionBlock.contains("reconnectProtection()"))
        XCTAssertTrue(source.contains("static var isVPNDebugProbeRequested"))
        XCTAssertTrue(source.contains("processInfo.arguments.contains(\"--lava-debug-vpn\")"))
        XCTAssertTrue(source.contains("processInfo.environment[\"LAVA_DEBUG_VPN\"] == \"1\""))
    }

    func testProtectionHapticsAreOutcomeDrivenAndSkipAutomaticRestores() throws {
        let source = try readAppViewModelSource()
        let hapticBlock = try readSource(.protectionHapticFeedback)
        let updateStatusBlock = try sourceBlock(
            in: source,
            startingAt: "func updateProtectionStatus(from manager: NETunnelProviderManager?)",
            endingBefore: "private func playProtectionStartFailedHaptic()"
        )
        let enableBlock = try sourceBlock(
            in: source,
            startingAt: "func enableProtection(",
            endingBefore: "func disableProtection("
        )
        let disableBlock = try sourceBlock(
            in: source,
            startingAt: "func disableProtection(",
            endingBefore: "func reconnectProtectionNow"
        )
        let reconnectBlock = try sourceBlock(
            in: source,
            startingAt: "func reconnectProtectionNow(",
            endingBefore: "private func waitForProtectionToConnect("
        )
        let restoreBlock = try sourceBlock(
            in: source,
            startingAt: "func restoreProtectionIfNeeded(_ request: ProtectionRestoreRequest) async",
            endingBefore: "func reconcileTunnelSnapshotAfterLaunch() async"
        )
        let successHapticBlock = try sourceBlock(
            in: source,
            startingAt: "private func resolveInitialChainedClaim(",
            endingBefore: "private func isCurrentChainedLifecycleMutation("
        )
        let failureHapticFeedbackBlock = try sourceBlock(
            in: hapticBlock,
            startingAt: "case .protectionStartFailed:",
            endingBefore: "case .protectionTurnedOff:"
        )
        let failureHapticBlock = try sourceBlock(
            in: source,
            startingAt: "private func playProtectionStartFailedHaptic()",
            endingBefore: "// MARK: - Chained-connect lifecycle"
        )
        let turnedOffHapticBlock = try sourceBlock(
            in: hapticBlock,
            startingAt: "case .protectionTurnedOff:",
            endingBefore: "case .guardianTapAcknowledged:"
        )

        XCTAssertFalse(hapticBlock.contains("private enum ProtectionHapticFeedback"))
        XCTAssertTrue(source.contains("var awaitsProtectionOnHaptic = false"))
        XCTAssertFalse(source.contains("playsHapticFeedback"))
        XCTAssertFalse(source.contains("setHapticFeedback"))
        XCTAssertTrue(hapticBlock.contains("case protectionOnSucceeded"))
        XCTAssertTrue(hapticBlock.contains("case protectionStartFailed"))
        XCTAssertTrue(hapticBlock.contains("case protectionTurnedOff"))
        XCTAssertTrue(failureHapticFeedbackBlock.contains("UINotificationFeedbackGenerator()"))
        XCTAssertTrue(failureHapticFeedbackBlock.contains("notificationOccurred(.error)"))

        XCTAssertTrue(updateStatusBlock.contains("let previousStatus = vpnStatus"))
        XCTAssertTrue(
            updateStatusBlock.contains(
                "let userInitiated = isFreshConnected && awaitsProtectionOnHaptic"))
        XCTAssertTrue(updateStatusBlock.contains("awaitsProtectionOnHaptic = false"))
        XCTAssertTrue(enableBlock.contains("if playsOutcomeHaptic"))
        XCTAssertTrue(enableBlock.contains("awaitsProtectionOnHaptic = true"))
        XCTAssertTrue(enableBlock.contains("playProtectionStartFailedHaptic()"))
        // An explicit start completes at provider-verified setup or returned forwarding proof.
        // Readiness shares the existing success owner; it must not create a second feedback path.
        XCTAssertTrue(successHapticBlock.contains("guard confirmed || setupReady,"))
        XCTAssertTrue(successHapticBlock.contains("userInitiated,"))
        XCTAssertTrue(successHapticBlock.contains("hasError: self.guardPanelMessageIsError"))
        XCTAssertTrue(successHapticBlock.contains("status: self.protectionStatus"))
        XCTAssertEqual(successHapticBlock.components(separatedBy:
            "ProtectionHapticFeedback.play(.protectionOnSucceeded)").count - 1, 1,
            "Readiness and later forwarding must share one fenced success publication.")
        XCTAssertTrue(successHapticBlock.contains("withProtectionLifecycleDescendantMutation("))
        XCTAssertTrue(successHapticBlock.contains("ProtectionHapticFeedback.play(.protectionOnSucceeded)"))
        XCTAssertTrue(failureHapticBlock.contains("ProtectionHapticFeedback.play(.protectionStartFailed)"))
        // Turn-off's outcome haptic remains parameterized for its callers, while the default stays
        // the neutral turned-off feel for the ordinary user action.
        XCTAssertTrue(disableBlock.contains("outcomeHaptic: ProtectionHapticFeedback = .protectionTurnedOff"))
        XCTAssertTrue(disableBlock.contains("ProtectionHapticFeedback.play(outcomeHaptic)"))
        XCTAssertFalse(turnedOffHapticBlock.contains("UINotificationFeedbackGenerator()"))
        XCTAssertTrue(turnedOffHapticBlock.contains("UIImpactFeedbackGenerator(style: .light)"))
        XCTAssertTrue(turnedOffHapticBlock.contains("generator.impactOccurred()"))
        XCTAssertFalse(turnedOffHapticBlock.contains("notificationOccurred(.warning)"))
        XCTAssertTrue(reconnectBlock.contains(
            "await enableProtection(\n                logUserAction: false,\n                playsOutcomeHaptic: playsOutcomeHaptic,"))
        XCTAssertTrue(reconnectBlock.contains("playProtectionStartFailedHaptic()"))
        XCTAssertTrue(restoreBlock.contains("playsOutcomeHaptic: false"))
        XCTAssertTrue(restoreBlock.contains("continueIfLifecycleLeaseOwned: validateOwnership"))
        // Canary: the negative pins above key on these identifiers - if a rename removes
        // one from the pinned source, those pins pass vacuously. Fail here instead, then
        // re-anchor both sides to the new name.
        XCTAssertTrue(source.contains("ProtectionHapticFeedback"))
    }

    func testAutomaticRestoreUsesRevisionedExplicitUserIntentAcrossEveryCaller() throws {
        let source = try readAppViewModelSource()
        XCTAssertTrue(source.contains("var userProtectionIntent = ProtectionRestoreIntentState(isEnabled: false)"))

        let initBlock = try sourceBlock(
            in: source,
            startingAt: "init(loadVPNState: Bool = true, headless: Bool = false, platformServices: LavaAppPlatformServices? = nil) {",
            endingBefore: "deinit {"
        )
        let loadIndex = try XCTUnwrap(initBlock.range(of: "loadPersistedConfiguration()")?.lowerBound)
        let initializeIntentIndex = try XCTUnwrap(
            initBlock.range(of: "recoverUserProtectionIntentFromDurableState()")?.lowerBound
        )
        XCTAssertLessThan(loadIndex, initializeIntentIndex)

        let unlockRecovery = try sourceBlock(
            in: source,
            startingAt: "func reloadSharedStateIfBlockedByDataProtection() {",
            endingBefore: "private func loadOrMigrateFilterLibrary()"
        )
        let recoveryLoadIndex = try XCTUnwrap(unlockRecovery.range(of: "loadPersistedConfiguration()")?.lowerBound)
        let recoveryIntentIndex = try XCTUnwrap(
            unlockRecovery.range(of: "recoverUserProtectionIntentFromDurableState()")?.lowerBound
        )
        XCTAssertLessThan(recoveryLoadIndex, recoveryIntentIndex)

        let statusRefresh = try sourceBlock(
            in: source,
            startingAt: "func updateProtectionStatus(from manager: NETunnelProviderManager?)",
            endingBefore: "private func playProtectionStartFailedHaptic()"
        )
        XCTAssertNil(
            sourceCodeOnly(statusRefresh).range(
                of: #"userProtectionIntent\s*(?:=(?!=)|\.\s*(?:recordUserIntent|recoverFromLoadedConfiguration)\s*\()"#,
                options: .regularExpression),
            "Status observation may read the intent revision, but only fenced reconciliation may replace intent.")

        let turnOff = try sourceBlock(in: source, startingAt: "func turnOffProtection()", endingBefore: "func reconnectProtection()")
        let reconnect = try sourceBlock(in: source, startingAt: "func reconnectProtection()", endingBefore: "func toggleProtection()")
        let toggle = try sourceBlock(in: source, startingAt: "func toggleProtection()", endingBefore: "// MARK: - Onboarding")
        for (block, intentWrite) in [
            (turnOff, "userProtectionIntent.recordUserIntent(isEnabled: false)"),
            (reconnect, "userProtectionIntent.recordUserIntent(isEnabled: true)"),
            (toggle, "userProtectionIntent.recordUserIntent(isEnabled: !shouldDisableProtection)"),
        ] {
            let claim = try XCTUnwrap(block.range(of: "protectionActionOrchestrator.claim")?.lowerBound)
            let write = try XCTUnwrap(block.range(of: intentWrite)?.lowerBound)
            let task = try XCTUnwrap(block.range(of: "Task {")?.lowerBound)
            XCTAssertLessThan(claim, write)
            XCTAssertLessThan(write, task, "Accepted user intent must be recorded synchronously before async lifecycle work.")
        }

        let restore = try sourceBlock(
            in: source,
            startingAt: "func restoreProtectionIfNeeded(_ request: ProtectionRestoreRequest) async",
            endingBefore: "func reconcileTunnelSnapshotAfterLaunch() async"
        )
        XCTAssertTrue(restore.contains("self.userProtectionIntent.allows(request)"))
        XCTAssertFalse(restore.contains("self.configuration.protectionEnabled"),
                       "A status refresh rewrites configuration.protectionEnabled, so it cannot be the post-refresh intent predicate.")

        let captureCases: [(String, String, String)] = [
            ("func prepareAndApplyFilterDraft(origin:", "private func prepareSwitchPublication(", "try await prepareFilterSnapshot"),
            ("func switchToFilter(id:", "enum SwitchPublication", "try await prepareSwitchPublication"),
            ("func applyImportedShareableConfiguration(", "private func nextSharedFilterName(", "try await prepareFilterSnapshot"),
            ("func performCatalogSyncTransaction(", "private struct BackgroundCatalogCacheSupersededError", "Task.detached"),
        ]
        for (start, end, firstSuspensionAnchor) in captureCases {
            let block = try sourceBlock(in: source, startingAt: start, endingBefore: end)
            let capture = try XCTUnwrap(block.range(of: "let restoreRequest = makeProtectionRestoreRequest()")?.lowerBound)
            let suspension = try XCTUnwrap(block.range(of: firstSuspensionAnchor)?.lowerBound)
            XCTAssertLessThan(capture, suspension, "Restore intent must be captured before the caller's first suspension.")
            XCTAssertTrue(block.contains("await restoreProtectionIfNeeded(restoreRequest)"))
        }

        let focusApply = try sourceBlock(
            in: source,
            startingAt: "private func applyPendingFilterSwitchOnce() async {",
            endingBefore: "private func applyCommittedOnDiskActiveFilter("
        )
        let focusCapture = try XCTUnwrap(focusApply.range(of: "let restoreRequest = makeProtectionRestoreRequest()")?.lowerBound)
        let focusLoad = try XCTUnwrap(focusApply.range(of: "loadPersistedConfiguration()")?.lowerBound)
        let focusAwait = try XCTUnwrap(focusApply.range(of: "await applyCommittedOnDiskActiveFilter")?.lowerBound)
        XCTAssertLessThan(focusCapture, focusLoad)
        XCTAssertLessThan(focusCapture, focusAwait)
        XCTAssertTrue(focusApply.contains("restoreRequest: restoreRequest"))
    }

    func testAutomaticRestoreCaptureAndClaimUseCrossProcessIntentCoordination() throws {
        let source = try readAppViewModelSource()
        let capture = try sourceBlock(
            in: source,
            startingAt: "func makeProtectionRestoreRequest() -> ProtectionRestoreRequest",
            endingBefore: "func restoreProtectionIfNeeded"
        )
        XCTAssertTrue(capture.contains("userProtectionIntent.makeRestoreRequest("))
        XCTAssertTrue(capture.contains("LavaProtectionCommandService.currentExternalRestartGeneration()"))
        XCTAssertFalse(capture.contains("configuration.protectionEnabled"))
        XCTAssertFalse(capture.contains("isProtectionEnabledStatus"))

        let restore = try sourceBlock(
            in: source,
            startingAt: "func restoreProtectionIfNeeded(_ request: ProtectionRestoreRequest) async",
            endingBefore: "func reconcileTunnelSnapshotAfterLaunch() async"
        )
        XCTAssertTrue(restore.contains("claimExternalExclusion:"))
        XCTAssertTrue(restore.contains("expectedExternalRestartGeneration: request.externalRestartGeneration"))
        XCTAssertTrue(restore.contains("validateExternalExclusion:"))
        XCTAssertTrue(restore.contains("releaseExternalExclusion:"))
        XCTAssertTrue(restore.contains("startProtectionLifecycleLeaseRenewal"))
        XCTAssertTrue(restore.contains("continueIfLifecycleLeaseOwned: validateOwnership"))

        let enable = try sourceBlock(
            in: source,
            startingAt: "func enableProtection(",
            endingBefore: "func disableProtection("
        )
        XCTAssertTrue(enable.contains("continueIfLifecycleLeaseOwned: (@MainActor () -> Bool)? = nil"))
        XCTAssertTrue(enable.contains("guard shouldContinueProtectionLifecycle() else"))
        XCTAssertTrue(
            sourceContainsInOrder([
                "try await performWhileProtectionLifecycleOwned {",
                "beginFreshProtectionVPNSession()",
                "try manager.connection.startVPNTunnel",
            ], in: enable),
            "The final session/start mutation must run inside the callback-spanning kernel fence."
        )
        XCTAssertFalse(enable.contains("freshProtectionSessionID"))
        XCTAssertFalse(enable.contains("clearProtectionSessionIfNoLiveLifecycleSuccessor"))
        XCTAssertFalse(
            source.contains("func beginFreshProtectionVPNSession() ->"),
            "The final-boundary session write does not expose an unused session identity."
        )
        XCTAssertEqual(
            enable.components(separatedBy: "continueIfLifecycleLeaseOwned: shouldContinueProtectionLifecycle").count - 1,
            2,
            "Both manager create/reload paths must keep lease validation inside the controller's suspended mutation sequence."
        )
        XCTAssertEqual(
            enable.components(separatedBy: "performPreferenceMutation: performWhileProtectionLifecycleOwned").count - 1,
            2,
            "Both manager create/reload paths must fence every non-cancellable preferences callback."
        )
        XCTAssertTrue(enable.contains("LavaProtectionCommandService.withProtectionLifecyclePreferenceMutation("))
        XCTAssertFalse(
            enable.contains("setManagerOnDemand(true"),
            "current main's reducer owns the delayed on-demand arm for the observed live connection")
        XCTAssertTrue(
            enable.contains("} catch is ProtectionLifecycleMutationFenceError {")
                && enable.contains("return abortSupersededProtectionLifecycle()"),
            "Busy/expired automatic owners must return false without publishing stale success or error state."
        )
        let timeoutPersist = try XCTUnwrap(
            enable.range(
                of: "_ = try? await persistSharedState(preparedSnapshot: preparedSnapshot, rewritesRuleArtifacts: false)"
            )?.lowerBound
        )
        let timeoutTail = String(enable[timeoutPersist...])
        let timeoutPostPersistGuard = try XCTUnwrap(
            timeoutTail.range(of: "guard shouldContinueProtectionLifecycle() else")?.lowerBound
        )
        let timeoutSuccess = try XCTUnwrap(
            timeoutTail.range(of: "actionStatus = \"timeout\"")?.lowerBound
        )
        XCTAssertLessThan(
            timeoutPostPersistGuard,
            timeoutSuccess,
            "A restore superseded during the timeout persist must not publish timeout-success."
        )

        let managerWrapper = try sourceBlock(
            in: source,
            startingAt: "func loadOrCreateTunnelManager(",
            endingBefore: "func setManagerOnDemand("
        )
        XCTAssertTrue(managerWrapper.contains("continueIfLifecycleLeaseOwned: @escaping @MainActor () -> Bool = { true }"))
        XCTAssertTrue(managerWrapper.contains("continueIfOwned: continueIfLifecycleLeaseOwned"))
        XCTAssertTrue(managerWrapper.contains("performPreferenceMutation: performPreferenceMutation"))
    }

    func testReducerDescendantsFenceConnectionIntentAndRestartGeneration() throws {
        let source = try readAppViewModelSource()

        let sampling = try sourceBlock(
            in: source,
            startingAt: "private func startChainedLifecycleSampling(connection: UInt64)",
            endingBefore: "private func stopChainedLifecycleSampling()"
        )
        let identityCapture = try XCTUnwrap(
            sampling.range(of: "chainedLifecycleMutationIdentity = ChainedLifecycleMutationIdentity(")?
                .lowerBound
        )
        let samplerStart = try XCTUnwrap(
            sampling.range(
                of: "chainedLifecycleSamplingTask = Task",
                range: identityCapture..<sampling.endIndex)?.lowerBound
        )
        XCTAssertLessThan(identityCapture, samplerStart)
        XCTAssertTrue(sampling.contains("protectionIntentRevision: userProtectionIntent.revision"))
        XCTAssertTrue(sampling.contains("captureExternalRestartGeneration()"))

        let arm = try sourceBlock(
            in: source,
            startingAt: "private func startChainedOnDemandArm(id: UInt64, connection: UInt64)",
            endingBefore: "private func completeChainedOnDemandArm(id: UInt64, confirmed: Bool)"
        )
        let armFence = try XCTUnwrap(
            arm.range(of: "withProtectionLifecycleDescendantMutation(")?.lowerBound
        )
        let armLoad = try XCTUnwrap(
            arm.range(of: "loadExistingTunnelManager()", range: armFence..<arm.endIndex)?.lowerBound
        )
        let armSave = try XCTUnwrap(
            arm.range(
                of: "try await self.setManagerOnDemand(true, on: manager)",
                range: armLoad..<arm.endIndex)?.lowerBound
        )
        XCTAssertLessThan(armFence, armLoad)
        XCTAssertLessThan(armLoad, armSave)
        XCTAssertTrue(arm.contains("capturedGeneration: externalRestartGeneration"))
        XCTAssertTrue(arm.contains("identity.connection == connection"))
        XCTAssertTrue(arm.contains("self.isCurrentChainedLifecycleMutation(identity, armID: id)"))

        let ownership = try sourceBlock(
            in: source,
            startingAt: "private func isCurrentChainedLifecycleMutation(",
            endingBefore: "private func startChainedOnDemandArm("
        )
        XCTAssertTrue(ownership.contains("chainedLifecycleMutationIdentity == identity"))
        XCTAssertTrue(ownership.contains("userProtectionIntent.isEnabled"))
        XCTAssertTrue(
            ownership.contains("userProtectionIntent.revision == identity.protectionIntentRevision")
        )
        XCTAssertTrue(ownership.contains("!isTearingDownProtection"))
        XCTAssertTrue(ownership.contains("vpnStatus == .connected"))

        let resolution = try sourceBlock(
            in: source,
            startingAt: "private func resolveInitialChainedClaim(",
            endingBefore: "private func isCurrentChainedLifecycleMutation("
        )
        XCTAssertTrue(resolution.contains("withProtectionLifecycleDescendantMutation("))
        XCTAssertTrue(resolution.contains("capturedGeneration: externalRestartGeneration"))
        XCTAssertTrue(resolution.contains("self.isCurrentChainedLifecycleMutation(identity)"))
        XCTAssertTrue(resolution.contains("ChainedConnectLifecyclePolicy.successFeedbackDisposition("))
        XCTAssertTrue(resolution.contains("hasError: self.guardPanelMessageIsError"))
        XCTAssertTrue(resolution.contains("ProtectionHapticFeedback.play(.protectionOnSucceeded)"))
        XCTAssertFalse(
            sourceCodeOnly(source).contains("turnOffAfterFailedChainedEstablishment"),
            "current main intentionally keeps an unconfirmed tunnel connected and monitored"
        )
    }

    func testOrdinaryAppLifecycleActionsShareTheDirectRestartFence() throws {
        let source = try readAppViewModelSource()

        let enable = try sourceBlock(
            in: source,
            startingAt: "func enableProtection(",
            endingBefore: "func disableProtection("
        )
        XCTAssertTrue(enable.contains("withExclusiveProtectionLifecycleMutation"))
        XCTAssertTrue(enable.contains("lifecycleMutationFenceIsOwned: true"))
        XCTAssertTrue(enable.contains("if lifecycleMutationFenceIsOwned {"))
        let foregroundFenceCatch = try sourceBlock(
            in: enable,
            startingAt: "if continueIfLifecycleLeaseOwned == nil, !lifecycleMutationFenceIsOwned {",
            endingBefore: "func shouldContinueProtectionLifecycle()"
        )
        XCTAssertTrue(
            foregroundFenceCatch.contains("prefix: \"Could not start protection\".lavaLocalized")
        )
        XCTAssertTrue(foregroundFenceCatch.contains("vpnMessageIsError = true"))
        XCTAssertTrue(foregroundFenceCatch.contains("playProtectionStartFailedHaptic()"))

        let disable = try sourceBlock(
            in: source,
            startingAt: "func disableProtection(",
            endingBefore: "func reconnectProtectionNow("
        )
        let disableFence = try XCTUnwrap(
            disable.range(of: "withExclusiveProtectionLifecycleMutation")?.lowerBound
        )
        let disableTeardown = try XCTUnwrap(
            disable.range(of: "beginProtectionTeardown()")?.lowerBound
        )
        let disableDrain = try XCTUnwrap(
            disable.range(of: "await drainChainedOnDemandArm()")?.lowerBound
        )
        let disableUI = try XCTUnwrap(
            disable.range(of: "vpnMessage = \"Stopping local protection...\"")?.lowerBound
        )
        XCTAssertLessThan(disableTeardown, disableDrain)
        XCTAssertLessThan(
            disableDrain,
            disableFence,
            "Explicit OFF must suspend reducer producers and drain an arm already holding the fence before acquiring it."
        )
        XCTAssertLessThan(disableFence, disableUI)
        XCTAssertTrue(disable.contains("lifecycleMutationFenceIsOwned: true"))
        XCTAssertTrue(disable.contains("prefix: \"Could not stop protection\".lavaLocalized"))
        XCTAssertTrue(disable.contains("vpnMessageIsError = true"))

        let reconnect = try sourceBlock(
            in: source,
            startingAt: "func reconnectProtectionNow(",
            endingBefore: "private func waitForProtectionToConnect("
        )
        let reconnectFence = try XCTUnwrap(
            reconnect.range(of: "withExclusiveProtectionLifecycleMutation")?.lowerBound
        )
        let reconnectTeardown = try XCTUnwrap(
            reconnect.range(of: "beginProtectionTeardown()")?.lowerBound
        )
        let reconnectDrain = try XCTUnwrap(
            reconnect.range(of: "await drainChainedOnDemandArm()")?.lowerBound
        )
        let reconnectUI = try XCTUnwrap(
            reconnect.range(of: "vpnMessage = \"Reconnecting local protection...\"")?.lowerBound
        )
        XCTAssertLessThan(reconnectTeardown, reconnectDrain)
        XCTAssertLessThan(reconnectDrain, reconnectFence)
        XCTAssertLessThan(reconnectFence, reconnectUI)
        XCTAssertTrue(
            reconnect.contains("lifecycleMutationFenceIsOwned: true"),
            "The whole reconnect owns one fence and its nested enable must not reacquire it."
        )
        XCTAssertTrue(reconnect.contains("preflightTeardownIsActive = false"))
        XCTAssertTrue(reconnect.contains("protectionTeardownIsOwned: true"))
        XCTAssertTrue(reconnect.contains("precondition(isTearingDownProtection)"))
        XCTAssertTrue(reconnect.contains("prefix: \"Could not reconnect protection\".lavaLocalized"))

        let service = try readSource(.lavaProtectionCommandService)
        let restartClaim = try sourceBlock(
            in: service,
            startingAt: "private static func claimRestartInFlight(",
            endingBefore: "private static func finishRestartInFlight("
        )
        let mutationClaim = try XCTUnwrap(
            restartClaim.range(of: "acquireProtectionLifecycleMutationFence(wait: false)")?.lowerBound
        )
        let generationClaim = try XCTUnwrap(
            restartClaim.range(of: "store.claimExplicitRestart(")?.lowerBound
        )
        XCTAssertLessThan(
            mutationClaim,
            generationClaim,
            "Rejected Restart must not rotate generation before winning the shared fence."
        )
        let foregroundFence = try sourceBlock(
            in: service,
            startingAt: "static func withExclusiveProtectionLifecycleMutation<T>(",
            endingBefore: "/// Runs an automatic-restore preference/tunnel mutation"
        )
        XCTAssertTrue(
            foregroundFence.contains("waitUntilAvailable: true"),
            "A foreground action must asynchronously hand off after an accepted Restart, not disappear as busy."
        )
    }

    func testAdminQAVPNProfileMutationsShareTheDirectRestartFence() throws {
        let source = try readAppViewModelSource()
        let entry = try sourceBlock(
            in: source,
            startingAt: "func applyAdminQAVPNProfileAction(_ action: AdminQAVPNProfileAction) async {",
            endingBefore: "private func installAdminQAVPNProfile() async"
        )
        XCTAssertTrue(
            entry.contains("LavaProtectionCommandService.withExclusiveProtectionLifecycleMutation"),
            "QA install save/create, remove stop/delete, and reset delete/recreate must not overlap Live Activity Restart."
        )
        XCTAssertTrue(
            sourceContainsInOrder([
                "try await LavaProtectionCommandService.withExclusiveProtectionLifecycleMutation {",
                "switch action {",
                "await self.installAdminQAVPNProfile()",
                "await self.removeAdminQAVPNProfile()",
                "await self.resetAdminQAVPNProfile()",
            ], in: entry),
            "One outer escaping fence must explicitly capture self and span each complete QA "
                + "profile action without nested same-process re-locking."
        )
        XCTAssertTrue(entry.contains("vpnMessageIsError = true"))

        let install = try sourceBlock(
            in: source,
            startingAt: "private func installAdminQAVPNProfile() async",
            endingBefore: "private func removeAdminQAVPNProfile() async"
        )
        XCTAssertTrue(install.contains("loadOrCreateTunnelManager("))
        XCTAssertFalse(install.contains("withExclusiveProtectionLifecycleMutation"))

        let remove = try sourceBlock(
            in: source,
            startingAt: "private func removeAdminQAVPNProfile() async",
            endingBefore: "private func resetAdminQAVPNProfile() async"
        )
        XCTAssertTrue(remove.contains("manager.connection.stopVPNTunnel()"))
        XCTAssertTrue(remove.contains("vpnLifecycleController.removeManager(manager)"))
        XCTAssertFalse(remove.contains("withExclusiveProtectionLifecycleMutation"))

        let reset = try sourceBlock(
            in: source,
            startingAt: "private func resetAdminQAVPNProfile() async",
            endingBefore: "#endif"
        )
        XCTAssertTrue(reset.contains("manager.connection.stopVPNTunnel()"))
        XCTAssertTrue(reset.contains("vpnLifecycleController.removeManager(manager)"))
        XCTAssertTrue(reset.contains("loadOrCreateTunnelManager(existingManager: nil)"))
        XCTAssertFalse(reset.contains("withExclusiveProtectionLifecycleMutation"))
    }

    func testProtectionStatusRefreshCoalescedFollowersAwaitBoundedOwner() throws {
        let source = try readAppViewModelSource()
        XCTAssertTrue(source.contains("let protectionStatusRefreshCoordinator = ProtectionStatusRefreshCoordinator()"))
        // Access-level independent: the class spans files now, so a reintroduced raw mirror would
        // naturally be an internal `var` and a `private`-spelled needle could never match it.
        XCTAssertFalse(source.contains("var isRefreshingProtectionStatus"))
        XCTAssertFalse(source.contains("var needsProtectionStatusRefresh"))

        let refresh = try sourceBlock(
            in: source,
            startingAt: "func refreshProtectionStatus(force: Bool = false) async",
            endingBefore: "// MARK: - Chained-connect lifecycle"
        )
        XCTAssertTrue(
            sourceContainsInOrder([
                "await protectionStatusRefreshCoordinator.run { [self] in",
                "let manager = try await self.loadExistingTunnelManager()",
                "self.tunnelManager = manager",
                "self.updateProtectionStatus(from: manager)",
                "self.lastProtectionStatusRefresh = Date()",
                "if self.vpnStatus == .connected {",
                "await self.requestTunnelHealthFlush()",
                "self.refreshTunnelHealth()",
                "self.vpnMessage = error.localizedDescription",
                "self.vpnMessageIsError = true",
                "self.logVPNDebugEvent(\"refresh-status-error\", details: self.errorDebugDetails(error))",
            ], in: refresh),
            "The escaping refresh owner must capture self explicitly and qualify every app-model "
                + "access so the Swift 6 QA device build type-checks the complete closure."
        )
        XCTAssertFalse(refresh.contains("guard !isRefreshingProtectionStatus"))
        XCTAssertFalse(refresh.contains("return\n        }\n\n        isRefreshingProtectionStatus = true"))
    }

    func testLavaHapticsToggleGatesEveryPlaybackAndOutcomeSurfaces() throws {
        let source = try readAppViewModelSource()
        let hapticBlock = try readSource(.protectionHapticFeedback)
        // The toggle setter lives on CustomizationController since the Phase D5 peel;
        // the ProtectionHapticFeedback choke point now lives in its app-only adapter;
        // the protection-outcome call sites remain hub-side. They share the
        // preferenceDefaultsKeyName.
        let customizationSource = try readSource(.customizationController)
        let setterBlock = try sourceBlock(
            in: customizationSource,
            startingAt: "func setUsesLavaHaptics(_ isEnabled: Bool)",
            endingBefore: "// MARK: - Preference load & notification toggles"
        )

        // The single choke point reads the toggle so disabling it silences protection,
        // guardian-tap, and every outcome haptic at once. Default-on preserves the
        // prior always-on behavior for a missing key.
        XCTAssertTrue(hapticBlock.contains("static let preferenceDefaultsKeyName = \"lavasec.customization.lavaHaptics\""))
        XCTAssertTrue(hapticBlock.contains("static var isEnabled: Bool"))
        XCTAssertTrue(hapticBlock.contains("UserDefaults.standard.object(forKey: preferenceDefaultsKeyName) as? Bool ?? true"))
        XCTAssertTrue(hapticBlock.contains("guard isEnabled else {"))
        // The controller's toggle writes the SAME key the choke point reads.
        XCTAssertTrue(customizationSource.contains("private let usesLavaHapticsDefaultsKey = ProtectionHapticFeedback.preferenceDefaultsKeyName"))

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

        // The removed configuration-backed haptics preference stays gone — from the hub
        // AND from the peeled controller (founder rule: the single usesLavaHaptics
        // toggle + ProtectionHapticFeedback façade, never playsHapticFeedback).
        XCTAssertFalse(source.contains("playsHapticFeedback"))
        XCTAssertFalse(source.contains("setHapticFeedback"))
        XCTAssertFalse(customizationSource.contains("playsHapticFeedback"))
        XCTAssertFalse(customizationSource.contains("setHapticFeedback"))
    }

    func testReconnectWaitWithoutBusyPolling() throws {
        let source = try readAppViewModelSource()
        let waitBlock = try sourceBlock(
            in: source,
            startingAt: "private func waitForProtectionToStop(timeout:",
            endingBefore: "func resumeTemporaryProtectionIfExpired"
        )

        XCTAssertTrue(source.contains("final class ProtectionStopNotificationWaiter"))
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
        let source = try readAppViewModelSource()
        let enableBlock = try sourceBlock(
            in: source,
            startingAt: "func enableProtection(",
            endingBefore: "func disableProtection("
        )
        let gateBlock = try sourceBlock(
            in: source,
            startingAt: "func hasReusableArtifactForCurrentConfiguration() async -> Bool",
            endingBefore: "func loadPreparedFilterSummaryForCurrentConfiguration()"
        )

        // Cache-first: turn-on only blocks on an in-flight catalog sync when no
        // reusable artifact exists for the current configuration. A valid cached
        // artifact lets the VPN start immediately; the background sync reconciles
        // the running tunnel on completion (notifyTunnelSnapshotUpdated +
        // restoreProtectionIfNeeded, which single-flights against this turn-on).
        XCTAssertTrue(enableBlock.contains("if await hasReusableArtifactForCurrentConfiguration()"))
        XCTAssertTrue(enableBlock.contains("await catalog.awaitCompletion()"))

        let syncTaskGuardIndex = try XCTUnwrap(enableBlock.range(of: "if catalog.isSyncInFlight {")?.lowerBound)
        let gateIndex = try XCTUnwrap(
            enableBlock.range(of: "if await hasReusableArtifactForCurrentConfiguration()")?.lowerBound
        )
        let waitIndex = try XCTUnwrap(enableBlock.range(of: "await catalog.awaitCompletion()")?.lowerBound)
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
        // Canary: the negative pins above key on these identifiers - if a rename removes
        // one from the pinned source, those pins pass vacuously. Fail here instead, then
        // re-anchor both sides to the new name.
        XCTAssertTrue(source.contains("PreparedFilterSnapshot"))
    }

    func testVPNStopAndStartWaitThroughIOSDisconnectingState() throws {
        let source = try readAppViewModelSource()
        let rootSource = try readSource(.rootView)
        let guardSource = try readSource(.reactNativeAppBridge)
        let initBlock = try sourceBlock(
            in: source,
            startingAt: "if loadVPNState {",
            endingBefore: "#if DEBUG\n            logVPNDebugEvent"
        )
        let enableBlock = try sourceBlock(
            in: source,
            startingAt: "func enableProtection(",
            endingBefore: "func disableProtection("
        )
        let disableBlock = try sourceBlock(
            in: source,
            startingAt: "func disableProtection(",
            endingBefore: "func reconnectProtectionNow"
        )
        let waitBlock = try sourceBlock(
            in: source,
            startingAt: "private func waitForProtectionToStop(timeout:",
            endingBefore: "func resumeTemporaryProtectionIfExpired"
        )
        let stopPendingStatusBlock = try sourceBlock(
            in: source,
            startingAt: "func isProtectionStopPendingStatus",
            endingBefore: "func isLocalProtectionUptimeStatus"
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
        XCTAssertTrue(source.contains("static let protectionRestartStopWaitTimeout: TimeInterval = 15"))
        XCTAssertTrue(source.contains("static let protectionStartWaitTimeout: TimeInterval = 15"))
        XCTAssertTrue(guardSource.contains("m.protectionPrimaryActionIsDisabled"))
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
        let source = try readAppViewModelSource()
        let disableBlock = try sourceBlock(
            in: source,
            startingAt: "func disableProtection(",
            endingBefore: "func reconnectProtectionNow"
        )
        let waitBlock = try sourceBlock(
            in: source,
            startingAt: "private func waitForProtectionToStop(timeout:",
            endingBefore: "func resumeTemporaryProtectionIfExpired"
        )

        // On a stuck stop, turn-off now attempts profile-removal recovery
        // (UR-31/UR-32) and only throws the actionable vpnStillStopping error if
        // that recovery also fails — it must never silently clear the message.
        XCTAssertTrue(disableBlock.contains("await waitForProtectionToStop() == false"))
        XCTAssertTrue(disableBlock.contains("guard await forceRemoveStuckProtectionProfile() else"))
        XCTAssertTrue(disableBlock.contains("throw LavaSecAppError.vpnStillStopping"))
        XCTAssertTrue(disableBlock.contains("vpnMessage = Self.vpnErrorMessage(prefix: \"Could not stop protection\".lavaLocalized, error: error)"))
        // The timeout-path manager reload (wait-for-stop-timeout-manager-reloaded)
        // is behavior-tested in VPNLifecycleControllerTests; here we pin that the
        // observation callback keeps the cached manager and published status fresh.
        XCTAssertTrue(waitBlock.contains("self?.tunnelManager = manager"))
        XCTAssertTrue(waitBlock.contains("self?.updateProtectionStatus(from: manager)"))
        XCTAssertFalse(disableBlock.contains("await waitForProtectionToStop()\n            }\n            lastProtectionStatusRefresh"))
    }

    func testProtectionErrorMessagesAreLocalizedEndToEnd() throws {
        // UX-1: the Guard-panel protection error messages render in production
        // (GuardView's `Text(message.lavaLocalized)`), so their prefixes must be
        // localized BEFORE they reach vpnErrorMessage's format-key composer — the
        // composer only localizes the separator, not the prefix it is handed. QA-only
        // sites (inside #if DEBUG || LAVA_QA_TOOLS) keep their raw English prefix.
        let source = try readAppViewModelSource()
        let enableBlock = try sourceBlock(
            in: source,
            startingAt: "func enableProtection(",
            endingBefore: "func disableProtection("
        )
        let reconnectBlock = try sourceBlock(
            in: source,
            startingAt: "func reconnectProtectionNow(",
            endingBefore: "private func waitForProtectionToConnect("
        )
        let resumeBlock = try sourceBlock(
            in: source,
            startingAt: "func resumeTemporaryProtectionIfExpired(",
            endingBefore: "func clearTemporaryProtectionPause("
        )

        XCTAssertTrue(enableBlock.contains(
            "vpnMessage = Self.vpnErrorMessage(prefix: \"Could not start protection\".lavaLocalized, error: error)"))
        XCTAssertTrue(reconnectBlock.contains(
            "vpnMessage = Self.vpnErrorMessage(prefix: \"Could not reconnect protection\".lavaLocalized, error: error)"))
        XCTAssertTrue(resumeBlock.contains(
            "vpnMessage = Self.vpnErrorMessage(prefix: \"Resumed protection, but could not refresh filter\".lavaLocalized, error: error)"))

        // The clear-diagnostics error messages interpolate the underlying error, so
        // they go through .lavaLocalizedFormat (a %@ format key) rather than raw
        // string interpolation — otherwise the English literal renders verbatim.
        // They live on DiagnosticsController since the Phase D4 peel and reach the
        // hub's vpnMessage banner through the bridge's presentVPNMessage.
        let diagnosticsControllerSource = try readSource(.diagnosticsController)
        XCTAssertTrue(diagnosticsControllerSource.contains(
            "\"Could not clear local history: %@\".lavaLocalizedFormat(error.localizedDescription)"))
        XCTAssertTrue(diagnosticsControllerSource.contains(
            "\"Could not clear local filtering counts: %@\".lavaLocalizedFormat(error.localizedDescription)"))
        XCTAssertTrue(diagnosticsControllerSource.contains(
            "\"Could not clear local logs: %@\".lavaLocalizedFormat(error.localizedDescription)"))
        // The bridge conformance is what lands them on the banner.
        XCTAssertTrue(source.contains("func presentVPNMessage(_ message: String, isError: Bool) {\n        vpnMessage = message\n        vpnMessageIsError = isError\n    }"))
    }

    func testVPNLifecycleActionsClaimConfiguringBeforeLaunchingAsyncWork() throws {
        let source = try readAppViewModelSource()
        let actionBlock = try sourceBlock(
            in: source,
            startingAt: "func turnOffProtection()",
            endingBefore: "func installLocalVPNProfileForOnboarding() async -> Bool"
        )
        let reconnectBlock = try sourceBlock(
            in: source,
            startingAt: "func reconnectProtectionNow(",
            endingBefore: "private func waitForProtectionToConnect("
        )

        // Single-flight is owned by ProtectionActionOrchestrator: entries claim a
        // kind synchronously (so a second tap is rejected before any await) and
        // release when the spawned flow finishes. isConfiguringVPN is a published
        // mirror with no manual writers; claim/release semantics are behavior-
        // tested in ProtectionActionOrchestratorTests.
        XCTAssertTrue(actionBlock.contains("guard protectionActionOrchestrator.claim(.turnOff) else"))
        XCTAssertTrue(actionBlock.contains("await disableProtection(persistsExplicitIntent: true)\n            protectionActionOrchestrator.release(.turnOff)"))
        XCTAssertTrue(actionBlock.contains("guard protectionActionOrchestrator.claim(.reconnect) else"))
        XCTAssertTrue(actionBlock.contains("guard protectionActionOrchestrator.claim(.toggle) else"))
        // An armed-but-dropped tunnel (awaiting on-demand reconnect) counts as "on" so the toggle's
        // "Turn Off" disables it, instead of re-enabling and stranding the user unable to turn it off.
        XCTAssertTrue(actionBlock.contains("let shouldDisableProtection = isProtectionEnabledStatus(vpnStatus) || isAwaitingOnDemandReconnect"))
        XCTAssertTrue(actionBlock.contains("if shouldDisableProtection"))
        XCTAssertFalse(
            source.contains("isConfiguringVPN = true"),
            "isConfiguringVPN is the orchestrator's published mirror; manual claims would bypass single-flight."
        )
        XCTAssertFalse(reconnectBlock.contains("isConfiguringVPN = false\n            await enableProtection"))
        // Canary: the negative pins above key on these identifiers - if a rename removes
        // one from the pinned source, those pins pass vacuously. Fail here instead, then
        // re-anchor both sides to the new name.
        XCTAssertTrue(source.contains("isConfiguringVPN"))
        XCTAssertTrue(source.contains("enableProtection"))
    }

    func testProtectionConnectedNetworkActivityIsLoggedOnStatusTransition() throws {
        let source = try readAppViewModelSource()
        let updateStatusBlock = try sourceBlock(
            in: source,
            startingAt: "func updateProtectionStatus(from manager: NETunnelProviderManager?)",
            endingBefore: "private func playProtectionStartFailedHaptic()"
        )

        XCTAssertTrue(updateStatusBlock.contains("previousStatus != .connected"))
        XCTAssertTrue(updateStatusBlock.contains("currentStatus == .connected"))
        XCTAssertTrue(updateStatusBlock.contains("appendNetworkActivity(.protectionConnected)"))
    }

    func testNonCriticalAppGroupDefaultsDoNotForceSynchronousFlushes() throws {
        let source = try readAppViewModelSource()
        // persistLavaGuardLook lives on CustomizationController since the Phase D5 peel.
        let customizationSource = try readSource(.customizationController)
        let persistLookBlock = try sourceBlock(
            in: customizationSource,
            startingAt: "private func persistLavaGuardLook(_ look: GuardianShieldStyle)",
            endingBefore: "private func syncAppIcon(to look: GuardianShieldStyle)"
        )
        let loadPauseBlock = try sourceBlock(
            in: source,
            startingAt: "func loadTemporaryProtectionPause()",
            endingBefore: "func beginFreshProtectionVPNSession()"
        )

        XCTAssertTrue(persistLookBlock.contains("appGroupDefaults.set(look.rawValue, forKey: lavaGuardLookDefaultsKey)"))
        XCTAssertFalse(persistLookBlock.contains("appGroupDefaults.synchronize()"))
        XCTAssertTrue(loadPauseBlock.contains("pauseController.currentPauseUntil()"))
        XCTAssertFalse(loadPauseBlock.contains("appGroupDefaults.synchronize()"))
    }

    func testTemporaryProtectionPausePersistsAndResumesRobustly() throws {
        let source = try readAppViewModelSource()
        let rootSource = try readSource(.rootView)
        let pauseBlock = try sourceBlock(
            in: source,
            startingAt: "func pauseProtectionTemporarily(for option: ProtectionPauseDuration)",
            endingBefore: "func resumeProtectionNow()"
        )
        let resumeBlock = try sourceBlock(
            in: source,
            startingAt: "func resumeTemporaryProtectionIfExpired(now: Date = Date()) async",
            endingBefore: "func restoreFiltersAfterTemporaryProtectionPause("
        )
        let restoreBlock = try sourceBlock(
            in: source,
            startingAt: "func restoreFiltersAfterTemporaryProtectionPause(",
            endingBefore: "func clearTemporaryProtectionPause()"
        )

        // The @Published mirror + pause/resume orchestration stay in AppViewModel;
        // the resume timer and legacy pause-key cleanup moved to
        // TemporaryProtectionPauseController.
        let pauseController = try readSource(.temporaryProtectionPauseController)
        // The setter is internal only because the class spans files (the pause and Sudoku
        // concerns write it); `AppViewModelEncapsulationSourceTests` pins that nothing outside
        // the class assigns it.
        XCTAssertTrue(source.contains("@Published var temporaryProtectionPauseUntil: Date?"))
        XCTAssertTrue(pauseController.contains("private var resumeTask: Task<Void, Never>?"))
        XCTAssertTrue(pauseController.contains("LavaSecAppGroup.protectionTemporaryPauseUntilDefaultsKey"))
        XCTAssertTrue(source.contains("loadTemporaryProtectionPause()"))
        XCTAssertTrue(pauseController.contains("resumeTask?.cancel()"))

        XCTAssertTrue(source.contains("var protectionCommandRequest: LavaLiveActivityActionRequest"))
        XCTAssertTrue(source.contains(".pauseFifteenMinutes"))
        // The fixed-length entry point delegates to a shared request-based flow
        // that also serves the Live Activity's configured-length Pause button.
        XCTAssertTrue(pauseBlock.contains("pauseProtectionTemporarily(request: option.protectionCommandRequest)"))
        XCTAssertTrue(pauseBlock.contains("func pauseProtectionTemporarily(request: LavaLiveActivityActionRequest)"))
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
        // Canary: the negative pins above key on these identifiers - if a rename removes
        // one from the pinned source, those pins pass vacuously. Fail here instead, then
        // re-anchor both sides to the new name.
        XCTAssertTrue(source.contains("disableProtection"))
        XCTAssertTrue(source.contains("enableProtection"))
    }

    func testTemporaryPauseControlsAreHiddenWhenNoNetworkPath() throws {
        let source = try readAppViewModelSource()
        let controlsBlock = try sourceBlock(
            in: source,
            startingAt: "var showsTemporaryProtectionPauseControls: Bool",
            endingBefore: "var formattedTemporaryProtectionResumeTime"
        )

        // The Guard status projection covers Network Lost, reconnect and pause
        // consistently; this control reads its single pause decision.
        XCTAssertTrue(controlsBlock.contains("vpnStatus == .connected"))
        XCTAssertTrue(controlsBlock.contains("guardStatusPresentation.allowsPause"))
        XCTAssertTrue(controlsBlock.contains("!isConfiguringVPN"))

        // The action entry point shares the same guard, so a stale pause intent
        // cannot pause protection while Network Lost is showing.
        let pauseBlock = try sourceBlock(
            in: source,
            startingAt: "func pauseProtectionTemporarily(for option: ProtectionPauseDuration)",
            endingBefore: "func resumeProtectionNow()"
        )
        XCTAssertTrue(pauseBlock.contains("guard showsTemporaryProtectionPauseControls else"))
    }

    func testTemporaryProtectionPauseIsBoundToCurrentVPNSession() throws {
        let source = try readAppViewModelSource()
        let enableBlock = try sourceBlock(
            in: source,
            startingAt: "func enableProtection(",
            endingBefore: "func disableProtection("
        )
        let disableBlock = try sourceBlock(
            in: source,
            startingAt: "func disableProtection(",
            endingBefore: "func reconnectProtectionNow("
        )
        let loadPauseBlock = try sourceBlock(
            in: source,
            startingAt: "func loadTemporaryProtectionPause()",
            endingBefore: "func beginFreshProtectionVPNSession()"
        )
        let clearPauseBlock = try sourceBlock(
            in: source,
            startingAt: "func clearTemporaryProtectionPause()",
            endingBefore: "func loadExistingTunnelManager() async throws"
        )

        // Session binding + legacy-key cleanup moved into the controller; the
        // store-routing contract is now enforced there.
        let pauseController = try readSource(.temporaryProtectionPauseController)
        XCTAssertTrue(pauseController.contains("LavaSecAppGroup.protectionTemporaryPauseSessionIDDefaultsKey"))

        let beginSessionIndex = try XCTUnwrap(enableBlock.range(of: "beginFreshProtectionVPNSession()")?.lowerBound)
        let snapshotIndex = try XCTUnwrap(enableBlock.range(of: "preparedSnapshotForProtectionStartup(")?.lowerBound)
        let startIndex = try XCTUnwrap(enableBlock.range(of: "manager.connection.startVPNTunnel(")?.lowerBound)
        XCTAssertLessThan(
            snapshotIndex,
            beginSessionIndex,
            "A superseded preparation must not mint a session that never starts a tunnel."
        )
        XCTAssertLessThan(
            beginSessionIndex,
            startIndex,
            "A fresh session must be installed immediately before the tunnel start."
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
        // Canary: the negative pins above key on these identifiers - if a rename removes
        // one from the pinned source, those pins pass vacuously. Fail here instead, then
        // re-anchor both sides to the new name.
        XCTAssertTrue(source.contains("temporaryProtectionPauseUntil"))
    }

    func testPreparedSnapshotsOnlyPersistWhenSelectedBlocklistsAreCovered() throws {
        let source = try readAppViewModelSource()
        let summaryBlock = try sourceBlock(
            in: source,
            startingAt: "private func preparedSummary(for snapshot: FilterSnapshot)",
            endingBefore: "func preparedSnapshotForCurrentConfiguration()"
        )
        let prepareBlock = try sourceBlock(
            in: source,
            startingAt: "func prepareFilterSnapshot(",
            endingBefore: "private func reportFilterPreparationProgress"
        )
        let persistBlock = try sourceBlock(
            in: source,
            startingAt: "func persistSharedState(",
            endingBefore: "func persistConfigurationOnly("
        )

        XCTAssertTrue(summaryBlock.contains("preparedBlocklistSourceRuleCounts()"))
        XCTAssertTrue(summaryBlock.contains("guard let rules = cachedBlockRuleSets[sourceID]"))
        XCTAssertTrue(
            prepareBlock.contains("service.prepare("),
            "Preparation (sync ladder, validation, merge, build) must route through FilterSnapshotPreparationService; its behavior is covered by FilterSnapshotPreparationServiceTests."
        )
        // Anchored on tokens, NOT on the call's wrapping. The previous form pinned
        // `"coversEnabledBlocklists(\n            in: configuration)"` — the exact two-line
        // split plus a 12-space continuation indent — so a formatter joining those lines
        // reddened the suite with zero behavioural change, and a re-indent did the same.
        // What this test is for is that the coverage gate feeds the persist decision; the
        // shape of the line it is written on is not part of that contract.
        XCTAssertTrue(
            persistBlock.contains("let coversEnabledBlocklists = snapshotToPersist.summary.coversEnabledBlocklists("),
            "The persist path must derive coverage from the snapshot it is about to write.")
        XCTAssertTrue(
            persistBlock.contains("coversEnabledBlocklists(\n            in: configuration)")
                || normalizedPersistBlockForCoverage(persistBlock).contains(
                    "coversEnabledBlocklists( in: configuration)"),
            "Coverage must be evaluated against the live configuration, not a captured copy. "
                + "A bare `in: configuration` search would pass on any other occurrence in the "
                + "block, so this ties the argument to THIS call.")
        XCTAssertTrue(persistBlock.contains("persistPreparedSnapshotArtifacts(")
                        && persistBlock.contains("snapshotToPersist,"),
                      "The artifact publish must route through persistPreparedSnapshotArtifacts(snapshotToPersist, …).")
        // The rewrite is gated on rewritesRuleArtifacts AND coverage, hoisted into a
        // `didRewriteArtifacts` flag (multi-filter reuses the same flag to decide
        // whether to record the active filter's compiled token). Same guarantee:
        // reused or configuration-only persists must not rewrite identical rule
        // artifacts (warm turn-on cost).
        // 🔴 NORMALIZED, not split into separate `contains` calls. Splitting was the first
        // attempt at de-brittling this and it made the pin VACUOUS: `coversEnabledBlocklists`
        // and `fitsTierBudget` each already appear several times elsewhere in this ~12k-char
        // block (their own `let` bindings, and the veto log dictionary), so dropping both
        // terms from the chain left every conjunct true. Collapsing whitespace keeps the
        // reflow-immunity that motivated the change while still pinning the CHAIN.
        let normalizedPersistBlock = persistBlock
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .joined(separator: " ")
        XCTAssertTrue(
            normalizedPersistBlock.contains(
                "let didRewriteArtifacts = rewritesRuleArtifacts && coversEnabledBlocklists "
                    + "&& fitsTierBudget")
                && persistBlock.contains("if didRewriteArtifacts {")
                // The veto must not be silent: a coverage veto strands the config naming
                // blocklists no artifact covers, and the tunnel then serves block-all forever.
                && persistBlock.contains("logVPNDebugEvent(\"artifact-flip-vetoed\""),
            "Reused or configuration-only persists must not rewrite identical rule artifacts (warm turn-on cost)."
        )
    }

    func testClearAndDisableBackupDivergeOnLocalEnvelopeHandling() throws {
        let source = try readSource(.backupController)
        let clear = try sourceBlock(in: source, startingAt: "func clearEncryptedBackup() async {", endingBefore: "func disableEncryptedBackup() async {")
        let disable = try sourceBlock(in: source, startingAt: "func disableEncryptedBackup() async {", endingBefore: "func prepareForAccountDeletion(")
        XCTAssertTrue(clear.contains("backupEnvelopeStore.clearUploadMarker()"))
        XCTAssertFalse(clear.contains("backupEnvelopeStore.deleteEnvelope()"))
        XCTAssertTrue(disable.contains("backupEnvelopeStore.deleteEnvelope()"))
        XCTAssertTrue(disable.contains("setAutomaticBackupEnabled(false)"))
        XCTAssertTrue(disable.contains("backupKeychainStore.saveDeletionIntent(intent)"))
        XCTAssertTrue(disable.contains("guard case .deleted = await deleteRemoteEncryptedBackup(expectedAccountID: intent.accountID)"))
        XCTAssertTrue(disable.contains("finishLocalBackupDeletion(intent)"))
    }

    func testBackupMaintenanceAndUploadsAreMutuallyExclusive() throws {
        let source = try readSource(.backupController)
        let disable = try sourceBlock(in: source, startingAt: "func disableEncryptedBackup() async {", endingBefore: "private func finishLocalBackupDeletion(")
        let upload = try sourceBlock(in: source, startingAt: "private func uploadEncryptedBackup(", endingBefore: "func uploadPendingEncryptedBackupIfPossible(")
        XCTAssertTrue(upload.contains("!isBackupMaintenanceInProgress, !hasBackupDeletionFence"))
        XCTAssertTrue(disable.contains("isBackupMaintenanceInProgress = true"))
        XCTAssertTrue(disable.contains("await uploadTask?.value"))
        XCTAssertTrue(disable.contains("lifecycleGeneration &+= 1"))
        // NativeBackupDeletionCompatibilityTests executes this drain with suspended
        // uploads and covers the account-deletion failure rescheduling path.
        XCTAssertTrue(source.contains("if !confirmed, hub.currentBackupAccountID == accountID"))
        XCTAssertTrue(source.contains("try await hub.refreshCurrentBackupSession()"))
        XCTAssertTrue(source.contains("try backupKeychainStore.cancelAccountDeletionPreparation(intent)"))
    }
    /// `logVPNDebugEvent` must be reachable from EVERY build configuration.
    ///
    /// It was not. It lived inside the debug-probe region — a 169-line block behind a build-flag
    /// `#if` — while one caller, `chained-upstream-disabled` (pinned by
    /// `ChainedUpstreamReconcileSourceTests`), sits outside any region. The Release device
    /// compile therefore failed with "cannot find 'logVPNDebugEvent' in scope", and main's
    /// app-compile lane was red from 2026-07-28 until this was found. The other 44 call sites are
    /// all inside build-flag regions, so nothing else could expose the gap — and `swift test`
    /// cannot see it at all, because the app target is not in the package.
    ///
    /// The check counts `#if`/`#endif` nesting rather than matching a flag name, deliberately:
    /// naming the internal build flag in tracked source trips the merge-up contamination guard,
    /// and the property being asserted is "not conditional on anything", which is stronger than
    /// "not conditional on that one flag".
    func testTheDebugEventWriterIsAvailableInEveryConfiguration() throws {
        let source = try readAppViewModelSource()
        var depth = 0
        var definitionDepth: Int?
        var ungatedCallLines: [Int] = []

        for (offset, line) in source.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("#if") {
                depth += 1
            } else if trimmed.hasPrefix("#endif") {
                depth = max(0, depth - 1)
            }

            guard line.contains("logVPNDebugEvent") else { continue }
            if trimmed.hasPrefix("func logVPNDebugEvent") {
                definitionDepth = depth
            } else if depth == 0 {
                ungatedCallLines.append(offset + 1)
            }
        }

        XCTAssertEqual(
            definitionDepth, 0,
            "logVPNDebugEvent is declared inside a conditional-compilation region, so any caller "
                + "outside one fails to compile in that configuration — which is exactly how the "
                + "Release device lane broke. Callers at lines \(ungatedCallLines) are unconditional."
        )
    }

    /// The SAME regression, one helper along.
    ///
    /// `testTheDebugEventWriterIsAvailableInEveryConfiguration` scans `logVPNDebugEvent` and
    /// nothing else, so it did not catch the actual break: the un-gated
    /// `launch-snapshot-reconcile-failed` breadcrumb called `errorDebugDetails`, which lives
    /// inside `#if DEBUG || LAVA_QA_TOOLS`. The writer was fine; its ARGUMENT was not. Both
    /// halves of that call have to be unconditional, and only one of them was pinned.
    ///
    /// Two assertions, because two distinct edits reopen the hole: moving
    /// `errorIdentityDetails` into a gated region, or reverting the call site to
    /// `errorDebugDetails`. Neither is visible to `swift test` — the app target is not in the
    /// package — so the Release `generic/platform=iOS` lane is the only thing that would go
    /// red, and only after a push.
    ///
    /// Depth counting rather than flag matching, for the same reason as its sibling: naming
    /// the internal build flag in tracked source trips the merge-up contamination guard, and
    /// "not conditional on anything" is the stronger property.
    func testTheReconcileFailureBreadcrumbTakesAnUnconditionalArgument() throws {
        let source = try readAppViewModelSource()
        var depth = 0
        var definitionDepth: Int?
        var sawBreadcrumb = false
        var breadcrumbUsesIdentityDetails = false

        for line in source.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("#if") {
                depth += 1
            } else if trimmed.hasPrefix("#endif") {
                depth = max(0, depth - 1)
            }

            if trimmed.hasPrefix("func errorIdentityDetails") {
                definitionDepth = depth
            }
            if line.contains("\"launch-snapshot-reconcile-failed\"") {
                sawBreadcrumb = true
                breadcrumbUsesIdentityDetails = line.contains("errorIdentityDetails(error)")
            }
        }

        XCTAssertEqual(
            definitionDepth, 0,
            "errorIdentityDetails is declared inside a conditional-compilation region. The "
                + "unconditional launch-snapshot-reconcile-failed breadcrumb calls it, so that "
                + "configuration fails to compile — the exact break this pin exists for.")
        // NOT a depth assertion on the CALL SITE, and the first draft of this test got that
        // wrong — it asserted depth 0 and failed, because `reconcileTunnelSnapshotAfterLaunch`
        // splits on `#if targetEnvironment(simulator)` and the breadcrumb lives in the device
        // `#else` arm. Depth 1 there is correct: every real build compiles it. A crude depth
        // count cannot tell a platform split from a build-flag gate, and the compile-break
        // class is already closed by the two assertions that remain — a depth-0 helper called
        // by name means no configuration can fail to compile on this pair.
        XCTAssertTrue(sawBreadcrumb, "The launch-snapshot-reconcile-failed breadcrumb is gone.")
        XCTAssertTrue(
            breadcrumbUsesIdentityDetails,
            "The breadcrumb must pass errorIdentityDetails(error). errorDebugDetails is both "
                + "build-gated AND carries localizedDescription, which can interpolate a user's "
                + "self-hosted blocklist host into the report bundle.")
    }

}
