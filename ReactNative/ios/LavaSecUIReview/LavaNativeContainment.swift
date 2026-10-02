import UIKit

/// Fabric owns the UIView lifetime; UIKit owns the hosted controller lifetime.
/// Window visibility is not containment: a retained tab or navigation transition
/// may take a view off-window without ending its route or SwiftUI state.
@MainActor
enum LavaNativeContainment {
    static func update(_ child: UIViewController, in container: UIView, configure: (UIView) -> Void) {
        var responder = container.next
        var parent: UIViewController?
        while let current = responder {
            if let controller = current as? UIViewController {
                // Transition containers can temporarily be the nearest owner.
                // addChild on UINavigationController changes viewControllers:
                // RN's tab-to-root delegate would then receive our hosting
                // controller instead of RNSScreen (PR #717 crash investigation).
                // Wait for a content owner; preserve a retained page meanwhile.
                // pinned: NativeContainmentTests navigation/container checks
                guard !(controller is UINavigationController),
                      !(controller is UITabBarController),
                      !(controller is UISplitViewController) else { return }
                parent = controller
                break
            }
            responder = current.next
        }
        if child.parent !== parent {
            remove(child)
            guard let parent else { return }
            // Establish the parent BEFORE loading SwiftUI or adding its view, so
            // the first layout receives the route's traits and safe-area owner.
            parent.addChild(child)
            child.view.frame = container.bounds
            child.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            configure(child.view)
            container.addSubview(child.view)
            child.didMove(toParent: parent)
        } else if parent != nil {
            child.view.frame = container.bounds
            configure(child.view)
        }
    }

    static func remove(_ child: UIViewController) {
        if child.parent != nil { child.willMove(toParent: nil) }
        child.viewIfLoaded?.removeFromSuperview()
        if child.parent != nil { child.removeFromParent() }
    }
}

/// Suspend input without changing SwiftUI's isEnabled environment. Inactivity
/// is not a disabled setting: metadata and controls retain their appearance.
@MainActor
enum LavaNativeInteractionGate {
    static func setOpen(_ open: Bool, on view: UIView) {
        let wasOpen = view.isUserInteractionEnabled
        view.isUserInteractionEnabled = open
        view.accessibilityElementsHidden = !open
        if wasOpen && !open { view.endEditing(true) }
    }
}
