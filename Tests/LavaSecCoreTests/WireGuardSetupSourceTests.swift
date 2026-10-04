import XCTest

/// The behavioral policy is executable; these pins cover the app/native bridge wiring.
final class WireGuardSetupSourceTests: XCTestCase {
    func testConsumerVPNWiringIsAvailableWithoutDebugOrQAFlags() throws {
        let sources: [(SourceFile, [String])] = [
            (.vpnChainingSettingsView, ["struct VPNChainingSettingsView", "struct VPNChainingConfigurationEditor"]),
            (.settingsView, ["case vpnChaining", "case .vpnChaining:"]),
            (.rootView, ["case .vpnChaining: screen = \"vpnChaining\""]),
            (.appViewModelCore, ["@Published var dnsSettingsProfileStatus", "@Published var isStagingChainedUpstreamForQA"]),
            (.appViewModelQATooling, ["struct ChainedUpstreamSurfaceStatus", "var chainedUpstreamSurfaceStatus:",
                "func setWireGuardSetupEnabled(", "func validateChainedConfigurationForStart()", "func setChainedUpstreamEnabled("]),
            (.appViewModelChainedDNSFallback, ["func requestChainedSettingsApply()", "func setChainedTierOneFallbackEnabled(",
                "func commitWireGuardPage(", "private func editableWireGuardStore()"]),
            (.appViewModelResolverSettings, ["dnsSettingsProfileStatus = chainedUpstreamSurfaceStatus", "return dnsSettingsPresentation(from: dnsSettingsProfileStatus)"]),
            (.appViewModelProtectionLifecycle, ["guard validateChainedConfigurationForStart()"]),
            (.reactNativeAppBridge, ["value[\"vpn\"] = vpnSettingsState()", "result[\"vpn\"] = [\"eligible\": true",
                "if name.hasPrefix(\"vpn.\")"]),
            (.reactNativeAppSettings, ["func vpnSettingsState()", "func vpnCommand("]),
            (.reactNativeAppQueries, ["let status = model.chainedUpstreamSurfaceStatus"]),
            (.reactNativeAppFlows, ["case \"vpnConfiguration\":"]),
        ]
        for (file, phrases) in sources {
            let source = try readSource(file)
            for phrase in phrases { assertNotQAGated(phrase, in: source, context: file.rawValue) }
        }
        let commands = try readSource(.appViewModelChainedDNSFallback)
        let store = try sourceBlock(in: commands, startingAt: "private func editableWireGuardStore()",
                                    endingBefore: "func stageChainedUpstreamForQA(")
        XCTAssertFalse(store.contains("guard identity != .production"))
        XCTAssertTrue(store.contains("ChainedUpstreamStoreIdentity.identity(forKeychainGroup: group) == identity"))
        // Test-only staging/deletion must still refuse the production slot.
        let clear = try sourceBlock(in: commands, startingAt: "func clearStagedChainedUpstreamForQA(",
                                    endingBefore: "func prepareQAInternetNetworkCondition(")
        XCTAssertTrue(clear.contains("guard identity != .production"))
        // QA hop removal reaches the store directly (it bypasses
        // `ChainedUpstreamStagingRequest`), so it carries its own production refusal.
        let remove = try sourceBlock(in: commands, startingAt: "func removeWireGuardHop(",
                                     endingBefore: "#endif")
        XCTAssertTrue(remove.contains("guard LavaSecAppGroup.chainedUpstreamStoreIdentity != .production"))
        for file in [SourceFile.vpnChainingSettingsView, .reactNativeAppSettings] {
            let editor = try readSource(file)
            XCTAssertTrue(editor.contains("ChainedUpstreamConfParser.rotation(from: $0)"))
            XCTAssertFalse(editor.contains("ChainedUpstreamStagingRequest("),
                           "Consumer imports must not use the QA staging admission policy")
        }
    }

    func testVPNPresentationUsesCachedMetadataAndRefreshesAtEntryResumeAndMutations() throws {
        let view = try readSource(.vpnChainingSettingsView)
        let body = try sourceBlock(in: view, startingAt: "var body: some View {", endingBefore: "private func pageContent(")
        XCTAssertTrue(body.contains("if let status = viewModel.dnsSettingsProfileStatus"))
        XCTAssertFalse(body.contains("viewModel.chainedUpstreamSurfaceStatus"))
        XCTAssertTrue(body.contains(".onAppear { viewModel.refreshDNSSettingsPresentation() }"))
        XCTAssertTrue(body.contains(".onChange(of: scenePhase)"))
        XCTAssertTrue(body.contains(".onChange(of: viewModel.configuration)"))
        let editGate = try sourceBlock(in: view, startingAt: "private var canEditConfiguration", endingBefore: "// MARK: - Actions")
        XCTAssertTrue(editGate.contains("viewModel.dnsSettingsProfileStatus"))
        XCTAssertFalse(editGate.contains("viewModel.chainedUpstreamSurfaceStatus"))
        let save = try sourceBlock(in: view, startingAt: "private func saveDraftConfiguration()", endingBefore: "validationMessage = savePendingDraft")
        XCTAssertTrue(sourceContainsInOrder(["viewModel.refreshDNSSettingsPresentation()", "guard canSaveDraft"], in: save))
    }

