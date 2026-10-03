import SwiftUI
import UIKit
import LavaSecKit

/// The review screen shares the production calendar, date normalization and
/// label formatting. It never reads diagnostics or holds a production model.
@objc(LavaActivityDateBridge)
@MainActor
final class ActivityDateBridge: NSObject {
    @objc static func today() -> NSDictionary {
        dictionary(.today())
    }

    @objc static func preset(_ rawValue: String) -> NSDictionary? {
        guard let preset = ActivityCalendarPreset(rawValue: rawValue) else { return nil }
        let calendar = Calendar.current
        let now = Date()
        let days = preset.dateRange(through: now, calendar: calendar)
        return dictionary(ActivityDateRange(start: days.lowerBound, end: days.upperBound, calendar: calendar),
                          now: now, calendar: calendar)
    }

    @objc static func pick(start: Double, end: Double, completion: @escaping (NSDictionary?) -> Void) {
        guard start.isFinite, end.isFinite,
              let root = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene })
                .flatMap(\.windows).first(where: \.isKeyWindow)?.rootViewController else {
            completion(nil)
            return
        }
        var presenter = root
        while let presented = presenter.presentedViewController { presenter = presented }
        // Only this isolated runtime may request the sheet. This also prevents
        // stacking another picker while the first is still being dismissed.
        #if LAVA_REACT_NATIVE
        guard !LavaAppBridge.shared.security.isAppUnlockBlockingUI,
              !LavaAppBridge.shared.security.isAppUnlockPrivacyMaskVisible,
              !presenter.isBeingDismissed else { completion(nil); return }
        #else
        guard presenter is ReactReviewViewController, !presenter.isBeingDismissed else {
            completion(nil)
            return
        }
        #endif
        let range = ActivityDateRange(start: Date(timeIntervalSince1970: start / 1000), end: Date(timeIntervalSince1970: end / 1000))
        let result = ActivityDateCompletion(completion)
        let sheet = ActivityDateRangePickerSheet(selectedRange: Binding(
            get: { range },
            set: { result.finish(dictionary($0)) }
        ))
        .onDisappear { result.finish(nil) }
        #if LAVA_REACT_NATIVE
        // A separately presented hosting controller does not inherit the native
        // flow's SwiftUI environment. Reuse its app preference owners here too.
        let customization = LavaAppBridge.shared.model.customization
        let presentedSheet = sheet
            .preferredColorScheme(customization.preferredColorScheme)
            .lavaTextSizeOverride(customization.textSizeOverride)
            .tint(LavaStyle.safeGreen)
        #else
        // The isolated review app follows its own window appearance and system text size.
        let presentedSheet = sheet
        #endif
        let controller = UIHostingController(rootView: presentedSheet)
        controller.modalPresentationStyle = .pageSheet
        controller.sheetPresentationController?.detents = [
            .custom(identifier: .init("activity-calendar")) { $0.maximumDetentValue * 0.62 }, .large()
        ]
        controller.sheetPresentationController?.prefersGrabberVisible = true
        presenter.present(controller, animated: true)
    }

    private static func dictionary(_ range: ActivityDateRange, now: Date = Date(), calendar: Calendar = .current) -> NSDictionary {
        ["start": range.start.timeIntervalSince1970 * 1000,
         "end": range.end.timeIntervalSince1970 * 1000,
         "label": range.pillText(calendar: calendar).lavaLocalized,
         "includesToday": range.contains(now, calendar: calendar)]
    }
}

@MainActor
private final class ActivityDateCompletion {
    private var completion: ((NSDictionary?) -> Void)?
    init(_ completion: @escaping (NSDictionary?) -> Void) { self.completion = completion }
    func finish(_ value: NSDictionary?) {
        let callback = completion
        completion = nil
        callback?(value)
    }
}


/// UIKit owns action-sheet layout, cancellation and adaptive presentation.
/// Actions carry no extra glyph. UIKit owns their appearance: action sheets do
/// not support preferredAction or a public per-action tint.
@objc(LavaFilterChoiceBridge)
@MainActor
final class FilterChoiceBridge: NSObject {
    @objc static func choose(name: String, canSwitch: Bool, canShare: Bool, completion: @escaping (String?) -> Void) {
        guard let root = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene })
            .flatMap(\.windows).first(where: \.isKeyWindow)?.rootViewController else { completion(nil); return }
        var presenter = root
        while let presented = presenter.presentedViewController { presenter = presented }
        guard !presenter.isBeingDismissed else { completion(nil); return }
        #if LAVA_REACT_NATIVE
        guard !LavaAppBridge.shared.security.isAppUnlockBlockingUI,
              !LavaAppBridge.shared.security.isAppUnlockPrivacyMaskVisible else { completion(nil); return }
        #endif
        let result = FilterChoiceCompletion(completion)
        let controller = UIAlertController(title: name, message: nil, preferredStyle: .actionSheet)
        for (action, title, enabled) in [
            ("switch", "Switch to this filter", canSwitch),
            ("view", "View or edit only", true), ("share", "Share", canShare), ("cancel", "Cancel", true)
        ] {
            // UIKit omits a .cancel action in its popover presentation. Keep an
            // explicit native row on every size class; both this row and native
            // outside dismissal resolve the same once-only cancellation owner.
            let item = UIAlertAction(title: title.lavaLocalized, style: .default) { _ in
                result.finish(action == "cancel" ? nil : action)
            }
            item.isEnabled = enabled
            controller.addAction(item)
        }
        controller.view.tintColor = UIColor(LavaStyle.safeGreen)
        if let popover = controller.popoverPresentationController {
            popover.sourceView = presenter.view
            popover.sourceRect = CGRect(x: presenter.view.bounds.midX, y: presenter.view.bounds.midY, width: 0, height: 0)
            popover.permittedArrowDirections = []
            popover.delegate = result
        }
        controller.presentationController?.delegate = result
        presenter.present(controller, animated: true)
    }
}

@MainActor
private final class FilterChoiceCompletion: NSObject, UIPopoverPresentationControllerDelegate {
    private var completion: ((String?) -> Void)?
    init(_ completion: @escaping (String?) -> Void) { self.completion = completion }
    func finish(_ value: String?) { let callback = completion; completion = nil; callback?(value) }
    func presentationControllerDidDismiss(_ presentationController: UIPresentationController) { finish(nil) }
    func popoverPresentationControllerDidDismissPopover(_ popoverPresentationController: UIPopoverPresentationController) { finish(nil) }
}
