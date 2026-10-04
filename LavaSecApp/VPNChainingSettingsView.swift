import SwiftUI
import UniformTypeIdentifiers
import LavaSecKit
import LavaSecPresentation

/// Settings → Protection Choices → VPN chaining.
/// The saved row exposes only metadata. The sheet holds a temporary replacement draft;
/// private and pre-shared keys are never rehydrated from storage into the editor.
/// Uses this build's credential store; QA staging remains a separate test surface.
struct VPNChainingSettingsView: View {
    @EnvironmentObject private var viewModel: AppViewModel
    @EnvironmentObject private var security: SecurityController
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase

    @State private var showUpgradePage = false
    @Binding var showDNSSettings: Bool
    var authorizationIsOwnedByParent = false
    /// A DNS-owned review detour returns to that existing editor after authentication.
    /// Ordinary Settings entry keeps the existing pushed DNS destination.
    var onOpenDNSSettings: (() -> Void)? = nil
    /// React-owned pages forward destinations into their existing native stack;
    /// the standalone SwiftUI feature keeps its own navigation destinations.
    var onOpenUpgrade: (() -> Void)? = nil
    /// React-owned pages present the editor through the app's native-flow presenter;
    /// the standalone SwiftUI feature keeps its direct sheet. A `.sheet` declared
    /// inside the hosting controller the React page owns gets no presentation
    /// animation, so the editor must not stay embedded there. The closure receives
    /// a reporter the editor calls with a removal failure (nil after a success) so
    /// the page can keep its retry affordance after the editor is dismissed.
    var onPresentConfigurationEditor: ((Int, UInt64?, String, Bool, @escaping (String, String?) -> String?, @escaping (String?) -> Void) -> Void)? = nil
    @State private var editing = false
    @State private var pageDraft: ChainedUpstreamEditDraft?
    @State private var showDiscardConfirmation = false
    @State private var editorIndex = 0
    @State private var editorGeneration: UInt64?
    @State private var editorName = ""
    @State private var editorExists = false
    @State private var removalIndex: Int?
    @State private var showConfigurationEditor = false
    @State private var removalMessage: String?
    @State private var swapMessage: String?

    var body: some View {
        Group {
            if let status = viewModel.dnsSettingsProfileStatus { pageContent(status) }
        }
        .onAppear { viewModel.refreshDNSSettingsPresentation() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { viewModel.refreshDNSSettingsPresentation() }
        }
        .onChange(of: viewModel.configuration) { _, _ in viewModel.refreshDNSSettingsPresentation() }
        .modifier(VPNSettingsAuthorization(reason: "Open VPN chaining settings",
            managedByParent: authorizationIsOwnedByParent, onDenied: { dismiss() }))
    }

    private var canModifySettings: Bool {
        scenePhase == .active && security.hasCurrentAuthorization(for: .appSettings)
    }

