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
        let ordinary = try sourceBlock(in: props, startingAt: "const BOOL ordinary =", endingBefore: ";")
        for kind in ["plain", "prose", "search", "localLogSearch", "wireGuardName"] {
            XCTAssertTrue(ordinary.contains("next.kind == \"\(kind)\""), "\(kind) keeps ordinary seed/reset/keyboard behavior")
        }
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
            (.reactNativeVPNChainingScreen, ["export function VPNChainingScreen"]),
            (.reactNativeVPNEditorFlow, ["export function VPNEditorFlow"]),
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
            (.reactNativeAppFlows, ["if flow.name == \"vpnConfiguration\" { result[\"vpnEditor\"] = wireGuardEditorProjection(flow)",
                "LavaAppForegroundContent(id: flow.id.uuidString)"]),
            (.reactNativeAppWireGuardEditor, ["func wireGuardEditorProjection(", "case \"vpnEditor.save\":"]),
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
        for file in [SourceFile.reactNativeAppSettings] {
            let editor = try readSource(file)
            XCTAssertTrue(editor.contains("ChainedUpstreamConfParser.rotation(from: $0)"))
            XCTAssertFalse(editor.contains("ChainedUpstreamStagingRequest("),
                           "Consumer imports must not use the QA staging admission policy")
        }
    }

    func testVPNPresentationUsesCachedMetadataAndRefreshesAtEntryResumeAndMutations() throws {
        let source = try readSource(.reactNativeAppSettings)
        let metadata = try sourceBlock(in: source, startingAt: "func vpnSettingsState()", endingBefore: "private func wireGuardDraftMetadata")
        XCTAssertTrue(metadata.contains("guard let status = model.dnsSettingsProfileStatus"))
        XCTAssertFalse(metadata.contains("model.chainedUpstreamSurfaceStatus"))
        let entry = try sourceBlock(in: source, startingAt: "if action == \"vpn.enter\"", endingBefore: "// Discard belongs")
        XCTAssertTrue(entry.contains("model.refreshDNSSettingsPresentation()"))
        let command = try sourceBlock(in: source, startingAt: "func vpnCommand(", endingBefore: "func dnsChoice(")
        XCTAssertTrue(command.contains("defer { model.refreshDNSSettingsPresentation() }"))
        XCTAssertTrue(command.contains("let status = model.chainedUpstreamSurfaceStatus"))
    }

    func testVPNNativeSurfacesReauthorizeAndFenceWritesAfterSettingsGrantRevocation() throws {
        let source = try readSource(.reactNativeAppWireGuardEditor)
        let command = try sourceBlock(in: source, startingAt: "func wireGuardEditorCommand(", endingBefore: "@MainActor")
        XCTAssertTrue(sourceContainsInOrder(["try await authorize(.appSettings, \"Edit VPN chaining\")", "guard self.flow?.id == flow.id, visit.canEdit"], in: command))
        let admission = try sourceBlock(in: source, startingAt: "var canEdit: Bool", endingBefore: "var canSave:")
        XCTAssertTrue(admission.contains("bridge.canReadPresentation(.appSettings)"))
        XCTAssertTrue(admission.contains("draft.revision == draftRevision"))
        XCTAssertTrue(admission.contains("bridge.flow?.id == id"))
        let commit = try sourceBlock(in: readSource(.reactNativeAppSettings), startingAt: "func vpnCommand(", endingBefore: "func dnsChoice(")
        XCTAssertTrue(sourceContainsInOrder(["try await authorize(.appSettings", "guard UIApplication.shared.applicationState == .active", "try model.commitWireGuardPage(&draft)"], in: commit))
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
        let source = try readSource(.reactNativeAppWireGuardEditor)
        XCTAssertTrue(source.contains("SecurityPrivacyPolicy.requiresPrivateDraftCover("))
        XCTAssertTrue(source.contains("backgroundCoverRequired: LavaAppBridge.shared.security.backgroundPrivacyCoverRequired"))
        XCTAssertTrue(source.contains("UIApplication.protectedDataWillBecomeUnavailableNotification"))
        let importing = try sourceBlock(in: source, startingAt: "func documentPicker(", endingBefore: "extension LavaAppBridge")
        XCTAssertTrue(sourceContainsInOrder(["guard canEdit", "await Task.detached", "guard let self, importToken == token", "security.viewAuthenticationRevision == authorization, canEdit", "configuration = text"], in: importing))
        XCTAssertTrue(source.contains("func retire() { importToken = UUID(); reading = false; configuration = \"\""))
        XCTAssertFalse(source.contains("keychainStore.load"))
    }

    func testPickedVPNDocumentsAreBoundedBeforeDecodingRegardlessOfReportedSize() throws {
        let source = try readSource(.wireGuardConfigurationFile)
        XCTAssertFalse(source.contains("Data(contentsOf:"))
        XCTAssertTrue(source.contains("maximumBytes + 1 - data.count"))
        XCTAssertTrue(source.contains("handle.read(upToCount: min(8 * 1024, remaining))"))
        XCTAssertTrue(sourceContainsInOrder(["guard data.count <= maximumBytes", "String(data: data, encoding: .utf8)"], in: source))
        XCTAssertTrue(source.contains("defer { try? handle.close() }"))
        XCTAssertTrue(source.contains("url.stopAccessingSecurityScopedResource()"))
        XCTAssertTrue(try readSource(.reactNativeAppWireGuardEditor).contains("WireGuardConfigurationFile.read(at: url)"))
    }

    func testSetupAndRoutingHaveIndependentControlsAndSavingDoesNotEnable() throws {
        let bridge = try readSource(.reactNativeAppSettings)
        let toggle = try sourceBlock(in: bridge, startingAt: "if action == \"vpn.toggle\"", endingBefore: "if action == \"vpn.rowToggle\"")
        XCTAssertTrue(sourceContainsInOrder(["case \"setup\":", "guard !value || model.hasLavaSecurityPlus", "model.setWireGuardSetupEnabled(value)", "case \"enabled\":"], in: toggle))
        let view = try readSource(.reactNativeVPNChainingScreen)
        XCTAssertTrue(sourceContainsInOrder(["I have a WireGuard configuration", "{setup&&<>", "vpn.configuration-panel", "DNS fallback"], in: view))
        let editor = try readSource(.reactNativeAppWireGuardEditor)
        XCTAssertTrue(editor.contains("visit.error = save(visit.name, visit.configuration.isEmpty ? nil : visit.configuration)"))
        XCTAssertFalse(editor.contains("model.saveWireGuardHop("))
        XCTAssertTrue(try readSource(.reactNativeVPNEditorFlow).contains("Discard changes?"))
        XCTAssertTrue(bridge.contains("try model.commitWireGuardPage(&draft)"))
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
