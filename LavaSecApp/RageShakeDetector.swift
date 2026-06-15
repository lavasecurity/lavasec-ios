import SwiftUI
import UIKit
import LavaSecCore

struct RageShakeDetector: UIViewControllerRepresentable {
    let onShake: () -> Void

    func makeUIViewController(context: Context) -> RageShakeViewController {
        RageShakeViewController(onShake: onShake)
    }

    func updateUIViewController(_ uiViewController: RageShakeViewController, context: Context) {
        uiViewController.onShake = onShake
    }
}

final class RageShakeViewController: UIViewController {
    var onShake: () -> Void
    private var isKeyboardVisible = false
    private var intentTracker = RageShakeIntentTracker()

    init(onShake: @escaping () -> Void) {
        self.onShake = onShake
        super.init(nibName: nil, bundle: nil)
        view.backgroundColor = .clear
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var canBecomeFirstResponder: Bool {
        true
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        activateShakeDetection()
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(keyboardWillShow),
            name: UIResponder.keyboardWillShowNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(keyboardDidHide),
            name: UIResponder.keyboardDidHideNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(appDidBecomeActive),
            name: UIApplication.didBecomeActiveNotification,
            object: nil
        )
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    func activateShakeDetection() {
        guard RageShakeActivationPolicy.shouldActivate(
            isViewInWindow: view.window != nil,
            isDetectorFirstResponder: isFirstResponder,
            isTextInputActive: isTextInputActive
        ) else {
            return
        }

        becomeFirstResponder()
    }

    override func motionEnded(_ motion: UIEvent.EventSubtype, with event: UIEvent?) {
        guard motion == .motionShake else {
            return
        }

        let timestamp = event?.timestamp ?? ProcessInfo.processInfo.systemUptime
        guard intentTracker.registerShake(at: timestamp) else {
            return
        }

        onShake()
    }

    private var isTextInputActive: Bool {
        if isKeyboardVisible {
            return true
        }

        guard let firstResponder = view.window?.lavaFirstResponder else {
            return false
        }

        return firstResponder !== self && firstResponder is any UITextInput
    }

    @objc private func keyboardWillShow() {
        isKeyboardVisible = true
    }

    @objc private func keyboardDidHide() {
        isKeyboardVisible = false
        activateShakeDetection()
    }

    @objc private func appDidBecomeActive() {
        activateShakeDetection()
    }
}

private extension UIView {
    var lavaFirstResponder: UIResponder? {
        if isFirstResponder {
            return self
        }

        for subview in subviews {
            if let firstResponder = subview.lavaFirstResponder {
                return firstResponder
            }
        }

        return nil
    }
}