    func testVPNNativeSurfacesReauthorizeAndFenceWritesAfterSettingsGrantRevocation() throws {
        let view = try readSource(.vpnChainingSettingsView)
        XCTAssertTrue(view.contains("VPNSettingsAuthorization(reason: \"Open VPN chaining settings\""))
        XCTAssertTrue(view.contains("VPNSettingsAuthorization(reason: \"Edit VPN chaining\""))
        let authorization = try sourceBlock(in: view, startingAt: "private struct VPNSettingsAuthorization",
            endingBefore: "private struct VPNChainingPageDestinations")
        XCTAssertTrue(authorization.contains("revision: security.viewAuthenticationRevision"))
        XCTAssertTrue(authorization.contains(".allowsHitTesting(canInteract)"))
        XCTAssertTrue(authorization.contains("security.hasCurrentAuthorization(for: .appSettings)"))
        XCTAssertTrue(authorization.contains(".onDisappear { isPresented = false }"))
        XCTAssertTrue(authorization.contains("!managedByParent"))
        XCTAssertTrue(try readSource(.reactNativePageContent).contains("authorizationIsOwnedByParent: true"))
        XCTAssertTrue(sourceContainsInOrder(["guard request.visible, request.phase == .active", "await security.requireAuthentication",
            "guard !Task.isCancelled, context == request", "if !accepted { onDenied() }"], in: authorization))
        let commit = try sourceBlock(in: view, startingAt: "private func commitPageEdit()", endingBefore: "private func stagePageRow(")
        XCTAssertTrue(sourceContainsInOrder(["guard canModifySettings", "try viewModel.commitWireGuardPage"], in: commit))
        let editGate = try sourceBlock(in: view, startingAt: "private var canEditConfiguration", endingBefore: "// MARK: - Actions")
        XCTAssertTrue(editGate.contains("security.hasCurrentAuthorization(for: .appSettings)"))
    }

    func testVPNMetadataRefreshesFromProviderSignalsAndConnectionTransitions() throws {
        let model = try readAppViewModelSource()
        let signal = try sourceBlock(in: model, startingAt: "func handleTunnelHealthNudge()",
            endingBefore: "func performLiveActivityActionRequest(")
        XCTAssertTrue(sourceContainsInOrder(["refreshDNSSettingsPresentation()", "Task { [weak self]"], in: signal))
        let status = try sourceBlock(in: model, startingAt: "func updateProtectionStatus(from manager:",
            endingBefore: "private func playProtectionStartFailedHaptic()")
        XCTAssertTrue(status.contains("""
        if previousStatus != currentStatus || installedStateChanged {
                    refreshDNSSettingsPresentation()
                }
        """))
    }

    private func assertNotQAGated(_ phrase: String, in source: String, context: String,
                                 file: StaticString = #filePath, line: UInt = #line) {
        var gates: [Bool] = []
        var found = false
        for raw in source.components(separatedBy: "\n") {
            let text = raw.trimmingCharacters(in: .whitespaces)
            if text.hasPrefix("#if ") { gates.append(text.contains("DEBUG") || text.contains("LAVA_QA_TOOLS")) }
            else if text.hasPrefix("#endif") { _ = gates.popLast() }
            guard !text.hasPrefix("//"), text.contains(phrase) else { continue }
            found = true
            XCTAssertFalse(gates.contains(true), "\(context): \(phrase) must ship in Release", file: file, line: line)
        }
        XCTAssertTrue(found, "\(context): missing \(phrase)", file: file, line: line)
    }

