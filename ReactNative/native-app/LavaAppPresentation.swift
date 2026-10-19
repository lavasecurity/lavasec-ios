import Foundation
import UIKit

extension LavaAppBridge {
    private static var searchClearMetricsCache: [String: [String: CGFloat]] = [:]
    private static var passcodeLockMetricsCache: [CGFloat: [String: CGFloat]] = [:]
    static let contentSizes: [UIContentSizeCategory] = [.extraSmall, .small, .medium, .large, .extraLarge, .extraExtraLarge, .extraExtraExtraLarge]
    static var systemTextSize: LavaTextSize {
        LavaTextSize.allCases[contentSizes.firstIndex(of: UIApplication.shared.preferredContentSizeCategory) ?? (UIApplication.shared.preferredContentSizeCategory.isAccessibilityCategory ? 6 : 3)]
    }
    var preferredContentSize: UIContentSizeCategory {
        model.customization.textSizeMatchesSystem ? UIApplication.shared.preferredContentSizeCategory : Self.contentSizes[LavaTextSize.allCases.firstIndex(of: model.customization.textSize) ?? 3]
    }
    private func searchClearMetrics(traits: UITraitCollection) -> [String: CGFloat] {
        let font = UIFont.preferredFont(forTextStyle: .body, compatibleWith: traits)
        let displayScale = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first(where: { $0.activationState == .foregroundActive })?.traitCollection.displayScale ?? 1
        let key = "\(preferredContentSize.rawValue):\(font.pointSize):\(displayScale)"
        if let cached = Self.searchClearMetricsCache[key] { return cached }
        // SF Symbol natural bounds do not scale linearly with semantic fonts.
        // Cache public UIImage metrics; no hosted view is built during publish.
        let configuration = UIImage.SymbolConfiguration(pointSize: font.pointSize, weight: .semibold)
        let image = UIImage(systemName: "xmark.circle.fill", withConfiguration: configuration)
        let size = image?.size ?? CGSize(width: 20, height: 20)
        let metric: [String: CGFloat] = ["fontSize": font.pointSize, "width": size.width, "height": size.height]
        Self.searchClearMetricsCache[key] = metric
        return metric
    }
    private func passcodeLockMetrics() -> [String: CGFloat] {
        let traits = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first(where: { $0.activationState == .foregroundActive })?.traitCollection ?? .current
        let displayScale = traits.displayScale
        if let cached = Self.passcodeLockMetricsCache[displayScale] { return cached }
        let pointSize: CGFloat = 44
        let configuration = UIImage.SymbolConfiguration(pointSize: pointSize, weight: .semibold)
        var naturalSize: CGSize?
        traits.performAsCurrent {
            naturalSize = UIImage(systemName: "lock.shield.fill", withConfiguration: configuration)?.size
        }
        // SwiftUI Image uses this natural symbol frame inside its stack.
        // An isolated host rounds the complete fitting result;
        // reserving that larger box adds a pixel to every following RN child.
        let size = naturalSize ?? CGSize(width: 47, height: 154.0 / 3)
        let metric: [String: CGFloat] = ["fontSize": pointSize, "width": size.width, "height": size.height]
        Self.passcodeLockMetricsCache[displayScale] = metric
        return metric
    }
    func presentationSnapshot() -> [String: Any] {
        // UIFontMetrics is authoritative for each semantic text style. Explicit
        // ratios also reach Fabric text, whose measurement can occur off the UI
        // thread and outside the view controller's trait override.
        let traits = UITraitCollection(preferredContentSizeCategory: preferredContentSize)
        let styles: [String: UIFont.TextStyle] = ["body": .body, "headline": .headline, "subheadline": .subheadline, "footnote": .footnote, "caption1": .caption1, "caption2": .caption2, "title1": .title1, "title2": .title2, "title3": .title3, "largeTitle": .largeTitle, "callout": .callout]
        let scales = styles.mapValues { UIFontMetrics(forTextStyle: $0).scaledValue(for: 100, compatibleWith: traits) / 100 }
        // SwiftUI retains the semantic font's leading between lines. Fabric
        // deliberately omits it; migrated native flows use these public metrics
        // to preserve that layout, including negative leading at large sizes.
        let nativeTextMetrics = styles.mapValues { style in
            let font = UIFont.preferredFont(forTextStyle: style, compatibleWith: traits)
            return ["fontSize": font.pointSize, "lineHeight": font.lineHeight, "leading": font.leading]
        }
        return ["locale": Bundle.main.preferredLocalizations.first ?? "en", "textScales": model.customization.textSizeMatchesSystem ? NSNull() : scales, "nativeTextMetrics": nativeTextMetrics,
                "nativeSymbolMetrics": ["searchClear": searchClearMetrics(traits: traits), "passcodeLock": passcodeLockMetrics()]]
    }
}
