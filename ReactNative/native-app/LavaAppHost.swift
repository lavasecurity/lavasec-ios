import SwiftUI
import Combine
import UIKit
import React
import React_RCTAppDelegate
import ReactAppDependencyProvider

/// Embeds only React presentation. RootView still owns app lifecycle and security.
struct LavaAppHost: UIViewControllerRepresentable {
    var onboardingPreview = false
    func makeUIViewController(context: Context) -> UIViewController { LavaAppViewController(onboardingPreview: onboardingPreview) }
    func updateUIViewController(_ controller: UIViewController, context: Context) {
        controller.traitOverrides.preferredContentSizeCategory = LavaAppBridge.shared.preferredContentSize
    }
}

@MainActor
private final class LavaAppViewController: UIViewController {
    private let onboardingPreview: Bool
    init(onboardingPreview: Bool) { self.onboardingPreview = onboardingPreview; super.init(nibName: nil, bundle: nil) }
    required init?(coder: NSCoder) { nil }
    private var exportDirectory: URL?
    private var exportSubscription: AnyCancellable?
    private let preparationFlow = LavaAppNativeFlow(name: "preparation")
    private var preparationSubscription: AnyCancellable?
    private var customizationSubscription: AnyCancellable?
    private var flowSubscription: AnyCancellable?
    private var securitySubscription: AnyCancellable?
    private var stagingSubscription: AnyCancellable?
    private var feedbackDraftSubscription: AnyCancellable?
    private var bootstrapSubscriptions = Set<AnyCancellable>()
    private weak var presentedFlow: LavaAppFlowController?
    private var presentedFlowID: UUID?
    private var isChangingFlow = false
    private let securityWindow = LavaAppSecurityWindow()
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        if !onboardingPreview, let scene = view.window?.windowScene { securityWindow.attach(to: scene) }
    }
    private var factory: RCTReactNativeFactory?
    private var factoryDelegate: LavaAppReactDelegate?
    override func viewDidLoad() {
        super.viewDidLoad()
        LavaAppBridge.shared.attach()
        traitOverrides.preferredContentSizeCategory = LavaAppBridge.shared.preferredContentSize
        customizationSubscription = LavaAppBridge.shared.model.customization.objectWillChange.sink { [weak self] _ in
            Task { @MainActor [weak self] in self?.traitOverrides.preferredContentSizeCategory = LavaAppBridge.shared.preferredContentSize }
        }
        exportSubscription = LavaAppBridge.shared.$exporting.sink { [weak self] _ in
            Task { @MainActor [weak self] in self?.updateNativeFlow() }
        }
        flowSubscription = LavaAppBridge.shared.$flow.sink { [weak self] _ in
            Task { @MainActor [weak self] in self?.updateNativeFlow() }
        }
        preparationSubscription = LavaAppBridge.shared.model.filterDrafts.objectWillChange.sink { [weak self] _ in
            Task { @MainActor [weak self] in self?.updateNativeFlow() }
        }
        securitySubscription = LavaAppBridge.shared.security.objectWillChange.sink { [weak self] _ in
            Task { @MainActor [weak self] in self?.updateNativeFlow() }
        }
        stagingSubscription = LavaAppBridge.shared.model.objectWillChange.sink { [weak self] _ in
            Task { @MainActor [weak self] in self?.updateFlowModalState() }
        }
        feedbackDraftSubscription = LavaAppBridge.shared.$feedbackDraftIsDirty.sink { [weak self] _ in
            Task { @MainActor [weak self] in self?.updateFlowModalState() }
        }
        view.backgroundColor = UIColor(LavaStyle.groupedBackground)
        for notification in [UIApplication.didBecomeActiveNotification, UIApplication.protectedDataDidBecomeAvailableNotification] {
            NotificationCenter.default.publisher(for: notification).sink { [weak self] _ in
                Task { @MainActor [weak self] in self?.mountReactRoot() }
            }.store(in: &bootstrapSubscriptions)
        }
        // React's device-info startup reads window safe areas. Mount after this
        // SwiftUI layout pass so an onboarding overlay cannot re-enter its
        // dispatch_once initializer while UIKit is resolving the host geometry.
        DispatchQueue.main.async { [weak self] in self?.mountReactRoot() }
    }
    private func mountReactRoot() {
        guard factory == nil else { return }
        let bridge = LavaAppBridge.shared
        // All-off launches hand React a real projection, never a temporary
        // inactive marker. Protected launches may mount their branded cover
        // immediately while the existing security owner authenticates.
        // pinned: RNOnlyAppSourceTests.testAllOffNativeBootstrapWaitsForAnAuthorizedProjectionBeforeCreatingReact
        guard bridge.security.backgroundPrivacyCoverRequired || bridge.canReadPresentation(.appUnlock) else { return }
        let delegate = LavaAppReactDelegate()
        delegate.dependencyProvider = LavaAppDependencyProvider()
        let factory = RCTReactNativeFactory(delegate: delegate)
        LavaInstallAppComponentProvider()
        self.factoryDelegate = delegate
        self.factory = factory
        bootstrapSubscriptions.removeAll()
        let root = factory.rootViewFactory.view(withModuleName: "LavaUIReview", initialProperties: ["fullApp": true, "onboardingPreview": onboardingPreview, "initialSnapshot": LavaAppBridge.shared.snapshot()])
        root.accessibilityIdentifier = "lava.full-app"
        root.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(root)
        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: view.leadingAnchor), root.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            root.topAnchor.constraint(equalTo: view.topAnchor), root.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }
    private func updateNativeFlow() {
        guard !onboardingPreview, !isChangingFlow else { return }
        let bridge = LavaAppBridge.shared
        if bridge.exporting { presentExportIfNeeded(); return }
        let pendingFlow = bridge.model.isFilterPreparationScreenPresented ? preparationFlow : bridge.flow
        let withholdImport = pendingFlow?.isImport == true && (bridge.security.isAppUnlockBlockingUI || bridge.security.isAppUnlockPrivacyMaskVisible)
        let desiredFlow = withholdImport ? nil : pendingFlow
        if presentedFlowID == desiredFlow?.id { return }
        if let controller = presentedFlow, controller.presentingViewController != nil {
            isChangingFlow = true
            // Withholding is not cancellation. Retain the staged request so it
            // can create a fresh importer once App Unlock/privacy clears.
            if withholdImport && presentedFlowID == pendingFlow?.id { controller.onDismiss = nil }
            controller.dismiss(animated: !withholdImport) { [weak self] in
                self?.presentedFlow = nil
                self?.presentedFlowID = nil
                self?.isChangingFlow = false
                self?.updateNativeFlow()
            }
            return
        }
        guard let flow = desiredFlow, let root = view.window?.rootViewController else { return }
        var top = root
        while let presented = top.presentedViewController { top = presented }
        let m = bridge.model
        let content = LavaAppNativeFlowView(flow: flow)
            .environmentObject(m).environmentObject(m.catalog).environmentObject(m.filterDrafts)
            .environmentObject(m.backup).environmentObject(m.plus).environmentObject(m.account)
            .environmentObject(m.reports).environmentObject(m.customization).environmentObject(bridge.security)
            .preferredColorScheme(m.customization.preferredColorScheme)
            .lavaTextSizeOverride(m.customization.textSizeOverride)
            .tint(LavaStyle.safeGreen)
        let controller = LavaAppFlowController(rootView: AnyView(content))
        controller.onDismiss = { [weak self] in
            if bridge.flow?.id == flow.id { bridge.flow = nil }
            if flow.name == "feedback" { bridge.feedbackDraftIsDirty = false }
            if self?.presentedFlowID == flow.id { self?.presentedFlowID = nil; self?.presentedFlow = nil }
            flow.onDismiss?()
            bridge.publish()
        }
        controller.modalPresentationStyle = flow.name == "preparation" ? .fullScreen : .pageSheet
        if flow.name == "account", let sheet = controller.sheetPresentationController {
            // UIKit owns the effective detents of this hosted SwiftUI sheet.
            // Keep its growing/scrolling account content reachable at large text.
            sheet.detents = [.medium(), .large()]
            sheet.prefersGrabberVisible = true
        }
        if flow.name == "renameFilter", let sheet = controller.sheetPresentationController {
            sheet.detents = [.medium()]
            sheet.selectedDetentIdentifier = .medium
        }
        if flow.name == "deleteFilters", let sheet = controller.sheetPresentationController {
            sheet.detents = [.large()]
        }
        controller.isModalInPresentation = flow.name == "preparation"
        presentedFlow = controller
        presentedFlowID = flow.id
        top.present(controller, animated: true)
    }
    /// SwiftUI's `.interactiveDismissDisabled` is inert inside this hosted controller,
    /// so mirror Feedback's discard guard and VPN QA staging state into UIKit.
    private func updateFlowModalState() {
        let bridge = LavaAppBridge.shared
        guard let presentedFlow, bridge.flow?.id == presentedFlowID else { return }
        var blocksInteractiveDismiss = bridge.flow?.name == "feedback" && bridge.feedbackDraftIsDirty
        blocksInteractiveDismiss = blocksInteractiveDismiss || bridge.model.isStagingChainedUpstreamForQA
        presentedFlow.isModalInPresentation = blocksInteractiveDismiss
    }
    private func presentExportIfNeeded() {
        let bridge = LavaAppBridge.shared
        guard exportDirectory == nil, let document = bridge.exportDocument else { return }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("lava-local-log-export-\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            exportDirectory = directory
            let url = directory.appendingPathComponent(bridge.exportFilename)
            try document.data.write(to: url, options: [.atomic, .completeFileProtection])
            // Share only the ZIP. A text activity item becomes a second attachment in
            // destinations such as AirDrop; the disclosure stays on the Privacy page.
            ShareSheetPresenter.present(activityItems: [url]) { [weak self] outcome in
                switch outcome {
                case .completed:
                    LavaFeedbackCoordinator.shared.interaction(.succeeded, control: "logs.saved")
                case .failed(let error):
                    bridge.logExportError = "Could not save local logs: %@".lavaLocalizedFormat(error.localizedDescription)
                    LavaFeedbackCoordinator.shared.interaction(.failed, control: "logs.saved")
                case .unavailable:
                    bridge.logExportError = "Could not open the share sheet."
                case .cancelled:
                    break
                }
                self?.finishExport()
            }
        } catch {
            bridge.logExportError = "Could not save local logs: %@".lavaLocalizedFormat(error.localizedDescription)
            finishExport()
        }
    }
    private func finishExport() {
        if let exportDirectory {
            // Completion reports acceptance, not that the destination finished reading: AirDrop
            // and share extensions keep reading after the callback. Delay the removal.
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 5 * 60 * 1_000_000_000)
                try? FileManager.default.removeItem(at: exportDirectory)
            }
        }
        exportDirectory = nil
        LavaAppBridge.shared.exportDocument = nil
        LavaAppBridge.shared.exporting = false
        LavaAppBridge.shared.publish()
    }
}
private final class LavaAppFlowController: UIHostingController<AnyView>, UIAdaptivePresentationControllerDelegate {
    var onDismiss: (() -> Void)?
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        presentationController?.delegate = self
    }
    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        if isBeingDismissed || presentingViewController == nil { onDismiss?() }
    }
    func presentationControllerDidDismiss(_ presentationController: UIPresentationController) { onDismiss?() }
}
private final class LavaAppReactDelegate: RCTDefaultReactNativeFactoryDelegate {
    override func sourceURL(for bridge: RCTBridge) -> URL? { bundleURL() }
    override func bundleURL() -> URL? { Bundle.main.url(forResource: "LavaUIReview", withExtension: "js") }
}

