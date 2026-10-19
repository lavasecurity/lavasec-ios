import Combine
import SwiftUI
import UIKit
import LavaSecPresentation

/// RN describes a bounded system alert. SwiftUI supplies the same native alert
/// and tint environment used by the original flows, rather than a custom dialog.
@MainActor
private final class LavaFlowAlertModel: ObservableObject {
    @Published var isPresented = false
    var selected: ((String) -> Void)?
    var dismissed: (() -> Void)?

    var presentation: Binding<Bool> {
        Binding(get: { [weak self] in self?.isPresented ?? false }, set: { [weak self] value in
            self?.isPresented = value
            if !value {
                // A system button can clear the binding before its action runs.
                // Let that action supply its ID before treating this as dismissal.
                DispatchQueue.main.async { [weak self] in self?.dismissed?() }
            }
        })
    }
}

@MainActor
private struct LavaFlowAlertContent: View {
    @ObservedObject var model: LavaFlowAlertModel
    let title: String
    let message: String
    let tint: String
    let buttons: [[String: String]]
    let preferred: String?

    var body: some View {
        if tint == "confirmation" {
            Color.clear.lavaConfirmationAlert { host in
                host.alert(title, isPresented: model.presentation) { actions } message: { Text(message) }
            }
        } else {
            Color.clear.alert(title, isPresented: model.presentation) { actions } message: { Text(message) }
                .tint(LavaStyle.safeGreen)
        }
    }

    @ViewBuilder private var actions: some View {
        ForEach(buttons, id: \.self) { button in
            if preferred == button["id"] {
                action(button).keyboardShortcut(.defaultAction)
            } else {
                action(button)
            }
        }
    }
    private func action(_ button: [String: String]) -> some View {
        let role: ButtonRole? = button["role"] == "destructive" ? .destructive : button["role"] == "cancel" ? .cancel : nil
        return Button(button["title"] ?? "", role: role) { model.selected?(button["id"] ?? "") }
    }
}

/// A transparent system-alert host preserves the underlying RN surface's
/// appearance/lifetime. It never owns or dismisses an unrelated modal.
@MainActor
private final class LavaFlowAlertController: UIHostingController<AnyView> {
    var onDetached: (() -> Void)?
    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        if isBeingDismissed || presentingViewController == nil {
            DispatchQueue.main.async { [weak self] in self?.onDetached?() }
        }
    }
}

@MainActor
final class LavaAppFlowAlert: NSObject {
    let ticket: ScopedSystemAlertLifetime.Ticket
    private let controller: LavaFlowAlertController
    private let model: LavaFlowAlertModel
    private let admitted: () -> Bool
    private var completion: ((String?) -> Void)?
    private var subscriptions = Set<AnyCancellable>()
    private var resolving = false
    private var cancelled = false
    private var selection: String?
    private var dismissing = false
    private var detachmentWaiters: [CheckedContinuation<Void, Never>] = []

    init(ticket: ScopedSystemAlertLifetime.Ticket, title: String, message: String, tint: String,
         buttons: [[String: String]], preferred: String?, bridge: LavaAppBridge, admitted: @escaping () -> Bool) {
        self.ticket = ticket; self.admitted = admitted
        let model = LavaFlowAlertModel()
        self.model = model
        let content = LavaFlowAlertContent(model: model, title: title, message: message, tint: tint, buttons: buttons, preferred: preferred)
        controller = LavaFlowAlertController(rootView: AnyView(content
            .preferredColorScheme(bridge.model.customization.preferredColorScheme)
            .lavaTextSizeOverride(bridge.model.customization.textSizeOverride)))
        super.init()
        controller.modalPresentationStyle = .overFullScreen
        controller.view.backgroundColor = .clear
        controller.traitOverrides.preferredContentSizeCategory = bridge.preferredContentSize
        model.selected = { [weak self] in self?.resolve($0) }
        model.dismissed = { [weak self] in self?.resolve(nil) }
        controller.onDetached = { [weak self] in self?.finishIfDetached() }
        // Reuse existing owner/read admission after synchronous native changes.
        for publisher in [bridge.objectWillChange, bridge.security.objectWillChange, bridge.model.account.objectWillChange] {
            publisher.sink { [weak self] _ in Task { @MainActor [weak self] in self?.revalidate() } }.store(in: &subscriptions)
        }
        for name in [UIApplication.willResignActiveNotification, UIApplication.protectedDataWillBecomeUnavailableNotification] {
            NotificationCenter.default.publisher(for: name).sink { [weak self] _ in
                MainActor.assumeIsolated { self?.cancel() }
            }.store(in: &subscriptions)
        }
    }

