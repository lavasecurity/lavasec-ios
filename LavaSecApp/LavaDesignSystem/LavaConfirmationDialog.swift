import SwiftUI
import UIKit

extension View {
    /// Routes a confirmation `.alert` through the app's shared scaffold so every
    /// two-choice prompt looks alike: the native system alert (the "Discard changes?"
    /// look — a centered card with the system's light border) whose buttons read
    /// *neutral* rather than the app's green. The Cancel/escape action stays calm, the
    /// way the old rage-shake "Not now" button did, and destructive roles keep their red.
    ///
    /// The app tints itself green (`RootView`'s `.tint`), and a native alert inherits that
    /// tint for its non-destructive buttons — which is why an un-styled "Cancel" shows up
    /// green. Re-tinting the *screen* neutral would also drain the green from its toggles
    /// and links, so instead the alert rides a clear, neutrally-tinted layer behind the
    /// content; the surrounding screen keeps its green untouched.
    ///
    /// Attach the `.alert` to the `Color` the closure hands back:
    ///
    ///     .lavaConfirmationAlert { host in
    ///         host.alert("Discard changes?", isPresented: $isShowing) {
    ///             Button("Cancel", role: .cancel) {}
    ///             Button("Discard", role: .destructive) { discard() }
    ///         } message: {
    ///             Text("Your draft changes will be removed.")
    ///         }
    ///     }
    func lavaConfirmationAlert<Output: View>(
        @ViewBuilder _ alert: (Color) -> Output
    ) -> some View {
        background {
            alert(Color.clear)
                .tint(LavaStyle.confirmationButtonTint)
        }
    }
}

extension View {
    /// Blocks an interactive sheet dismissal and routes the attempt through the
    /// caller's existing confirmation. Programmatic Save/Discard remain explicit.
    func lavaConfirmInteractiveDismiss(_ blocked: Bool, onAttempt: @escaping () -> Void) -> some View {
        background(LavaInteractiveDismissObserver(blocked: blocked, onAttempt: onAttempt))
    }
}

private struct LavaInteractiveDismissObserver: UIViewRepresentable {
    let blocked: Bool
    let onAttempt: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeUIView(context: Context) -> ObserverView {
        let view = ObserverView()
        view.isUserInteractionEnabled = false
        view.onAttach = { [weak coordinator = context.coordinator] view in coordinator?.attach(to: view) }
        return view
    }
    func updateUIView(_ view: ObserverView, context: Context) {
        context.coordinator.blocked = blocked
        context.coordinator.onAttempt = onAttempt
        context.coordinator.attach(to: view)
    }
    static func dismantleUIView(_ view: ObserverView, coordinator: Coordinator) { coordinator.detach() }

    final class ObserverView: UIView {
        var onAttach: ((UIView) -> Void)?
        override func didMoveToWindow() {
            super.didMoveToWindow()
            if window != nil { onAttach?(self) }
        }
    }

    final class Coordinator: NSObject, UIAdaptivePresentationControllerDelegate {
        var blocked = false
        var onAttempt: (() -> Void)?
        private weak var presentation: UIPresentationController?
        // NSObject's forwarding hooks are nonisolated; UIKit calls this entire
        // delegate protocol on the main thread, including selector discovery.
        nonisolated(unsafe) private weak var previousDelegate: (any UIAdaptivePresentationControllerDelegate)?
        private var previouslyModal = false

        func attach(to view: UIView) {
            guard blocked else { detach(); return }
            guard view.window != nil else { return }
            var responder: UIResponder? = view
            while let current = responder, !(current is UIViewController) { responder = current.next }
            guard var controller = responder as? UIViewController else { return }
            while let parent = controller.parent { controller = parent }
            guard controller.presentingViewController != nil, let next = controller.presentationController else { return }
            if presentation !== next { detach(); presentation = next; previouslyModal = controller.isModalInPresentation }
            // The RN flow host and SwiftUI own dismissal completion. Preserve
            // their delegate and forward its callbacks rather than stealing it.
            if next.delegate !== self { previousDelegate = next.delegate; next.delegate = self }
            controller.isModalInPresentation = true
        }
        func detach() {
            if let presentation, presentation.delegate === self {
                presentation.delegate = previousDelegate
                presentation.presentedViewController.isModalInPresentation = previouslyModal
            }
            presentation = nil
            previousDelegate = nil
        }
        func presentationControllerShouldDismiss(_ presentationController: UIPresentationController) -> Bool {
            !blocked && (previousDelegate?.presentationControllerShouldDismiss?(presentationController) ?? true)
        }
        func presentationControllerDidAttemptToDismiss(_ presentationController: UIPresentationController) {
            if blocked { onAttempt?() }
            previousDelegate?.presentationControllerDidAttemptToDismiss?(presentationController)
        }
        func presentationControllerWillDismiss(_ presentationController: UIPresentationController) {
            previousDelegate?.presentationControllerWillDismiss?(presentationController)
        }
        func presentationControllerDidDismiss(_ presentationController: UIPresentationController) {
            previousDelegate?.presentationControllerDidDismiss?(presentationController)
        }
        // Optional adaptation callbacks still belong to the original host.
        // UIKit invokes presentation delegates on the main thread.
        nonisolated override func responds(to selector: Selector!) -> Bool {
            super.responds(to: selector) || previousDelegate?.responds(to: selector) == true
        }
        nonisolated override func forwardingTarget(for selector: Selector!) -> Any? {
            previousDelegate?.responds(to: selector) == true ? previousDelegate : super.forwardingTarget(for: selector)
        }
    }
}
