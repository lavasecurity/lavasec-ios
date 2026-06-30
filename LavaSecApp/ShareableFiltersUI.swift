import SwiftUI
import LavaSecCore
@preconcurrency import AVFoundation
import CoreImage.CIFilterBuiltins
import UIKit

// MARK: - Import result

enum ShareableFilterImportResult: Equatable {
    case success(ruleCount: Int)
    case failure(message: String)
}

// MARK: - QR code generation

enum LavaQRCode {
    /// Renders `string` as a crisp (non-interpolated) QR image suitable for
    /// on-screen display. Returns `nil` only if Core Image cannot build the code.
    static func image(for string: String, scale: CGFloat = 12) -> UIImage? {
        let context = CIContext()
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(string.utf8)
        filter.correctionLevel = "M"

        guard let output = filter.outputImage else {
            return nil
        }

        let transformed = output.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        guard let cgImage = context.createCGImage(transformed, from: transformed.extent) else {
            return nil
        }

        return UIImage(cgImage: cgImage)
    }
}

// MARK: - Share my filters

/// Presents the current setup as a copyable code and a (security-masked) QR.
struct ShareFiltersSheet: View {
    /// The shareable code for the chosen filter (the picker computes it per filter).
    let code: String
    @Environment(\.dismiss) private var dismiss

    @State private var isQRRevealed = false
    @State private var didCopyCode = false

    var body: some View {
        NavigationStack {
            LavaSheetScaffold(spacing: 20) {
                VStack(alignment: .leading, spacing: 20) {
                    LavaInfoPanel(
                        title: "Only your block list is shared",
                        description: "For safety, a code carries just your blocklists and blocked domains. Your allowed exceptions never leave this device.",
                        systemImage: "lock.shield.fill",
                        tint: LavaStyle.safeGreen
                    )

                    qrCard(for: code)

                    codeCard(for: code)
                }
            }
            .navigationTitle("Share my filter".lavaLocalized)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    NativeToolbarIconButton(systemName: "xmark", accessibilityLabel: "Close", role: .close) {
                        dismiss()
                    }
                }
            }
            .lavaTier(.calm)
        }
    }

    @ViewBuilder
    private func qrCard(for code: String) -> some View {
        LavaPlainCard {
            // Generation returns nil when the setup is too large to fit a QR
            // (even compressed). Detect that up front and steer to the code
            // rather than presenting a broken/empty QR.
            if let qrImage = LavaQRCode.image(for: code) {
                VStack(spacing: 14) {
                    ZStack {
                        Image(uiImage: qrImage)
                            .interpolation(.none)
                            .resizable()
                            .scaledToFit()
                            .frame(width: 220, height: 220)
                            .padding(10)
                            .background(.white, in: RoundedRectangle(cornerRadius: 14))
                            .blur(radius: isQRRevealed ? 0 : 18)
                            .accessibilityHidden(!isQRRevealed)

                        if !isQRRevealed {
                            VStack(spacing: 12) {
                                Image(systemName: "eye.slash.fill")
                                    .font(.title2)
                                    .foregroundStyle(LavaStyle.secondaryText)

                                Button {
                                    withAnimation(.easeOut(duration: 0.2)) {
                                        isQRRevealed = true
                                    }
                                } label: {
                                    Text("Show the QR Code")
                                        .padding(.horizontal, 18)
                                }
                                .buttonStyle(LavaPanelActionButtonStyle())
                                .fixedSize()

                                // The privacy fine print lives inside the reveal
                                // panel, directly under the button, so it reads as
                                // a caption for the action rather than the card.
                                Text("Hidden for privacy. Reveal only when you're ready to share.")
                                    .lavaMetadataText()
                                    .multilineTextAlignment(.center)
                                    .frame(maxWidth: 196)
                            }
                            .padding(16)
                            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
                        }
                    }

                    if isQRRevealed {
                        Text("Point another phone's camera here to import.")
                            .lavaMetadataText()
                    }
                }
                .frame(maxWidth: .infinity)
            } else {
                VStack(spacing: 10) {
                    Image(systemName: "qrcode")
                        .font(.title)
                        .foregroundStyle(LavaStyle.secondaryText)
                    Text("This setup is too large for a QR code")
                        .font(.headline)
                        .foregroundStyle(LavaStyle.ink)
                    Text("Share the setup code below instead — it carries the same setup.")
                        .lavaMetadataText()
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
            }
        }
    }

    @ViewBuilder
    private func codeCard(for code: String) -> some View {
        LavaSectionGroup("Setup code", footer: "Anyone with this code can copy your blocklists and blocked sites. Share it only with people you trust.") {
            VStack(alignment: .leading, spacing: 12) {
                Text(code)
                    .font(.system(.footnote, design: .monospaced))
                    .foregroundStyle(LavaStyle.ink)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14)
                    .lavaSurface(.panel, cornerRadius: 14)

                Button {
                    UIPasteboard.general.string = code
                    ProtectionHapticFeedback.play(.selectionConfirmed)
                    withAnimation { didCopyCode = true }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
                        withAnimation { didCopyCode = false }
                    }
                } label: {
                    Label(
                        didCopyCode ? "Copied" : "Copy setup code",
                        systemImage: didCopyCode ? "checkmark" : "doc.on.doc"
                    )
                }
                .buttonStyle(LavaStandaloneActionButtonStyle())
            }
        }
    }
}

// MARK: - Import flow

/// How the import flow begins. Filters opens at the method chooser; onboarding
/// jumps straight to a method.
enum ImportFiltersStartMode {
    case chooseMethod
    case enterCode
    case scanCode
}