    private func pageContent(_ status: AppViewModel.ChainedUpstreamSurfaceStatus) -> some View {
        SettingsSubpageContent(
            title: "VPN chaining",
            tier: .technical,
            intro: LavaInfoPanel(
                title: "Send filtered DNS through your VPN",
                description:
                    "Lava filters first, then sends allowed DNS requests through your WireGuard VPN.",
                systemImage: "link"
            )
        ) {
            let state = viewModel.chainedOperationalState(from: status)
            let setupEnabled = viewModel.configuration.wireGuardSetupEnabled

            LavaSectionGroup("Prerequisite", footer: "Get a WireGuard config from your VPN provider.") {
                LavaSettingsRow {
                    LavaToggleRow(title: "I have a WireGuard configuration", isOn: Binding(
                        get: { viewModel.configuration.wireGuardSetupEnabled },
                        set: {
                            guard canModifySettings else { return }
                            viewModel.setWireGuardSetupEnabled($0); viewModel.refreshDNSSettingsPresentation()
                        }
                    ))
                    .accessibilityIdentifier("vpn.setup-toggle")
                    .disabled(viewModel.isStagingChainedUpstreamForQA)
                }
            }

            // Setup stays reachable with routing OFF, including after an entitlement lapse.
            // Closing it retains credentials; the model commits OFF in the same write.
            if setupEnabled {
                LavaSectionGroup("WireGuard Configuration") {
                    configurationRow(status)
                    configurationRemovalFailure
                    if let swapMessage { LavaQuietFooter(swapMessage) { EmptyView() } }
                }

                VStack(alignment: .leading, spacing: LavaSpacing.md) {
                    LavaQuietFooter(chainingExplanation) { EmptyView() }

                    if let restriction = chainingRestriction(status, state: state) {
                        LavaQuietFooter(restriction) { EmptyView() }
                    }
                    if state == .notEntitled {
                        Button("See Lava Security Plus".lavaLocalized) {
                            if let onOpenUpgrade { onOpenUpgrade() }
                            else { showUpgradePage = true }
                        }
                        .buttonStyle(LavaSecondaryActionButtonStyle())
                    }
                    if let error = viewModel.chainedSettingsApplyError {
                        DomainRejectPanel(title: "Could not reconnect protection", message: error)
                    }
                }

                let rotation = rotationFreshness(status)
                if rotation.deservesSurfacing && !isApplyingSettings {
                    LavaSectionGroup("Running Configuration") {
                        LavaInfoPanel(
                            title: rotation.title,
                            description: rotation.detail,
                            systemImage: rotation.isActionable
                                ? "exclamationmark.triangle.fill" : "checkmark.seal.fill",
                            tint: rotation.isActionable
                                ? LavaStyle.lavaOrange : LavaStyle.safeGreen,
                            borderTint: rotation.isActionable ? LavaStyle.lavaOrange : nil)
                    }
                }

                let canChangeFallback = viewModel.dnsSettingsPresentation(from: status).canChangeFallback
                let alternativeDNSFooter = canChangeFallback ? self.alternativeDNSFooter
                    : "DNS fallback is unavailable with an active full-tunnel VPN."
                LavaSectionGroup(
                    "DNS fallback",
                    footer: alternativeDNSFooter,
                    footerLink: canChangeFallback ? LavaSectionFooterLink(
                        title: "Review DNS settings", action: openDNSSettings) : nil
                ) {
                    LavaSettingsRow {
                        LavaToggleRow(
                            title: "Use Lava DNS settings as fallback", isOn: tierOneFallbackBinding(status),
                            accessibilityHint: alternativeDNSFooter)
                            .accessibilityIdentifier("vpn.fallback-toggle")
                            .disabled(!canChangeFallback)
                    }
                }
            }
        }
        .modifier(VPNChainingPageDestinations(
            showUpgradePage: $showUpgradePage, showDNSSettings: $showDNSSettings,
            ownsUpgrade: onOpenUpgrade == nil, ownsDNS: onOpenDNSSettings == nil))
        .navigationBarBackButtonHidden(true)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                NativeToolbarIconButton(systemName: editing ? "xmark" : "chevron.left", accessibilityLabel: editing ? "Cancel editing" : "Back") {
                    if !editing { dismiss() }
                    else if pageDraft?.hasChanges == true { showDiscardConfirmation = true }
                    else { discardPageEdit() }
                }
            }
            if editing || viewModel.configuration.wireGuardSetupEnabled {
                ToolbarItem(placement: .topBarTrailing) {
                    NativeToolbarIconButton(systemName: editing ? "checkmark" : "square.and.pencil",
                                            accessibilityLabel: editing ? "Save" : "Edit") {
                        if editing { commitPageEdit() } else { beginPageEdit(status) }
                    }
                    .disabled(viewModel.isStagingChainedUpstreamForQA)
                }
            }
        }
        .alert("Discard changes?".lavaLocalized, isPresented: $showDiscardConfirmation) {
            Button("Discard".lavaLocalized, role: .destructive, action: discardPageEdit)
            Button("Cancel".lavaLocalized, role: .cancel) {}
        } message: { Text("Your saved VPN settings will stay active.".lavaLocalized) }
        .sheet(isPresented: $showConfigurationEditor) {
            VPNChainingConfigurationEditor(
                reportRemovalFailure: { removalMessage = $0 },
                onFinish: { showConfigurationEditor = false },
                rowIndex: editorIndex, expectedGeneration: editorGeneration,
                initialName: editorName, isExisting: editorExists,
                savePendingDraft: { name, conf in stagePageRow(index: editorIndex, name: name, conf: conf) })
                // The editor conforms to the canonical large sheet; the staging guard
                // stays explicit here because the flow host carries it separately.
                .interactiveDismissDisabled(viewModel.isStagingChainedUpstreamForQA)
        }
        // Rotation freshness reads the provider's sampled generation (PR #613).
        // pinned: ChainedUpstreamStagingWiringSourceTests.testThePanelSamplesHealthSoTheRotationIsFresh
        .task { await viewModel.sampleTunnelHealth() }
    }

    @ViewBuilder
    private var configurationRemovalFailure: some View {
        if let removalMessage {
            DomainRejectPanel(title: "Can't save this configuration", message: removalMessage)
            // A partial deletion can leave orphaned keys after the configuration file is
            // gone. Keep retry reachable while setup is open, including when chaining is OFF.
            Button("Try again".lavaLocalized) {
                openConfigurationEditor()
            }
            .buttonStyle(LavaSecondaryActionButtonStyle())
            .disabled(viewModel.isStagingChainedUpstreamForQA)
        }
    }

    @ViewBuilder
    private func configurationRow(_ status: AppViewModel.ChainedUpstreamSurfaceStatus) -> some View {
        let rows = pageDraft?.rows.map(\.configuration) ?? status.storedConfigurationRows
        let canEdit = ChainedSetupPolicy.canEditConfiguration(viewModel.chainedSurfaceInputs(from: status))
        if rows.isEmpty {
            LavaSettingsRow {
                Text((status.storeUnavailableReason == nil ? "No configurations" : "Saved configuration unavailable").lavaLocalized)
                    .font(LavaTypography.rowTitle)
            }
        }
        ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
            LavaSettingsRow {
                HStack(spacing: LavaSpacing.md) {
                    Button { if editing { openConfigurationEditor(index: index, status: status) } } label: {
                        HStack(spacing: LavaSpacing.md) {
                            Image(systemName: "\(index + 1).circle")
                            VStack(alignment: .leading, spacing: LavaSpacing.xs) {
                                Text(row.displayName.isEmpty ? "Configuration %d".lavaLocalizedFormat(index + 1) : row.displayName)
                                    .font(LavaTypography.rowTitle)
                                Text((row.routingPolicy == .fullTunnel ? "Full tunnel" : "Split tunnel").lavaLocalized)
                                    .lavaQuietNoteText()
                            }
                            Spacer(minLength: 0)
                        }
                        .contentShape(Rectangle())
                    }
                    .accessibilityIdentifier(index == 0 ? "vpn.configuration-row" : "vpn.configuration-row.2")
                    .buttonStyle(LavaCondensedRowButtonStyle())
                    .allowsHitTesting(editing)
                    .accessibilityAddTraits(editing ? [] : .isStaticText)
                    .disabled(!canEdit || viewModel.isStagingChainedUpstreamForQA)
                    if editing {
                        LavaIconActionButton(systemName: "minus.circle", accessibilityLabel: "Remove", destructive: true, presentation: .plain) {
                            removalIndex = index; removeSelectedConfiguration()
                        }
                        .disabled(viewModel.isStagingChainedUpstreamForQA)
                    } else {
                        Toggle(row.displayName, isOn: Binding(
                            get: { viewModel.configuration.chainedUpstreamEnabled && row.isEnabled },
                            set: { value in
                                guard canModifySettings else { return }
                                do { try viewModel.setWireGuardRowEnabled(value, index: index, expectedGeneration: status.storedConfigurationGeneration) }
                                catch { removalMessage = error.localizedDescription }
                            }))
                            .labelsHidden().tint(LavaStyle.safeGreen)
                            .disabled(!canEdit || viewModel.isStagingChainedUpstreamForQA)
                    }
                }
            }
        }
        if editing && status.storeUnavailableReason == nil && !status.hasConfigurationWithoutKey && pageDraft?.resetsStorage != true {
            Button {
                guard canModifySettings else { return }
                if rows.count == 2 {
                    do { try pageDraft?.swapOrder(); swapMessage = nil }
                    catch { swapMessage = error.localizedDescription }
                } else { openConfigurationEditor(index: rows.count, status: status) }
            } label: {
                Label((rows.count == 2 ? "Swap order" : "Add configuration").lavaLocalized,
                      systemImage: rows.count == 2 ? "arrow.up.arrow.down" : "plus")
            }
            .buttonStyle(LavaPanelActionButtonStyle())
            .disabled(!canEdit || viewModel.isStagingChainedUpstreamForQA)
        }
        if editing && (status.storeUnavailableReason != nil || status.hasConfigurationWithoutKey || removalMessage != nil) {
            Button("Delete configuration".lavaLocalized, role: .destructive) {
                removalIndex = nil; removeSelectedConfiguration()
            }
            .buttonStyle(LavaPanelActionButtonStyle())
            .disabled(viewModel.isStagingChainedUpstreamForQA)
        }
    }

    private func removeSelectedConfiguration() {
        guard canModifySettings else { return }
        do {
            if let index = removalIndex { try pageDraft?.remove(index: index) }
            else { pageDraft?.reset() }
        } catch { removalMessage = error.localizedDescription }
    }

    private func tierOneFallbackBinding(_ status: AppViewModel.ChainedUpstreamSurfaceStatus) -> Binding<Bool> {
        Binding(
            get: { (viewModel.dnsSettingsPresentation(from: status).canChangeFallback)
                && viewModel.configuration.chainedTierOneFallbackEnabled },
            set: { value in
                guard canModifySettings else { return }
                viewModel.setChainedTierOneFallbackEnabled(value); viewModel.refreshDNSSettingsPresentation()
            })
    }

    // MARK: - Chained DNS fallback (T1)

    /// Whether the live session is tunnelling through the configuration now stored.
    ///
    /// The DECISION lives in `ChainedUpstreamRotationFreshness`, in the package where it can
    /// carry executable tests; this reads the two inputs off the surfaces that hold them.
    ///
    /// THE LATCHED GENERATION IS THE RUNTIME'S, never the stored one: like every chained field
    /// in the snapshot it outlives the session that wrote it, and `0` is what says no chained
    /// session has published one. The policy short-circuits on that, so this does not have to.
    private func rotationFreshness(
        _ status: AppViewModel.ChainedUpstreamSurfaceStatus
    ) -> ChainedUpstreamRotationFreshness.Verdict {
        ChainedUpstreamRotationFreshness.verdict(
            // THE LIVE FLAG GATES IT, as belt to the tunnel's braces. The provider clears the
            // generation on stop, but every chained field in this snapshot outlives the session
            // that wrote it and the snapshot is PERSISTED — so a file written by a build that
            // forgot, or by a crash between the two writes, would let this panel demand a restart
            // for a session that is not running (PR #613).
            runningGeneration: viewModel.tunnelHealth.isChainedUpstreamActive
                ? viewModel.tunnelHealth.runningChainedUpstreamGeneration : 0,
            storedRotation: storedRotationFreshness(status))
    }

    /// Which of the three stored-rotation situations the surface status describes.
    ///
    /// VALUE FIRST — and this REVERSES the guard PR #613 added here.
    ///
    /// `storeUnavailableReason` means "SOME read failed", not "the configuration is unreadable".
    /// `chainedUpstreamSurfaceStatus` reads the configuration and then the private key inside one
    /// `do`, so a key-read failure sets it while the configuration — and therefore this generation
    /// — was read perfectly. In that state the running rotation IS answerable, and the store's own
    /// answer is the honest one.
    ///
    /// Guarding on the reason first turned that known answer into `.unreadable`, which this
    /// policy renders as silence: a user who had replaced their configuration was told nothing,
    /// when "restart to use the new configuration" was correct and actionable. The premise the
    /// guard rested on — reason set implies the configuration is unreadable — is simply false
    /// (Codex P2, PR #614).
    ///
    /// `.unreadable` is for a configuration that could not be read at all. There is then no
    /// generation, and this falls through to it.
    ///
    /// The separate snapshot limitation remains: `loadStoredPrivateKey()` re-reads the
    /// configuration internally, so a rotation landing between the status's two reads can
    /// leave this generation describing the older one.
    /// pinned: ChainedUpstreamStagingWiringSourceTests.testAKnownRotationIsNotDiscardedByAKeyReadFailure
    private func storedRotationFreshness(
        _ status: AppViewModel.ChainedUpstreamSurfaceStatus
    ) -> ChainedUpstreamRotationFreshness.StoredRotation {
        if let generation = status.storedConfigurationGeneration {
            return .present(generation: generation)
        }
        return status.storeUnavailableReason == nil ? .absent : .unreadable
    }

    /// Fallback leaves the VPN only for split-tunnel configurations. The selected
    /// provider can be the device network's resolver or a provider using encrypted DNS.
    /// pinned: ChainedUpstreamStagingWiringSourceTests.testTheAlternativeDNSFooterStatesTheEgressAndItsLimit
    private var alternativeDNSFooter: String {
        "Split-tunnel VPNs only. "
            + "These lookups leave the VPN tunnel and go to your selected DNS providers."
    }

    // MARK: - Derived state

    /// The toggle stays disabled for EVERY ineligible state, including `notEntitled`.
    /// Letting a non-Plus user switch it on would persist a preference the latch refuses
    /// and `reconcileChainedUpstreamAfterEligibilityChange` then clears — the control would
    /// appear to work and quietly revert. The upgrade button beside it is the actionable
    /// route, the same job `selectCustomResolver()`'s upgrade guard does on the DNS page.
    private func chainingBinding(
        _ status: AppViewModel.ChainedUpstreamSurfaceStatus
    ) -> Binding<Bool> {
        Binding(
            get: { viewModel.configuration.chainedUpstreamEnabled },
            set: {
                guard canModifySettings else { return }
                viewModel.setChainedUpstreamEnabled($0); viewModel.refreshDNSSettingsPresentation()
            })
    }

    /// The option's explanation is independent of its value and reconciliation state.
    /// The switch owns consent; actual admission failures remain separate from helper copy.
    private var chainingExplanation: String {
        "The order determines which VPN your traffic uses and when it uses both."
    }

    /// Keep real availability failures visible without turning ordinary toggle transitions
    /// into changing instructions. Admission still comes from the shared setup policy and
    /// the same operational snapshot used by the control and upgrade action (PR #637).
    private func chainingRestriction(
        _ status: AppViewModel.ChainedUpstreamSurfaceStatus,
        state: ChainedOperationalState
    ) -> String? {
        let inputs = viewModel.chainedSurfaceInputs(from: status)
        if ChainedSetupPolicy.canEditConfiguration(inputs),
            let issue = ChainedSetupPolicy.configurationIssue(inputs)
        {
            if issue == .missingConfiguration { return "Save a configuration above to enable chaining." }
            return issue.message
        }
        switch state {
        case .notEntitled:
            return "Chaining is part of Lava Security Plus."
        case .unsupportedDevice:
            return "This device doesn't have enough memory for chaining."
        case .deviceStateUnreadable:
            return "Lava can't check this device right now. Unlock it and try again."
        case .suspendedAfterStartupFailure:
            return "Guard stopped after VPN chaining failed during startup. Turn Guard on to retry."
        case .suspendedAfterSurrender:
            return "Guard stopped because VPN chaining could not keep forwarding. Turn Guard on to retry."
        case .storeUnreadable:
            return "Your saved configuration couldn't be read. Load the file again."
        case .noUpstreamConfigured:
            return "Save a configuration above to enable chaining."
        case .upstreamKeyMissing:
            return "Your saved configuration is missing its key. Load the file again."
        case .preferenceOff, .ready:
            return nil
        }
    }

    private var isApplyingSettings: Bool {
        viewModel.chainedSettingsApplyState.pending != nil || viewModel.chainedSettingsApplyState.applying != nil
    }

    // MARK: - Actions

    private func openConfigurationEditor() {
        openConfigurationEditor(index: 0, status: viewModel.chainedUpstreamSurfaceStatus)
    }

    private func beginPageEdit(_ status: AppViewModel.ChainedUpstreamSurfaceStatus) {
        guard canModifySettings else { return }
        guard !editing else { return }
        do {
            pageDraft = try ChainedUpstreamEditDraft(id: UUID().uuidString, generation: status.storedConfigurationGeneration,
                                                   configurations: status.storedConfigurationRows)
            editing = true
        } catch { removalMessage = error.localizedDescription }
    }

    private func discardPageEdit() { pageDraft = nil; editing = false; removalMessage = nil }

    private func commitPageEdit() {
        guard canModifySettings else { return }
        guard var draft = pageDraft else { return }
        do {
            try viewModel.commitWireGuardPage(&draft)
            discardPageEdit()
        } catch { pageDraft = draft; removalMessage = error.localizedDescription }
    }

    private func stagePageRow(index: Int, name: String, conf: String?) -> String? {
        do {
            guard canModifySettings, pageDraft != nil else { throw WireGuardChainFailure.changed }
            let replacement = try conf.map { try ChainedUpstreamConfParser.rotation(from: $0) }
            try pageDraft?.save(index: index, name: name, replacement: replacement)
            return nil
        } catch { return error.localizedDescription }
    }

    private func openConfigurationEditor(index: Int, status: AppViewModel.ChainedUpstreamSurfaceStatus) {
        guard canModifySettings else { return }
        beginPageEdit(status)
        let rows = pageDraft?.rows.map(\.configuration) ?? []
        editorIndex = index
        editorGeneration = pageDraft?.generation
        editorExists = rows.indices.contains(index)
        editorName = editorExists ? rows[index].displayName : ""
        if let onPresentConfigurationEditor {
            onPresentConfigurationEditor(index, editorGeneration, editorName, editorExists,
                { name, conf in stagePageRow(index: index, name: name, conf: conf) }, { removalMessage = $0 })
        } else { showConfigurationEditor = true }
    }

    private func openDNSSettings() {
        Task {
            guard await security.requireAuthentication(for: .appSettings, reason: "Edit DNS settings") else { return }
            if let onOpenDNSSettings { onOpenDNSSettings() }
            else { showDNSSettings = true }
        }
    }

}

