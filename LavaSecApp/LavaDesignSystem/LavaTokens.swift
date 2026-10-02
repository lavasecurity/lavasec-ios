import SwiftUI
import UIKit

enum LavaStyle {
    typealias RGB = (red: CGFloat, green: CGFloat, blue: CGFloat)

    static let safeGreen = adaptiveColor(
        light: (0.141176, 0.403922, 0.262745),
        dark: (0.505882, 0.749020, 0.615686)
    )
    static let safeControlGreen = adaptiveColor(
        light: (0.156863, 0.419608, 0.270588),
        dark: (0.168627, 0.321569, 0.231373)
    )
    static let softGreen = adaptiveColor(
        light: (0.878431, 0.925490, 0.854902),
        dark: (0.145098, 0.211765, 0.172549)
    )
    static let panelActionGreen = adaptiveColor(
        light: (0.141176, 0.403922, 0.262745),
        dark: (0.505882, 0.749020, 0.615686)
    )
    static let panelActionFill = adaptiveColor(
        light: (0.878431, 0.925490, 0.854902),
        dark: (0.145098, 0.211765, 0.172549)
    )
    static let panelActionPressedFill = adaptiveColor(
        light: (0.819608, 0.886275, 0.788235),
        dark: (0.188235, 0.294118, 0.223529)
    )
    static let quietControl = adaptiveColor(
        light: (0.349020, 0.407843, 0.356863),
        dark: (0.231373, 0.274510, 0.247059)
    )
    static let lavaOrange = adaptiveColor(
        light: (0.95, 0.34, 0.18),
        dark: (1.00, 0.54, 0.34)
    )
    static let lavaOrangeSoft = adaptiveColor(
        light: (1.00, 0.92, 0.86),
        dark: (0.30, 0.13, 0.08)
    )
    /// The orange used as FOREGROUND TEXT/glyphs. `lavaOrange` (bright) is a fine accent/fill but
    /// too light for text on light backgrounds — it measures ~2.93:1 on `lavaOrangeSoft` and ~3.4:1
    /// on card/panel, below the 4.5:1 WCAG text target. This darker burnt-orange clears it (light:
    /// 4.57:1 on soft, 5.30:1 on card). Dark mode keeps the bright orange, which already passes
    /// (5.84:1 on soft-dark). Use this wherever orange is the text color; keep `lavaOrange` for fills.
    static let lavaOrangeText = adaptiveColor(
        light: (0.75, 0.25, 0.09),
        dark: (1.00, 0.54, 0.34)
    )
    /// A darker orange for a SELECTED pill/segment fill that carries WHITE text. Plain `lavaOrange`
    /// as a white-text fill fails (3.40:1 light / 2.33:1 dark); this clears 4.5:1 in both (4.82:1
    /// light / 5.64:1 dark). Non-selected fills keep `lavaOrange`/`lavaOrangeSoft`.
    static let lavaOrangeSelectedFill = adaptiveColor(
        light: (0.78, 0.28, 0.12),
        dark: (0.68, 0.28, 0.15)
    )
    static let cream = adaptiveColor(
        light: (1.000000, 0.980392, 0.945098),
        dark: (0.078431, 0.078431, 0.078431)
    )
    static let ink = adaptiveColor(
        light: (0.149020, 0.227451, 0.168627),
        dark: (0.964706, 0.945098, 0.898039)
    )
    static let primaryText = ink
    /// System chrome has neutral ink; green denotes an affirmative action.
    static let navigationForeground = adaptiveColor(
        light: (0.0, 0.0, 0.0),
        dark: (1.0, 1.0, 1.0)
    )
    static let secondaryText = adaptiveColor(
        light: (0.349020, 0.407843, 0.356863),
        dark: (0.741176, 0.741176, 0.713725)
    )
    static let tertiaryText = adaptiveColor(
        light: (0.407843, 0.458824, 0.415686),
        dark: (0.588235, 0.607843, 0.584314)
    )
    static let groupedBackground = adaptiveColor(
        light: (0.980392, 0.972549, 0.941176),
        dark: (0.078431, 0.078431, 0.078431)
    )
    static let cardBackground = adaptiveColor(
        light: (0.941176, 0.933333, 0.890196),
        dark: (0.141176, 0.141176, 0.141176)
    )
    static let panelBackground = adaptiveColor(
        light: (0.941176, 0.933333, 0.890196),
        dark: (0.141176, 0.141176, 0.141176)
    )
    static let panelStroke = adaptiveColor(
        light: (0.780392, 0.831373, 0.772549),
        dark: (0.270588, 0.270588, 0.270588)
    )
    static let guardianSleepGray = adaptiveColor(
        light: (0.67, 0.71, 0.69),
        dark: (0.36, 0.40, 0.38)
    )
    static let guardianFaceLight = adaptiveColor(
        light: (1.00, 0.98, 0.93),
        dark: (0.94, 0.98, 0.95)
    )
    /// The one color the brand reserves for a single meaning: danger / error.
    /// Red is never decorative here — it only ever marks an error or destructive state.
    static let dangerRed = adaptiveColor(
        light: (0.86, 0.20, 0.18),
        dark: (1.00, 0.45, 0.40)
    )
    /// Semantic alias for error-message text. Resolves to `dangerRed`.
    static let errorText = dangerRed
    /// Neutral button tint for confirmation alerts. The app tints itself green, which a
    /// native alert otherwise inherits for its Cancel/affirmative buttons; this resolves
    /// them to the calm label color instead, so the escape action reads like the old
    /// "Not now" rather than a branded primary. Destructive roles stay `dangerRed`.
    static let confirmationButtonTint = primaryText