/// Self-contained import experience reused by Filters and onboarding. Manages
/// its own simple stage machine so the freeform code-entry screen can own its
/// chevron-back / skip chrome exactly as designed.
struct ImportFiltersFlow: View {
    let startMode: ImportFiltersStartMode
    var showsSkip: Bool = false
    /// Overrides "back" from the first method screen (used by onboarding to
    /// return to its own chooser instead of dismissing the whole sheet).
    var onRootBack: (() -> Void)? = nil
    var onSkip: (() -> Void)? = nil
    /// Called after a config is successfully applied (e.g. to finish onboarding).
    var onImported: (() -> Void)? = nil
    /// Whether the preview offers "Add as a new filter" (the additive Filters-tab flow). Onboarding
    /// passes `false`: the library is pre-seeded to the free cap there, so "add" can't apply — the
    /// import instead becomes the active filter ("Use this filter"), which is the first-run intent.
    var allowsAddingNewFilter: Bool = true
    /// Fresh-auth gate run before applying an import — replacing filters is a
    /// filter-editing action. Defaults to allow (onboarding's first-run flow has
    /// no protected surface); the Filters entry point supplies the real check.
    var authorizeImport: () async -> Bool = { true }

    @EnvironmentObject private var viewModel: AppViewModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var stage: Stage
    @State private var applyError: String?
    /// Add-as-new at the filter cap routes here for a FREE user (upgrade to get more).
    @State private var showingPaywall = false
    /// A Plus user already at the 10-filter cap can't upgrade their way past it, so they get an
    /// informational "Maximum filters reached" note instead of the paywall.
    @State private var showingMaxFilters = false
    /// Whether the next stage swap reads as a push or a pop, so the slide matches
    /// the direction of travel. Set by `go(to:)` from the stage ordering.
    @State private var navDirection: LavaFlowDirection = .forward

    init(
        startMode: ImportFiltersStartMode,
        showsSkip: Bool = false,
        allowsAddingNewFilter: Bool = true,
        onRootBack: (() -> Void)? = nil,
        onSkip: (() -> Void)? = nil,
        onImported: (() -> Void)? = nil,
        authorizeImport: @escaping () async -> Bool = { true }
    ) {
        self.startMode = startMode
        self.showsSkip = showsSkip
        self.allowsAddingNewFilter = allowsAddingNewFilter
        self.onRootBack = onRootBack
        self.onSkip = onSkip
        self.onImported = onImported
        self.authorizeImport = authorizeImport
        _stage = State(initialValue: Stage(startMode: startMode))
    }

    enum Stage: Equatable {
        case chooseMethod
        case enterCode
        case scanCode
        case confirm(ShareableFilterConfiguration)
        case nameNew(ShareableFilterConfiguration)
        case chooseReplace(ShareableFilterConfiguration)
        case applying(ShareableFilterConfiguration)

        init(startMode: ImportFiltersStartMode) {
            switch startMode {
            case .chooseMethod:
                self = .chooseMethod
            case .enterCode:
                self = .enterCode
            case .scanCode:
                self = .scanCode
            }
        }

        /// Stable identity for the page transition (the associated config doesn't
        /// change which page is on screen, so it's deliberately excluded).
        var transitionID: String {
            switch self {
            case .chooseMethod: "chooseMethod"
            case .enterCode: "enterCode"
            case .scanCode: "scanCode"
            case .confirm: "confirm"
            case .nameNew: "nameNew"
            case .chooseReplace: "chooseReplace"
            case .applying: "applying"
            }
        }

        /// Depth in the flow, so `go(to:)` can tell a push from a pop. Enter/scan
        /// share a depth — they're siblings off the chooser, never reached from
        /// one another.
        var order: Int {
            switch self {
            case .chooseMethod: 0
            case .enterCode, .scanCode: 1
            case .confirm: 2
            case .nameNew, .chooseReplace: 3
            case .applying: 4
            }
        }
    }

    var body: some View {
        // One NavigationStack hosts every stage so each step renders a native
        // navigation bar (title + back/skip toolbar items). The stage machine
        // swaps the stack's root content; back is driven by `stage`, not a push —
        // so the slide between stages is supplied here (a real push would give it
        // for free) to match the native page transitions elsewhere in the app.
        NavigationStack {
            ZStack {
                content
                    .lavaFlowTransition(
                        value: stage.transitionID,
                        direction: navDirection,
                        reduceMotion: reduceMotion
                    )
            }
            .background(LavaStyle.groupedBackground.ignoresSafeArea())
            .alert(
                "Couldn't import",
                isPresented: Binding(
                    get: { applyError != nil },
                    set: { if !$0 { applyError = nil } }
                )
            ) {
                Button("OK", role: .cancel) { applyError = nil }
            } message: {
                Text((applyError ?? "").lavaLocalized)
            }
            .sheet(isPresented: $showingPaywall) {
                LavaPlusUpgradeSheet()
            }
            .lavaConfirmationAlert { host in
                host.alert(
                    "Maximum filters reached".lavaLocalized,
                    isPresented: $showingMaxFilters
                ) {
                    Button("OK", role: .cancel) {}
                } message: {
                    Text("You can host up to %d filters. Delete one to add another.".lavaLocalizedFormat(viewModel.configuration.limits.maxFilters))
                }
            }
            .lavaTier(.calm)
        }
    }

