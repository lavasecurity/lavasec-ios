import Foundation
import UIKit

extension LavaAppBridge {
    static let contentSizes: [UIContentSizeCategory] = [.extraSmall, .small, .medium, .large, .extraLarge, .extraExtraLarge, .extraExtraExtraLarge]
    static var systemTextSize: LavaTextSize {
        LavaTextSize.allCases[contentSizes.firstIndex(of: UIApplication.shared.preferredContentSizeCategory) ?? (UIApplication.shared.preferredContentSizeCategory.isAccessibilityCategory ? 6 : 3)]
    }
    var preferredContentSize: UIContentSizeCategory {
        model.customization.textSizeMatchesSystem ? UIApplication.shared.preferredContentSizeCategory : Self.contentSizes[LavaTextSize.allCases.firstIndex(of: model.customization.textSize) ?? 3]
    }
    func presentationSnapshot() -> [String: Any] {
        // UIFontMetrics is authoritative for each semantic text style. Explicit
        // ratios also reach Fabric text, whose measurement can occur off the UI
        // thread and outside the view controller's trait override.
        let traits = UITraitCollection(preferredContentSizeCategory: preferredContentSize)
        let styles: [String: UIFont.TextStyle] = ["body": .body, "headline": .headline, "subheadline": .subheadline, "footnote": .footnote, "caption1": .caption1, "caption2": .caption2, "title1": .title1, "title2": .title2, "title3": .title3, "largeTitle": .largeTitle, "callout": .callout]
        let scales = styles.mapValues { UIFontMetrics(forTextStyle: $0).scaledValue(for: 100, compatibleWith: traits) / 100 }
        return ["locale": Bundle.main.preferredLocalizations.first ?? "en", "textScales": model.customization.textSizeMatchesSystem ? NSNull() : scales]
    }
}