    // Shared interaction materials. Keep these roles across the RN and native hosts.
    static let actionForeground = adaptiveColor(
        light: (1.000000, 0.980392, 0.945098),
        dark: (0.929412, 0.952941, 0.921569)
    )
    static let pressedSurface = adaptiveColor(
        light: (0.890196, 0.898039, 0.850980),
        dark: (0.188235, 0.203922, 0.188235)
    )
    static let disabledSurface = adaptiveColor(
        light: (0.898039, 0.898039, 0.854902),
        dark: (0.188235, 0.200000, 0.188235)
    )
    static let separator = adaptiveColor(
        light: (0.823529, 0.839216, 0.792157),
        dark: (0.231373, 0.250980, 0.231373)
    )
    static let focusRing = adaptiveColor(
        light: (0.141176, 0.403922, 0.262745),
        dark: (0.505882, 0.749020, 0.615686)
    )

    private static func adaptiveColor(light: RGB, dark: RGB) -> Color {
        Color(uiColor: UIColor { traits in
            let rgb = traits.userInterfaceStyle == .dark ? dark : light
            return UIColor(red: rgb.red, green: rgb.green, blue: rgb.blue, alpha: 1)
        })
    }
}

enum LavaSurface {
    enum Role {
        case card
        case success
        case panel
        case selection(isSelected: Bool)
    }

    static let cardCornerRadius: CGFloat = 24
    static let outlineWidth: CGFloat = 1
    static let compactCornerRadius: CGFloat = 16
    static let selectionCornerRadius: CGFloat = 12
    /// Shared rounded action geometry across native sheets and the RN interface.
    static let controlCornerRadius: CGFloat = 16
    /// Shared action-button height. The panel/standalone/secondary action button
    /// styles all render at this single height so sibling buttons line up without
    /// any per-call-site hand adjustments (UR-4: Clear/Disable backup no longer
    /// disagree with the sign-in/standalone buttons beside them).
    static let actionButtonHeight: CGFloat = 44
    /// Portable pill-shape radius retained by the cross-platform design-token contract.
    static let pillCornerRadius: CGFloat = 14
    /// Small icon-badge corner radius (e.g. the 34×34 nav-row glyph chip).
    static let iconBadgeCornerRadius: CGFloat = 10
    static let cardBackground = LavaStyle.cardBackground
    static let panelBackground = LavaStyle.panelBackground
    static let panelStroke = LavaStyle.panelStroke
    static let selectionBackground = cardBackground
    static let selectedSelectionBackground = LavaStyle.softGreen
}

