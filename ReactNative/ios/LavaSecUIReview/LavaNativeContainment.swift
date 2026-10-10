import UIKit

/// Fabric owns the UIView lifetime; UIKit owns the hosted controller lifetime.
/// Window visibility is not containment: a retained tab or navigation transition
/// may take a view off-window without ending its route or SwiftUI state.
@MainActor
enum LavaNativeContainment {
    static func update(_ child: UIViewController, in container: UIView,
                       tracksContentScrollView: Bool = false, configure: (UIView) -> Void) {
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
        if tracksContentScrollView, let parent {
            // SwiftUI's scroll view sits below its hosting view rather than as
            // the RN screen's direct child. Give UIKit the content scroll view
            // explicitly so the shared navigation bar can track its top edge.
            child.view.layoutIfNeeded()
            if let scrollView = firstScrollView(in: child.view), parent.contentScrollView(for: .top) !== scrollView {
                parent.setContentScrollView(scrollView, for: .top)
            }
        }
    }

    static func remove(_ child: UIViewController) {
        if let parent = child.parent, let view = child.viewIfLoaded,
           let scrollView = parent.contentScrollView(for: .top), scrollView.isDescendant(of: view) {
            parent.setContentScrollView(nil, for: .top)
        }
        if child.parent != nil { child.willMove(toParent: nil) }
        child.viewIfLoaded?.removeFromSuperview()
        if child.parent != nil { child.removeFromParent() }
    }

    private static func firstScrollView(in view: UIView) -> UIScrollView? {
        // These hosted pages expose an outer vertical ScrollView. Search outer
        // content before nested editors, and never register a text input as it.
        guard !(view is UITextView) else { return nil }
        if let scrollView = view as? UIScrollView { return scrollView }
        for subview in view.subviews {
            if let scrollView = firstScrollView(in: subview) { return scrollView }
        }
        return nil
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
