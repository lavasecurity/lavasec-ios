import UIKit
import SwiftUI

/// Runs the production UIKit scaffold in a tiny simulator app, independently of
/// Metro, app data and the full native app's compilation. Never ships in Lava.
@main
@MainActor
final class NativeContainmentTests: UIResponder, UIApplicationDelegate {
    var window: UIWindow?
    private var checks = 0
    private var failures: [String] = []

    func application(_ application: UIApplication, didFinishLaunchingWithOptions options: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        return true
    }

    func application(_ application: UIApplication, configurationForConnecting session: UISceneSession, options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        let configuration = UISceneConfiguration(name: "Native regression", sessionRole: session.role)
        configuration.delegateClass = NativeRegressionSceneDelegate.self
        return configuration
    }

    private func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        checks += 1
        if !condition() { failures.append(message) }
    }

    func run(in scene: UIWindowScene) {
        let parent = UIViewController()
        parent.view.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        let container = UIView(frame: CGRect(x: 0, y: 80, width: 390, height: 680))
        parent.view.addSubview(container)
        let child = ObservedController()
        let update = { LavaNativeContainment.update(child, in: container) { $0.backgroundColor = .systemBackground } }

        // The responder chain exists before the window. Loading a SwiftUI root
        // before this relationship is installed caused a late safe-area layout.
        update()
        expect(child.hadParentAtLoad, "Child must have its parent when its view first loads")
        expect(child.parent === parent, "Child attaches before entering a window")
        expect(child.frameAtAttachment == container.bounds, "Initial attachment must use the container's bounds")
        expect(child.attachments == 1, "Initial mount attaches once")
        update()
        expect(child.attachments == 1, "Repeated layouts must not remount the child")

        let window = UIWindow(windowScene: scene)
        window.frame = parent.view.bounds
        self.window = window
        window.rootViewController = parent
        window.makeKeyAndVisible()
        update()
        // Simulate a retained route moving off-window while its responder parent
        // remains. It must retain identity, child navigation and appearance turn.
        window.rootViewController = nil
        update()
        expect(container.window == nil, "Fixture must exercise off-window containment")
        expect(child.parent === parent && child.attachments == 1, "Off-window retention must not tear down the controller")
        window.rootViewController = parent
        update()
        expect(child.attachments == 1, "Window return must not create a new appearance turn")

        container.bounds.size = CGSize(width: 320, height: 540)
        update()
        expect(child.view.frame == container.bounds, "Container resizing must update child geometry")
        let replacement = UIViewController()
        replacement.view.addSubview(container)
        update()
        expect(child.parent === replacement && !parent.children.contains(child), "A real parent change must transfer ownership")
        expect(child.attachments == 2, "Only a real parent change remounts the child")

        let enabled = UIButton(type: .system)
        enabled.setTitle("Last saved on Sep 11, 2026", for: .normal)
        let unavailable = UISwitch()
        unavailable.isEnabled = false
        child.view.addSubview(enabled)
        child.view.addSubview(unavailable)
        let tint = enabled.tintColor
        LavaNativeInteractionGate.setOpen(false, on: child.view)
        expect(!child.view.isUserInteractionEnabled && child.view.accessibilityElementsHidden, "Closed gate blocks pointer and accessibility input")
        expect(enabled.isEnabled && enabled.alpha == 1 && enabled.tintColor == tint, "Inactivity must not dim enabled metadata or controls")
        expect(!unavailable.isEnabled, "A closed gate must retain genuinely unavailable controls")
        LavaNativeInteractionGate.setOpen(true, on: child.view)
        expect(child.view.isUserInteractionEnabled && !child.view.accessibilityElementsHidden, "Successful authorization restores interaction")
        expect(!unavailable.isEnabled, "Opening the gate must not enable unavailable settings")

        container.removeFromSuperview()
        update()
        expect(child.parent == nil && child.view.superview == nil, "Actual removal detaches both controller and view")
        LavaNativeContainment.remove(child)
        expect(child.parent == nil, "Repeated recycle removal is harmless")

        // During a native transition, the next controller can be the navigation
        // container itself. addChild there changes UIKit's navigation stack and
        // gives RN's pop delegate a controller that does not implement screenView.
        let screen = UIViewController()
        let navigation = UINavigationController(rootViewController: screen)
        let movingContainer = UIView(frame: CGRect(x: 0, y: 0, width: 96, height: 96))
        navigation.view.addSubview(movingContainer)
        let artwork = ObservedController()
        let mountArtwork = { LavaNativeContainment.update(artwork, in: movingContainer) { _ in } }
        mountArtwork()
        expect(navigation.viewControllers == [screen], "A decorative child must never enter the navigation stack")
        expect(artwork.parent == nil && !artwork.isViewLoaded, "Mounting waits for a content controller, without loading the child")
        screen.view.addSubview(movingContainer)
        mountArtwork()
        expect(artwork.parent === screen, "The content controller owns the hosted child once available")
        navigation.view.addSubview(movingContainer)
        mountArtwork()
        expect(artwork.parent === screen, "A temporary transition container must retain the existing page owner")
        expect(navigation.viewControllers == [screen], "Moving a retained child must not mutate the navigation stack")
        movingContainer.removeFromSuperview()
        mountArtwork()
        expect(artwork.parent == nil, "Actual removal still releases a deferred native child")
        for managedContainer in [UITabBarController(), UISplitViewController(style: .doubleColumn)] as [UIViewController] {
            managedContainer.view.addSubview(movingContainer)
            mountArtwork()
            expect(artwork.parent == nil && managedContainer.children.isEmpty, "A decorative child must not become a tab or split column")
            movingContainer.removeFromSuperview()
        }

        // Embedded SwiftUI pages are not RN ScrollView children. The owning
        // native route must explicitly track their scroll view across layouts
        // and release it when that route's hosted content moves or recycles.
        let pageContainer = UIView(frame: screen.view.bounds)
        screen.view.addSubview(pageContainer)
        let page = UIHostingController(rootView: ScrollView { Color.green.frame(height: 1800) })
        window.rootViewController = navigation
        window.layoutIfNeeded()
        let mountPage = { LavaNativeContainment.update(page, in: pageContainer, tracksContentScrollView: true) { _ in } }
        mountPage()
        page.view.insertSubview(UITextView(frame: .zero), at: 0)
        mountPage()
        let contentScrollView = screen.contentScrollView(for: .top)
        expect(contentScrollView != nil, "Native navigation must track an actual hosted SwiftUI scroll view")
        expect(!(contentScrollView is UITextView), "An earlier text editor must not replace the content scroll view")
        expect(contentScrollView?.isDescendant(of: page.view) == true, "Tracked scroll view belongs to the hosted page")
        contentScrollView?.setContentOffset(CGPoint(x: 0, y: 90), animated: false)
        let retainedOffset = contentScrollView?.contentOffset
        mountPage()
        expect(screen.contentScrollView(for: .top) === contentScrollView, "Layout updates preserve the scroll view and its offset")
        expect(contentScrollView?.contentOffset == retainedOffset, "Layout updates must not reset a page's scroll position")
        let nextPageOwner = UIViewController()
        nextPageOwner.view.addSubview(pageContainer)
        mountPage()
        expect(screen.contentScrollView(for: .top) == nil, "Reparenting releases the previous route's scroll association")
        expect(nextPageOwner.contentScrollView(for: .top) === contentScrollView, "Reparenting transfers the scroll association")
        LavaNativeContainment.remove(page)
        expect(nextPageOwner.contentScrollView(for: .top) == nil, "Recycling releases the tracked content scroll view")
        expect(page.parent == nil, "Recycling still releases the hosted controller")
        window.rootViewController = parent

        // Real UIKit ancestors may locally invert transparent-toolbar traits.
        // The actual SF Symbol tint resolver must keep the app-selected palette.
        let symbol = UIImageView(image: UIImage(systemName: "chevron.left"))
        let toolbar = UIView(frame: CGRect(x: 0, y: 0, width: 44, height: 44))
        toolbar.addSubview(symbol)
        parent.view.addSubview(toolbar)
        for (scheme, expectedStyle, ancestorStyle) in [("light", UIUserInterfaceStyle.light, UIUserInterfaceStyle.dark),
                                                       ("dark", UIUserInterfaceStyle.dark, UIUserInterfaceStyle.light)] {
            toolbar.overrideUserInterfaceStyle = ancestorStyle
            toolbar.updateTraitsIfNeeded()
            symbol.updateTraitsIfNeeded()
            expect(symbol.traitCollection.userInterfaceStyle == ancestorStyle, "\(scheme) fixture must expose opposing UIKit style \(ancestorStyle.rawValue), got \(symbol.traitCollection.userInterfaceStyle.rawValue)")
            for (tone, nativeColor) in [("primary", LavaStyle.primaryText), ("white", LavaStyle.actionForeground),
                                        ("tertiary", LavaStyle.tertiaryText), ("error", LavaStyle.errorText)] {
                symbol.tintColor = LavaSymbolPalette.color(for: tone, colorScheme: scheme)
                let actual = symbol.tintColor.resolvedColor(with: symbol.traitCollection)
                let expected = UIColor(nativeColor).resolvedColor(with: UITraitCollection(userInterfaceStyle: expectedStyle))
                expect(actual.isEqual(expected), "\(scheme) \(tone) SF Symbol tint must ignore opposing toolbar appearance")
            }
            symbol.tintColor = LavaSymbolPalette.color(for: "primary")
            let inherited = UIColor(LavaStyle.primaryText).resolvedColor(with: symbol.traitCollection)
            expect(symbol.tintColor.resolvedColor(with: symbol.traitCollection).isEqual(inherited), "Unpinned artwork must still inherit native traits")
        }

        for (name, passed) in LavaControlTrackingChecks() {
            expect(passed.boolValue, name)
        }

        let report: [String: Any] = ["checks": checks, "failures": failures, "passed": failures.isEmpty]
        let data = try! JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        let path = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("results.json")
        try! data.write(to: path)
        exit(failures.isEmpty ? 0 : 1)
    }
}

@MainActor
private final class ObservedController: UIViewController {
    var hadParentAtLoad = false
    var attachments = 0
    var frameAtAttachment = CGRect.null
    override func viewDidLoad() {
        super.viewDidLoad()
        hadParentAtLoad = parent != nil
    }
    override func didMove(toParent parent: UIViewController?) {
        super.didMove(toParent: parent)
        if parent != nil {
            attachments += 1
            frameAtAttachment = view.frame
        }
    }
}

@MainActor
private final class NativeRegressionSceneDelegate: NSObject, UIWindowSceneDelegate {
    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options: UIScene.ConnectionOptions) {
        guard let scene = scene as? UIWindowScene,
              let app = UIApplication.shared.delegate as? NativeContainmentTests else { return }
        DispatchQueue.main.async { app.run(in: scene) }
    }
}