    @ViewBuilder
    private var content: some View {
        switch stage {
        case .chooseMethod:
            ImportMethodChooserView(
                onEnterCode: { go(to: .enterCode) },
                onScanCode: { go(to: .scanCode) },
                onClose: { dismiss() }
            )
        case .enterCode:
            ImportCodeEntryView(
                showsSkip: showsSkip,
                onBack: { goBackFromMethod() },
                onSkip: { onSkip?() },
                onDecoded: { config in go(to: .confirm(config)) }
            )
        case .scanCode:
            ImportQRScannerView(
                showsSkip: showsSkip,
                onBack: { goBackFromMethod() },
                onSkip: { onSkip?() },
                onDecoded: { config in go(to: .confirm(config)) }
            )
        case .confirm(let config):
            ImportPreviewView(
                configuration: config,
                allowsAddingNewFilter: allowsAddingNewFilter,
                onBack: { go(to: Stage(startMode: startMode)) },
                onAddNew: {
                    // Additive default — name a brand-new filter. At the cap, a free user trips the
                    // paywall (upgrade for more); a Plus user (already subscribed) can't pay past the
                    // 10-filter cap, so they get the "Maximum filters reached" note instead.
                    if viewModel.canCreateFilter {
                        go(to: .nameNew(config))
                    } else if viewModel.configuration.hasLavaSecurityPlus {
                        showingMaxFilters = true
                    } else {
                        showingPaywall = true
                    }
                },
                onReplace: { go(to: .chooseReplace(config)) },
                onUseAsActiveFilter: { replaceActive(config) }
            )
        case .nameNew(let config):
            ImportNameNewFilterView(
                onBack: { go(to: .confirm(config)) },
                onAdd: { name in addNew(config, name: name) }
            )
        case .chooseReplace(let config):
            ImportChooseReplaceTargetView(
                onBack: { go(to: .confirm(config)) },
                onReplace: { filter in replace(config, into: filter) }
            )
        case .applying:
            ImportApplyingView()
        }
    }

    /// Moves to `newStage`, sliding in the direction implied by the stage depth
    /// (deeper = push, shallower = pop) so the transition matches a native
    /// navigation stack.
    private func go(to newStage: Stage) {
        navDirection = newStage.order >= stage.order ? .forward : .backward
        withAnimation(LavaFlowTransition.animation(reduceMotion: reduceMotion)) {
            stage = newStage
        }
    }

    private func goBackFromMethod() {
        if startMode == .chooseMethod {
            go(to: .chooseMethod)
        } else if let onRootBack {
            onRootBack()
        } else {
            dismiss()
        }
    }

    /// Add the imported setup as a brand-new filter (additive). Library-only — never touches the
    /// other filters or the live tunnel.
    private func addNew(_ config: ShareableFilterConfiguration, name: String) {
        go(to: .applying(config))
        Task { @MainActor in
            // Adding a filter is a filter-editing action — gate it behind the same fresh-auth
            // surface the manual edit/save flow uses.
            guard await authorizeImport() else {
                go(to: .nameNew(config))
                return
            }

            // Carry the EXACT plan the preview showed (same importPlan convenience) so what was
            // previewed is what's added — no per-destination re-plan that could diverge.
            let applied = viewModel.importPlan(for: config).applied
            if viewModel.addImportedShareableConfigurationAsNewFilter(applied, name: name) != nil {
                onImported?()
                dismiss()
            } else {
                applyError = "Couldn't add this filter. Please try again."
                go(to: .nameNew(config))
            }
        }
    }

    /// Onboarding path: make the import the ACTIVE filter (the library is pre-seeded to the cap
    /// there, so "add as new" can't apply). Goes through the full active-replace (prepare + reload).
    private func replaceActive(_ config: ShareableFilterConfiguration) {
        go(to: .applying(config))
        Task { @MainActor in
            guard await authorizeImport() else {
                go(to: .confirm(config))
                return
            }

            let applied = viewModel.importPlan(for: config).applied
            let result = await viewModel.replaceFilterWithImportedShareableConfiguration(
                id: viewModel.activeFilterID,
                applied
            )
            switch result {
            case .success:
                onImported?()
                dismiss()
            case .failure(let message):
                applyError = message
                go(to: .confirm(config))
            }
        }
    }

    /// Replace a chosen existing filter with the imported setup. Replacing the active filter
    /// reloads the tunnel; a non-active filter is replaced library-only.
    private func replace(_ config: ShareableFilterConfiguration, into filter: Filter) {
        go(to: .applying(config))
        Task { @MainActor in
            guard await authorizeImport() else {
                go(to: .chooseReplace(config))
                return
            }

            // Carry the EXACT plan the preview showed (worst-case fits any target's budget).
            let applied = viewModel.importPlan(for: config).applied
            let result = await viewModel.replaceFilterWithImportedShareableConfiguration(
                id: filter.id,
                applied
            )
            switch result {
            case .success:
                onImported?()
                dismiss()
            case .failure(let message):
                applyError = message
                go(to: .chooseReplace(config))
            }
        }
    }
}

// MARK: Method chooser

private struct ImportMethodChooserView: View {
    let onEnterCode: () -> Void
    let onScanCode: () -> Void
    let onClose: () -> Void

    var body: some View {
        LavaSheetScaffold(spacing: 18) {
            VStack(alignment: .leading, spacing: 14) {
                LavaInfoPanel(
                    title: "Import a shared filter",
                    description: "Bring in a setup someone shared. Add it as a new filter, or replace one of yours — you choose after previewing it.",
                    systemImage: "square.and.arrow.down"
                )

                ImportOptionRow(
                    systemImage: "qrcode.viewfinder",
                    title: "Scan a QR code",
                    subtitle: "Point your camera at the shared QR",
                    action: onScanCode
                )

                ImportOptionRow(
                    systemImage: "character.cursor.ibeam",
                    title: "Enter a code",
                    subtitle: "Paste or type the setup code",
                    action: onEnterCode
                )
            }
        }
        .navigationTitle("Import a filter".lavaLocalized)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                NativeToolbarIconButton(systemName: "xmark", accessibilityLabel: "Close", role: .close, action: onClose)
            }
        }
    }
}