    func present(from presenter: UIViewController, completion: @escaping (String?) -> Void) {
        self.completion = completion
        guard !cancelled, admitted(), presenter.view.window != nil, !presenter.isBeingDismissed else { cancel(); return }
        // overFullScreen keeps the underlying flow mounted; no visual transition
        // is introduced around the system alert's own presentation animation.
        controller.overrideUserInterfaceStyle = presenter.traitCollection.userInterfaceStyle
        presenter.present(controller, animated: false) { [weak self] in
            guard let self, self.completion != nil else { return }
            guard !self.cancelled, self.admitted(), self.controller.view.window != nil else { self.cancel(); return }
            self.model.isPresented = true
        }
        // Reject an unmounted host or a SwiftUI alert that never appeared. The
        // check uses only this host's public presentation ownership.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            guard let self, self.completion != nil, !self.resolving else { return }
            if self.controller.presentingViewController == nil || self.controller.view.window == nil || self.controller.presentedViewController == nil {
                self.cancel()
            }
        }
    }
    private func revalidate() { if !admitted() { cancel() } }
    func cancel() {
        // Privacy/retirement can revoke a choice while its animation finishes.
        // A later admission change must never resurrect that selection.
        cancelled = true; selection = nil
        if !resolving { resolve(nil) } else { dismissOwnedHost(animated: false) }
    }
    func cancelAndWaitForDetachment() async {
        cancel()
        if controller.presentingViewController == nil, controller.viewIfLoaded?.window == nil {
            finishIfDetached()
            return
        }
        // More than one replacement can wait on the same old host. None may
        // discover a presenter until UIKit has removed that exact host and child.
        await withCheckedContinuation { detachmentWaiters.append($0) }
    }
    private func resolve(_ value: String?) {
        guard completion != nil, !resolving else { return }
        resolving = true
        selection = !cancelled && admitted() ? value : nil
        model.isPresented = false
        DispatchQueue.main.async { [weak self] in self?.dismissOwnedHost(animated: value != nil) }
    }
    private func dismissOwnedHost(animated: Bool) {
        guard completion != nil, !dismissing else { return }
        // Let an in-flight presentation or the system button's own dismissal
        // finish before dismissing the transparent host that contains it.
        let transition = controller.isBeingPresented ? controller.transitionCoordinator
            : controller.presentedViewController.flatMap { $0.isBeingDismissed ? $0.transitionCoordinator : nil }
        if let transition, transition.animate(alongsideTransition: nil, completion: { [weak self] _ in
            self?.dismissOwnedHost(animated: animated)
        }) { return }
        guard let owner = controller.presentingViewController else { finishIfDetached(); return }
        // Dismissing on the host could dismiss only its presented alert. Ask
        // the exact verified owner to retire this host and its child together.
        guard owner.presentedViewController === controller else { return }
        dismissing = true
        owner.dismiss(animated: animated) { [weak self] in self?.finishIfDetached() }
    }
    private func finishIfDetached() {
        guard controller.presentingViewController == nil, controller.viewIfLoaded?.window == nil else { return }
        // Completion is after actual dismissal, so an admitted follow-up may
        // immediately present authentication without competing with this host.
        let value = !cancelled && admitted() ? selection : nil
        let callback = completion; completion = nil
        let waiters = detachmentWaiters; detachmentWaiters.removeAll()
        subscriptions.removeAll()
        model.selected = nil; model.dismissed = nil; controller.onDetached = nil
        callback?(value)
        for waiter in waiters { waiter.resume() }
    }
}

