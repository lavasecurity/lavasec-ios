import SwiftUI
import LavaSecKit
import UniformTypeIdentifiers

private struct LocalLogExportDocument: FileDocument {
    static var readableContentTypes: [UTType] {
        [.zip]
    }

    let data: Data

    init(data: Data) {
        self.data = data
    }

    init(configuration: ReadConfiguration) throws {
        data = Data()
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

struct PrivacyDataSettingsView: View {
    @EnvironmentObject private var viewModel: AppViewModel
    // The diagnostics scope (Phase D4 peel): the store-coupled keep-flags + clears live here.
    @EnvironmentObject private var reports: DiagnosticsController
    @EnvironmentObject private var security: SecurityController
    @State private var disableTarget: LocalLogSetting?
    @State private var clearTarget: LocalLogClearTarget?
    @State private var showsClearOptions = false
    @State private var localLogExportDocument: LocalLogExportDocument?
    @State private var localLogExportFilename = "lava-local-logs.zip"
    @State private var isPresentingLocalLogExporter = false
    @State private var localLogExportErrorMessage: String?
    // True while an export is draining off the main actor. Concurrent CLEARS can no longer
    // truncate the archive — the export reads a pinned SQLite snapshot (see
    // DiagnosticsController.domainHistoryExportSource) — so this flag exists only to stop a second
    // overlapping export from racing the shared `localLogExportDocument`/exporter state below.
    // pinned: DNSEventLogWiringSourceTests.testLocalLogExportGuardsOverlappingExports
    @State private var isExportingLocalLogs = false

    var body: some View {
        SettingsSubpageContent(
            title: "Privacy & Data",
            tier: .calm,
            intro: LavaInfoPanel(
                title: "All local logs stay on this iPhone",
                description: "Domain history and network activity are kept for 7 days; counts and Lava Guard progress last longer. Keep or clear each below.",
                systemImage: "eyeglasses"
            )
        ) {
            LavaSectionGroup("Local Logs", footer: "Detailed activity is kept for 7 days — export to keep a copy.") {
                VStack(spacing: 10) {
                    LavaCondensedList {
                        localLogToggle("Filtering Counts", isOn: keepFilteringCountsBinding)

                        LavaCondensedDivider()

                        localLogToggle("Domain Logs", isOn: keepDomainHistoryBinding)

                        LavaCondensedDivider()

                        localLogToggle("Network Activity", isOn: keepNetworkActivityBinding)

                        LavaCondensedDivider()

                        localLogToggle("Lava Guard Progress", isOn: keepLavaGuardProgressBinding)
                    }
                    .font(.headline)
                    .tint(LavaStyle.safeGreen)

                    Button {
                        exportLocalLogs()
                    } label: {
                        ExportLocalLogsRow()
                            .lavaControlRowCard()
                    }
                    .buttonStyle(.plain)
                    // Prevent a second overlapping export from clobbering the in-flight one's
                    // exporter state; concurrent clears are handled by the snapshot, not here.
                    .disabled(isExportingLocalLogs)

                    if let localLogExportErrorMessage {
                        Text(localLogExportErrorMessage)
                            .lavaQuietNoteText()
                            .foregroundStyle(.red)
                    }
                }
            }

            LavaSectionGroup("Delete Local Logs") {
                VStack(spacing: 10) {
                    Toggle("Show Delete Options", isOn: $showsClearOptions)
                        .font(.headline)
                        .tint(LavaStyle.safeGreen)
                        .lavaControlRowCard()

                    if showsClearOptions {
                        VStack(spacing: 10) {
                            LavaCondensedList {
                                localLogClearButton(.filteringCounts)
                                LavaCondensedDivider()
                                localLogClearButton(.domainHistory)
                                LavaCondensedDivider()
                                localLogClearButton(.networkActivity)
                                LavaCondensedDivider()
                                localLogClearButton(.lavaGuardProgress)
                            }

                            LavaCondensedList {
                                localLogClearButton(.all)
                            }
                        }
                    }
                }
            }
        }
        .fileExporter(
            isPresented: $isPresentingLocalLogExporter,
            document: localLogExportDocument,
            contentType: .zip,
            defaultFilename: localLogExportFilename
        ) { result in
            handleLocalLogExportCompletion(result)
        }
        .lavaConfirmationAlert { host in
            host.alert(
                disableTarget?.disableTitle.lavaLocalized ?? "",
                isPresented: disableConfirmationBinding,
                presenting: disableTarget
            ) { target in
                Button("Cancel", role: .cancel) {}
                Button(target.disableActionTitle.lavaLocalized, role: .destructive) {
                    disable(target)
                }
            } message: { target in
                Text(target.disableMessage.lavaLocalized)
            }
        }
        .lavaConfirmationAlert { host in
            host.alert(
                clearTarget?.clearTitle.lavaLocalized ?? "",
                isPresented: clearConfirmationBinding,
                presenting: clearTarget
            ) { target in
                Button("Cancel", role: .cancel) {}
                Button(target.clearActionTitle.lavaLocalized, role: .destructive) {
                    clear(target)
                }
            } message: { target in
                Text(target.clearMessage.lavaLocalized)
            }
        }
    }

    private var keepFilteringCountsBinding: Binding<Bool> {
        Binding {
            viewModel.configuration.keepFilteringCounts
        } set: { newValue in
            if newValue {
                performAppSettingsMutation(reason: "Edit Privacy & Data settings") {
                    reports.setKeepFilteringCounts(true)
                }
            } else {
                disableTarget = .filteringCounts
            }
        }
    }

    private var keepDomainHistoryBinding: Binding<Bool> {
        Binding {
            viewModel.configuration.keepDomainDiagnostics
        } set: { newValue in
            if newValue {
                performAppSettingsMutation(reason: "Edit Privacy & Data settings") {
                    reports.setKeepDomainDiagnostics(true)
                }
            } else {
                disableTarget = .domainHistory
            }
        }
    }

    private var keepNetworkActivityBinding: Binding<Bool> {
        Binding {
            viewModel.configuration.keepNetworkActivity
        } set: { newValue in
            if newValue {
                performAppSettingsMutation(reason: "Edit Privacy & Data settings") {
                    viewModel.setKeepNetworkActivity(true)
                }
            } else {
                disableTarget = .networkActivity
            }
        }
    }

    private var keepLavaGuardProgressBinding: Binding<Bool> {
        Binding {
            viewModel.configuration.keepLavaGuardProgress
        } set: { newValue in
            if newValue {
                performAppSettingsMutation(reason: "Edit Privacy & Data settings") {
                    viewModel.setKeepLavaGuardProgress(true)
                }
            } else {
                disableTarget = .lavaGuardProgress
            }
        }
    }

    private var disableConfirmationBinding: Binding<Bool> {
        Binding {
            disableTarget != nil
        } set: { isPresented in
            if !isPresented {
                disableTarget = nil
            }
        }
    }

    private var clearConfirmationBinding: Binding<Bool> {
        Binding {
            clearTarget != nil
        } set: { isPresented in
            if !isPresented {
                clearTarget = nil
            }
        }
    }

    private func disable(_ target: LocalLogSetting) {
        performAppSettingsMutation(reason: "Edit Privacy & Data settings") {
            switch target {
            case .filteringCounts:
                reports.setKeepFilteringCounts(false)
            case .domainHistory:
                reports.setKeepDomainDiagnostics(false)
            case .networkActivity:
                viewModel.setKeepNetworkActivity(false)
            case .lavaGuardProgress:
                viewModel.setKeepLavaGuardProgress(false)
            }
        }
    }

    private func localLogToggle(_ title: String, isOn: Binding<Bool>) -> some View {
        Toggle(title.lavaLocalized, isOn: isOn)
            .lavaRow()
    }

    private func localLogClearButton(_ target: LocalLogClearTarget) -> some View {
        Button(role: .destructive) {
            clearTarget = target
        } label: {
            SettingsActionRow(
                title: target.buttonTitle,
                iconTint: .red,
                titleTint: .red
            ) {
                Image(systemName: target.systemImage)
                    .font(.title3.weight(.semibold))
            }
            .lavaRow()
        }
        .buttonStyle(.plain)
    }

    private func clear(_ target: LocalLogClearTarget) {
        performAppSettingsMutation(reason: "Delete Local Logs") {
            let didClear: Bool
            switch target {
            case .filteringCounts:
                didClear = reports.clearLocalFilteringCounts()
            case .domainHistory:
                didClear = reports.clearDomainHistory()
            case .networkActivity:
                didClear = viewModel.clearNetworkActivityLog()
            case .lavaGuardProgress:
                didClear = viewModel.clearLavaGuardProgress()
            case .all:
                didClear = reports.clearAllLocalLogs()
            }
            // Rows clear in place with no on-screen confirmation, so announce completion for
            // VoiceOver — but ONLY when the clear durably persisted. The VM catches write failures
            // internally (surfacing an error banner + failure haptic) rather than throwing, so an
            // unconditional announcement would say "… cleared" even on a failed write. On failure
            // the error banner + haptic already convey the outcome.
            if didClear {
                LavaAccessibilityAnnouncer.announce(target.clearedConfirmation.lavaLocalized)
            }
        }
    }

    private func exportLocalLogs() {
        // Raise the flag SYNCHRONOUSLY (before authentication) so the export button disables
        // immediately and a second tap during the auth prompt can't queue an overlapping export
        // (Codex review, PR #341). The guard is belt-and-suspenders; the defer always clears the
        // flag, including when authentication is cancelled. Auth is inlined here (rather than via
        // performAppSettingsMutation) so the flag spans the whole auth+build, not just the build.
        guard !isExportingLocalLogs else { return }
        isExportingLocalLogs = true
        Task { @MainActor in
            defer { isExportingLocalLogs = false }
            guard await security.requireAuthentication(for: .appSettings, reason: "Export local logs") else {
                return
            }
            do {
                let archive = try await viewModel.makeLocalLogExportArchive()
                localLogExportFilename = archive.filename
                localLogExportDocument = LocalLogExportDocument(data: archive.data)
                localLogExportErrorMessage = nil
                isPresentingLocalLogExporter = true
            } catch {
                localLogExportErrorMessage = "Could not export local logs: \(error.localizedDescription)"
            }
        }
    }

    private func handleLocalLogExportCompletion(_ result: Result<URL, Error>) {
        localLogExportDocument = nil

        if case .failure(let error) = result {
            let nsError = error as NSError
            guard !(nsError.domain == NSCocoaErrorDomain && nsError.code == NSUserCancelledError) else {
                return
            }

            localLogExportErrorMessage = "Could not save local logs: \(error.localizedDescription)"
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
}

struct SecuritySettingsView: View {
    @EnvironmentObject private var viewModel: AppViewModel
    @EnvironmentObject private var security: SecurityController
    @State private var isShowingPasscodeSetup = false

    var body: some View {
        SettingsSubpageContent(
            title: "Security",
            tier: .calm,
            intro: LavaInfoPanel(
                title: "Lock Lava with a passcode",
                description: "Add a passcode or Face ID so only you can change Lava. Pick which screens ask for it below.",
                systemImage: "lock.fill"
            )
        ) {
            LavaSectionGroup("Authentication method") {
                LavaCondensedList {
                    Toggle("Passcode", isOn: passcodeBinding)
                        .lavaRow()

                    if security.shouldShowBiometricToggle {
                        LavaCondensedDivider()

                        Toggle(security.biometricToggleTitle.lavaLocalized, isOn: biometricBinding)
                            .lavaRow()
                            .disabled(!security.canEnableBiometrics)
                    }
                }
                .font(.headline)
                .tint(LavaStyle.safeGreen)
            }

            LavaSectionGroup(
                "Use authentication for",
                footer: "These switches turn on after you set a passcode or Face ID above. Each one decides which screen asks before it lets you in."
            ) {
                LavaCondensedList {
                    ForEach(Array(authenticationSurfaces.enumerated()), id: \.offset) { index, item in
                        securitySurfaceToggle(item.title, surface: item.surface)

                        if index < authenticationSurfaces.count - 1 {
                            LavaCondensedDivider()
                        }
                    }
                }
                .disabled(!security.hasAuthenticationMethod)
                .opacity(security.hasAuthenticationMethod ? 1 : 0.45)
            }

            if let statusMessage = security.statusMessage {
                Text(statusMessage.lavaLocalized)
                    .lavaQuietNoteText()
            }
        }
        .fullScreenCover(isPresented: $isShowingPasscodeSetup) {
            SecurityPasscodeSetupView()
                .environmentObject(security)
        }
    }

    private var passcodeBinding: Binding<Bool> {
        Binding {
            security.isPasscodeEnabled
        } set: { isEnabled in
            if isEnabled {
                isShowingPasscodeSetup = true
            } else {
                Task {
                    guard await security.requirePasscodeAuthentication(reason: "Turn off Security passcode") else {
                        return
                    }

                    security.disablePasscode()
                }
            }
        }
    }

    private var biometricBinding: Binding<Bool> {
        Binding {
            security.isBiometricEnabled
        } set: { isEnabled in
            Task {
                if isEnabled {
                    await security.setBiometricEnabled(true)
                    return
                }

                guard await security.requireBiometricAuthentication(reason: "Turn off %@".lavaLocalizedFormat(security.biometricToggleTitle)) else {
                    return
                }

                await security.setBiometricEnabled(false)
            }
        }
    }

    private var authenticationSurfaces: [(title: String, surface: SecurityProtectedSurface)] {
        [
            ("App Unlock", .appUnlock),
            ("Turn on/off Lava", .protectionControl),
            ("Pause Lava", .protectionPause),
            ("Update domains and lists", .filterEditing),
            ("View Activities", .activityViewing),
            ("Update App Settings", .appSettings),
        ]
    }

    private func securitySurfaceToggle(_ title: String, surface: SecurityProtectedSurface) -> some View {
        Toggle(title.lavaLocalized, isOn: Binding {
            security.hasAuthenticationMethod && security.isProtected(surface)
        } set: { isEnabled in
            guard security.hasAuthenticationMethod else {
                return
            }

            security.setProtection(isEnabled, for: surface)
            if surface == .protectionPause {
                viewModel.reconcileLiveActivity()
            }
        })
        .font(.headline)
        .tint(LavaStyle.safeGreen)
        .lavaRow()
    }
}

private enum SecurityPasscodeSetupPhase {
    case enter
    case confirm

    var title: String {
        switch self {
        case .enter:
            return "Set Passcode"
        case .confirm:
            return "Confirm Passcode"
        }
    }

    var subtitle: String {
        switch self {
        case .enter:
            return "Enter a 4-digit code for Lava"
        case .confirm:
            return "Enter it again to confirm"
        }
    }
}

private struct SecurityPasscodeSetupView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var security: SecurityController
    @State private var phase: SecurityPasscodeSetupPhase = .enter
    @State private var firstCode = ""
    @State private var code = ""
    @State private var message: String?
    @State private var isPasscodeFieldFocused = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 28) {
                Spacer()

                Image(systemName: "lock.shield.fill")
                    .font(.system(size: LavaIconSize.hero, weight: .semibold))
                    .foregroundStyle(LavaStyle.safeGreen)

                VStack(spacing: 8) {
                    Text(phase.title.lavaLocalized)
                        .font(.title.bold())
                    Text(phase.subtitle.lavaLocalized)
                        .lavaSupportingText()
                        .multilineTextAlignment(.center)
                }

                SecurityPasscodeDigitsView(code: code)

                if let message {
                    Text(message.lavaLocalized)
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.red)
                }

                SecurityHiddenPasscodeField(code: $code, isFocused: $isPasscodeFieldFocused)
                    .frame(width: 1, height: 1)
                    .opacity(0.01)
                    .onChange(of: code) { _, newValue in
                        handleCodeChange(newValue)
                    }

                Spacer()
            }
            .padding(24)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(LavaStyle.groupedBackground.ignoresSafeArea())
            .navigationTitle("Passcode")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    NativeToolbarIconButton(systemName: "xmark", accessibilityLabel: "Cancel", role: .cancel, action: dismiss.callAsFunction)
                }
            }
            .task {
                await focusPasscodeField()
            }
            .onTapGesture {
                isPasscodeFieldFocused = true
            }
        }
    }

    @MainActor
    private func focusPasscodeField() async {
        isPasscodeFieldFocused = false
        try? await Task.sleep(nanoseconds: 200_000_000)
        isPasscodeFieldFocused = true
    }

    private func handleCodeChange(_ value: String) {
        let filtered = String(value.filter(\.isNumber).prefix(4))
        if filtered != value {
            code = filtered
            return
        }

        guard filtered.count == 4 else {
            return
        }

        switch phase {
        case .enter:
            firstCode = filtered
            code = ""
            message = nil
            phase = .confirm
        case .confirm:
            guard filtered == firstCode else {
                message = "Passcodes did not match"
                phase = .enter
                firstCode = ""
                code = ""
                return
            }

            do {
                try security.setPasscode(filtered)
                dismiss()
            } catch {
                message = error.localizedDescription
                phase = .enter
                firstCode = ""
                code = ""
            }
        }
    }
}

