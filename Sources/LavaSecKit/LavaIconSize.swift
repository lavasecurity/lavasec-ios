import CoreGraphics

/// The shared SF Symbol glyph-size scale — the typographic counterpart to
/// `LavaSpacing`/`LavaSurface`, for the point sizes fed to `.font(.system(size:))`
/// on `Image(systemName:)` glyphs.
///
/// Why this lives in `LavaSecCore` and not `LavaTokens.swift`: the app *and* the
/// widget extension both render status glyphs, but the widget can't see the app
/// target's `LavaTokens.swift`. The values here are plain, platform-agnostic
/// design data (the same shape as the numbers in `design/lava-design-tokens.json`),
/// so they belong in the one module both targets already link. SwiftUI `Font`
/// helpers that *aren't* portable (see `LavaTypography`) stay in the app.
///
/// Before this scale existed, the same glyph was sized by hand at each call site,
/// so one symbol drifted across screens — most visibly the security shield, which
/// rendered at 42 / 44 / 46 / 48 depending on which screen you were on. Naming the
/// steps collapses those near-duplicates to one value per role.
public enum LavaIconSize {
    /// Tiny overlay badge glyph — e.g. the "+" composited onto the Security+ mark.
    /// Reconciles the prior odd `9.9` to a whole point.
    public static let badge: CGFloat = 10
    /// Inline icon sitting beside body/footnote text (e.g. a filter action label).
    public static let inline: CGFloat = 13
    /// Small standalone decoration glyph — inline arrows, flow connectors, the
    /// Dynamic Island compact status glyph.
    public static let small: CGFloat = 16
    /// Navigation-control glyph — the back chevron and its peers, the Dynamic
    /// Island expanded status glyph.
    public static let control: CGFloat = 17
    /// Compact variant of `endpoint`, for space-constrained diagram tiles.
    public static let endpointCompact: CGFloat = 25
    /// Medium glyph centered in a circular tile (e.g. a data-flow endpoint).
    public static let endpoint: CGFloat = 30
    /// Large decorative glyph standing alone in a flow node (phone / globe).
    public static let node: CGFloat = 40
    /// Hero status glyph — the security shield on the lock, status, and
    /// diagnostics screens. Reconciles the prior 42 / 44 / 46 / 48 disagreement
    /// (one symbol, six call sites, four sizes) to a single value.
    public static let hero: CGFloat = 44
    /// Oversized result glyph — the success check / failure triangle that caps the
    /// filter-preparation flow. Reconciles the prior 54 / 58 (two glyphs sharing
    /// one visual slot) to a single value.
    public static let heroResult: CGFloat = 56
}