/// The WireGuard configuration editor.
///
/// It is a separate view because a `.sheet` declared inside the hosting controller
/// that `LavaNativePageContent` owns gets no presentation animation: it appears at
/// its final geometry and contracts from up-left while dismissal still animates
/// (the owner's recording). `LavaNativePageContent` therefore routes this editor
/// through `LavaAppHost`'s native-flow presenter, and the standalone SwiftUI app
/// keeps its direct sheet. The draft lives here, so dismissing either presentation
/// discards it structurally; stored keys are still never rehydrated into the field.
struct VPNChainingConfigurationEditor: View {
    @EnvironmentObject private var viewModel: AppViewModel
    @EnvironmentObject private var security: SecurityController
    /// The temporary draft follows the same native concealment choice as the window.
    /// An explicitly revealed all-off draft stays painted through inactivity and sleep;
    /// imported/unrevealed text and selected or unknown security remain concealed.
    @State private var isApplicationActive = UIApplication.shared.applicationState == .active
    /// Reports a failed deletion (nil after a success) so the page can keep its
    /// retry affordance once this editor is dismissed.
    let reportRemovalFailure: (String?) -> Void
    /// Dismisses the presentation after Save, Delete, or Cancel.
    let onFinish: () -> Void

    var rowIndex = 0
    var expectedGeneration: UInt64? = nil
    var initialName = ""
    var isExisting = false
    var savePendingDraft: (String, String?) -> String?
    @State private var showDiscardConfirmation = false
    @State private var name = ""
    @State private var draftRevealed = true