extension LavaAppBridge {
    @objc func retireFlowAlert() {
        if let ticket = flowAlertLifetime.current { flowAlertLifetime.cancel(ticket) }
        // Keep the teardown reference until actual detachment. A newly admitted
        // request after retirement must still wait for this disappearing host.
        flowAlert?.cancel()
    }
    func flowAlertCommand(_ name: String, _ input: [String: Any]) async throws -> Any {
        guard let owner = input["owner"] as? [String: Any], let kind = owner["kind"] as? String,
              ["foreground", "qa", "dnsPatch"].contains(kind), let id = owner["id"] as? String, !id.isEmpty, id.utf8.count <= 200,
              let requestID = input["requestID"] as? String, UUID(uuidString: requestID) != nil else { throw CommandError("Invalid app command.") }
        let ticket = ScopedSystemAlertLifetime.Ticket(ownerID: "\(kind):\(id)", requestID: requestID)
        if name == "presentation.flowAlert.cancel" {
            // Cleanup grants no reads and cancels only this component's exact
            // request. Tombstones also cover cancel-before-present ordering.
            flowAlertLifetime.cancel(ticket)
            if flowAlert?.ticket == ticket { flowAlert?.cancel() }
            return NSNull()
        }
        guard let revision = input["readRevision"] as? NSNumber, revision.doubleValue >= 0,
              let token = input["presentationToken"] as? String, let title = input["title"] as? String, title.utf8.count <= 512,
              let message = input["message"] as? String, message.utf8.count <= 8192,
              let tint = input["tint"] as? String, ["app", "confirmation"].contains(tint),
              let buttons = input["buttons"] as? [[String: String]], (1...4).contains(buttons.count),
              Set(buttons.compactMap { $0["id"] }).count == buttons.count,
              buttons.allSatisfy({ button in
                  guard let id = button["id"], !id.isEmpty, id.utf8.count <= 80,
                        let title = button["title"], title.utf8.count <= 512, let role = button["role"] else { return false }
                  return ["default", "cancel", "destructive"].contains(role)
              }), buttons.filter({ $0["role"] == "cancel" }).count <= 1 else { throw CommandError("Invalid app command.") }
        let ownerIsCurrent = try flowAlertAdmission(kind: kind, id: id, owner: owner)
        let admitted = { [weak self] in
            guard let self else { return false }
            return self.security.viewAuthenticationRevision == revision.uint64Value && self.presentationReveal.token == token
                && self.canReadPresentation(.appUnlock) && ownerIsCurrent()
        }
        guard admitted() else { throw CommandError("Read access changed.") }
        // Reject retired/duplicate requests before touching a newer dialog.
        guard flowAlertLifetime.mayBegin(ticket) else { return NSNull() }
        // Reserve the newest intent before suspension. If B and C both wait for
        // A's host, A/B's later callbacks cannot present or retire C's dialog.
        // pinned: ScopedSystemAlertLifetimeTests and scoped-flow-alert-source.test.js
        if let previous = flowAlertLifetime.current { flowAlertLifetime.cancel(previous) }
        guard flowAlertLifetime.begin(ticket) else { return NSNull() }
        defer { flowAlertLifetime.cancel(ticket) }
        if let previous = flowAlert {
            await previous.cancelAndWaitForDetachment()
            if flowAlert === previous { flowAlert = nil }
        }
        try requireCurrentRuntime()
        guard flowAlertLifetime.current == ticket, admitted() else { return NSNull() }
        guard let root = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).flatMap(\.windows)
            .first(where: \.isKeyWindow)?.rootViewController else { throw CommandError("Read access changed.") }
        var presenter = root
        while let next = presenter.presentedViewController { presenter = next }
        guard !(presenter is UIAlertController), !presenter.isBeingDismissed, presenter.view.window != nil else {
            flowAlertLifetime.cancel(ticket); return NSNull()
        }
        let dialog = LavaAppFlowAlert(ticket: ticket, title: title, message: message, tint: tint, buttons: buttons,
                                      preferred: input["preferred"] as? String, bridge: self, admitted: admitted)
        flowAlert = dialog
        let selected: String? = await withCheckedContinuation { continuation in
            dialog.present(from: presenter) { continuation.resume(returning: $0) }
        }
        if flowAlert === dialog { flowAlert = nil }
        guard flowAlertLifetime.finish(ticket), admitted() else { return NSNull() }
        return selected.map { $0 as Any } ?? NSNull()
    }

    /// No new authorization policy: bind only to the existing admitted native
    /// owner. Static DNS help additionally has a local focused-route lifetime.
    private func flowAlertAdmission(kind: String, id: String, owner: [String: Any]) throws -> () -> Bool {
        if kind == "foreground", let flow, flow.id.uuidString == id {
            if flow.isImport, let session = importSession, session.id == flow.id,
               owner["stageID"] as? String == session.stageID.uuidString {
                let stage = session.stageID
                return { [weak self, weak session] in
                    guard let self, let session else { return false }
                    return self.flow?.id == flow.id && self.importSession === session && session.stageID == stage
                        && session.ownsFlow() && self.canReadPresentation(.appUnlock)
                }
            }
            if ["account", "backupSetup", "backupRestore"].contains(flow.name), let session = accountBackupSession,
               session.id == flow.id, session.kind == flow.name, session.isCurrent {
                return { [weak self, weak session] in
                    guard let self, let session else { return false }
                    return self.accountBackupSession === session && session.isCurrent && self.canReadPresentation(.appSettings)
                }
            }
        }
        #if DEBUG || LAVA_QA_TOOLS
        if kind == "qa", let session = qaSession, session.id == id, session.current {
            let detail = owner["detailID"] as? String
            return { [weak self, weak session] in
                guard let self, let session else { return false }
                return self.qaSession === session && session.current
                    && session.admits(detail == nil ? "row" : "detail.close", input: detail.map { ["detail": $0] } ?? [:])
            }
        }
        #endif
        if kind == "dnsPatch" { return { [weak self] in self?.canReadPresentation(.appSettings) == true } }
        throw CommandError("Read access changed.")
    }
}