struct ImportOptionRow: View {
    let systemImage: String
    let title: String
    let subtitle: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Image(systemName: systemImage)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(LavaStyle.safeGreen)
                    .frame(width: 38, height: 38)
                    .background(LavaStyle.softGreen, in: RoundedRectangle(cornerRadius: LavaSurface.iconBadgeCornerRadius))

                VStack(alignment: .leading, spacing: 3) {
                    Text(title.lavaLocalized)
                        .font(.headline)
                        .foregroundStyle(.primary)
                    Text(subtitle.lavaLocalized)
                        .lavaRowSubtitleText()
                }

                Spacer(minLength: 8)

                Image(systemName: "chevron.right")
                    .font(.headline.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .lavaSurface(.card)
            .contentShape(RoundedRectangle(cornerRadius: LavaSurface.cardCornerRadius, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}

// MARK: Freeform code entry

private struct ImportCodeEntryView: View {
    let showsSkip: Bool
    let onBack: () -> Void
    let onSkip: () -> Void
    let onDecoded: (ShareableFilterConfiguration) -> Void

    @State private var enteredCode = ""
    @State private var errorMessage: String?

    var body: some View {
        LavaSheetScaffold(spacing: 16) {
            VStack(alignment: .leading, spacing: 14) {
                LavaInfoPanel(
                    title: "Enter a setup code",
                    description: "Paste the setup code someone shared with you. It usually starts with \"LF1-\".",
                    systemImage: "character.cursor.ibeam"
                )

                LavaTextEditorInputRow(
                    title: "Setup code",
                    text: $enteredCode,
                    placeholder: "LF1-…",
                    minHeight: 180
                )
                .onChange(of: enteredCode) { _, _ in
                    errorMessage = nil
                }

                if let errorMessage {
                    Text(errorMessage.lavaLocalized)
                        .lavaQuietNoteText()
                        .foregroundStyle(LavaStyle.errorText)
                }
            }
        } footer: {
            Button("Continue") {
                continueTapped()
            }
            .buttonStyle(LavaStandaloneActionButtonStyle())
            .disabled(enteredCode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .navigationTitle("Enter a code".lavaLocalized)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            importFlowToolbar(showsSkip: showsSkip, onBack: onBack, onSkip: onSkip)
        }
    }

    private func continueTapped() {
        do {
            let config = try ShareableFilterConfiguration.decode(configurationCode: enteredCode)
            guard !config.isEmpty else {
                errorMessage = "This code doesn't contain a filter to import."
                return
            }
            onDecoded(config)
        } catch {
            errorMessage = ShareableFilterImportMessages.message(for: error)
        }
    }
}

// MARK: QR scanner

private struct ImportQRScannerView: View {
    let showsSkip: Bool
    let onBack: () -> Void
    let onSkip: () -> Void
    let onDecoded: (ShareableFilterConfiguration) -> Void

    @State private var errorMessage: String?
    @State private var hasHandledMatch = false
    @State private var cameraDenied = false
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        LavaSheetScaffold(spacing: 16) {
            VStack(alignment: .leading, spacing: 14) {
                if cameraDenied {
                    cameraDeniedCard
                } else {
                    QRCodeScannerRepresentable(
                        onScan: { handleScan($0) },
                        onCameraDenied: { cameraDenied = true }
                    )
                    .frame(height: 320)
                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .strokeBorder(LavaStyle.safeGreen.opacity(0.6), lineWidth: 2)
                    }

                    Text("Hold the shared QR code inside the frame.")
                        .lavaSupportingText()

                    if let errorMessage {
                        Text(errorMessage.lavaLocalized)
                            .lavaQuietNoteText()
                            .foregroundStyle(LavaStyle.errorText)
                    }
                }
            }
        }
        .navigationTitle("Scan a QR code".lavaLocalized)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            importFlowToolbar(showsSkip: showsSkip, onBack: onBack, onSkip: onSkip)
        }
        .onChange(of: scenePhase) { _, phase in
            // Returning from Settings (where the user may have granted access)
            // re-checks authorization so the scanner remounts instead of leaving
            // the user stuck on the recovery card.
            if phase == .active, cameraDenied,
               AVCaptureDevice.authorizationStatus(for: .video) == .authorized {
                cameraDenied = false
            }
        }
    }

    private var cameraDeniedCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Camera access is off", systemImage: "video.slash.fill")
                .font(.headline)
                .foregroundStyle(LavaStyle.ink)

            Text("Allow camera access in Settings to scan a QR code — or tap back and enter the code instead.")
                .lavaSupportingText()

            Button("Open Settings") {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            }
            .buttonStyle(LavaStandaloneActionButtonStyle())
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .lavaSurface(.card)
    }

    private func handleScan(_ scanned: String) {
        guard !hasHandledMatch else {
            return
        }

        do {
            let config = try ShareableFilterConfiguration.decode(configurationCode: scanned)
            guard !config.isEmpty else {
                errorMessage = "That QR code doesn't contain a filter to import."
                return
            }
            hasHandledMatch = true
            onDecoded(config)
        } catch {
            // Keep scanning; surface a hint but don't latch on a non-Lava code.
            errorMessage = ShareableFilterImportMessages.message(for: error)
        }
    }
}

struct QRCodeScannerRepresentable: UIViewControllerRepresentable {
    let onScan: (String) -> Void
    var onCameraDenied: () -> Void = {}

