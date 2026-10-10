import XCTest

/// The behavioral policy is executable; these pins cover the app/native bridge wiring.
final class WireGuardSetupSourceTests: XCTestCase {
    func testRNWireGuardDismissChecksCurrentNativeDirtyBeforeRetirement() throws {
        let source = try readSource(.reactNativeAppFlows)
        let dismiss = try sourceBlock(in: source, startingAt: "if action == \"foreground.dismiss\" {",
            endingBefore: "if action == \"foreground.dirty\" {")
        let vpn = try sourceBlock(in: dismiss, startingAt: "if flow.name == \"vpnConfiguration\" {",
            endingBefore: "if flow.name == \"feedback\" {")
        // Source-boundary coverage: actual UIKit owner behavior remains in the
        // app target, while this cross-platform target pins the safety ordering.
        XCTAssertTrue(sourceContainsInOrder([
            "if let visit = wireGuardEditorVisit", "guard visit.id == flow.id",
            "guard !visit.dirty || input[\"discardConfirmed\"] as? Bool == true else { return false }",
            "visit.retire(); wireGuardEditorVisit = nil"
        ], in: vpn))
        XCTAssertTrue(sourceContainsInOrder([
            "else { return false }", "visit.retire()", "self.flow = nil; foregroundDraftIsDirty = false"
        ], in: dismiss))
        XCTAssertFalse(vpn.contains("wireGuardEditorOwner("), "Close cannot create or replace a visit")
        XCTAssertFalse(vpn.contains("configuration"), "Dismissal returns only a confirmation result, never Content")
        XCTAssertFalse(vpn.contains("authorize("), "A clean Cancel must retain its existing cancellation behavior")
    }