private struct ExportLocalLogsRow: View {
    var body: some View {
        HStack(spacing: 12) {
            Text("Export Local Logs".lavaLocalized)
                .font(.headline)
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 0)

            Image(systemName: "square.and.arrow.up")
                .font(.headline.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .contentShape(Rectangle())
    }
}

private enum LocalLogSetting: Identifiable {
    case filteringCounts
    case domainHistory
    case networkActivity
    case lavaGuardProgress

    var id: String {
        switch self {
        case .filteringCounts:
            return "filtering-counts"
        case .domainHistory:
            return "domain-history"
        case .networkActivity:
            return "network-activity"
        case .lavaGuardProgress:
            return "lava-guard-progress"
        }
    }

    var disableTitle: String {
        switch self {
        case .filteringCounts:
            return "Turn off local filtering counts?"
        case .domainHistory:
            return "Turn off local domain history?"
        case .networkActivity:
            return "Turn off local network activity?"
        case .lavaGuardProgress:
            return "Turn off Lava Guard progress?"
        }
    }

    var disableActionTitle: String {
        switch self {
        case .filteringCounts:
            return "Turn Off and Clear Counts"
        case .domainHistory:
            return "Turn Off and Clear History"
        case .networkActivity:
            return "Turn Off and Clear Activity"
        case .lavaGuardProgress:
            return "Turn Off and Clear Progress"
        }
    }