    @State private var isImportingConfiguration = false
    @State private var validationMessage: String?
    @State private var removalMessage: String?
    @State private var swapMessage: String?
    /// The configuration being ENTERED, shown in the Content editor and committed on
    /// Save. Distinct from anything stored: a committed secret lives in the Keychain and is
    /// only ever summarised, never rehydrated into this field.
    @State private var draftConfiguration = ""
    @State private var isReadingConfiguration = false
    @State private var importToken = UUID()

    /// Content types offered to the importer.
    ///
    /// `.data` is what actually guarantees selectability: an extension with no registered
    /// type gets a dynamic UTType conforming to `public.data`, so `.conf` files are
    /// selectable through that entry alone. The explicit `UTType(filenameExtension: "conf")`
    /// is there to put the expected type FIRST, not to make it reachable — an earlier version
    /// of this comment claimed the latter, which would have led someone trimming the list to
    /// drop the wrong entries. `.plainText` and `.text` cover exporters that tag properly.
    ///
    /// Breadth is safe because NOTHING trusts the type: `ChainedUpstreamConfParser`
    /// parses the bytes and refuses anything that is not a well-formed configuration.
    private static let importableTypes: [UTType] = {
        var types: [UTType] = [.plainText, .text, .data]
        if let conf = UTType(filenameExtension: "conf") {
            types.insert(conf, at: 0)
        }
        return types
    }()