    func testRNWireGuardNameUsesCurrentNativeOwnerAndCannotMutateThroughRetainedUIKitInput() throws {
        let editor = try readSource(.reactNativeAppWireGuardEditor)
        let nameGate = try sourceBlock(in: editor, startingAt: "func canEditWireGuardName(ownerID: String)",
            endingBefore: "func wireGuardEditorOwner(")
        XCTAssertTrue(sourceContainsInOrder([
            "flow.name == \"vpnConfiguration\"", "flow.id.uuidString == ownerID",
            "let visit = wireGuardEditorVisit", "visit.id == flow.id",
            "flow.wireGuardDraftID == visit.draftID", "flow.wireGuardDraftRevision == visit.draftRevision",
            "return visit.canEdit"
        ], in: nameGate))
        XCTAssertFalse(nameGate.contains("wireGuardEditorOwner("), "Admission must not create a native visit")
        XCTAssertFalse(nameGate.contains("configuration"), "Name admission must not read private configuration")
        XCTAssertFalse(nameGate.contains("authorize("), "A keyboard event cannot start authentication")

        // The first registered internal source read above supplies public-export
        // skipping. These UIKit leaves are inspected without importing UIKit into
        // the cross-platform policy test target.
        let field = try String(contentsOf: packageRootURL.appendingPathComponent("ReactNative/ios/LavaSecUIReview/LavaTextFieldView.mm"), encoding: .utf8)
        let admission = try sourceBlock(in: field, startingAt: "static BOOL mayEditWireGuardName", endingBefore: "@interface")
        XCTAssertTrue(admission.contains("if (props.kind != \"wireGuardName\") return YES;"), "Other ordinary fields retain their existing policy")
        XCTAssertTrue(admission.contains("props.editable && [[LavaAppBridge shared] canEditWireGuardNameForOwnerID:"))
        XCTAssertTrue(admission.contains("props.ownerID.c_str()"))
        XCTAssertTrue(admission.contains("#else\n  return NO;"))
        for notification in ["UIApplicationWillResignActiveNotification", "UIApplicationProtectedDataWillBecomeUnavailable"] {
            XCTAssertTrue(field.contains("selector:@selector(suspendWireGuardName) name:\(notification)"))
        }
        let suspension = try sourceBlock(in: field, startingAt: "- (void)suspendWireGuardName {", endingBefore: "- (void)refreshWireGuardNameAdmission {")
        XCTAssertTrue(sourceContainsInOrder(["_wireGuardNameSuspended = YES", "if (props.kind != \"wireGuardName\") return;", "_field.enabled = NO", "[_field resignFirstResponder]"], in: suspension))
        XCTAssertFalse(suspension.contains("_field.text"), "Revocation preserves the accepted Name buffer")
        XCTAssertFalse(suspension.contains("_confidentialInput"), "Only the ordinary Name responder resigns")
        let refresh = try sourceBlock(in: field, startingAt: "- (void)refreshWireGuardNameAdmission {", endingBefore: "- (void)updateProps:")
        XCTAssertTrue(refresh.contains("applicationState != UIApplicationStateActive"))
        XCTAssertTrue(refresh.contains("!UIApplication.sharedApplication.protectedDataAvailable"))
        XCTAssertTrue(refresh.contains("BOOL editable = [self admitsWireGuardNameEdit]"))
        XCTAssertFalse(refresh.contains("becomeFirstResponder"))
        let props = try sourceBlock(in: field, startingAt: "- (void)updateProps:", endingBefore: "- (void)didMoveToWindow")
        XCTAssertTrue(props.contains("next.kind == \"search\" || next.kind == \"wireGuardName\""), "Name keeps ordinary seed/reset/keyboard behavior")
        XCTAssertTrue(props.contains("const BOOL ordinaryReseed = ordinary && (!_ordinarySeeded || next.ownerID != previous.ownerID || next.resetRevision != previous.resetRevision);"), "A recycled ordinary buffer reseeds for its current owner and reset revision")
        XCTAssertTrue(props.contains("!_wireGuardNameSuspended && mayEditWireGuardName(next)"))
        XCTAssertTrue(props.contains("_field.enabled = next.editable && nameEditable"))
        let reconciliation = try sourceBlock(in: props, startingAt: "[super updateProps:props oldProps:oldProps];")
        XCTAssertTrue(sourceContainsInOrder([
            "next.kind == \"wireGuardName\" && next.editable && nameEditable",
            "NSString *ownerID", "const int resetRevision", "dispatch_async(dispatch_get_main_queue()",
            "current.kind != \"wireGuardName\"", "current.ownerID != ownerID.UTF8String",
            "current.resetRevision != resetRevision", "!current.editable", "!strongSelf.window",
            "![strongSelf admitsWireGuardNameEdit]", "strongSelf->_field.markedTextRange",
            "strongSelf->_field.text", "[strongSelf textChanged]"
        ], in: reconciliation))
        XCTAssertFalse(reconciliation.contains("_confidentialInput"))
        XCTAssertFalse(reconciliation.contains("becomeFirstResponder"))
        XCTAssertFalse(reconciliation.contains("_field.text ="), "Restoration reports the live retained buffer and cannot overwrite newer typing")
        let changes = try sourceBlock(in: field, startingAt: "- (void)textChanged {", endingBefore: "- (BOOL)textField:")
        XCTAssertTrue(sourceContainsInOrder(["if (![self admitsWireGuardNameEdit]) return;", "NSString *accepted", "emitter->onChange"], in: changes))
        let delegates = try sourceBlock(in: field, startingAt: "- (BOOL)textField:", endingBefore: "- (void)textFieldDidBeginEditing:")
        XCTAssertTrue(sourceContainsInOrder(["if (![self admitsWireGuardNameEdit]) return NO;", "field.text = accepted"], in: delegates))
        XCTAssertTrue(delegates.contains("textFieldShouldBeginEditing:(UITextField *)field { return [self admitsWireGuardNameEdit]; }"))
        XCTAssertTrue(delegates.contains("textFieldShouldClear:(UITextField *)field { return [self admitsWireGuardNameEdit]; }"))
        let submit = try sourceBlock(in: field, startingAt: "- (BOOL)textFieldShouldReturn:", endingBefore: "- (void)prepareForRecycle")
        XCTAssertTrue(sourceContainsInOrder(["if (![self admitsWireGuardNameEdit]) return NO;", "emitter->onSubmit"], in: submit))
        XCTAssertTrue(field.contains("mayPerformEditAction = ^BOOL"))
        XCTAssertTrue(field.contains("strongSelf && [strongSelf admitsWireGuardNameEdit]"))
        let content = try String(contentsOf: packageRootURL.appendingPathComponent("ReactNative/ios/LavaSecUIReview/LavaDecorationContent.swift"), encoding: .utf8)
        let ordinaryField = try sourceBlock(in: content, startingAt: "final class LavaEmojiTextField", endingBefore: "/// The small, native drawing surface")
        XCTAssertTrue(ordinaryField.contains("(mayPerformEditAction?() ?? true) && super.canPerformAction"))
    }

