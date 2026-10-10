import SwiftUI
import Combine
import UIKit
import React
import React_RCTAppDelegate
import ReactAppDependencyProvider

/// Embeds only React presentation. RootView still owns app lifecycle and security.
struct LavaAppHost: UIViewControllerRepresentable {
    var onboardingPreview = false
    @Environment(\.dismiss) private var dismiss
    func makeUIViewController(context: Context) -> UIViewController { LavaAppViewController(onboardingPreview: onboardingPreview, onPreviewDismiss: { dismiss() }) }
    func updateUIViewController(_ controller: UIViewController, context: Context) {
        controller.traitOverrides.preferredContentSizeCategory = LavaAppBridge.shared.preferredContentSize
    }
    static func dismantleUIViewController(_ controller: UIViewController, coordinator: ()) {
        (controller as? LavaAppViewController)?.retirePreview()
    }
}

/// A second surface in the existing React runtime. Native import keeps its
/// staged payload and owns dismissal; purchase authority is still native.
struct LavaAppPlusContent: UIViewRepresentable {
    @MainActor static var makeRoot: ((String) -> UIView?)?
    let context: String
    func makeUIView(context: Context) -> UIView { Self.makeRoot?(self.context) ?? UIView() }
    func updateUIView(_ view: UIView, context: Context) {}
    static func dismantleUIView(_ view: UIView, coordinator: ()) { (view as? LavaAppReactSurface)?.retire() }
}

/// Bounded RN body in the same runtime and UIKit modal owner as native flows.
/// Its independent command port can complete a parent command awaiting dismissal.
struct LavaAppForegroundContent: UIViewRepresentable {
    @MainActor static var makeRoot: ((String) -> UIView?)?
    let id: String
    func makeUIView(context: Context) -> UIView { Self.makeRoot?(id) ?? UIView() }
    func updateUIView(_ view: UIView, context: Context) {}
    static func dismantleUIView(_ view: UIView, coordinator: ()) { (view as? LavaAppReactSurface)?.retire() }
}

