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
    @EnvironmentObject private var viewModel: AppViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var isQRRevealed = false
    @State private var didCopyCode = false

    var body: some View {
        let code = viewModel.shareableFilterConfigurationCode

        return NavigationStack {
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
            .navigationTitle("Share my filters".lavaLocalized)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    NativeToolbarIconButton(systemName: "xmark", accessibilityLabel: "Close") {
                        dismiss()
                    }
                }
            }
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
                    Text("Share the config code below instead — it carries the same setup.")
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
        LavaSectionGroup("Config code") {
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
                    withAnimation { didCopyCode = true }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
                        withAnimation { didCopyCode = false }
                    }
                } label: {
                    Label(
                        didCopyCode ? "Copied" : "Copy config code",
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
    /// Fresh-auth gate run before applying an import — replacing filters is a
    /// filter-editing action. Defaults to allow (onboarding's first-run flow has
    /// no protected surface); the Filters entry point supplies the real check.
    var authorizeImport: () async -> Bool = { true }

    @EnvironmentObject private var viewModel: AppViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var stage: Stage
    @State private var applyError: String?

    init(
        startMode: ImportFiltersStartMode,
        showsSkip: Bool = false,
        onRootBack: (() -> Void)? = nil,
        onSkip: (() -> Void)? = nil,
        onImported: (() -> Void)? = nil,
        authorizeImport: @escaping () async -> Bool = { true }
    ) {
        self.startMode = startMode
        self.showsSkip = showsSkip
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
    }

    var body: some View {
        content
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
                Text(applyError ?? "")
            }
    }

    @ViewBuilder
    private var content: some View {
        switch stage {
        case .chooseMethod:
            ImportMethodChooserView(
                onEnterCode: { stage = .enterCode },
                onScanCode: { stage = .scanCode },
                onClose: { dismiss() }
            )
        case .enterCode:
            ImportCodeEntryView(
                showsSkip: showsSkip,
                onBack: { goBackFromMethod() },
                onSkip: { onSkip?() },
                onDecoded: { config in stage = .confirm(config) }
            )
        case .scanCode:
            ImportQRScannerView(
                showsSkip: showsSkip,
                onBack: { goBackFromMethod() },
                onSkip: { onSkip?() },
                onDecoded: { config in stage = .confirm(config) }
            )
        case .confirm(let config):
            ImportPreviewView(
                configuration: config,
                onBack: { stage = Stage(startMode: startMode) },
                onConfirm: { apply(config) }
            )
        case .applying:
            ImportApplyingView()
        }
    }

    private func goBackFromMethod() {
        if startMode == .chooseMethod {
            stage = .chooseMethod
        } else if let onRootBack {
            onRootBack()
        } else {
            dismiss()
        }
    }

    private func apply(_ config: ShareableFilterConfiguration) {
        let plan = viewModel.importPlan(for: config)
        stage = .applying(config)
        Task { @MainActor in
            // Replacing filters is a filter-editing action — gate it behind the
            // same fresh-auth surface the manual edit/save flow uses.
            guard await authorizeImport() else {
                stage = .confirm(config)
                return
            }

            let result = await viewModel.applyImportedShareableConfiguration(plan.applied)
            switch result {
            case .success:
                onImported?()
                dismiss()
            case .failure(let message):
                applyError = message
                stage = .confirm(config)
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
        NavigationStack {
            LavaSheetScaffold(spacing: 18) {
                VStack(alignment: .leading, spacing: 14) {
                    Text("Import a setup someone shared with you. This replaces your blocklists and blocked domains.")
                        .lavaSupportingText()

                    ImportOptionRow(
                        systemImage: "qrcode.viewfinder",
                        title: "Scan a QR code",
                        subtitle: "Point your camera at the shared QR",
                        action: onScanCode
                    )

                    ImportOptionRow(
                        systemImage: "character.cursor.ibeam",
                        title: "Enter a code",
                        subtitle: "Paste or type the config code",
                        action: onEnterCode
                    )
                }
            }
            .navigationTitle("Import filters".lavaLocalized)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    NativeToolbarIconButton(systemName: "xmark", accessibilityLabel: "Close", action: onClose)
                }
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
            importFlowHeader(
                title: "Enter a code",
                showsSkip: showsSkip,
                onBack: onBack,
                onSkip: onSkip
            )
        } content: {
            VStack(alignment: .leading, spacing: 14) {
                Text("Paste the config code that was shared with you. It usually starts with \"LF1-\".")
                    .lavaSupportingText()

                LavaTextEditorInputRow(
                    title: "Config code",
                    text: $enteredCode,
                    placeholder: "LF1-…",
                    minHeight: 180
                )
                .onChange(of: enteredCode) { _, _ in
                    errorMessage = nil
                }

                if let errorMessage {
                    Text(errorMessage)
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
    }

    private func continueTapped() {
        do {
            let config = try ShareableFilterConfiguration.decode(configurationCode: enteredCode)
            guard !config.isEmpty else {
                errorMessage = "This code doesn't contain any filters to import."
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
            importFlowHeader(
                title: "Scan a QR code",
                showsSkip: showsSkip,
                onBack: onBack,
                onSkip: onSkip
            )
        } content: {
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
                        Text(errorMessage)
                            .lavaQuietNoteText()
                            .foregroundStyle(LavaStyle.errorText)
                    }
                }
            }
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
                errorMessage = "That QR code doesn't contain any filters to import."
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
        startSessionIfNeeded()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
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
    let onBack: () -> Void
    let onConfirm: () -> Void

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
            importFlowHeader(
                title: "Review import",
                showsSkip: false,
                onBack: onBack,
                onSkip: {}
            )
        } content: {
            VStack(alignment: .leading, spacing: 16) {
                LavaInfoPanel(
                    title: "This overrides your lists",
                    description: "Importing replaces your blocklists and blocked domains. Your allowed exceptions and resolver stay as they are.",
                    systemImage: "exclamationmark.triangle.fill",
                    tint: LavaStyle.lavaOrange,
                    borderTint: LavaStyle.lavaOrange
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
            Button(plan.applied.isEmpty ? "Nothing to import" : "Replace my filters") {
                onConfirm()
            }
            .buttonStyle(LavaStandaloneActionButtonStyle())
            .disabled(plan.applied.isEmpty)
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
                        title: "\(unavailable) blocklist\(unavailable == 1 ? "" : "s") aren't available here"
                    )
                }
                if upgrade > 0 {
                    ImportAlertRow(
                        title: "\(upgrade) custom blocklist\(upgrade == 1 ? "" : "s") need Lava Security+"
                    )
                }
                if overLimit > 0 {
                    ImportAlertRow(
                        title: "\(overLimit) blocked domain\(overLimit == 1 ? "" : "s") over your plan's limit"
                    )
                }
                if unsafe > 0 {
                    ImportAlertRow(
                        title: "\(unsafe) custom blocklist\(unsafe == 1 ? "" : "s") were skipped for safety"
                    )
                }
                if overBudget > 0 {
                    ImportAlertRow(
                        title: "\(overBudget) blocklist\(overBudget == 1 ? "" : "s") didn't fit your plan's rule limit"
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

private struct ImportApplyingView: View {
    var body: some View {
        VStack(spacing: 16) {
            ProgressView()
                .controlSize(.large)
            Text("Applying filters…")
                .lavaSupportingText()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(LavaStyle.groupedBackground.ignoresSafeArea())
    }
}

// MARK: Shared flow header (chevron back + optional skip)

// Builds @MainActor UI (LavaToolbarIconButton) and forwards the callbacks into it,
// so the helper itself must be main-actor-isolated — otherwise Swift 6 flags
// sending `onBack`/`onSkip` from a nonisolated context into a @MainActor init as a
// data race. All callers are SwiftUI view bodies (already @MainActor).
@MainActor
@ViewBuilder
private func importFlowHeader(
    title: String,
    showsSkip: Bool,
    onBack: @escaping () -> Void,
    onSkip: @escaping () -> Void
) -> some View {
    HStack {
        LavaToolbarIconButton(systemName: "chevron.left", accessibilityLabel: "Back", action: onBack)

        Spacer()

        Text(title.lavaLocalized)
            .font(.headline)
            .foregroundStyle(LavaStyle.ink)

        Spacer()

        if showsSkip {
            Button("Skip", action: onSkip)
                .font(.headline)
                .foregroundStyle(LavaStyle.panelActionGreen)
                .frame(minWidth: 44, minHeight: 44)
        } else {
            Color.clear.frame(width: 44, height: 44)
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