    func testRNPrivateDraftRetentionDoesNotReadOrEditWithoutAuthority() throws {
        let source = try readSource(.reactNativeAppWireGuardEditor)
        let update = try sourceBlock(in: source, startingAt: "private func update()", endingBefore: "@objc private func showConfiguration()")
        let revoked = try sourceBlock(in: update,
            startingAt: "guard let owner, bridge.canReadPresentation(.appSettings) else {",
            endingBefore: "cover.rootView = AnyView(LavaPrivateContentCover(title: \"Configuration hidden\",\n")
        XCTAssertTrue(revoked.contains("SecurityPrivacyPolicy.canRetainAcceptedPrivateDraftDisplay("))
        XCTAssertTrue(revoked.contains("ownerIsCurrent: owner?.id == bridge.flow?.id && owner != nil"))
        XCTAssertTrue(revoked.contains("backgroundCoverRequired: bridge.security.backgroundPrivacyCoverRequired"))
        XCTAssertTrue(revoked.contains("freezeInteraction(); return"))
        XCTAssertFalse(revoked.contains("owner.configuration"))
        XCTAssertFalse(revoked.contains("isEditable = true"))
        let frozen = try sourceBlock(in: source, startingAt: "private func freezeInteraction()", endingBefore: "private func concealImmediately()")
        XCTAssertTrue(frozen.contains("textView.interactionFrozen = true"))
        XCTAssertTrue(frozen.contains("textView.isAccessibilityElement = false"))
        XCTAssertFalse(frozen.contains("resignFirstResponder"))
        XCTAssertFalse(frozen.contains("becomeFirstResponder"))
        XCTAssertFalse(frozen.contains("isUserInteractionEnabled"))
        XCTAssertFalse(frozen.contains("isEditable"))
        XCTAssertFalse(frozen.contains("textView.text"))
        XCTAssertFalse(frozen.contains("owner.configuration"))
        XCTAssertTrue(source.contains("if owner?.id != nextOwner?.id { concealImmediately() }"))
        XCTAssertTrue(source.contains("hasAcceptedRevealedDisplay = false"))
        let textView = try sourceBlock(in: source, startingAt: "private final class LavaWireGuardTextView", endingBefore: "/// Confidential text")
        XCTAssertTrue(textView.contains("!interactionFrozen && mayInteract?() == true"))
        XCTAssertTrue(textView.contains("isInteractionAdmitted && super.point(inside: point, with: event)"))
        XCTAssertTrue(textView.contains("isInteractionAdmitted && super.canPerformAction"))
        XCTAssertTrue(source.contains("textView.mayInteract = { [weak self] in self?.owner?.canEdit == true && self?.owner?.concealed == false }"))
        XCTAssertTrue(update.contains("let editable = owner.canEdit && !owner.concealed"))
        XCTAssertTrue(update.contains("textView.interactionFrozen = !editable"))
        let delegates = try sourceBlock(in: source, startingAt: "func textViewDidChange", endingBefore: "func textViewDidBeginEditing")
        XCTAssertTrue(delegates.contains("guard let owner, self.textView.isInteractionAdmitted else { update(); return }"))
        XCTAssertTrue(delegates.contains("func textViewShouldBeginEditing(_ textView: UITextView) -> Bool { self.textView.isInteractionAdmitted }"))
        XCTAssertTrue(delegates.contains("shouldChangeTextIn range: NSRange"))
        XCTAssertTrue(delegates.contains("self.textView.isInteractionAdmitted\n"))
        let conceal = try sourceBlock(in: source, startingAt: "private func concealImmediately()", endingBefore: "private func update()")
        XCTAssertTrue(conceal.contains("hasAcceptedRevealedDisplay = false"))
        XCTAssertTrue(conceal.contains("textView.resignFirstResponder(); textView.text = \"\"; textView.isHidden = true"))
        XCTAssertFalse(source.contains("becomeFirstResponder"))
    }

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

    func testRNVPNRouteAdmissionUsesTheCurrentNativeGrantWithoutMutatingOrRetiringItsDraft() throws {
        let source = try readSource(.reactNativeAppSettings)
        let metadata = try sourceBlock(in: source, startingAt: "func vpnSettingsState()", endingBefore: "private func wireGuardDraftMetadata")
        XCTAssertTrue(sourceContainsInOrder([
            "guard canReadPresentation(.appSettings) else { return [\"authorized\": false] }",
            "guard let status = model.dnsSettingsProfileStatus",
            "\"authorized\": true"
        ], in: metadata))
        let entry = try sourceBlock(in: source, startingAt: "if action == \"vpn.enter\"", endingBefore: "// Discard belongs")
        XCTAssertTrue(sourceContainsInOrder([
            "try await authorize(.appSettings, \"Open VPN chaining settings\")",
            "guard canReadPresentation(.appSettings)",
            "model.refreshDNSSettingsPresentation()",
            "return NSNull()"
        ], in: entry))
        XCTAssertFalse(entry.contains("wireGuardDraft"))
        XCTAssertFalse(entry.contains("setWireGuardSetupEnabled"))
        XCTAssertFalse(entry.contains("commitWireGuardPage"))
        XCTAssertFalse(entry.contains("flow ="))
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
        let bridge = try readSource(.reactNativeAppSettings)
        let toggle = try sourceBlock(in: bridge, startingAt: "if action == \"vpn.toggle\"", endingBefore: "if action == \"vpn.rowToggle\"")
        XCTAssertTrue(sourceContainsInOrder([
            "case \"setup\":", "guard !value || model.hasLavaSecurityPlus",
            "model.setWireGuardSetupEnabled(value)", "case \"enabled\":"
        ], in: toggle), "Setup ON must revalidate native entitlement before persistence; OFF must stay available")
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
