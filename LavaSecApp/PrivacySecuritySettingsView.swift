import SwiftUI
import LavaSecKit
import UniformTypeIdentifiers

struct LocalLogExportDocument: FileDocument {
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

struct SecurityPasscodeSetupView: View {
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
                .lavaToolbarChrome()
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

enum LocalLogSetting: Identifiable {
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

enum LocalLogClearTarget: Identifiable {
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
            return "This removes saved allowed, blocked, and local protection uptime counts from this device."
        case .domainHistory:
            return "This removes saved domain rows from this device. Filtering counts and network activity are unchanged."
        case .networkActivity:
            return "This removes saved network activity entries from this device. Filtering counts and domain history are unchanged."
        case .lavaGuardProgress:
            return "This removes unearned Lava Guard progress from this device. Earned Lava Guards stay unlocked."
        case .all:
            return "This removes saved filtering counts, domain history, network activity, and unearned Lava Guard progress from this device."
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