@MainActor
private final class LavaAppViewController: UIViewController {
    private let onboardingPreview: Bool
    private let onPreviewDismiss: () -> Void
    private var onboardingID: String?
    init(onboardingPreview: Bool, onPreviewDismiss: @escaping () -> Void) { self.onboardingPreview = onboardingPreview; self.onPreviewDismiss = onPreviewDismiss; super.init(nibName: nil, bundle: nil) }
    required init?(coder: NSCoder) { nil }
    func retirePreview() {
        reactSurface?.retire()
        if onboardingPreview, let onboardingID { LavaAppBridge.shared.endOnboarding(onboardingID) }
    }
    private var reactSurface: LavaAppReactSurface?
    private var exportDirectory: URL?
    private var exportSubscription: AnyCancellable?
    private let preparationFlow = LavaAppNativeFlow(name: "preparation")
    private var preparationSubscription: AnyCancellable?
    private var customizationSubscription: AnyCancellable?
    private var flowSubscription: AnyCancellable?
    private var securitySubscription: AnyCancellable?
    private var stagingSubscription: AnyCancellable?
    private var feedbackDraftSubscription: AnyCancellable?
    private var foregroundDraftSubscription: AnyCancellable?
    private var bootstrapSubscriptions = Set<AnyCancellable>()
    private var onboardingChromeObserver: String?
    private weak var onboardingChromeController: UIViewController?
    private weak var presentedFlow: LavaAppFlowController?
    private var presentedFlowID: UUID?
    private var isChangingFlow = false
    private let securityWindow = LavaAppSecurityWindow()
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        if !onboardingPreview, let scene = view.window?.windowScene { securityWindow.attach(to: scene) }
        updateOnboardingChrome()
    }
    private var factory: RCTReactNativeFactory?
    private var factoryDelegate: LavaAppReactDelegate?
    override func viewDidLoad() {
        super.viewDidLoad()
        LavaAppBridge.shared.attach()
        onboardingChromeObserver = LavaAppBridge.shared.observe { [weak self] _ in
            Task { @MainActor [weak self] in self?.updateOnboardingChrome() }
        }
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
        foregroundDraftSubscription = LavaAppBridge.shared.$foregroundDraftIsDirty.sink { [weak self] _ in
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
    deinit {
        if let token = onboardingChromeObserver {
            Task { @MainActor in LavaAppBridge.shared.removeObserver(token) }
        }
    }
    /// Over-full-screen setup retains the measured Guard underneath. UIKit
    /// requires this explicit flag before that modal can own its status bar.
    private func updateOnboardingChrome() {
        guard LavaAppBridge.shared.onboardingVisit != nil else {
            onboardingChromeController?.modalPresentationCapturesStatusBarAppearance = false
            onboardingChromeController?.setNeedsStatusBarAppearanceUpdate()
            onboardingChromeController = nil
            return
        }
        guard let root = view.window?.rootViewController else { return }
        func presented(in controller: UIViewController) -> UIViewController? {
            if let next = controller.presentedViewController { return presented(in: next) ?? next }
            for child in controller.children.reversed() { if let next = presented(in: child) { return next } }
            return nil
        }
        func containsSetup(_ view: UIView) -> Bool {
            view.accessibilityIdentifier == "onboarding.surface" || view.subviews.contains(where: containsSetup)
        }
        guard let controller = presented(in: root), controller.modalPresentationStyle == .overFullScreen,
              containsSetup(controller.view), !controller.modalPresentationCapturesStatusBarAppearance else { return }
        controller.modalPresentationCapturesStatusBarAppearance = true
        onboardingChromeController = controller
        controller.setNeedsStatusBarAppearanceUpdate()
        root.setNeedsStatusBarAppearanceUpdate()
    }
    private func mountReactRoot() {
        guard factory == nil else { return }
        let bridge = LavaAppBridge.shared
        // All-off launches hand React a real projection, never a temporary
        // inactive marker. Protected launches may mount their branded cover
        // immediately while the existing security owner authenticates.
        // pinned: RNOnlyAppSourceTests.testAllOffNativeBootstrapWaitsForAnAuthorizedProjectionBeforeCreatingReact
        guard bridge.security.backgroundPrivacyCoverRequired || bridge.canReadPresentation(.appUnlock) else { return }
        if onboardingPreview || !UserDefaults.standard.bool(forKey: "hasSeenLavaOnboarding") {
            let visit = bridge.beginOnboarding(mock: onboardingPreview, onDismiss: onboardingPreview ? onPreviewDismiss : nil)
            onboardingID = visit.id
        }
        let delegate = LavaAppReactDelegate()
        delegate.dependencyProvider = LavaAppDependencyProvider()
        let factory = RCTReactNativeFactory(delegate: delegate)
        LavaInstallAppComponentProvider()
        self.factoryDelegate = delegate
        self.factory = factory
        // A temporary QA preview cannot replace the retained main runtime's
        // factories. Its dismissal must leave subsequent native sheets usable.
        if !onboardingPreview {
            LavaAppPlusContent.makeRoot = { [weak factory] context in
                guard let factory else { return nil }
                return LavaAppReactSurface(factory: factory, properties: ["fullApp": true, "plusContext": context])
            }
            LavaAppForegroundContent.makeRoot = { [weak factory] id in
                guard let factory else { return nil }
                return LavaAppReactSurface(factory: factory, properties: ["fullApp": true, "foregroundContext": id])
            }
        }
        bootstrapSubscriptions.removeAll()
        let root = LavaAppReactSurface(factory: factory, properties: ["fullApp": true, "onboardingPreview": onboardingPreview])
        reactSurface = root
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
            if flow.name == "feedback" { bridge.retireFeedback(flow.id) }
            if flow.name == "vpnConfiguration", bridge.wireGuardEditorVisit?.id == flow.id {
                bridge.wireGuardEditorVisit?.retire(); bridge.wireGuardEditorVisit = nil
            }
            if flow.usesReactPresentation { bridge.foregroundDraftIsDirty = false }
            bridge.closingForegroundIDs.remove(flow.id)
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
        controller.onDismissAttempt = {
            guard bridge.flow?.id == flow.id, flow.usesReactPresentation else { return }
            bridge.foregroundDismissAttempt += 1; bridge.publish()
        }
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
        blocksInteractiveDismiss = blocksInteractiveDismiss || bridge.flow?.usesReactPresentation == true && bridge.foregroundDraftIsDirty
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
    var onDismissAttempt: (() -> Void)?
    private var completedDismissal = false
    private func completeDismissal() {
        guard !completedDismissal else { return }
        completedDismissal = true; onDismiss?()
    }
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        presentationController?.delegate = self
    }
    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        if isBeingDismissed || presentingViewController == nil { completeDismissal() }
    }
    func presentationControllerDidDismiss(_ presentationController: UIPresentationController) { completeDismissal() }
    func presentationControllerDidAttemptToDismiss(_ presentationController: UIPresentationController) { onDismissAttempt?() }
}
/// Each actual React surface participates in one native reveal. A mounted sheet
/// must commit too; the underlying Guard cannot reveal it prematurely.
private final class LavaAppReactSurface: UIView {
    private let presentationID = UUID().uuidString
    private var retired = false
    init(factory: RCTReactNativeFactory, properties: [String: Any]) {
        super.init(frame: .zero)
        let bridge = LavaAppBridge.shared
        bridge.mountPresentation(presentationID)
        var properties = properties
        properties["presentationID"] = presentationID
        properties["initialSnapshot"] = bridge.snapshot()
        // Public locale/type metrics prepare the covered scaffold in its actual
        // language even when the private snapshot is correctly withheld.
        properties["initialPresentation"] = bridge.presentationSnapshot()
        let root = factory.rootViewFactory.view(withModuleName: "LavaUIReview", initialProperties: properties)
        backgroundColor = UIColor(LavaStyle.groupedBackground)
        root.backgroundColor = backgroundColor
        root.translatesAutoresizingMaskIntoConstraints = false
        addSubview(root)
        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: leadingAnchor), root.trailingAnchor.constraint(equalTo: trailingAnchor),
            root.topAnchor.constraint(equalTo: topAnchor), root.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }
    required init?(coder: NSCoder) { nil }
    func retire() {
        guard !retired else { return }
        retired = true
        LavaAppBridge.shared.unmountPresentation(presentationID)
    }
    deinit {
        let id = presentationID
        Task { @MainActor in LavaAppBridge.shared.unmountPresentation(id) }
    }
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
    private var subscriptions = Set<AnyCancellable>()
    private let security = LavaProtectionShortcutRuntime.shared.security
    func attach(to scene: UIWindowScene) {
        guard window == nil else { return }
        let window = UIWindow(windowScene: scene)
        window.accessibilityIdentifier = "lava-security-window"
        window.windowLevel = .alert + 1
        let controller = UIHostingController(rootView: LavaAppSecuritySurface().environmentObject(security).environmentObject(LavaAppBridge.shared))
        controller.view.backgroundColor = UIColor(LavaStyle.groupedBackground)
        controller.view.accessibilityViewIsModal = true
        window.rootViewController = controller
        self.window = window
        for publisher in [security.objectWillChange, LavaAppBridge.shared.objectWillChange] {
            publisher.sink { [weak self] _ in
                Task { @MainActor [weak self] in self?.update() }
            }.store(in: &subscriptions)
        }
        update()
    }
    private func update() {
        guard let window else { return }
        let visible = security.isAppUnlockBlockingUI || security.isAppUnlockPrivacyMaskVisible || security.passcodeAuthenticationRequest != nil || LavaAppBridge.shared.isPresentationRevealPending
        if visible && window.isHidden {
            previousKeyWindow = window.windowScene?.windows.first(where: { $0.isKeyWindow })
            window.makeKeyAndVisible()
        } else if !visible && !window.isHidden {
            SecurityController.tracePresentation("presentation.revealed")
            window.isHidden = true
            previousKeyWindow?.makeKey()
        }
    }
}
private struct LavaAppSecuritySurface: View {
    @EnvironmentObject private var security: SecurityController
    @EnvironmentObject private var bridge: LavaAppBridge
    var body: some View {
        Group {
            if let request = security.passcodeAuthenticationRequest {
                SecurityPasscodeAuthenticationView(request: request).id(request.id)
            } else if security.isAppUnlockPrivacyMaskVisible || !security.isAppUnlockBlockingUI && bridge.isPresentationRevealPending {
                SecurityPrivacyMaskOverlay()
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
