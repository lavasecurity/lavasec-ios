import SwiftUI
import LavaSecKit

private struct DomainEntryForm: View {
    @Binding var domain: String
    @FocusState private var isDomainFieldFocused: Bool
    @State private var showUpgradePage = false

    let placeholder: String
    let primaryActionTitle: String
    let usageText: String
    let usageTextIsError: Bool
    let isSubmitDisabled: Bool
    let submit: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            DomainTextField(
                placeholder: placeholder,
                text: $domain,
                isFocused: $isDomainFieldFocused
            )
                .submitLabel(.done)
                .onSubmit {
                    if !isSubmitDisabled {
                        primaryAction()
                    }
                }

            Button(action: primaryAction) {
                Text(primaryActionTitle.lavaLocalized)
            }
            .buttonStyle(LavaStandaloneActionButtonStyle())
            .disabled(isSubmitDisabled)

            Text(usageText.lavaLocalized)
                .font(.footnote.weight(.medium))
                .foregroundStyle(usageTextIsError ? LavaStyle.lavaOrangeText : LavaStyle.secondaryText)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
        }
        .sheet(isPresented: $showUpgradePage) {
            LavaPlusUpgradeSheet()
        }
        .task {
            try? await Task.sleep(nanoseconds: 180_000_000)
            guard !Task.isCancelled else {
                return
            }

            isDomainFieldFocused = true
        }
    }

    private func primaryAction() {
        if primaryActionTitle == "Upgrade" {
            showUpgradePage = true
            return
        }

        submit()
    }
}

private struct DomainTextField: View {
    let placeholder: String
    @Binding var text: String
    let isFocused: FocusState<Bool>.Binding

    var body: some View {
        LavaTextInputPanel {
            LavaTextInputRow(title: "Domain") {
                TextField(placeholder.lavaLocalized, text: $text)
                    .lavaTextInputBody(keyboardType: .URL)
                    .focused(isFocused)
            }
        }
    }
}
struct AddBlockedDomainSheet: View {
    @EnvironmentObject private var viewModel: AppViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var domain = ""
    @State private var result: DomainDraftResult?

    var body: some View {
        NavigationStack {
            LavaSheetScaffold(spacing: 18, scrolls: true) {
                DomainEntryForm(
                    domain: $domain,
                    placeholder: "example.com",
                    primaryActionTitle: primaryActionTitle,
                    usageText: usageText,
                    usageTextIsError: usageTextIsError,
                    isSubmitDisabled: isSubmitDisabled,
                    submit: addDomain
                )

                if let result, !result.isAccepted {
                    DomainRejectPanel(title: result.title, message: result.message)
                }
            }
            .navigationTitle("Add Blocked Domain".lavaLocalized)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    NativeToolbarIconButton(systemName: "xmark", accessibilityLabel: "Cancel", role: .cancel, action: dismiss.callAsFunction)
                }
            }
        }
        .presentationDetents([.height(sheetHeight)])
    }

    private var draftCount: Int {
        viewModel.filterEditDraft?.blockedDomains.count ?? viewModel.configuration.blockedDomains.count
    }

    private var limit: Int {
        viewModel.configuration.limits.maxBlockedDomains
    }

    private var usageText: String {
        if isFreeAtLimit {
            return "%d/%d blocked domains used - Upgrade or remove entries".lavaLocalizedFormat(draftCount, limit)
        }

        if draftCount >= limit {
            return "%d/%d blocked domains used - Remove entries to continue".lavaLocalizedFormat(draftCount, limit)
        }

        return "%d/%d blocked domains used".lavaLocalizedFormat(draftCount, limit)
    }

    private var usageTextIsError: Bool {
        draftCount >= limit
    }

    private var isFreeAtLimit: Bool {
        !viewModel.configuration.hasLavaSecurityPlus && draftCount >= limit
    }

    private var primaryActionTitle: String {
        isFreeAtLimit ? "Upgrade" : "Add Domain"
    }

    private var isSubmitDisabled: Bool {
        if isFreeAtLimit {
            return false
        }

        return domain.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || draftCount >= limit
    }

    private var sheetHeight: CGFloat {
        340
    }

    private func addDomain() {
        let addResult = viewModel.addBlockedDomainToDraft(domain)
        result = addResult
        if addResult.isAccepted {
            dismiss()
        }
    }
}

struct AddAllowedExceptionSheet: View {
    @EnvironmentObject private var viewModel: AppViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var domain = ""
    @State private var result: DomainDraftResult?

    var body: some View {
        NavigationStack {
            LavaSheetScaffold(spacing: 18, scrolls: true) {
                LavaInfoPanel(
                    title: "Before you allow a site",
                    description: "A site you allow here always gets through, even if a blocklist would block it. Only add sites you fully trust.",
                    systemImage: "exclamationmark.triangle.fill",
                    tint: LavaStyle.lavaOrange,
                    borderTint: LavaStyle.lavaOrange
                )

                DomainEntryForm(
                    domain: $domain,
                    placeholder: "trusted.example.com",
                    primaryActionTitle: primaryActionTitle,
                    usageText: usageText,
                    usageTextIsError: usageTextIsError,
                    isSubmitDisabled: isSubmitDisabled,
                    submit: addDomain
                )

                if let result, !result.isAccepted {
                    DomainRejectPanel(title: result.title, message: result.message)
                }
            }
            .navigationTitle("Add Allowed Exception".lavaLocalized)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    NativeToolbarIconButton(systemName: "xmark", accessibilityLabel: "Cancel", role: .cancel, action: dismiss.callAsFunction)
                }
            }
        }
        .presentationDetents([.height(sheetHeight)])
    }

    private var draftCount: Int {
        viewModel.filterEditDraft?.allowedDomains.count ?? viewModel.configuration.allowedDomains.count
    }

    private var limit: Int {
        viewModel.configuration.limits.maxAllowedDomains
    }

    private var usageText: String {
        if isFreeAtLimit {
            return "%d/%d exceptions used - Upgrade or remove entries".lavaLocalizedFormat(draftCount, limit)
        }

        if draftCount >= limit {
            return "%d/%d exceptions used - Remove entries to continue".lavaLocalizedFormat(draftCount, limit)
        }

        return "%d/%d exceptions used".lavaLocalizedFormat(draftCount, limit)
    }

    private var usageTextIsError: Bool {
        draftCount >= limit
    }

    private var isFreeAtLimit: Bool {
        !viewModel.configuration.hasLavaSecurityPlus && draftCount >= limit
    }

    private var primaryActionTitle: String {
        isFreeAtLimit ? "Upgrade" : "Add Exception"
    }

    private var isSubmitDisabled: Bool {
        if isFreeAtLimit {
            return false
        }

        return domain.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || draftCount >= limit
    }

    private var sheetHeight: CGFloat {
        420
    }

    private func addDomain() {
        let addResult = viewModel.addAllowedDomainToDraft(domain)
        result = addResult
        if addResult.isAccepted {
            dismiss()
        }
    }
}