    /// A WireGuard configuration is a few hundred bytes; a large one is a few kilobytes.
    ///
    /// The cap exists because the picker can hand back ANY file the user taps, including a
    /// multi-gigabyte video. The background read is bounded independently of provider
    /// metadata — once from the file's declared size where the provider offers one, and once on the bytes
    /// that actually arrived, which is the check that always runs. Generous enough that no
    /// real configuration is ever refused by it.
    nonisolated private static let maximumConfigurationBytes = 64 * 1024


    var body: some View {
        NavigationStack {
            LavaSheetScaffold(spacing: SettingsSubpageLayout.spacing) {
                LavaTextInputPanel {
                    LavaTextInputRow(title: "Name") {
                        TextField("Configuration name".lavaLocalized, text: $name)
                            .lavaTextInputBody()
                            .disabled(!canEditConfiguration)
                    }
                    Divider()
                    // Keep the same scaffold and geometry in both states. The obscured
                    // editor binds to empty text, so no real secret sits behind the cover.
                    LavaTextEditorInputRow(title: "Content", text: Binding(
                        get: { isDraftConcealed ? "" : draftConfiguration },
                        set: { if !isDraftConcealed { draftConfiguration = $0 } }),
                        placeholder: "Paste a WireGuard .conf, or use Choose File.", fixedHeight: 184)
                        .autocorrectionDisabled().textInputAutocapitalization(.never)
                        .disabled(!canEditConfiguration || isDraftConcealed)
                        .opacity(isDraftConcealed ? 0 : 1)
                        .accessibilityHidden(isDraftConcealed)
                        .overlay {
                            if isDraftConcealed {
                                LavaPrivateContentCover(title: "Configuration hidden", actionTitle: isApplicationActive ? "Show configuration" : nil) {
                                    draftRevealed = true
                                }
                            }
                        }
                }
                LavaQuietFooter("After saving, your private key stays in this device's Keychain and isn't shown again.") {
                    EmptyView()
                }
                if let validationMessage {
                    DomainRejectPanel(title: "Can't save this configuration", message: validationMessage)
                }
            } footer: {
                // Buttons follow the panel in the scaffold's pinned footer, so they stay
                // reachable as the keyboard appears and the content scrolls.
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: LavaSpacing.md) { configurationActions }
                    VStack(spacing: LavaSpacing.md) { configurationActions }
                }
            }
            .onAppear {
                name = initialName
                isApplicationActive = UIApplication.shared.applicationState == .active
                viewModel.refreshDNSSettingsPresentation()
            }
            .onChange(of: viewModel.configuration) { _, _ in viewModel.refreshDNSSettingsPresentation() }
            .onDisappear { importToken = UUID(); isReadingConfiguration = false }
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.willResignActiveNotification)) { _ in
                isApplicationActive = false
                if security.backgroundPrivacyCoverRequired { draftRevealed = false }
            }
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.protectedDataWillBecomeUnavailableNotification)) { _ in
                // Revoke access before iOS changes its bit. Only selected or unknown
                // security retires an already revealed draft; saved keys are never shown.
                // pinned: WireGuardSetupSourceTests.testEditorRetainsOnlyAnExplicitlyRevealedAllOffDraftAcrossProtectedDataLoss
                security.protectedDataWillBecomeUnavailable()
                if security.backgroundPrivacyCoverRequired { draftRevealed = false }
            }
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
                isApplicationActive = true
                viewModel.refreshDNSSettingsPresentation()
            }
            .navigationTitle("WireGuard Configuration".lavaLocalized)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    NativeToolbarIconButton(systemName: "xmark", accessibilityLabel: "Cancel", role: .cancel) {
                        requestDismiss()
                    }
                    .disabled(viewModel.isStagingChainedUpstreamForQA)
                }
                .lavaToolbarChrome()
            }
            .lavaConfirmInteractiveDismiss(hasUnsavedChanges) { requestDismiss() }
            .lavaConfirmationAlert { host in
                host.alert("Discard changes?".lavaLocalized, isPresented: $showDiscardConfirmation) {
                    Button("Cancel".lavaLocalized, role: .cancel) {}
                    Button("Discard".lavaLocalized, role: .destructive) { onFinish() }
                } message: { Text("Your saved VPN settings will stay active.".lavaLocalized) }
            }
            .fileImporter(
                isPresented: $isImportingConfiguration,
                allowedContentTypes: Self.importableTypes,
                allowsMultipleSelection: false,
                onCompletion: handleImport)
            .modifier(VPNSettingsAuthorization(reason: "Edit VPN chaining", onDenied: onFinish))

        }
    }

    @ViewBuilder
    private var configurationActions: some View {
        Button {
            guard canEditConfiguration else { return }
            validationMessage = nil
            isImportingConfiguration = true
        } label: {
            Text("Choose File".lavaLocalized).fixedSize()
        }
        .buttonStyle(LavaSecondaryActionButtonStyle())
        .disabled(!canEditConfiguration)

        Button(action: requestSaveDraftConfiguration) {
            Text(saveButtonTitle.lavaLocalized).fixedSize()
        }
        .buttonStyle(LavaStandaloneActionButtonStyle())
        .disabled(!canSaveDraft)
    }


    // MARK: - Derived state

    /// Derived from the model's in-flight flag, never a latch this view sets itself.
    ///
    /// The previous version latched a `hasSavedDraft` flag to swap "Save" for "Saved" — and
    /// the label was unreachable, because the same update cleared the draft and the
    /// `onChange` observer reset the latch before the view drew. `DNSResolverSettingsView`
    /// avoids that by deriving its title from state it does not itself set, and so does this.
    private var saveButtonTitle: String {
        viewModel.isStagingChainedUpstreamForQA ? "Saving…" : "Save"
    }

    /// Save requires a nonempty draft, eligible chaining, and no commit already running.
    /// The trim matters: a box holding only whitespace is not a configuration, and staging it
    /// would fail the parser for a reason the empty-box disable already communicates.
    private var isDraftConcealed: Bool {
        !draftConfiguration.isEmpty && SecurityPrivacyPolicy.requiresPrivateDraftCover(
            isRevealed: draftRevealed, applicationIsActive: isApplicationActive,
            backgroundCoverRequired: security.backgroundPrivacyCoverRequired)
    }

    private var canSaveDraft: Bool {
        canEditConfiguration && ((!draftConfiguration.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            || (isExisting && String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(80)) != initialName))
    }

    /// The sheet can be opened solely to delete an ineligible device's saved keys.
    /// Recheck at commit too: eligibility can change while a confirmation is open.
    private var canEditConfiguration: Bool {
        guard let status = viewModel.dnsSettingsProfileStatus else { return false }
        return !isReadingConfiguration && isApplicationActive && security.protectedDataIsAvailableForPresentation
            && security.hasCurrentAuthorization(for: .appSettings)
            && !viewModel.isStagingChainedUpstreamForQA
            && ChainedSetupPolicy.canEditConfiguration(
                viewModel.chainedSurfaceInputs(from: status))
    }


    // MARK: - Actions

    private var hasUnsavedChanges: Bool { name != initialName || !draftConfiguration.isEmpty }

    private func requestDismiss() {
        if hasUnsavedChanges { showDiscardConfirmation = true }
        else { onFinish() }
    }

    private func requestSaveDraftConfiguration() {
        guard canSaveDraft else { return }
        saveDraftConfiguration()
    }

    private func handleImport(_ result: Result<[URL], Error>) {
        // A picker completion can arrive after the phone has revoked access.
        guard canEditConfiguration else { return }
        validationMessage = nil
        switch result {
        case .failure(let error):
            // Dismissing the picker arrives through the same failure channel as a real
            // problem. Painting the red panel for an action the user deliberately abandoned
            // reads as a bug — and it stays latched until the next import. Filtered the same
            // way `PrivacySecuritySettingsView` filters its own file-dialog result.
            let nsError = error as NSError
            guard !(nsError.domain == NSCocoaErrorDomain && nsError.code == NSUserCancelledError)
            else { return }
            validationMessage = error.localizedDescription
        case .success(let urls):
            guard let url = urls.first else { return }
            let token = UUID()
            importToken = token
            let authorizationRevision = security.viewAuthenticationRevision
            isReadingConfiguration = true
            Task {
                let imported = await Task.detached(priority: .userInitiated) {
                    Result { try Self.readConfiguration(at: url) }
                }.value
                guard importToken == token else { return }
                isReadingConfiguration = false
                guard security.viewAuthenticationRevision == authorizationRevision, canEditConfiguration else { return }
                switch imported {
                case .success(let text):
                    // Saved content is never loaded here; imported secrets start concealed.
                    draftConfiguration = text
                    draftRevealed = false
                    if name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { name = url.deletingPathExtension().lastPathComponent }
                case .failure(let error as ConfigurationReadFailure):
                    validationMessage = error.message
                case .failure(let error):
                    validationMessage = error.localizedDescription
                }
            }
        }
    }

    private enum ConfigurationReadFailure: Error {
        case unreadable
        case tooLarge(Int)
        case notText

        var message: String {
            switch self {
            case .unreadable:
                return "Couldn't open that file. Try moving it to Files first."
            case .tooLarge(let bytes):
                return "That file is \(bytes / 1024) KB — far too big for a WireGuard config. Wrong file?"
            case .notText:
                return "That file isn't text, so it isn't a WireGuard config."
            }
        }
    }

    /// Reads the picked document into a string, refusing anything that cannot be one.
    ///
    /// 🔴 The security-scoped access is not optional. A document handed over by the picker
    /// lives outside the app's sandbox, and without the start/stop pair the read fails —
    /// intermittently, because a file the app has touched before may still be reachable.
    /// `defer` rather than a trailing call so an early `throw` cannot leak the scope.
    ///
    /// Order matters: the attribute size is checked BEFORE any read, so a wrongly-picked
    /// large file is normally refused rather than loaded. That pre-read gate is BEST-EFFORT
    /// and the code says so — `try?` swallows a failed `resourceValues`, and a provider may
    /// report no size at all. Read at most the cap plus one byte to detect an oversized
    /// document without materializing it, then validate UTF-8 only within that bound.
    nonisolated private static func readConfiguration(at url: URL) throws -> String {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }

        let values = try? url.resourceValues(forKeys: [.fileSizeKey])
        if let size = values?.fileSize, size > Self.maximumConfigurationBytes {
            throw ConfigurationReadFailure.tooLarge(size)
        }

        guard let handle = try? FileHandle(forReadingFrom: url) else {
            throw ConfigurationReadFailure.unreadable
        }
        defer { try? handle.close() }
        var data = Data()
        do {
            while data.count <= Self.maximumConfigurationBytes {
                let remaining = Self.maximumConfigurationBytes + 1 - data.count
                guard let chunk = try handle.read(upToCount: min(8 * 1024, remaining)), !chunk.isEmpty else { break }
                data.append(chunk)
            }
        } catch { throw ConfigurationReadFailure.unreadable }
        guard data.count <= Self.maximumConfigurationBytes else {
            throw ConfigurationReadFailure.tooLarge(data.count)
        }
        guard let text = String(data: data, encoding: .utf8) else {
            throw ConfigurationReadFailure.notText
        }
        return text
    }

    private func saveDraftConfiguration() {
        viewModel.refreshDNSSettingsPresentation()
        guard canSaveDraft else { return }
        validationMessage = savePendingDraft(name, draftConfiguration.isEmpty ? nil : draftConfiguration)
        if validationMessage == nil {
            // Native memory owns the pending replacement. Only page Save writes keys
            // or changes the running connection, and secrets never cross the RN bridge.
            draftConfiguration = ""
            reportRemovalFailure(nil)
            onFinish()
        }
    }

}

