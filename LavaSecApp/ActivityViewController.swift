import SwiftUI
import UIKit
import LinkPresentation

/// Presents the system share sheet for a rendered card or an exported file.
///
/// Deliberately NOT wrapped in a SwiftUI `.sheet`. Two earlier attempts failed in
/// the simulator, both silently and both with every unit test still green:
///
///   1. Returning `UIActivityViewController` from `makeUIViewController` and
///      letting a `.sheet` host it renders an EMPTY sheet — the content behind
///      dims as though something presented, but nothing draws, because the
///      activity controller expects to be *presented*, not installed as a
///      sheet's root.
///   2. Hosting an empty controller inside that sheet and presenting from it
///      leaves a blank white sheet instead: presenting a second modal from a
///      controller that is itself mid-presentation does not reliably take.
///
/// So the share sheet is presented straight from the topmost view controller,
/// with no SwiftUI modal in the path at all. This is also what makes the iPad
/// popover anchor meaningful — it attaches to a controller that is genuinely on
/// screen.
enum ShareSheetPresenter {
    enum Outcome { case completed, cancelled, failed(Error), unavailable }
    /// Presents `image` as the sole activity item.
    ///
    /// Only the image is offered. Adding the raw code or the URL as a second item
    /// would push the payload into clipboards and link previews the sender never
    /// asked for.
    @MainActor
    static func present(image: UIImage, onComplete: ((Outcome) -> Void)? = nil) {
        present(activityItems: [ShareCardActivityItemSource(image: image)], onComplete: onComplete)
    }

    /// Presents arbitrary activity items — an exported file URL plus the disclosure copy that
    /// should travel with it. The caller owns the file and removes it from `onComplete`.
    @MainActor
    static func present(activityItems: [Any], onComplete: ((Outcome) -> Void)? = nil) {
        guard let top = topViewController() else {
            onComplete?(.unavailable)
            return
        }

        let controller = UIActivityViewController(
            activityItems: activityItems,
            applicationActivities: nil
        )
        controller.completionWithItemsHandler = { _, completed, _, error in
            // Completion confirms an activity, never recipient delivery. System feedback remains sole owner.
            if let error { onComplete?(.failed(error)) }
            else { onComplete?(completed ? .completed : .cancelled) }
        }

        // iPad presents this as a popover and raises without an anchor.
        if let popover = controller.popoverPresentationController {
            popover.sourceView = top.view
            popover.sourceRect = CGRect(
                x: top.view.bounds.midX,
                y: top.view.bounds.midY,
                width: 0,
                height: 0
            )
            popover.permittedArrowDirections = []
        }

        top.present(controller, animated: true)
    }

    /// The deepest currently-presented controller, which for this feature is the
    /// share sheet itself.
    @MainActor
    private static func topViewController() -> UIViewController? {
        let scene = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }
        let window = scene?.windows.first { $0.isKeyWindow } ?? scene?.windows.first
        guard var top = window?.rootViewController else { return nil }
        while let presented = top.presentedViewController, !presented.isBeingDismissed {
            top = presented
        }
        return top
    }
}

/// Supplies local preview metadata from an immutable image snapshot. The activity
/// item source protocol is nonisolated; presenting its controller stays on MainActor.
final class ShareCardActivityItemSource: NSObject, UIActivityItemSource {
    let image: UIImage
    init(image: UIImage) { self.image = image }
    func activityViewControllerPlaceholderItem(_ activityViewController: UIActivityViewController) -> Any { image }
    func activityViewController(_ activityViewController: UIActivityViewController, itemForActivityType activityType: UIActivity.ActivityType?) -> Any? { image }
    func activityViewControllerLinkMetadata(_ activityViewController: UIActivityViewController) -> LPLinkMetadata? {
        let metadata = LPLinkMetadata()
        metadata.title = "Scan to import my Lava filter".lavaLocalized
        // Leave image providers unset so the share header can keep the app icon.
        return metadata
    }
}