    func makeCoordinator() -> Coordinator {
        Coordinator(onScan: onScan)
    }

    func makeUIViewController(context: Context) -> QRScannerViewController {
        let controller = QRScannerViewController()
        controller.onScan = { context.coordinator.handle($0) }
        controller.onCameraAuthorizationDenied = onCameraDenied
        return controller
    }

    func updateUIViewController(_ uiViewController: QRScannerViewController, context: Context) {}

    final class Coordinator {
        let onScan: (String) -> Void
        private var lastValue: String?

        init(onScan: @escaping (String) -> Void) {
            self.onScan = onScan
        }

        func handle(_ value: String) {
            // Debounce repeated frames of the same code.
            guard value != lastValue else {
                return
            }
            lastValue = value
            onScan(value)
        }
    }
}

final class QRScannerViewController: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
    var onScan: ((String) -> Void)?
    var onCameraAuthorizationDenied: (() -> Void)?

    private let session = AVCaptureSession()
    private let sessionQueue = DispatchQueue(label: "app.lavasecurity.qrscanner.session")
    private var previewLayer: AVCaptureVideoPreviewLayer?
    private var captureDevice: AVCaptureDevice?

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        configureSession()

        // Tap anywhere to refocus — useful when the phone parks focus on the
        // wrong plane while the QR is held close.
        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTapToFocus(_:)))
        view.addGestureRecognizer(tap)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        previewLayer?.frame = view.bounds
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        registerAppActivityObservers()
        startSessionIfNeeded()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        unregisterAppActivityObservers()
        stopSession()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    /// Power the capture session down whenever the app leaves the active state —
    /// app switcher (`.inactive`) or background — and bring it back on return.
    /// `viewWillDisappear` only fires on real navigation, not on resign-active, so
    /// without this the camera keeps running behind the UIKit privacy shield in
    /// the app switcher even when App Unlock is off. Mirrors the lifecycle that
    /// installs `LavaPrivacyShield`; the restart re-checks camera authorization.
    private func registerAppActivityObservers() {
        let center = NotificationCenter.default
        center.addObserver(
            self,
            selector: #selector(appWillResignActive),
            name: UIApplication.willResignActiveNotification,
            object: nil
        )
        center.addObserver(
            self,
            selector: #selector(appDidBecomeActive),
            name: UIApplication.didBecomeActiveNotification,
            object: nil
        )
    }

    private func unregisterAppActivityObservers() {
        let center = NotificationCenter.default
        center.removeObserver(self, name: UIApplication.willResignActiveNotification, object: nil)
        center.removeObserver(self, name: UIApplication.didBecomeActiveNotification, object: nil)
    }

    @objc private func appWillResignActive() {
        stopSession()
    }

    @objc private func appDidBecomeActive() {
        startSessionIfNeeded()
    }

    private func stopSession() {
        nonisolated(unsafe) let session = self.session
        sessionQueue.async {
            if session.isRunning {
                session.stopRunning()
            }
        }
    }

    private func configureSession() {
        guard let device = Self.bestAvailableCaptureDevice(),
              let input = try? AVCaptureDeviceInput(device: device),
              session.canAddInput(input)
        else {
            return
        }

        session.beginConfiguration()

        // 1080p gives QR detection more pixels to work with for dense codes.
        if session.canSetSessionPreset(.hd1920x1080) {
            session.sessionPreset = .hd1920x1080
        }

        session.addInput(input)
        captureDevice = device
        configureContinuousFocus(for: device)

        let output = AVCaptureMetadataOutput()
        guard session.canAddOutput(output) else {
            session.commitConfiguration()
            return
        }
        session.addOutput(output)
        output.setMetadataObjectsDelegate(self, queue: .main)
        output.metadataObjectTypes = [.qr]

        session.commitConfiguration()

        let preview = AVCaptureVideoPreviewLayer(session: session)
        preview.videoGravity = .resizeAspectFill
        preview.frame = view.bounds
        view.layer.addSublayer(preview)
        previewLayer = preview
    }

    /// Prefer a multi-lens virtual device so the system can switch between lenses
    /// (e.g. to the ultra-wide) to keep a close-held QR in focus. Falls back to
    /// the plain wide-angle camera, then any default video device.
    private static func bestAvailableCaptureDevice() -> AVCaptureDevice? {
        let preferredTypes: [AVCaptureDevice.DeviceType] = [
            .builtInTripleCamera,
            .builtInDualWideCamera,
            .builtInDualCamera,
            .builtInWideAngleCamera
        ]
        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: preferredTypes,
            mediaType: .video,
            position: .back
        )
        for type in preferredTypes {
            if let match = discovery.devices.first(where: { $0.deviceType == type }) {
                return match
            }
        }
        return AVCaptureDevice.default(for: .video)
    }

    /// Continuous autofocus biased toward near subjects (QR codes are usually
    /// held close), with continuous auto-exposure.
    private func configureContinuousFocus(for device: AVCaptureDevice) {
        guard (try? device.lockForConfiguration()) != nil else {
            return
        }
        defer { device.unlockForConfiguration() }

        if device.isFocusModeSupported(.continuousAutoFocus) {
            device.focusMode = .continuousAutoFocus
        }
        if device.isAutoFocusRangeRestrictionSupported {
            device.autoFocusRangeRestriction = .near
        }
        if device.isExposureModeSupported(.continuousAutoExposure) {
            device.exposureMode = .continuousAutoExposure
        }
    }

    @objc private func handleTapToFocus(_ gesture: UITapGestureRecognizer) {
        guard let device = captureDevice, let previewLayer else {
            return
        }

        let layerPoint = gesture.location(in: view)
        let focusPoint = previewLayer.captureDevicePointConverted(fromLayerPoint: layerPoint)

        guard device.isFocusPointOfInterestSupported || device.isExposurePointOfInterestSupported,
              (try? device.lockForConfiguration()) != nil
        else {
            return
        }
        defer { device.unlockForConfiguration() }

        if device.isFocusPointOfInterestSupported {
            device.focusPointOfInterest = focusPoint
            device.focusMode = device.isFocusModeSupported(.continuousAutoFocus) ? .continuousAutoFocus : .autoFocus
        }
        if device.isExposurePointOfInterestSupported {
            device.exposurePointOfInterest = focusPoint
            device.exposureMode = device.isExposureModeSupported(.continuousAutoExposure) ? .continuousAutoExposure : .autoExpose
        }
    }

    private func startSessionIfNeeded() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            startRunning()
        case .notDetermined:
            Task { @MainActor [weak self] in
                let granted = await AVCaptureDevice.requestAccess(for: .video)
                guard let self else {
                    return
                }
                if granted {
                    self.startRunning()
                } else {
                    self.onCameraAuthorizationDenied?()
                }
            }
        default:
            // Denied or restricted — surface a recovery path instead of a black frame.
            onCameraAuthorizationDenied?()
        }
    }

    private func startRunning() {
        nonisolated(unsafe) let session = self.session
        sessionQueue.async {
            guard !session.isRunning else {
                return
            }
            session.startRunning()
        }
    }

    nonisolated func metadataOutput(
        _ output: AVCaptureMetadataOutput,
        didOutput metadataObjects: [AVMetadataObject],
        from connection: AVCaptureConnection
    ) {
        // AVCaptureMetadataOutputObjectsDelegate is nonisolated, but this is a
        // UIViewController (@MainActor), so the conformance must be nonisolated to
        // avoid the actor-isolation data-race error. AVFoundation delivers on the
        // main queue here (setMetadataObjectsDelegate(self, queue: .main)); hop to
        // the main actor to touch onScan, matching the Task { @MainActor } pattern
        // used elsewhere in this controller.
        guard let object = metadataObjects.first as? AVMetadataMachineReadableCodeObject,
              let value = object.stringValue
        else {
            return
        }
        Task { @MainActor [weak self] in
            self?.onScan?(value)
        }
    }
}

