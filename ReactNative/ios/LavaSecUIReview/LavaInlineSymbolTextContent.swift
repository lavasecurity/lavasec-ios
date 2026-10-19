import SwiftUI
import UIKit

@MainActor
enum LavaInlineSemanticFont {
    private static let categories: [UIContentSizeCategory] = [
        .extraSmall, .small, .medium, .large, .extraLarge, .extraExtraLarge, .extraExtraExtraLarge,
        .accessibilityMedium, .accessibilityLarge, .accessibilityExtraLarge,
        .accessibilityExtraExtraLarge, .accessibilityExtraExtraExtraLarge
    ]

    static func textStyle(_ value: String) -> UIFont.TextStyle {
        switch value {
        case "title1": .title1
        case "subheadline": .subheadline
        case "footnote": .footnote
        default: .headline
        }
    }

    static func resolve(size: CGFloat, weight: String, traits: UITraitCollection,
                        textStyle: UIFont.TextStyle = .headline) -> UIFont {
        let fallbackSize: CGFloat = textStyle == .title1 ? 28 : textStyle == .subheadline ? 15 : textStyle == .footnote ? 13 : 17
        let pointSize = size.isFinite ? max(1, size) : fallbackSize
        let current = UIFont.preferredFont(forTextStyle: textStyle, compatibleWith: traits)
        // Fabric can configure before containment supplies the parent's traits.
        // RN's measured semantic point size identifies the exact native font;
        // resizing a font from another category also scales its wrong leading.
        let matches: (UIFont) -> Bool = { abs($0.pointSize - pointSize) < 0.001 }
        let semantic = matches(current) ? current : categories.lazy.map {
            UIFont.preferredFont(forTextStyle: textStyle,
                                 compatibleWith: UITraitCollection(preferredContentSizeCategory: $0))
        }.first(where: matches) ?? current
        let font = semantic.withSize(pointSize)
        if textStyle == .headline {
            if weight == "semibold" { return font } // Headline's native default.
        }
        let requestedWeight: UIFont.Weight = weight == "semibold" ? .semibold : weight == "bold" ? .bold : .regular
        let descriptor = font.fontDescriptor.addingAttributes([
            .traits: [UIFontDescriptor.TraitKey.weight: requestedWeight.rawValue]
        ])
        return UIFont(descriptor: descriptor, size: pointSize)
    }
}

/// A single native text run preserves SF Symbol baseline and multiline wrapping.
/// Its React owner supplies every visible value and owns the surrounding panel.
@objc(LavaInlineSymbolTextContent)
@MainActor
final class LavaInlineSymbolTextContent: UIView {
    @objc var onSizeChange: ((String, Double, Double) -> Void)?
    private var host: UIHostingController<AnyView>?
    private var measurementID = ""
    private var reportedID = ""
    private var reportedSize = CGSize.zero
    required init?(coder: NSCoder) { nil }
    override init(frame: CGRect) { super.init(frame: frame); isUserInteractionEnabled = false }
    @objc(configureWithTitle:symbol:tintColor:textColor:fontSize:fontWeight:colorScheme:measurementID:textStyle:contentAlignment:multilineAlignment:)
    func configure(title: String, symbol: String, tintColor: UIColor, textColor: UIColor,
                   fontSize: Double, fontWeight: String, colorScheme: String, measurementID: String,
                   textStyle: String, contentAlignment: String, multilineAlignment: String) {
        self.measurementID = measurementID
        let font = LavaInlineSemanticFont.resolve(size: fontSize, weight: fontWeight, traits: traitCollection,
                                                textStyle: LavaInlineSemanticFont.textStyle(textStyle))
        let alignment: Alignment = contentAlignment == "center" ? .center : contentAlignment == "trailing" ? .trailing : .leading
        let textAlignment: TextAlignment = multilineAlignment == "center" ? .center : multilineAlignment == "trailing" ? .trailing : .leading
        let inline = symbol.isEmpty ? Text(title).foregroundColor(Color(uiColor: textColor))
            : Text(Image(systemName: symbol)).foregroundColor(Color(uiColor: tintColor))
                + Text(" \(title)").foregroundColor(Color(uiColor: textColor))
        let body = inline
            .font(Font(font))
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: alignment)
            .multilineTextAlignment(textAlignment)
            .accessibilityLabel(title)
            .preferredColorScheme(colorScheme == "dark" ? .dark : .light)
        if let host { host.rootView = AnyView(body) }
        else {
            let host = UIHostingController(rootView: AnyView(body)); host.safeAreaRegions = []
            host.view.backgroundColor = .clear; self.host = host
        }
        updateContainment(); setNeedsLayout()
    }
    override func didMoveToWindow() { super.didMoveToWindow(); updateContainment(); setNeedsLayout() }
    override func layoutSubviews() {
        super.layoutSubviews(); updateContainment()
        guard let host, bounds.width > 0 else { return }
        let size = host.sizeThatFits(in: CGSize(width: bounds.width, height: CGFloat.greatestFiniteMagnitude))
        let accepted = CGSize(width: bounds.width, height: size.height)
        guard accepted.height.isFinite, accepted.height > 0,
              measurementID != reportedID || accepted != reportedSize else { return }
        reportedID = measurementID; reportedSize = accepted
        let id = measurementID
        // Fabric installs the emitter after applying initial props. Never emit
        // stale geometry after a later text/font/width update or recycling.
        DispatchQueue.main.async { [weak self] in
            guard let self, self.measurementID == id, self.reportedID == id,
                  self.reportedSize == accepted, self.bounds.width == accepted.width else { return }
            self.onSizeChange?(id, Double(accepted.width), Double(accepted.height))
        }
    }
    private func updateContainment() {
        if let host { LavaNativeContainment.update(host, in: self) { $0.backgroundColor = .clear } }
    }
    @objc func resetForRecycle() {
        if let host { LavaNativeContainment.remove(host) }
        host = nil; measurementID = ""; reportedID = ""; reportedSize = .zero
    }
}
