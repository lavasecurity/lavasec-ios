import SwiftUI
import UIKit
import LavaSecAppServices

@main
@MainActor
final class AppDelegate: UIResponder, UIApplicationDelegate {
    var window: UIWindow?
    private var appearanceObserver: UUID?

    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--seed-native-qa-appearance") {
            AppearancePreferencesService(defaults: .standard).setPreference(.light)
        }
        #endif
        if ProcessInfo.processInfo.arguments.contains("--reset-review-appearance") {
            AppearanceBridge.shared.service.setPreference(.system)
        }
        let window = UIWindow(frame: UIScreen.main.bounds)
        let root = NativeReviewViewController()
        window.rootViewController = UINavigationController(rootViewController: root)
        self.window = window
        appearanceObserver = AppearanceBridge.shared.service.observe { [weak window] snapshot in
            window?.overrideUserInterfaceStyle = switch snapshot.preference {
            case .system: .unspecified
            case .light: .light
            case .dark: .dark
            }
        }
        window.makeKeyAndVisible()
        return true
    }

    func applicationDidBecomeActive(_ application: UIApplication) {
        AppearanceBridge.shared.service.refresh()
    }
}

@MainActor
final class NativeReviewViewController: UIViewController {
    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Lava UI Review"
        let controller = UIHostingController(rootView: NativeReviewHome { [weak self] activityExample, reviewGallery in
            let review = ReactReviewViewController(activityExample: activityExample, reviewGallery: reviewGallery)
            review.modalPresentationStyle = .fullScreen
            self?.present(review, animated: true)
        })
        addChild(controller)
        controller.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(controller.view)
        NSLayoutConstraint.activate([
            controller.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            controller.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            controller.view.topAnchor.constraint(equalTo: view.topAnchor),
            controller.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        controller.didMove(toParent: self)
    }
}

private struct NativeReviewHome: View {
    let openReact: (Bool, Bool) -> Void
    @State private var activityExample = false
    @State private var snapshot = AppearanceBridge.shared.service.snapshot
    @State private var observer: UUID?

    var body: some View {
        Form {
            Section("Native appearance") {
                Picker("Appearance", selection: Binding(
                    get: { snapshot.preference },
                    set: { AppearanceBridge.shared.service.setPreference($0) }
                )) {
                    ForEach(AppearancePreference.allCases, id: \.self) { preference in
                        Text(preference.rawValue).tag(preference)
                    }
                }
                .pickerStyle(.segmented)
                Text("Confirmed: \(snapshot.preference.rawValue)")
                #if DEBUG
                if ProcessInfo.processInfo.arguments.contains("--inspect-native-qa-appearance") {
                    Text("Native QA reference: \(AppearancePreferencesService(defaults: .standard).snapshot.preference.rawValue)")
                }
                #endif
            }
            Section {
                Picker("Activity sample", selection: $activityExample) {
                    Text("Empty").tag(false)
                    Text("Example").tag(true)
                }
                .pickerStyle(.segmented)
                Button("Open React Native") { openReact(activityExample, false) }
                Button("Open component gallery") { openReact(activityExample, true) }
                Text("Guard, Settings, Filters, and Activity are UI previews with sample data. This separate app does not run a VPN or change your production filters. Appearance is a real native preference.")
                Text("The reference fixture uses a signed-out Free account, Balanced filter, empty local logs and sample plan prices. Other controls change only this review session. Double-tap with three fingers, or use VoiceOver escape, to return here.")
            }
        }
        .onAppear {
            observer = AppearanceBridge.shared.service.observe { snapshot = $0 }
        }
        .onDisappear {
            if let observer { AppearanceBridge.shared.service.removeObserver(observer) }
            observer = nil
        }
    }
}