// MARK: Preview / confirm

private struct ImportPreviewView: View {
    @EnvironmentObject private var viewModel: AppViewModel

    let configuration: ShareableFilterConfiguration
    /// Additive (Filters tab) when true; single "Use this filter" → active replace when false
    /// (onboarding, where the library is pre-seeded to the cap).
    var allowsAddingNewFilter: Bool = true
    let onBack: () -> Void
    /// Add the imported setup as a brand-new filter (the additive default).
    let onAddNew: () -> Void
    /// Replace one of the user's existing filters with the imported setup.
    let onReplace: () -> Void
    /// Make the import the active filter directly (onboarding single-action path).
    var onUseAsActiveFilter: () -> Void = {}

    /// How many blocked domains to list before collapsing the rest into a
    /// "+N more" note, so a large import doesn't render an unbounded wall of rows.
    private static let blockedDomainPreviewLimit = 12

    var body: some View {
        let plan = viewModel.importPlan(for: configuration)
        // Break the planned subset down into the actual things being imported,
        // resolving curated IDs to their human names, rather than bare counts.
        let customIDs = Set(plan.applied.customBlocklists.map(\.id))
        let curatedNames = plan.applied.enabledBlocklistIDs
            .subtracting(customIDs)
            .map { viewModel.blocklistName(for: $0) }
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
        let customBlocklists = plan.applied.customBlocklists
            .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
        let blockedDomains = plan.applied.blockedDomains.sorted()
        let shownDomains = Array(blockedDomains.prefix(Self.blockedDomainPreviewLimit))
        let hiddenDomainCount = blockedDomains.count - shownDomains.count

        return LavaSheetScaffold(spacing: 18) {
            VStack(alignment: .leading, spacing: 16) {
                LavaInfoPanel(
                    title: "Import this filter",
                    description: "Add it as a new filter, or replace one of yours. Your allowed exceptions and DNS choice stay put.",
                    systemImage: "square.and.arrow.down"
                )

                if !curatedNames.isEmpty {
                    LavaSectionGroup("Curated blocklists") {
                        VStack(spacing: 10) {
                            ForEach(curatedNames, id: \.self) { name in
                                ImportContentRow(systemImage: "shield.lefthalf.filled", title: name)
                            }
                        }
                    }
                }

                if !customBlocklists.isEmpty {
                    LavaSectionGroup("Custom blocklists") {
                        VStack(spacing: 10) {
                            ForEach(customBlocklists, id: \.id) { source in
                                ImportContentRow(
                                    systemImage: "link",
                                    title: source.displayName,
                                    subtitle: source.sourceURL.host
                                )
                            }
                        }
                    }
                }

                if !blockedDomains.isEmpty {
                    LavaSectionGroup("Blocked domains") {
                        VStack(spacing: 10) {
                            ForEach(shownDomains, id: \.self) { domain in
                                ImportContentRow(
                                    systemImage: "hand.raised.fill",
                                    title: domain,
                                    monospacedTitle: true
                                )
                            }

                            if hiddenDomainCount > 0 {
                                Text("+\(hiddenDomainCount) more")
                                    .lavaQuietNoteText()
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                    }
                }

                if plan.hasUnsupportedEntries {
                    unsupportedSection(for: plan)
                }
            }
        } footer: {
            VStack(spacing: 10) {
                if allowsAddingNewFilter {
                    Button((plan.applied.isEmpty ? "Nothing to import" : "Add as a new filter").lavaLocalized) {
                        onAddNew()
                    }
                    .buttonStyle(LavaStandaloneActionButtonStyle())
                    .disabled(plan.applied.isEmpty)

                    if !plan.applied.isEmpty {
                        Button("Replace a filter instead") { onReplace() }
                            .font(.subheadline.weight(.medium))
                            .tint(LavaStyle.safeGreen)
                            .padding(.top, 2)
                    }
                } else {
                    // Onboarding: the import becomes the active filter (no add/replace choice).
                    Button((plan.applied.isEmpty ? "Nothing to import" : "Use this filter").lavaLocalized) {
                        onUseAsActiveFilter()
                    }
                    .buttonStyle(LavaStandaloneActionButtonStyle())
                    .disabled(plan.applied.isEmpty)
                }
            }
        }
        .navigationTitle("Review import".lavaLocalized)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            importFlowToolbar(showsSkip: false, onBack: onBack, onSkip: {})
        }
    }

    @ViewBuilder
    private func unsupportedSection(for plan: ShareableFilterImportPlan) -> some View {
        let unavailable = plan.droppedCount(of: .unavailableBlocklist)
        let upgrade = plan.droppedCount(of: .requiresUpgrade)
        let overLimit = plan.droppedCount(of: .exceedsLimit)
        let unsafe = plan.droppedCount(of: .unsafeSource)
        let overBudget = plan.droppedCount(of: .exceedsRuleBudget)

        LavaSectionGroup("Not imported on this device") {
            VStack(spacing: 10) {
                if unavailable > 0 {
                    ImportAlertRow(
                        title: (unavailable == 1 ? "%@ blocklist isn't available here" : "%@ blocklists aren't available here").lavaLocalizedFormat(unavailable.formatted())
                    )
                }
                if upgrade > 0 {
                    ImportAlertRow(
                        title: (upgrade == 1 ? "%@ custom blocklist needs Lava Security+" : "%@ custom blocklists need Lava Security+").lavaLocalizedFormat(upgrade.formatted())
                    )
                }
                if overLimit > 0 {
                    ImportAlertRow(
                        title: (overLimit == 1 ? "%@ blocked domain is over your plan's limit" : "%@ blocked domains are over your plan's limit").lavaLocalizedFormat(overLimit.formatted())
                    )
                }
                if unsafe > 0 {
                    ImportAlertRow(
                        title: (unsafe == 1 ? "%@ custom blocklist was skipped for safety" : "%@ custom blocklists were skipped for safety").lavaLocalizedFormat(unsafe.formatted())
                    )
                }
                if overBudget > 0 {
                    ImportAlertRow(
                        title: (overBudget == 1 ? "%@ blocklist didn't fit your plan's rule limit" : "%@ blocklists didn't fit your plan's rule limit").lavaLocalizedFormat(overBudget.formatted())
                    )
                }
            }
        }
    }
}

/// Alert-styled row calling out something that couldn't be imported.
private struct ImportAlertRow: View {
    let title: String

