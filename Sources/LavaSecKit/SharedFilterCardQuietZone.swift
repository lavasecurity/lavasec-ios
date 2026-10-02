import CoreGraphics

/// How much clear space a rendered share-card QR needs around it.
///
/// The QR spec requires a quiet zone of four modules on **all four sides**. On this
/// card the horizontal side is satisfied by the 33pt page margin, which is why the
/// original sizing reasoned only about width — and why the vertical side, where the
/// neighbours are a summary chip above and instruction text below, was left roughly
/// a third of what it needed. A code can be perfectly valid and still fail to scan
/// once a messenger recompresses it, so this is a correctness rule, not a style one.
public enum SharedFilterCardQuietZone {
    /// The spec's requirement, in modules, per side.
    public static let requiredModules: CGFloat = 4

    /// `CIQRCodeGenerator` draws one module of border inside its own output, so the
    /// generated image already carries part of the quiet zone. Measured from the
    /// filter's output extent, which is the symbol's module count plus this border
    /// on each side — not assumed from the QR version tables.
    public static let generatorBorderModules: CGFloat = 1

    /// Module width when a `moduleCount`-wide image is drawn at `renderedSide`.
    ///
    /// `moduleCount` is the image's full extent in modules, border included, which is
    /// what dividing the image's pixel width by its points-per-module yields.
    public static func moduleWidth(renderedSide: CGFloat, moduleCount: CGFloat) -> CGFloat {
        guard moduleCount > 0 else { return 0 }
        return renderedSide / moduleCount
    }

    /// Clear space the *card* must add per side, beyond the generator's own border.
    ///
    /// Pass the widest module the code can ever resolve to — i.e. compute it at the
    /// code's maximum rendered side. A code that lays out smaller has thinner modules
    /// and a smaller requirement, so a clearance sized for the maximum is always
    /// sufficient. That one-directional relationship is what keeps this safe to use
    /// as a constant inset against a flexibly-sized code.
    public static func additionalClearance(widestModule: CGFloat) -> CGFloat {
        max(0, (requiredModules - generatorBorderModules) * widestModule)
    }

    /// Whether `clearance` points of white satisfies the four-module rule.
    public static func isSufficient(clearance: CGFloat, moduleWidth: CGFloat) -> Bool {
        clearance + generatorBorderModules * moduleWidth >= requiredModules * moduleWidth
    }
}