/// RN navigation sheets are UIKit presentations above RootView. A scene-owned
/// security window keeps the existing lock and passcode surfaces above every
/// presentation, including an in-progress native backup or import flow.
@MainActor
private final class LavaAppSecurityWindow {
    private var window: UIWindow?
    private weak var previousKeyWindow: UIWindow?
    private var subscription: AnyCancellable?
    private let security = LavaProtectionShortcutRuntime.shared.security
    func attach(to scene: UIWindowScene) {
        guard window == nil else { return }
        let window = UIWindow(windowScene: scene)
        window.windowLevel = .alert + 1
        window.rootViewController = UIHostingController(rootView: LavaAppSecuritySurface().environmentObject(security))
        self.window = window
        subscription = security.objectWillChange.sink { [weak self] _ in
            Task { @MainActor [weak self] in self?.update() }
        }
        update()
    }
    private func update() {
        guard let window else { return }
        let visible = security.isAppUnlockBlockingUI || security.isAppUnlockPrivacyMaskVisible || security.passcodeAuthenticationRequest != nil
        if visible && window.isHidden {
            previousKeyWindow = window.windowScene?.windows.first(where: { $0.isKeyWindow })
            window.makeKeyAndVisible()
        } else if !visible && !window.isHidden {
            window.isHidden = true
            previousKeyWindow?.makeKey()
        }
    }
}
private struct LavaAppSecuritySurface: View {
    @EnvironmentObject private var security: SecurityController
    var body: some View {
        Group {
            if security.isAppUnlockPrivacyMaskVisible {
                SecurityPrivacyMaskOverlay()
            } else if let request = security.passcodeAuthenticationRequest {
                SecurityPasscodeAuthenticationView(request: request).id(request.id)
            } else {
                SecurityLockOverlay { Task { await security.authenticateAppUnlockIfNeeded() } }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(LavaStyle.groupedBackground.ignoresSafeArea())
        .tint(LavaStyle.safeGreen)
        .preferredColorScheme(LavaProtectionShortcutRuntime.shared.viewModel.customization.preferredColorScheme)
    }
}

private final class LavaAppDependencyProvider: RCTAppDependencyProvider {
    override func unstableModulesRequiringMainQueueSetup() -> [String] {
        // RN 0.87 codegen lists its example SampleTurboModule, but the packaged
        // CoreModulesPlugins does not supply it. Keep every real app/core module.
        super.unstableModulesRequiringMainQueueSetup().filter { $0 != "SampleTurboModule" }
    }
}