    func testEditorRetainsOnlyAnExplicitlyRevealedAllOffDraftAcrossProtectedDataLoss() throws {
        let view = try readSource(.vpnChainingSettingsView)
        let editor = String(view[try XCTUnwrap(view.range(of: "struct VPNChainingConfigurationEditor")).lowerBound...])
        XCTAssertTrue(editor.contains("@EnvironmentObject private var security: SecurityController"))
        XCTAssertTrue(editor.contains("SecurityPrivacyPolicy.requiresPrivateDraftCover("))
        XCTAssertTrue(editor.contains("backgroundCoverRequired: security.backgroundPrivacyCoverRequired"))
        XCTAssertTrue(editor.contains("if security.backgroundPrivacyCoverRequired { draftRevealed = false }"))
        XCTAssertTrue(editor.contains("UIApplication.protectedDataWillBecomeUnavailableNotification"))
        XCTAssertTrue(editor.contains("security.protectedDataWillBecomeUnavailable()"))
        let preLock = try sourceBlock(in: editor,
            startingAt: ".onReceive(NotificationCenter.default.publisher(for: UIApplication.protectedDataWillBecomeUnavailableNotification))",
            endingBefore: ".onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification))")
        XCTAssertTrue(preLock.contains("if security.backgroundPrivacyCoverRequired { draftRevealed = false }"))
        let editing = try sourceBlock(in: editor, startingAt: "private var canEditConfiguration", endingBefore: "// MARK: - Actions")
        XCTAssertTrue(editing.contains("security.protectedDataIsAvailableForPresentation"))
        let importing = try sourceBlock(in: editor, startingAt: "private func handleImport", endingBefore: "private enum ConfigurationReadFailure")
        XCTAssertTrue(sourceContainsInOrder([
            "guard canEditConfiguration else { return }", "validationMessage = nil",
            "await Task.detached", "guard security.viewAuthenticationRevision == authorizationRevision, canEditConfiguration",
            "draftConfiguration = text"
        ], in: importing))
        XCTAssertTrue(importing.contains("guard importToken == token else { return }"))
        XCTAssertTrue(editor.contains(".onDisappear { importToken = UUID(); isReadingConfiguration = false }"))
        XCTAssertFalse(editor.contains("keychainStore.load"))
    }

    func testPickedVPNDocumentsAreBoundedBeforeDecodingRegardlessOfReportedSize() throws {
        let view = try readSource(.vpnChainingSettingsView)
        let read = try sourceBlock(in: view, startingAt: "nonisolated private static func readConfiguration(at",
                                  endingBefore: "private func saveDraftConfiguration()")
        XCTAssertFalse(read.contains("Data(contentsOf:"))
        XCTAssertTrue(read.contains("Self.maximumConfigurationBytes + 1 - data.count"))
        XCTAssertTrue(read.contains("handle.read(upToCount: min(8 * 1024, remaining))"))
        XCTAssertTrue(sourceContainsInOrder(["guard data.count <= Self.maximumConfigurationBytes", "String(data: data, encoding: .utf8)"], in: read))
        XCTAssertTrue(read.contains("defer { try? handle.close() }"))
        XCTAssertTrue(read.contains("url.stopAccessingSecurityScopedResource()"))
    }

    func testSetupAndRoutingHaveIndependentControlsAndSavingDoesNotEnable() throws {
        let view = try readSource(.vpnChainingSettingsView)
        XCTAssertTrue(sourceContainsInOrder([
            "I have a WireGuard configuration", "if setupEnabled {", "configurationRow(status)",
            "LavaQuietFooter(chainingExplanation)", "\"DNS fallback\""
        ], in: view))
        XCTAssertTrue(view.contains("validationMessage = savePendingDraft(name,"))
        let editor = String(view[try XCTUnwrap(view.range(of: "struct VPNChainingConfigurationEditor")).lowerBound...])
        XCTAssertFalse(editor.contains("viewModel.saveWireGuardHop("))
        XCTAssertTrue(editor.contains("lavaConfirmInteractiveDismiss(hasUnsavedChanges)"))
        XCTAssertTrue(editor.contains("lavaConfirmationAlert"))
        XCTAssertTrue(editor.contains("requestDismiss()"))
        XCTAssertTrue(view.contains("try viewModel.commitWireGuardPage(&draft)"))
        let source = try readAppViewModelSource()
        let stage = try sourceBlock(in: source, startingAt: "if !enablesChaining {",
                                    endingBefore: "let generation = try store.commit")
        XCTAssertTrue(stage.contains("try store.commit(request.rotation)"))
        XCTAssertFalse(stage.contains("chainedUpstreamEnabled = true"))
        XCTAssertTrue(stage.contains("didCommitConfiguration = configuration.chainedUpstreamEnabled"))
        let setter = try sourceBlock(in: source, startingAt: "func setChainedUpstreamEnabled",
                                     endingBefore: "func recordDemo")
        XCTAssertTrue(sourceContainsInOrder([
            "guard !isStagingChainedUpstreamForQA", "if enabled {", "canEnableChainedUpstream(from: status)",
            "configuration.chainedUpstreamEnabled = enabled", "try persistConfigurationOnly()"
        ], in: setter))
    }

}