struct LavaSurfaceBackground: ViewModifier {
    let role: LavaSurface.Role
    let cornerRadius: CGFloat
    let borderTint: Color?

    @ViewBuilder
    func body(content: Content) -> some View {
        // Keep the inset outline outside the content clip. Applying that clip
        // again to the outline would multiply antialiased coverage at its edge.
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        switch role {
        case .card:
            content
                .background(LavaSurface.cardBackground, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        case .success:
            content
                .background(LavaStyle.softGreen, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        case .panel:
            content
                .background(LavaSurface.panelBackground, in: shape)
                .clipShape(shape)
                .overlay {
                    // Ordinary information uses a soft surface. An explicit warning or
                    // selected-Guard accent keeps its intentional, inset outline.
                    if let borderTint {
                        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                            .strokeBorder(borderTint, lineWidth: 1)
                    }
                }
        case .selection(let isSelected):
            content
                .background(
                    isSelected ? LavaSurface.selectedSelectionBackground : LavaSurface.selectionBackground,
                    in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                )
        }
    }
}

extension View {
    func lavaSurface(_ role: LavaSurface.Role, cornerRadius: CGFloat? = nil, borderTint: Color? = nil) -> some View {
        let resolvedCornerRadius: CGFloat
        switch role {
        case .card, .success:
            resolvedCornerRadius = cornerRadius ?? LavaSurface.cardCornerRadius
        case .panel:
            resolvedCornerRadius = cornerRadius ?? LavaSurface.cardCornerRadius
        case .selection:
            resolvedCornerRadius = cornerRadius ?? LavaSurface.selectionCornerRadius
        }

        return modifier(LavaSurfaceBackground(role: role, cornerRadius: resolvedCornerRadius, borderTint: borderTint))
    }

    func lavaPanelBackground(cornerRadius: CGFloat = LavaSurface.cardCornerRadius, borderTint: Color? = nil) -> some View {
        lavaSurface(.panel, cornerRadius: cornerRadius, borderTint: borderTint)
    }
}

// MARK: - Spacing scale

/// The shared spacing scale. Replaces the ~17 distinct ad-hoc padding values that
/// coexisted across the app with one legible, portable set of steps.
enum LavaSpacing {
    static let xs: CGFloat = 4
    static let sm: CGFloat = 8
    static let md: CGFloat = 12
    static let lg: CGFloat = 16
    static let xl: CGFloat = 18
    /// Information surfaces share compact insets, including Guard's stable spotlight.
    static let infoPanelHorizontalInset: CGFloat = 16
    static let infoPanelVerticalInset: CGFloat = 12
    /// Keeps a quiet action close to its explanation without changing its touch target.
    static let explanationToLink: CGFloat = 8
    /// Expands a quiet link's real target without adding a blank row to text flow.
    static let quietLinkInteractionInset: CGFloat = 12
    static let screenHorizontal: CGFloat = 18
    static let screenTop: CGFloat = 16
    static let screenBottom: CGFloat = 96
}

// MARK: - Typography

/// SwiftUI `Font` tokens for the few places the app needs a specific, non-Dynamic-Type
/// display face. Body and label text uses the system semantic styles directly
/// (`.headline`, `.subheadline`, …) so it tracks the user's text-size setting; this
/// enum is only for genuinely fixed display faces that those styles don't cover.
///
/// Portable *numeric* glyph sizes live in `LavaIconSize` (in `LavaSecKit`, so the
/// widget can share them); these helpers wrap SwiftUI's `Font`, which is app-only.
/// The app's type scale — one named role per kind of text, so the same kind is one size
/// everywhere and cannot drift per screen (the color analog is `LavaStyle`). All roles are
/// Dynamic-Type-scaling semantic fonts except the fixed metric numeral. Prefer the matching
/// `View.lava…Text()` modifier at call sites; the raw `Font` here is for APIs that take a `Font`
/// (e.g. `LavaCondensedListItem.titleFont`).
/// Outcome identity shared by native views, bridge payloads and generated UI tokens.
enum LavaOutcomeSymbol {
    static let blocked = "xmark.circle.fill"
    static let allowed = "arrow.right.circle.fill"
    /// Stroke-only counterparts for dense filter-content lists (blocklists,
    /// blocked and allowed domains). The shape matches the filled semantic above
    /// with the fill removed; a filled, tinted mark reads too heavy in a list, so
    /// these rows draw the outline in the ordinary label color. Keep both pairs in
    /// one definition so the blocked/allowed shape cannot drift between the filter
    /// detail and the import review.
    static let blockedOutline = "xmark.circle"
    static let allowedOutline = "arrow.right.circle"
}

enum LavaTypography {
    /// Primary value/title within a story panel, shared by filter identity states.
    static let primaryValue = Font.title2.bold()

    /// Repeated row content sits below section headings in size, with matching semibold emphasis.
    /// Use the system subheadline ramp; never shrink individual long values to fit.
    static let rowTitle = Font.subheadline.weight(.semibold)

    /// Quiet row metadata shares the title size and Dynamic Type ramp.
    static let rowMetadata = Font.subheadline

    /// Title of a tappable ENTRY CARD or navigation row (the surfaces that OPEN a list/detail).
    /// One step above a row title: `.headline` (17 pt semibold).
    static let cardTitle = Font.headline

    /// Prominent actions retain their 17pt semibold emphasis when row content is quieter.
    static let actionLabel = Font.headline

    /// Functional group headings retain the same 17pt semibold face in both hosts.
    static let sectionLabel = Font.headline

    /// Readable labels above editable fields and their read-only review values.
    static let fieldLabel = Font.footnote.weight(.semibold)

    /// Large rounded numeral for an overview metric block's headline value (e.g.
    /// the "blocked today" count). Apply `.monospacedDigit()` at the call site so
    /// the digits stay column-aligned as the value animates.
    static let metricNumeral = Font.system(size: 42, weight: .bold, design: .rounded)
}

// MARK: - Row metrics

/// Shared row geometry for settings, toggles, and embedded navigation rows.
/// Single-line rows share a 58pt floor. Content keeps its 12pt vertical insets;
/// accessory touch targets are centered separately, without adding those insets
/// around their invisible hit area. Wrapped content grows naturally above the floor.
enum LavaRowHeight {
    static let standard: CGFloat = 58
    /// A minimum inset around content that wraps; applied before the shared row floor.
    static let verticalInset: CGFloat = 12
    /// Horizontal inset shared by every row, so content lines up whether the row is a
    /// standalone control card or sits inside a condensed list.
    static let horizontalInset: CGFloat = 16
}

/// Utility-row glyphs share the same optical sizes in native and React Native.
/// The content-safe-area origin of a full-size presented sheet is its header origin.
/// Circular controls have the same inset from the top and the nearest side.
enum LavaFullSheetMetrics {
    static let headerInset: CGFloat = 18
    static let headerBottomInset: CGFloat = 12
}

/// Scoped identity artwork; list headings and navigation glyphs keep their own sizes.
/// Both metric groups are parsed by ReactNative/scripts/generate-tokens.mjs, so they
/// stay declared even where no native view consumes them directly.
enum LavaFilterIdentityMetrics {
    static let emojiPointSize: CGFloat = 18
}

enum LavaNavigationRowMetrics {
    static let glyphPointSize: CGFloat = 20
    static let accessoryPointSize: CGFloat = 12
}

// MARK: - Depth semantics

/// The product's three depths, made legible in the design system — the code
/// expression of Lava's "calm core, earned depth" model.
///
/// - `calm` = the Floor: default "just works" protection surfaces, for everyone.
/// - `celebratory` = the Window: awareness & delight (streaks, unlocks, success) —
///   opt-in, never nags.
/// - `technical` = the Workshop: advanced/inspectable surfaces (DNS, Nerd Stats,
///   diagnostics) — invisible until sought.
///
/// Governance: place a new surface in the depth that matches its job, then let the
/// tier supply its defaults. `LavaTier` is a *vocabulary + defaults*, not a full
/// re-theme — wire it into representative containers; do not retrofit every view.
enum LavaTier: Sendable {
    case calm, celebratory, technical

    /// On iOS this returns today's exact tokens; Phase 3 swaps `accent` to a color role.
    var accent: Color {
        switch self {
        case .calm:        LavaStyle.safeGreen     // trust
        case .celebratory: LavaStyle.lavaOrange    // "Lava handled it"
        case .technical:   LavaStyle.ink           // restrained
        }
    }

    /// Celebration motion (mascot cycles, count-ups, success haptics) is sanctioned
    /// only in the Window.
    var allowsDelightMotion: Bool { self == .celebratory }

    /// Workshop metadata prefers monospaced numerals for scannability.
    var usesMonospacedMetadata: Bool { self == .technical }
}

private struct LavaTierKey: EnvironmentKey { static let defaultValue: LavaTier = .calm }

extension EnvironmentValues {
    var lavaTier: LavaTier {
        get { self[LavaTierKey.self] }
        set { self[LavaTierKey.self] = newValue }
    }
}

extension View {
    /// Declares the design-system depth tier for a subtree.
    func lavaTier(_ tier: LavaTier) -> some View { environment(\.lavaTier, tier) }

    /// Opt-in metadata treatment that reads the surrounding `LavaTier`: in the
    /// Workshop (`.technical`) it monospaces digits for scannability; elsewhere it
    /// is a no-op. Demonstrates the tier read-through.
    func lavaTierMetadata() -> some View { modifier(LavaTierMetadataModifier()) }
}

private struct LavaTierMetadataModifier: ViewModifier {
    @Environment(\.lavaTier) private var lavaTier

    @ViewBuilder
    func body(content: Content) -> some View {
        if lavaTier.usesMonospacedMetadata {
            content.monospacedDigit()
        } else {
            content
        }
    }
}

/// Shared native and React Native toolbar geometry, including SF Symbol optical sizes.
enum LavaToolbarMetrics {
    static let buttonSize: CGFloat = 44
    static let iconFrameSize: CGFloat = 24
    // Matches the system navigation back chevron so custom flow-back buttons (import flow,
    // backup, custom resolver, bug report) are visually consistent with screens that use the
    // native back button — was 22pt, which read noticeably larger than the system chevron.
    static let chevronIconPointSize: CGFloat = 17
    static let xmarkIconPointSize: CGFloat = 15
    static let plusIconPointSize: CGFloat = 18
    static let checkmarkIconPointSize: CGFloat = 17
    static let framedIconPointSize: CGFloat = 15
    static let wideIconPointSize: CGFloat = 15
    static let framedIconVerticalOffset: CGFloat = -1
}

/// A ranking destination is distinct from a time-series chart or filter funnel.
enum LavaGlyphSymbol {
    static let ranking = "lava.ranking"
}

/// Three ordered horizontal bars, shared by native and RN destination rows.
struct LavaRankingGlyph: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let thickness = rect.height * 0.08
        for (index, length) in [CGFloat(0.8), 0.56, 0.32].enumerated() {
            let bar = CGRect(x: rect.minX + rect.width * 0.1,
                             y: rect.minY + rect.height * (0.2 + CGFloat(index) * 0.3) - thickness / 2,
                             width: rect.width * length, height: thickness)
            path.addRoundedRect(in: bar, cornerSize: CGSize(width: thickness / 2, height: thickness / 2))
        }
        return path
    }
}

/// Shared by the live Guard panel and its onboarding handoff.
enum LavaGuardMetrics {
    static let mascotSize: CGFloat = 96
    static let mascotSlotHeight: CGFloat = 104
}