    var body: some View {
        LavaOverviewBannerRow(
            systemImage: "exclamationmark.triangle.fill",
            title: title,
            tint: LavaStyle.lavaOrange,
            background: LavaStyle.lavaOrangeSoft,
            allowsTitleWrapping: true
        )
    }
}

/// One concrete item in the import breakdown: a curated/custom blocklist by name
/// (optionally with its source host) or a single blocked domain.
private struct ImportContentRow: View {
    let systemImage: String
    let title: String
    var subtitle: String? = nil
    var monospacedTitle: Bool = false

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: systemImage)
                .font(.headline)
                .foregroundStyle(LavaStyle.safeGreen)
                .frame(width: 34, height: 34)
                .background(LavaStyle.softGreen, in: RoundedRectangle(cornerRadius: LavaSurface.iconBadgeCornerRadius))

            VStack(alignment: .leading, spacing: 2) {
                Text(monospacedTitle ? title : title.lavaLocalized)
                    .font(monospacedTitle ? .subheadline.monospaced() : .headline)
                    .foregroundStyle(LavaStyle.ink)
                    .lineLimit(1)
                    .truncationMode(.middle)

                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .lavaRowSubtitleText()
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }

            Spacer(minLength: 8)
        }
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(minHeight: 56)
        .lavaSurface(.panel, cornerRadius: 14)
    }
}

// MARK: Add-as-new (name) + Replace (picker) stages

/// Name a brand-new filter for an additive import. The name must be non-empty and not collide
/// with an existing filter (enforced at the model layer too).
private struct ImportNameNewFilterView: View {
    @EnvironmentObject private var viewModel: AppViewModel
    let onBack: () -> Void
    let onAdd: (String) -> Void

    @State private var name = ""

    private var trimmed: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var isDuplicate: Bool { !trimmed.isEmpty && !viewModel.isFilterNameAvailable(trimmed) }
    private var canAdd: Bool { !trimmed.isEmpty && !isDuplicate }