    var disableMessage: String {
        switch self {
        case .filteringCounts:
            return "Saved filtering counts will be cleared and new allowed, blocked, and local protection uptime counts will not be saved."
        case .domainHistory:
            return "Saved domain names will be cleared and new domain names will not be saved."
        case .networkActivity:
            return "Saved network activity entries will be cleared and new network activity entries will not be saved."
        case .lavaGuardProgress:
            return "Saved Lava Guard progress will be cleared and new Lava Guard progress will not be saved."
        }
    }
}

private enum LocalLogClearTarget: Identifiable {
    case filteringCounts
    case domainHistory
    case networkActivity
    case lavaGuardProgress
    case all

    var id: String {
        switch self {
        case .filteringCounts:
            return "filtering-counts"
        case .domainHistory:
            return "domain-history"
        case .networkActivity:
            return "network-activity"
        case .lavaGuardProgress:
            return "lava-guard-progress"
        case .all:
            return "all"
        }
    }

    var systemImage: String {
        "trash"
    }

    var buttonTitle: String {
        switch self {
        case .filteringCounts:
            return "Clear filtering counts"
        case .domainHistory:
            return "Clear domain history"
        case .networkActivity:
            return "Clear network activity"
        case .lavaGuardProgress:
            return "Clear Lava Guard progress"
        case .all:
            return "Clear all logs"
        }
    }

