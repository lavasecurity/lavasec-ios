import UIKit
import React
import React_RCTAppDelegate
import ReactAppDependencyProvider

@MainActor
final class ReactReviewViewController: UIViewController {
    private let activityExample: Bool
    private let reviewGallery: Bool

    init(activityExample: Bool, reviewGallery: Bool) {
        self.activityExample = activityExample
        self.reviewGallery = reviewGallery
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { nil }

    private var factory: RCTReactNativeFactory?
    private var factoryDelegate: ReviewReactDelegate?

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        ReviewMetrics.beginOpening()
        let delegate = ReviewReactDelegate()
        delegate.dependencyProvider = ReviewDependencyProvider()
        let factory = RCTReactNativeFactory(delegate: delegate)
        factoryDelegate = delegate
        self.factory = factory
        let root = factory.rootViewFactory.view(withModuleName: "LavaUIReview", initialProperties: ["activityExample": activityExample, "reviewGallery": reviewGallery])
        root.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(root)
        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            root.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            root.topAnchor.constraint(equalTo: view.topAnchor),
            root.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        // Review controls stay outside product chrome. A deliberate three-finger
        // double tap returns to the native fixture picker without an extra X on
        // Guard or Settings. VoiceOver escape provides the accessible equivalent.
        let exitGesture = UITapGestureRecognizer(target: self, action: #selector(closeReview))
        exitGesture.numberOfTouchesRequired = 3
        exitGesture.numberOfTapsRequired = 2
        view.addGestureRecognizer(exitGesture)
    }

    @objc private func closeReview() { dismiss(animated: true) }
    override func accessibilityPerformEscape() -> Bool { closeReview(); return true }
}

private final class ReviewReactDelegate: RCTDefaultReactNativeFactoryDelegate {
    override func sourceURL(for bridge: RCTBridge) -> URL? { bundleURL() }
    override func bundleURL() -> URL? {
        // The review artifact always runs its bundled JS, with no Metro server or
        // development HTTP exception needed on a device.
        Bundle.main.url(forResource: "LavaUIReview", withExtension: "js")
    }
}

private final class ReviewDependencyProvider: RCTAppDependencyProvider {
    override func unstableModulesRequiringMainQueueSetup() -> [String] {
        // RN 0.87 codegen lists its example SampleTurboModule, but the packaged
        // CoreModulesPlugins does not supply it. Keep every real app/core module.
        super.unstableModulesRequiringMainQueueSetup().filter { $0 != "SampleTurboModule" }
    }
}
