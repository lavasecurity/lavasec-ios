import SwiftUI
import LavaSecKit
import UIKit

struct DNSResolverSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var viewModel: AppViewModel
    @EnvironmentObject private var security: SecurityController
    @State private var customResolverDraft = ""
    @State private var customResolverSecondaryDraft = ""
    @State private var customResolverNameDraft = ""
    @State private var hasPendingCustomResolverAddressChange = false
    @State private var hasPendingCustomResolverSecondaryAddressChange = false
    @State private var hasPendingCustomResolverNameChange = false
    @State private var isEditingCustomResolver = false
    @State private var showingCustomResolverDiscardConfirmation = false
    @State private var pendingCustomResolverDiscardAction: CustomResolverDiscardAction?
    @State private var customResolverValidationMessage: String?
    @State private var showUpgradePage = false
    @FocusState private var focusedCustomResolverField: CustomResolverFocusField?

    var body: some View {
        SettingsSubpageContent(
            title: "DNS Resolver",
            tier: .technical,
            intro: LavaInfoPanel(
                title: "How websites get found",
                description: "DNS is how your phone finds a website's address. Our default is safe for almost everyone, so we recommend keeping it.",
                systemImage: "network"
            )
        ) {
            LavaSectionGroup("Device DNS") {
                VStack(alignment: .leading, spacing: 8) {
                    Toggle("Use Device DNS Setting", isOn: useDeviceDNSBinding)
                        .font(.headline)
                        .tint(LavaStyle.safeGreen)
                        .lavaControlRowCard()

                    Text(viewModel.deviceDNSResolverDetailText.lavaLocalized)
                        .lavaQuietNoteText()

                    // The fallback toggle sits directly under the Device DNS detail in
                    // both states. When an encrypted primary is selected it offers the
                    // Device-DNS safety net; when Device DNS is the primary it offers an
                    // encrypted alternative resolver instead. The toggle + its detail now
                    // carry the disclosure that previously lived in static copy.
                    if usesDeviceDNSSetting {
                        ResolverOptionControl(
                            title: "Fallback to alternative DNS",
                            detail: "If your device's DNS stops responding, Lava sends allowed requests to a backup DNS provider, then switches back automatically.",
                            isOn: usesEncryptedDeviceDNSFallbackBinding
                        )
                    } else {
                        ResolverOptionControl(
                            title: "Fallback to Device DNS",
                            detail: viewModel.deviceDNSFallbackDetailText,
                            isOn: fallbackToDeviceDNSBinding
                        )
                    }
                }
            }

            if usesDeviceDNSSetting && viewModel.configuration.usesEncryptedDeviceDNSFallback {
                ResolverPickerSections(
                    selectedPreset: viewModel.configuration.fallbackResolverPreset,
                    configuredCustomAddress: viewModel.configuration.fallbackCustomResolverAddress,
                    configuredCustomSecondaryAddress: viewModel.configuration.fallbackCustomResolverSecondaryAddress,
                    configuredCustomName: viewModel.configuration.fallbackCustomResolverName,
                    allowsCustomDNS: viewModel.configuration.limits.allowsCustomDNS,
                    supportsDNSOverQUIC: viewModel.supportsDNSOverQUIC,
                    selectPreset: { preset in
                        performAppSettingsMutation(reason: "Edit DNS settings") {
                            viewModel.setFallbackResolver(preset)
                        }
                    },
                    saveCustom: { name, primary, secondary in
                        performAppSettingsMutation(reason: "Edit DNS settings") {
                            viewModel.setFallbackCustomResolverName(name)
                            viewModel.setFallbackCustomResolverAddresses(primary: primary, secondary: secondary)
                        }
                    },
                    clearCustom: { fallback in
                        performAppSettingsMutation(reason: "Edit DNS settings") {
                            viewModel.clearFallbackCustomResolver(fallback: fallback)
                        }
                    },
                    requestUpgrade: {
                        showUpgradePage = true
                    }
                )
            }

            if !usesDeviceDNSSetting {
                LavaSectionGroup("DNS Providers", footer: "A provider answers your phone's \"where is this website?\" questions. Any of these are trustworthy.") {
                    LavaCondensedList {
                        ForEach(Array(DNSResolverPreset.settingsPresets.filter { $0.id != DNSResolverPreset.device.id }.enumerated()), id: \.element.id) { _, preset in
                            Button {
                                selectResolver(preset)
                            } label: {
                                LavaSelectableRow(
                                    state: (!isCustomResolverSelected && selectedBaseResolver.id == preset.id) ? .selected : .unselected
                                ) {
                                    ResolverPresetRowContent(
                                        title: preset.displayName,
                                        metadata: metadata(for: preset)
                                    )
                                }
                            }
                            .buttonStyle(.plain)
                            .tint(LavaStyle.safeGreen)
                            // Provider-selection VoiceOver semantics (WS-S): lead with the
                            // provider name as the accessibility label and carry the
                            // transport-address summary as the value, so VoiceOver announces
                            // the provider identity first instead of a name+address run-on.
                            // Selection itself stays on LavaSelectableRow's .isSelected trait.
                            .accessibilityLabel(preset.displayName.lavaLocalized)
                            .accessibilityValue(metadata(for: preset).lavaLocalized)

                            LavaCondensedDivider(leadingInset: 16)
                        }

                        Button {
                            selectCustomResolver()
                        } label: {
                            CustomDNSResolverRow(
                                isSelected: isCustomResolverSelected,
                                isEnabled: viewModel.configuration.limits.allowsCustomDNS,
                                metadata: customResolverMetadata
                            )
                        }
                        .buttonStyle(.plain)
                        .tint(LavaStyle.safeGreen)
                        .accessibilityLabel("Custom DNS".lavaLocalized)
                        .accessibilityValue(customResolverMetadata.lavaLocalized)
                    }
                }

                if showsCustomResolverOptions {
                    LavaSectionGroup("Custom Resolver", footer: "For advanced users: enter the address of a DNS service you trust. Not sure? Leave it and pick a provider above.") {
                        VStack(spacing: 12) {
                            LavaTextInputPanel {
                                CustomResolverTextField(
                                    title: "Name (optional)",
                                    placeholder: "Custom DNS",
                                    text: $customResolverNameDraft,
                                    focus: $focusedCustomResolverField,
                                    focusField: .name,
                                    onChange: updateCustomResolverNameDraft
                                )

                                Divider()

                                CustomResolverTextField(
                                    title: "Primary DNS",
                                    placeholder: "IPv4/6, https://, tls://, doq://, quic://, or sdns://",
                                    text: $customResolverDraft,
                                    keyboardType: .URL,
                                    axis: .vertical,
                                    focus: $focusedCustomResolverField,
                                    focusField: .primaryAddress,
                                    onChange: updateCustomResolverDraft
                                )

                                Divider()

                                CustomResolverTextField(
                                    title: "Secondary DNS (optional)",
                                    placeholder: "Same transport as Primary",
                                    text: $customResolverSecondaryDraft,
                                    keyboardType: .URL,
                                    axis: .vertical,
                                    focus: $focusedCustomResolverField,
                                    focusField: .secondaryAddress,
                                    onChange: updateCustomResolverSecondaryDraft
                                )
                            }

                            HStack(spacing: 12) {
                                Button(action: clearCustomResolverDrafts) {
                                    Text("Clear".lavaLocalized)
                                }
                                .buttonStyle(LavaSecondaryActionButtonStyle(disabledOpacity: 0.55))
                                .disabled(!canClearCustomResolver)

                                Button(action: saveCustomResolver) {
                                    Text(customResolverSaveButtonTitle.lavaLocalized)
                                }
                                .buttonStyle(CustomResolverSaveButtonStyle(isSaved: customResolverSaveButtonTitle == "Saved"))
                                .disabled(!canSaveCustomResolver)
                            }

                            if let customResolverValidationMessage {
                                DomainRejectPanel(title: "Custom DNS cannot be saved", message: customResolverValidationMessage)
                            }
                        }
                    }
                }

                if showsResolverOptions {
                    LavaSectionGroup("DNS Transport", footer: "\"Transport\" is how the lookup travels. IP is unencrypted; DoH, DoT, and DoQ scramble it so others on your network can't see the sites you visit.") {
                        ResolverTransportControl(
                            detail: transportDetailText,
                            selectedBaseResolver: selectedBaseResolver,
                            selection: resolverTransportBinding
                        )
                    }
                }
            }
        }
        .navigationBarBackButtonHidden(customResolverBackButtonIsVisible)
        .toolbar {
            if customResolverBackButtonIsVisible {
                ToolbarItem(placement: .topBarLeading) {
                    NativeToolbarIconButton(systemName: "chevron.left", accessibilityLabel: "Back", action: requestCustomResolverDismiss)
                }
            }
        }
        .lavaConfirmationAlert { host in
            host.alert("Discard custom DNS changes?", isPresented: $showingCustomResolverDiscardConfirmation) {
                Button("Cancel", role: .cancel) {
                    pendingCustomResolverDiscardAction = nil
                }
                Button("Discard", role: .destructive) {
                    discardPendingCustomResolverDraft()
                }
            } message: {
                Text("Your custom DNS draft will be removed.")
            }
        }
        .navigationDestination(isPresented: $showUpgradePage) {
            LavaPlusUpgradeDestination()
        }
        .onAppear(perform: resetCustomResolverDrafts)
        .onDisappear(perform: resetCustomResolverDrafts)
    }

    private var selectedResolver: DNSResolverPreset {
        viewModel.configuration.resolverPreset
    }

    private var selectedBaseResolver: DNSResolverPreset {
        selectedResolver.settingsBasePreset
    }

    private var selectedTransport: DNSResolverTransport {
        selectedResolver.transport
    }

    private var usesDeviceDNSSetting: Bool {
        viewModel.configuration.resolverPresetID == DNSResolverPreset.device.id
    }

    private var isCustomResolverSelected: Bool {
        isEditingCustomResolver || viewModel.configuration.resolverPresetID == DNSResolverPreset.customID
    }

    private var showsResolverOptions: Bool {
        !showsCustomResolverOptions
            && selectedBaseResolver.id != DNSResolverPreset.device.id
            && selectedBaseResolver.id != DNSResolverPreset.customID
    }

    private var showsCustomResolverOptions: Bool {
        (isEditingCustomResolver || isCustomResolverSelected) && viewModel.configuration.limits.allowsCustomDNS
    }

    private var customResolverBackButtonIsVisible: Bool {
        showsCustomResolverOptions
    }

    private var useDeviceDNSBinding: Binding<Bool> {
        Binding {
            usesDeviceDNSSetting
        } set: { newValue in
            guard newValue != usesDeviceDNSSetting else {
                return
            }

            if customResolverHasUnsavedDraft {
                requestCustomResolverDiscard(for: .useDeviceDNS(newValue))
                return
            }

            applyUseDeviceDNSSetting(newValue)
        }
    }

    private func applyUseDeviceDNSSetting(_ newValue: Bool) {
        performAppSettingsMutation(reason: "Edit DNS settings") {
            isEditingCustomResolver = false
            hasPendingCustomResolverAddressChange = false
            hasPendingCustomResolverSecondaryAddressChange = false
            hasPendingCustomResolverNameChange = false

            if newValue {
                viewModel.setResolver(.device)
                resetCustomResolverDrafts()
            } else {
                // Leaving Device DNS: there is no prior non-device transport to restore
                // (`selectedMenuTransport` is forced to `.plainDNS` while Device DNS is
                // selected), so adopt the app's default/top resolver — Mullvad DoH — to
                // match onboarding and the AppConfiguration default, rather than dropping
                // the user onto Google plain IP.
                viewModel.setResolver(.mullvadDoH)
            }
        }
    }

    private var resolverTransportBinding: Binding<DNSResolverTransport> {
        Binding {
            selectedTransport
        } set: { newValue in
            let nextPreset = selectedBaseResolver.resolverVariant(for: newValue)
            performAppSettingsMutation(reason: "Edit DNS settings") {
                viewModel.setResolver(nextPreset)
            }
        }
    }

    private var fallbackToDeviceDNSBinding: Binding<Bool> {
        Binding {
            viewModel.configuration.fallbackToDeviceDNS
        } set: { newValue in
            performAppSettingsMutation(reason: "Edit DNS settings") {
                viewModel.setFallbackToDeviceDNS(newValue)
            }
        }
    }

    private var usesEncryptedDeviceDNSFallbackBinding: Binding<Bool> {
        Binding {
            viewModel.configuration.usesEncryptedDeviceDNSFallback
        } set: { newValue in
            performAppSettingsMutation(reason: "Edit DNS settings") {
                viewModel.setUsesEncryptedDeviceDNSFallback(newValue)
            }
        }
    }

    private var transportDetailText: String {
        "IP uses standard DNS. DNS over HTTPS (DoH), TLS (DoT), and QUIC (DoQ) encrypt allowed lookups to the resolver."
    }

    private var selectedMenuTransport: DNSResolverTransport {
        selectedTransport == .deviceDNS ? .plainDNS : selectedTransport
    }

    private var customResolverMetadata: String {
        guard viewModel.configuration.limits.allowsCustomDNS else {
            return "Upgrade to use DNS over HTTPS, TLS and QUIC"
        }

        let configuredValue = viewModel.configuration.customResolverAddress ?? ""
        let configuredSecondaryValue = viewModel.configuration.customResolverSecondaryAddress ?? ""
        guard let preset = DNSResolverPreset.custom(
            primaryRawValue: configuredValue,
            secondaryRawValue: configuredSecondaryValue
        ) else {
            return "Supports DNS over IP, HTTPS, TLS and QUIC"
        }

        return resolverAddressSummary(for: preset)
    }

    private var trimmedCustomResolverDraft: String {
        customResolverDraft.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var trimmedCustomResolverSecondaryDraft: String {
        customResolverSecondaryDraft.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var normalizedCustomResolverNameDraft: String? {
        let trimmedValue = customResolverNameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedValue.isEmpty ? nil : trimmedValue
    }

    private var normalizedConfiguredCustomResolverName: String? {
        let trimmedValue = viewModel.configuration.customResolverName?.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedValue?.isEmpty == true ? nil : trimmedValue
    }

    private var normalizedConfiguredCustomResolverAddress: String {
        viewModel.configuration.customResolverAddress?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    private var normalizedConfiguredCustomResolverSecondaryAddress: String {
        viewModel.configuration.customResolverSecondaryAddress?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    private var customResolverDraftIsValid: Bool {
        DNSResolverPreset.customValidationMessage(
            primaryRawValue: trimmedCustomResolverDraft,
            secondaryRawValue: trimmedCustomResolverSecondaryDraft,
            supportsDNSOverQUIC: viewModel.supportsDNSOverQUIC
        ) == nil
    }

    private var customResolverDraftMatchesSavedEntry: Bool {
        normalizedConfiguredCustomResolverAddress == trimmedCustomResolverDraft
            && normalizedConfiguredCustomResolverSecondaryAddress == trimmedCustomResolverSecondaryDraft
            && normalizedConfiguredCustomResolverName == normalizedCustomResolverNameDraft
    }

    private var customResolverDraftIsCleared: Bool {
        trimmedCustomResolverDraft.isEmpty
            && trimmedCustomResolverSecondaryDraft.isEmpty
            && normalizedCustomResolverNameDraft == nil
    }

    private var customResolverClearFallbackPreset: DNSResolverPreset {
        let fallbackBasePreset = selectedBaseResolver.id == DNSResolverPreset.customID ? DNSResolverPreset.google : selectedBaseResolver
        return fallbackBasePreset.resolverVariant(for: selectedMenuTransport)
    }

    private var customResolverHasChanges: Bool {
        !customResolverDraftMatchesSavedEntry
    }

    private var customResolverHasUnsavedDraft: Bool {
        customResolverHasChanges
    }

    private var canSaveCustomResolver: Bool {
        customResolverHasChanges
            && (!trimmedCustomResolverDraft.isEmpty || customResolverDraftIsCleared)
    }

    private var canClearCustomResolver: Bool {
        !customResolverDraft.isEmpty || !customResolverSecondaryDraft.isEmpty || !customResolverNameDraft.isEmpty
    }

    private var customResolverSaveButtonTitle: String {
        if !customResolverHasChanges && customResolverDraftIsValid {
            return "Saved"
        }

        return "Save"
    }

    private func selectResolver(_ preset: DNSResolverPreset) {
        if customResolverHasUnsavedDraft {
            requestCustomResolverDiscard(for: .selectResolver(preset))
            return
        }

        applyResolverSelection(preset)
    }

    private func applyResolverSelection(_ preset: DNSResolverPreset) {
        performAppSettingsMutation(reason: "Edit DNS settings") {
            isEditingCustomResolver = false
            hasPendingCustomResolverAddressChange = false
            hasPendingCustomResolverSecondaryAddressChange = false
            hasPendingCustomResolverNameChange = false
            viewModel.setResolver(preset.resolverVariant(for: selectedMenuTransport))
            resetCustomResolverDrafts()
        }
    }

    private func selectCustomResolver() {
        guard viewModel.configuration.limits.allowsCustomDNS else {
            showUpgradePage = true
            return
        }

        isEditingCustomResolver = true
        if !customResolverHasUnsavedDraft {
            customResolverDraft = viewModel.configuration.customResolverAddress ?? ""
            customResolverSecondaryDraft = viewModel.configuration.customResolverSecondaryAddress ?? ""
            customResolverNameDraft = viewModel.configuration.customResolverName ?? ""
            hasPendingCustomResolverAddressChange = false
            hasPendingCustomResolverSecondaryAddressChange = false
            hasPendingCustomResolverNameChange = false
            customResolverValidationMessage = nil
        }
    }

    private func updateCustomResolverDraft() {
        hasPendingCustomResolverAddressChange = true
        customResolverValidationMessage = nil
    }

    private func updateCustomResolverSecondaryDraft() {
        hasPendingCustomResolverSecondaryAddressChange = true
        customResolverValidationMessage = nil
    }

    private func updateCustomResolverNameDraft() {
        hasPendingCustomResolverNameChange = true
        customResolverValidationMessage = nil
    }

    private func resetCustomResolverDrafts() {
        customResolverDraft = viewModel.configuration.customResolverAddress ?? ""
        customResolverSecondaryDraft = viewModel.configuration.customResolverSecondaryAddress ?? ""
        customResolverNameDraft = viewModel.configuration.customResolverName ?? ""
        hasPendingCustomResolverAddressChange = false
        hasPendingCustomResolverSecondaryAddressChange = false
        hasPendingCustomResolverNameChange = false
        customResolverValidationMessage = nil
        isEditingCustomResolver = viewModel.configuration.resolverPresetID == DNSResolverPreset.customID
    }

    private func saveCustomResolver() {
        guard canSaveCustomResolver else {
            return
        }

        if customResolverDraftIsCleared {
            focusedCustomResolverField = nil
            performAppSettingsMutation(reason: "Edit DNS settings") {
                viewModel.clearCustomResolver(fallback: customResolverClearFallbackPreset)
                customResolverDraft = ""
                customResolverSecondaryDraft = ""
                customResolverNameDraft = ""
                hasPendingCustomResolverNameChange = false
                hasPendingCustomResolverAddressChange = false
                hasPendingCustomResolverSecondaryAddressChange = false
                customResolverValidationMessage = nil
                isEditingCustomResolver = false
            }
            return
        }

        if let validationMessage = DNSResolverPreset.customValidationMessage(
            primaryRawValue: trimmedCustomResolverDraft,
            secondaryRawValue: trimmedCustomResolverSecondaryDraft,
            supportsDNSOverQUIC: viewModel.supportsDNSOverQUIC
        ) {
            customResolverValidationMessage = validationMessage
            return
        }

        let trimmedValue = trimmedCustomResolverDraft
        let trimmedSecondaryValue = trimmedCustomResolverSecondaryDraft
        focusedCustomResolverField = nil
        performAppSettingsMutation(reason: "Edit DNS settings") {
            viewModel.setCustomResolverName(customResolverNameDraft)
            viewModel.setCustomResolverAddresses(primary: trimmedValue, secondary: trimmedSecondaryValue)
            customResolverDraft = trimmedValue
            customResolverSecondaryDraft = viewModel.configuration.customResolverSecondaryAddress ?? ""
            customResolverNameDraft = viewModel.configuration.customResolverName ?? ""
            hasPendingCustomResolverNameChange = false
            hasPendingCustomResolverAddressChange = false
            hasPendingCustomResolverSecondaryAddressChange = false
            customResolverValidationMessage = nil
            isEditingCustomResolver = true
        }
    }

    private func clearCustomResolverDrafts() {
        customResolverDraft = ""
        customResolverSecondaryDraft = ""
        customResolverNameDraft = ""
        hasPendingCustomResolverAddressChange = true
        hasPendingCustomResolverSecondaryAddressChange = true
        hasPendingCustomResolverNameChange = true
        customResolverValidationMessage = nil
    }

    private func requestCustomResolverDismiss() {
        if customResolverHasUnsavedDraft {
            requestCustomResolverDiscard(for: .dismiss)
        } else {
            dismiss()
        }
    }

    private func requestCustomResolverDiscard(for action: CustomResolverDiscardAction) {
        pendingCustomResolverDiscardAction = action
        showingCustomResolverDiscardConfirmation = true
    }

    private func discardPendingCustomResolverDraft() {
        let action = pendingCustomResolverDiscardAction
        pendingCustomResolverDiscardAction = nil
        showingCustomResolverDiscardConfirmation = false
        focusedCustomResolverField = nil
        resetCustomResolverDrafts()

        switch action {
        case .selectResolver(let preset):
            applyResolverSelection(preset)
        case .useDeviceDNS(let newValue):
            applyUseDeviceDNSSetting(newValue)
        case .dismiss:
            dismiss()
        case nil:
            break
        }
    }

    private func performAppSettingsMutation(reason: String, action: @escaping @MainActor () -> Void) {
        Task {
            guard await security.requireAuthentication(for: .appSettings, reason: reason) else {
                return
            }

            action()
        }
    }

    private func metadata(for preset: DNSResolverPreset) -> String {
        resolverAddressSummary(for: displayPreset(for: preset))
    }

    private func displayPreset(for preset: DNSResolverPreset) -> DNSResolverPreset {
        preset.resolverVariant(for: selectedMenuTransport)
    }

    private func resolverAddressSummary(for preset: DNSResolverPreset) -> String {
        let dohEndpointAddresses = preset.dohEndpoints.map { $0.url.absoluteString }
        if !dohEndpointAddresses.isEmpty {
            return dohEndpointAddresses.joined(separator: ", ")
        }

        let dotEndpointAddresses = preset.dotEndpoints.map(\.displayAddress)
        if !dotEndpointAddresses.isEmpty {
            return dotEndpointAddresses.joined(separator: ", ")
        }

        let doqEndpointAddresses = preset.doqEndpoints.map(\.displayAddress)
        if !doqEndpointAddresses.isEmpty {
            return doqEndpointAddresses.joined(separator: ", ")
        }

        let servers = preset.allServers
        if !servers.isEmpty {
            return servers.joined(separator: ", ")
        }

        return "Supports DNS over IP, HTTPS, TLS and QUIC"
    }
}

private enum CustomResolverDiscardAction {
    case selectResolver(DNSResolverPreset)
    case useDeviceDNS(Bool)
    case dismiss
}

// Reusable DNS provider list + Custom-resolver editor + transport selector. The
// primary resolver picker is rendered inline in DNSResolverSettingsView (it owns a
// page-level discard-confirmation flow that also guards the Device-DNS toggle and
// page dismissal). This component is used for the encrypted Device-DNS *fallback*
// selection: it owns its own draft state and applies edits immediately through the
// supplied closures, mirroring the primary's provider/transport/custom layout.
private struct ResolverPickerSections: View {
    let selectedPreset: DNSResolverPreset
    let configuredCustomAddress: String?
    let configuredCustomSecondaryAddress: String?
    let configuredCustomName: String?
    let allowsCustomDNS: Bool
    let supportsDNSOverQUIC: Bool
    let selectPreset: (DNSResolverPreset) -> Void
    let saveCustom: (_ name: String, _ primary: String, _ secondary: String) -> Void
    let clearCustom: (_ fallback: DNSResolverPreset) -> Void
    let requestUpgrade: () -> Void

    @State private var customResolverDraft = ""
    @State private var customResolverSecondaryDraft = ""
    @State private var customResolverNameDraft = ""
    @State private var isEditingCustomResolver = false
    @State private var customResolverValidationMessage: String?
    @FocusState private var focusedCustomResolverField: CustomResolverFocusField?

    var body: some View {
        Group {
            LavaSectionGroup("DNS Providers") {
                LavaCondensedList {
                    ForEach(Array(DNSResolverPreset.settingsPresets.filter { $0.id != DNSResolverPreset.device.id }.enumerated()), id: \.element.id) { _, preset in
                        Button {
                            selectBaseResolver(preset)
                        } label: {
                            LavaSelectableRow(
                                state: (!isCustomResolverSelected && selectedBaseResolver.id == preset.id) ? .selected : .unselected
                            ) {
                                ResolverPresetRowContent(
                                    title: preset.displayName,
                                    metadata: metadata(for: preset)
                                )
                            }
                        }
                        .buttonStyle(.plain)
                        .tint(LavaStyle.safeGreen)

                        LavaCondensedDivider(leadingInset: 16)
                    }

                    Button {
                        selectCustomResolver()
                    } label: {
                        CustomDNSResolverRow(
                            isSelected: isCustomResolverSelected,
                            isEnabled: allowsCustomDNS,
                            metadata: customResolverMetadata
                        )
                    }
                    .buttonStyle(.plain)
                    .tint(LavaStyle.safeGreen)
                }
            }

            if showsCustomResolverOptions {
                LavaSectionGroup("Custom Resolver") {
                    VStack(spacing: 12) {
                        LavaTextInputPanel {
                            CustomResolverTextField(
                                title: "Name (optional)",
                                placeholder: "Custom DNS",
                                text: $customResolverNameDraft,
                                focus: $focusedCustomResolverField,
                                focusField: .name,
                                onChange: { customResolverValidationMessage = nil }
                            )

                            Divider()

                            CustomResolverTextField(
                                title: "Primary DNS",
                                placeholder: "IPv4/6, https://, tls://, doq://, quic://, or sdns://",
                                text: $customResolverDraft,
                                keyboardType: .URL,
                                axis: .vertical,
                                focus: $focusedCustomResolverField,
                                focusField: .primaryAddress,
                                onChange: { customResolverValidationMessage = nil }
                            )

                            Divider()

                            CustomResolverTextField(
                                title: "Secondary DNS (optional)",
                                placeholder: "Same transport as Primary",
                                text: $customResolverSecondaryDraft,
                                keyboardType: .URL,
                                axis: .vertical,
                                focus: $focusedCustomResolverField,
                                focusField: .secondaryAddress,
                                onChange: { customResolverValidationMessage = nil }
                            )
                        }

                        HStack(spacing: 12) {
                            Button(action: clearCustomResolverDrafts) {
                                Text("Clear".lavaLocalized)
                            }
                            .buttonStyle(LavaSecondaryActionButtonStyle(disabledOpacity: 0.55))
                            .disabled(!canClearCustomResolver)

                            Button(action: saveCustomResolver) {
                                Text(customResolverSaveButtonTitle.lavaLocalized)
                            }
                            .buttonStyle(CustomResolverSaveButtonStyle(isSaved: customResolverSaveButtonTitle == "Saved"))
                            .disabled(!canSaveCustomResolver)
                        }

                        if let customResolverValidationMessage {
                            DomainRejectPanel(title: "Custom DNS cannot be saved", message: customResolverValidationMessage)
                        }
                    }
                }
            }

            if showsResolverOptions {
                LavaSectionGroup("DNS Transport") {
                    ResolverTransportControl(
                        detail: transportDetailText,
                        selectedBaseResolver: selectedBaseResolver,
                        selection: transportBinding
                    )
                }
            }
        }
        .onAppear(perform: resetCustomResolverDrafts)
        .onDisappear(perform: resetCustomResolverDrafts)
    }

    private var selectedBaseResolver: DNSResolverPreset {
        selectedPreset.settingsBasePreset
    }

    private var selectedTransport: DNSResolverTransport {
        selectedPreset.transport
    }

    private var selectedMenuTransport: DNSResolverTransport {
        selectedTransport == .deviceDNS ? .plainDNS : selectedTransport
    }

    private var isCustomResolverSelected: Bool {
        isEditingCustomResolver || selectedPreset.id == DNSResolverPreset.customID
    }

    private var showsResolverOptions: Bool {
        !showsCustomResolverOptions
            && selectedBaseResolver.id != DNSResolverPreset.device.id
            && selectedBaseResolver.id != DNSResolverPreset.customID
    }

    private var showsCustomResolverOptions: Bool {
        (isEditingCustomResolver || isCustomResolverSelected) && allowsCustomDNS
    }

    private var transportBinding: Binding<DNSResolverTransport> {
        Binding {
            selectedTransport
        } set: { newValue in
            selectPreset(selectedBaseResolver.resolverVariant(for: newValue))
        }
    }

    private var transportDetailText: String {
        "IP uses standard DNS. DNS over HTTPS (DoH), TLS (DoT), and QUIC (DoQ) encrypt allowed lookups to the resolver."
    }

    private var customResolverMetadata: String {
        guard allowsCustomDNS else {
            return "Upgrade to use DNS over HTTPS, TLS and QUIC"
        }

        let configuredValue = configuredCustomAddress ?? ""
        let configuredSecondaryValue = configuredCustomSecondaryAddress ?? ""
        guard let preset = DNSResolverPreset.custom(
            primaryRawValue: configuredValue,
            secondaryRawValue: configuredSecondaryValue
        ) else {
            return "Supports DNS over IP, HTTPS, TLS and QUIC"
        }

        return resolverAddressSummary(for: preset)
    }

    private var trimmedCustomResolverDraft: String {
        customResolverDraft.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var trimmedCustomResolverSecondaryDraft: String {
        customResolverSecondaryDraft.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var normalizedCustomResolverNameDraft: String? {
        let trimmedValue = customResolverNameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedValue.isEmpty ? nil : trimmedValue
    }

    private var normalizedConfiguredCustomResolverName: String? {
        let trimmedValue = configuredCustomName?.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedValue?.isEmpty == true ? nil : trimmedValue
    }

    private var normalizedConfiguredCustomResolverAddress: String {
        configuredCustomAddress?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    private var normalizedConfiguredCustomResolverSecondaryAddress: String {
        configuredCustomSecondaryAddress?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    private var customResolverDraftIsValid: Bool {
        DNSResolverPreset.customValidationMessage(
            primaryRawValue: trimmedCustomResolverDraft,
            secondaryRawValue: trimmedCustomResolverSecondaryDraft,
            supportsDNSOverQUIC: supportsDNSOverQUIC
        ) == nil
    }

    private var customResolverDraftMatchesSavedEntry: Bool {
        normalizedConfiguredCustomResolverAddress == trimmedCustomResolverDraft
            && normalizedConfiguredCustomResolverSecondaryAddress == trimmedCustomResolverSecondaryDraft
            && normalizedConfiguredCustomResolverName == normalizedCustomResolverNameDraft
    }

    private var customResolverDraftIsCleared: Bool {
        trimmedCustomResolverDraft.isEmpty
            && trimmedCustomResolverSecondaryDraft.isEmpty
            && normalizedCustomResolverNameDraft == nil
    }

    private var customResolverClearFallbackPreset: DNSResolverPreset {
        let fallbackBasePreset = selectedBaseResolver.id == DNSResolverPreset.customID ? DNSResolverPreset.mullvad : selectedBaseResolver
        let variant = fallbackBasePreset.resolverVariant(for: selectedMenuTransport)
        // The encrypted fallback must stay encrypted. A custom DoQ alternative has no
        // built-in QUIC variant, so resolverVariant degrades to plain Mullvad IP —
        // clearing it would silently drop the safety net from encrypted to unencrypted.
        // Coerce that unsupported-QUIC case to the encrypted default/top resolver.
        if selectedMenuTransport == .dnsOverQUIC, variant.transport != .dnsOverQUIC {
            return .mullvadDoH
        }
        return variant
    }

    private var customResolverHasChanges: Bool {
        !customResolverDraftMatchesSavedEntry
    }

    private var canSaveCustomResolver: Bool {
        customResolverHasChanges
            && (!trimmedCustomResolverDraft.isEmpty || customResolverDraftIsCleared)
    }

    private var canClearCustomResolver: Bool {
        !customResolverDraft.isEmpty || !customResolverSecondaryDraft.isEmpty || !customResolverNameDraft.isEmpty
    }

    private var customResolverSaveButtonTitle: String {
        if !customResolverHasChanges && customResolverDraftIsValid {
            return "Saved"
        }

        return "Save"
    }

    private func selectBaseResolver(_ preset: DNSResolverPreset) {
        // Selecting a built-in provider always leaves custom-editing. Set that
        // explicitly and reset the draft text inline — do NOT call
        // resetCustomResolverDrafts() here: the config change via selectPreset is
        // deferred (the parent wraps it in an authenticated mutation), so
        // `selectedPreset` is still the old Custom value at this point, and
        // re-deriving isEditingCustomResolver from it would flip the editor back on
        // and keep the Custom row selected until the page is recreated.
        isEditingCustomResolver = false
        customResolverDraft = configuredCustomAddress ?? ""
        customResolverSecondaryDraft = configuredCustomSecondaryAddress ?? ""
        customResolverNameDraft = configuredCustomName ?? ""
        customResolverValidationMessage = nil
        selectPreset(preset.resolverVariant(for: selectedMenuTransport))
    }

    private func selectCustomResolver() {
        guard allowsCustomDNS else {
            requestUpgrade()
            return
        }

        isEditingCustomResolver = true
        customResolverDraft = configuredCustomAddress ?? ""
        customResolverSecondaryDraft = configuredCustomSecondaryAddress ?? ""
        customResolverNameDraft = configuredCustomName ?? ""
        customResolverValidationMessage = nil
    }

    private func resetCustomResolverDrafts() {
        customResolverDraft = configuredCustomAddress ?? ""
        customResolverSecondaryDraft = configuredCustomSecondaryAddress ?? ""
        customResolverNameDraft = configuredCustomName ?? ""
        customResolverValidationMessage = nil
        isEditingCustomResolver = selectedPreset.id == DNSResolverPreset.customID
    }

    private func saveCustomResolver() {
        guard canSaveCustomResolver else {
            return
        }

        if customResolverDraftIsCleared {
            focusedCustomResolverField = nil
            clearCustom(customResolverClearFallbackPreset)
            customResolverDraft = ""
            customResolverSecondaryDraft = ""
            customResolverNameDraft = ""
            customResolverValidationMessage = nil
            isEditingCustomResolver = false
            return
        }

        if let validationMessage = DNSResolverPreset.customValidationMessage(
            primaryRawValue: trimmedCustomResolverDraft,
            secondaryRawValue: trimmedCustomResolverSecondaryDraft,
            supportsDNSOverQUIC: supportsDNSOverQUIC
        ) {
            customResolverValidationMessage = validationMessage
            return
        }

        let trimmedValue = trimmedCustomResolverDraft
        let trimmedSecondaryValue = trimmedCustomResolverSecondaryDraft
        focusedCustomResolverField = nil
        saveCustom(customResolverNameDraft, trimmedValue, trimmedSecondaryValue)
        customResolverDraft = trimmedValue
        customResolverSecondaryDraft = trimmedSecondaryValue.isEmpty ? "" : trimmedSecondaryValue
        customResolverNameDraft = normalizedCustomResolverNameDraft ?? ""
        customResolverValidationMessage = nil
        isEditingCustomResolver = true
    }

    private func clearCustomResolverDrafts() {
        customResolverDraft = ""
        customResolverSecondaryDraft = ""
        customResolverNameDraft = ""
        customResolverValidationMessage = nil
    }

    private func metadata(for preset: DNSResolverPreset) -> String {
        resolverAddressSummary(for: preset.resolverVariant(for: selectedMenuTransport))
    }

    private func resolverAddressSummary(for preset: DNSResolverPreset) -> String {
        let dohEndpointAddresses = preset.dohEndpoints.map { $0.url.absoluteString }
        if !dohEndpointAddresses.isEmpty {
            return dohEndpointAddresses.joined(separator: ", ")
        }

        let dotEndpointAddresses = preset.dotEndpoints.map(\.displayAddress)
        if !dotEndpointAddresses.isEmpty {
            return dotEndpointAddresses.joined(separator: ", ")
        }

        let doqEndpointAddresses = preset.doqEndpoints.map(\.displayAddress)
        if !doqEndpointAddresses.isEmpty {
            return doqEndpointAddresses.joined(separator: ", ")
        }

        let servers = preset.allServers
        if !servers.isEmpty {
            return servers.joined(separator: ", ")
        }

        return "Supports DNS over IP, HTTPS, TLS and QUIC"
    }
}

private enum CustomResolverFocusField {
    case name
    case primaryAddress
    case secondaryAddress
}

private struct CustomResolverSaveButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    let isSaved: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(isSaved ? LavaStyle.secondaryText : .white)
            .lineLimit(1)
            .minimumScaleFactor(0.82)
            .frame(maxWidth: .infinity)
            .frame(height: LavaSurface.actionButtonHeight)
            .background {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(isSaved ? LavaStyle.quietControl : LavaStyle.safeControlGreen)
                    .overlay {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(Color.black.opacity(configuration.isPressed ? 0.10 : 0))
                    }
            }
            .scaleEffect(configuration.isPressed ? 0.99 : 1)
            .opacity(isEnabled || isSaved ? 1 : 0.45)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

private struct CustomResolverTextField: View {
    let title: String
    let placeholder: String
    @Binding var text: String
    var keyboardType: UIKeyboardType = .default
    var axis: Axis = .horizontal
    let focus: FocusState<CustomResolverFocusField?>.Binding
    let focusField: CustomResolverFocusField
    let onChange: () -> Void

    var body: some View {
        LavaTextInputRow(title: title) {
            TextField(placeholder.lavaLocalized, text: $text, axis: axis)
                .lavaTextInputBody(keyboardType: keyboardType, axis: axis)
                .lineLimit(1...3)
                .focused(focus, equals: focusField)
                .onSubmit {
                    focus.wrappedValue = nil
                }
                .onChange(of: text) { _, _ in
                    onChange()
                }
        }
    }
}

/// Title + transport-address metadata for a preset DNS provider row. The selection
/// checkmark is supplied by the enclosing ``LavaSelectableRow``.
private struct ResolverPresetRowContent: View {
    let title: String
    let metadata: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title.lavaLocalized)
                .lavaRowTitleText()
                .lineLimit(2)
                .minimumScaleFactor(0.82)
                .fixedSize(horizontal: false, vertical: true)

            if let metadata {
                Text(metadata.lavaLocalized)
                    .lavaMetadataText()
            }
        }
    }
}

private struct CustomDNSResolverRow: View {
    let isSelected: Bool
    let isEnabled: Bool
    let metadata: String

    var body: some View {
        LavaSelectableRow(
            state: isSelected ? .selected : .unselected,
            verticalPadding: 9,
            minHeight: 52
        ) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Custom DNS".lavaLocalized)
                    .lavaRowTitleText()
                    .lavaInactiveText(!isEnabled)
                    .lineLimit(2)
                    .minimumScaleFactor(0.82)
                    .fixedSize(horizontal: false, vertical: true)

                metadataView
            }
        }
    }

    @ViewBuilder
    private var metadataView: some View {
        if isEnabled {
            Text(metadata.lavaLocalized)
                .lavaMetadataText()
        } else {
            // One concatenated Text so the copy flows and wraps as a single
            // paragraph instead of "Upgrade" sitting in its own column beside a
            // separately-wrapping remainder.
            (Text("Upgrade".lavaLocalized)
                .font(.caption.weight(.bold))
                .foregroundStyle(LavaStyle.safeGreen)
             + Text(" to use DNS over HTTPS, TLS and QUIC".lavaLocalized)
                .font(.caption)
                .foregroundStyle(LavaStyle.secondaryText))
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, minHeight: 14, alignment: .leading)
        }
    }
}

private struct ResolverTransportControl: View {
    let detail: String
    let selectedBaseResolver: DNSResolverPreset
    @Binding var selection: DNSResolverTransport

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("DNS Transport", selection: $selection) {
                ForEach(selectedBaseResolver.availableTransports, id: \.self) { transport in
                    Text(transport.menuTitle.lavaLocalized)
                        .tag(transport)
                }
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: .infinity, alignment: .leading)
            .lavaControlRowCard()

            Text(detail.lavaLocalized)
                .lavaQuietNoteText()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct ResolverToggleRow: View {
    let title: String
    @Binding var isOn: Bool

    var body: some View {
        Toggle(title.lavaLocalized, isOn: $isOn)
            .font(.headline)
            .tint(LavaStyle.safeGreen)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct ResolverOptionControl: View {
    let title: String
    let detail: String
    @Binding var isOn: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ResolverToggleRow(title: title, isOn: $isOn)
                .lavaControlRowCard()

            Text(detail.lavaLocalized)
                .lavaQuietNoteText()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
