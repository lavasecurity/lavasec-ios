import UIKit

/// Extends the results' native scroll edge behind the sheet's fixed controls.
/// Explicit scaffold identifiers survive Fabric's optional content containers;
/// traversal stays inside this header's parent and never follows its categories.
@MainActor
final class LavaSheetScrollEdge {
    private var interaction: (any UIInteraction)?

    @discardableResult
    func update(from decoration: UIView) -> Bool {
        guard #available(iOS 26.0, *), let window = decoration.window,
              let header = ancestor(of: decoration, identified: "sheet.pinned-header"),
              let resultsBranch = header.superview?.subviews.first(where: { $0.accessibilityIdentifier == "sheet.results" }),
              let results = firstScrollView(in: resultsBranch), results.window === window else {
            reset()
            return false
        }
        if let current = interaction as? UIScrollEdgeElementContainerInteraction,
           current.view === header, current.scrollView === results { return true }
        reset()
        let current = UIScrollEdgeElementContainerInteraction()
        current.scrollView = results
        current.edge = .top
        header.addInteraction(current)
        interaction = current
        return true
    }

    func reset() {
        if #available(iOS 26.0, *), let current = interaction as? UIScrollEdgeElementContainerInteraction {
            current.scrollView = nil
        }
        if let interaction { interaction.view?.removeInteraction(interaction) }
        interaction = nil
    }

    private func firstScrollView(in view: UIView) -> UIScrollView? {
        if let scroll = view as? UIScrollView { return scroll }
        for child in view.subviews {
            if let scroll = firstScrollView(in: child) { return scroll }
        }
        return nil
    }

    private func ancestor(of view: UIView, identified identifier: String) -> UIView? {
        var candidate = view.superview
        while let current = candidate {
            if current.accessibilityIdentifier == identifier { return current }
            candidate = current.superview
        }
        return nil
    }
}