/// Reuses the current Settings grant and closes interaction immediately when it is revoked.
private struct VPNSettingsAuthorization: ViewModifier {
    @EnvironmentObject private var security: SecurityController
    @Environment(\.scenePhase) private var scenePhase
    @State private var isPresented = false
    let reason: String
    var managedByParent = false
    let onDenied: () -> Void
    private struct Context: Equatable {
        let visible: Bool
        let phase: ScenePhase
        let revision: UInt64
    }
    private var context: Context { .init(visible: isPresented, phase: scenePhase, revision: security.viewAuthenticationRevision) }
    private var canInteract: Bool { isPresented && scenePhase == .active && security.hasCurrentAuthorization(for: .appSettings) }

    func body(content: Content) -> some View {
        content
            .allowsHitTesting(canInteract)
            .accessibilityHidden(!canInteract)
            .onAppear { isPresented = true }
            .onDisappear { isPresented = false }
            .task(id: context) {
                let request = context
                guard request.visible, request.phase == .active, !managedByParent else { return }
                let accepted = await security.requireAuthentication(for: .appSettings, reason: reason)
                guard !Task.isCancelled, context == request else { return }
                if !accepted { onDenied() }
            }
    }
}

/// Do not attach SwiftUI destinations to content whose enclosing page stack is
/// owned by React. Sheets below the feature still keep their native navigation.
private struct VPNChainingPageDestinations: ViewModifier {
    @Binding var showUpgradePage: Bool
    @Binding var showDNSSettings: Bool
    let ownsUpgrade: Bool
    let ownsDNS: Bool

    @ViewBuilder func body(content: Content) -> some View {
        if ownsUpgrade {
            dnsDestination(content).navigationDestination(isPresented: $showUpgradePage) {
                LavaPlusUpgradeDestination()
            }
        } else {
            dnsDestination(content)
        }
    }

    @ViewBuilder private func dnsDestination(_ content: Content) -> some View {
        if ownsDNS {
            content.navigationDestination(isPresented: $showDNSSettings) {
                NativeDNSSettingsDestinationView()
            }
        } else {
            content
        }
    }
}