    var body: some View {
        LavaSheetScaffold(spacing: 16) {
            VStack(alignment: .leading, spacing: 14) {
                LavaInfoPanel(
                    title: "Name your new filter",
                    description: "This import is added as a new filter in your library — give it a name you'll recognize.",
                    systemImage: "square.and.pencil"
                )

                LavaSectionGroup("Filter name") {
                    TextField("Filter name".lavaLocalized, text: $name)
                        .textInputAutocapitalization(.words)
                        .autocorrectionDisabled()
                        .submitLabel(.done)
                        .onSubmit { if canAdd { onAdd(trimmed) } }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 12)
                        .lavaSurface(.panel, cornerRadius: 14)
                }

                if isDuplicate {
                    Text("You already have a filter with that name.".lavaLocalized)
                        .lavaQuietNoteText()
                        .foregroundStyle(LavaStyle.errorText)
                }
            }
        } footer: {
            Button("Add filter") { onAdd(trimmed) }
                .buttonStyle(LavaStandaloneActionButtonStyle())
                .disabled(!canAdd)
        }
        .navigationTitle("New filter".lavaLocalized)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            importFlowToolbar(showsSkip: false, onBack: onBack, onSkip: {})
        }
    }
}

/// Pick which existing filter the import should replace. Replacing the in-effect filter reloads
/// the tunnel; any other filter is replaced library-only. A frozen (lapsed-Plus) filter is
/// read-only and can't be a replace target.
private struct ImportChooseReplaceTargetView: View {
    @EnvironmentObject private var viewModel: AppViewModel
    let onBack: () -> Void
    let onReplace: (Filter) -> Void

    var body: some View {
        LavaSheetScaffold(spacing: 18) {
            VStack(alignment: .leading, spacing: 14) {
                LavaInfoPanel(
                    title: "Replace which filter?",
                    description: "The filter you pick keeps its name and allowed exceptions; its blocklists and blocked domains become the imported ones.",
                    systemImage: "arrow.triangle.2.circlepath"
                )

                LavaSectionGroup("Your filters") {
                    LavaCondensedList {
                        let filters = viewModel.filters
                        ForEach(filters) { filter in
                            ImportReplaceTargetRow(
                                name: filter.name,
                                summary: summary(for: filter),
                                isReplaceable: !viewModel.isFilterFrozen(filter.id)
                            ) {
                                onReplace(filter)
                            }

                            if filter.id != filters.last?.id {
                                LavaCondensedDivider()
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("Replace a filter".lavaLocalized)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            importFlowToolbar(showsSkip: false, onBack: onBack, onSkip: {})
        }
    }

    private func summary(for filter: Filter) -> String {
        if viewModel.isFilterFrozen(filter.id) {
            return "Locked".lavaLocalized
        }
        let rules = filter.isEmpty
            ? "Blocks nothing".lavaLocalized
            : "%@ rules".lavaLocalizedFormat(viewModel.filterRuleCount(for: filter).formatted())
        if filter.id == viewModel.activeFilterID {
            return "%1$@ · %2$@".lavaLocalizedFormat(rules, "In effect".lavaLocalized)
        }
        return rules
    }
}

/// One row in the import replace-target picker: name + summary, greyed and non-tappable when the
/// filter is frozen (read-only).
private struct ImportReplaceTargetRow: View {
    let name: String
    let summary: String
    let isReplaceable: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(name)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(isReplaceable ? LavaStyle.primaryText : LavaStyle.secondaryText)
                        .lineLimit(1)
                        .minimumScaleFactor(0.82)

                    Text(summary)
                        .lavaMetadataText()
                        .lineLimit(1)
                }

                Spacer(minLength: 6)

                if isReplaceable {
                    Image(systemName: "chevron.right")
                        .font(.headline.weight(.semibold))
                        .foregroundStyle(.tertiary)
                } else {
                    Image(systemName: "lock.fill")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(LavaStyle.secondaryText)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 9)
            .frame(minHeight: 64)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!isReplaceable)
        .opacity(isReplaceable ? 1 : 0.5)
    }
}

private struct ImportApplyingView: View {
    var body: some View {
        VStack(spacing: 16) {
            ProgressView()
                .controlSize(.large)
            Text("Applying filter…")
                .lavaSupportingText()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(LavaStyle.groupedBackground.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
    }
}

// MARK: Shared flow toolbar (native back chevron + optional skip)

// Builds @MainActor toolbar items (NativeToolbarIconButton) and forwards the
// callbacks into them, so the helper itself must be main-actor-isolated —
// otherwise Swift 6 flags sending `onBack`/`onSkip` from a nonisolated context
// into a @MainActor init as a data race. All callers are SwiftUI view bodies
// (already @MainActor). The "back" chevron drives the flow's own stage machine
// rather than a NavigationStack pop, so it's an explicit leading item.
@MainActor
@ToolbarContentBuilder
private func importFlowToolbar(
    showsSkip: Bool,
    onBack: @escaping () -> Void,
    onSkip: @escaping () -> Void
) -> some ToolbarContent {
    ToolbarItem(placement: .topBarLeading) {
        NativeToolbarIconButton(systemName: "chevron.left", accessibilityLabel: "Back", action: onBack)
    }

    if showsSkip {
        ToolbarItem(placement: .topBarTrailing) {
            Button("Skip", action: onSkip)
        }
    }
}

// MARK: Error copy

enum ShareableFilterImportMessages {
    static func message(for error: Error) -> String {
        guard let codeError = error as? ShareableFilterConfigurationCodeError else {
            return "That code couldn't be read. Double-check it and try again."
        }

        switch codeError {
        case .unrecognizedFormat:
            return "That doesn't look like a Lava filter code."
        case .integrityCheckFailed:
            return "This code looks edited or incomplete. Ask for a fresh one."
        case .unsupportedVersion:
            return "This code needs a newer version of Lava. Update the app and try again."
        case .malformedPayload:
            return "That code couldn't be read. Double-check it and try again."
        case .payloadTooLarge:
            return "This code is too large to import safely."
        }
    }
}