    var clearTitle: String {
        switch self {
        case .filteringCounts:
            return "Clear filtering counts?"
        case .domainHistory:
            return "Clear domain history?"
        case .networkActivity:
            return "Clear network activity?"
        case .lavaGuardProgress:
            return "Clear Lava Guard progress?"
        case .all:
            return "Clear all logs?"
        }
    }

    var clearActionTitle: String {
        switch self {
        case .filteringCounts:
            return "Clear Counts"
        case .domainHistory:
            return "Clear History"
        case .networkActivity:
            return "Clear Activity"
        case .lavaGuardProgress:
            return "Clear Progress"
        case .all:
            return "Clear All Logs"
        }
    }

    var clearMessage: String {
        switch self {
        case .filteringCounts:
            return "This removes saved allowed, blocked, and local protection uptime counts from this phone."
        case .domainHistory:
            return "This removes saved domain rows from this phone. Filtering counts and network activity are unchanged."
        case .networkActivity:
            return "This removes saved network activity entries from this phone. Filtering counts and domain history are unchanged."
        case .lavaGuardProgress:
            return "This removes unearned Lava Guard progress from this phone. Earned Lava Guards stay unlocked."
        case .all:
            return "This removes saved filtering counts, domain history, network activity, and unearned Lava Guard progress from this phone."
        }
    }

    // Past-tense confirmation spoken to VoiceOver after the clear completes (assistive-nav
    // Task 6). The rows clear in place with no on-screen confirmation, so for a VoiceOver
    // user this announcement is the only completion signal.
    var clearedConfirmation: String {
        switch self {
        case .filteringCounts:
            return "Filtering counts cleared."
        case .domainHistory:
            return "Domain history cleared."
        case .networkActivity:
            return "Network activity cleared."
        case .lavaGuardProgress:
            return "Lava Guard progress cleared."
        case .all:
            return "All logs cleared."
        }
    }
}
