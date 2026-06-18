import SwiftUI
import LavaSecCore
import UIKit

enum LavaStyle {
    typealias RGB = (red: CGFloat, green: CGFloat, blue: CGFloat)

    static let safeGreen = adaptiveColor(
        light: (0.16, 0.47, 0.34),
        dark: (0.45, 0.86, 0.63)
    )
    static let safeControlGreen = adaptiveColor(
        light: (0.16, 0.47, 0.34),
        dark: (0.13, 0.50, 0.32)
    )
    static let softGreen = adaptiveColor(
        light: (0.91, 0.97, 0.94),
        dark: (0.10, 0.22, 0.17)
    )
    static let panelActionGreen = adaptiveColor(
        light: (0.12, 0.40, 0.28),
        dark: (0.45, 0.86, 0.63)
    )
    static let panelActionFill = adaptiveColor(
        light: (0.82, 0.93, 0.87),
        dark: (0.12, 0.29, 0.21)
    )
    static let panelActionPressedFill = adaptiveColor(
        light: (0.75, 0.88, 0.81),
        dark: (0.15, 0.35, 0.25)
    )
    static let quietControl = adaptiveColor(
        light: (0.38, 0.46, 0.42),
        dark: (0.22, 0.30, 0.26)
    )
    static let lavaOrange = adaptiveColor(
        light: (0.95, 0.34, 0.18),
        dark: (1.00, 0.54, 0.34)
    )
    static let lavaOrangeSoft = adaptiveColor(
        light: (1.00, 0.92, 0.86),
        dark: (0.30, 0.13, 0.08)
    )
    static let cream = adaptiveColor(
        light: (1.00, 0.98, 0.94),
        dark: (0.11, 0.10, 0.09)
    )
    static let ink = adaptiveColor(
        light: (0.13, 0.23, 0.20),
        dark: (0.92, 0.96, 0.93)
    )
    static let primaryText = Color(uiColor: .label)
    static let secondaryText = Color(uiColor: .secondaryLabel)
    static let tertiaryText = Color(uiColor: .tertiaryLabel)
    static let groupedBackground = adaptiveColor(
        light: (0.96, 0.98, 0.96),
        dark: (0.04, 0.07, 0.06)
    )
    static let cardBackground = adaptiveColor(
        light: (1.00, 1.00, 1.00),
        dark: (0.17, 0.17, 0.18)
    )
    static let panelBackground = adaptiveColor(
        light: (0.98, 1.00, 0.98),
        dark: (0.01, 0.05, 0.035)
    )
    static let panelStroke = adaptiveColor(
        light: (0.72, 0.86, 0.76),
        dark: (0.16, 0.32, 0.24)
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
        case panel
        case selection(isSelected: Bool)
    }

    static let cardCornerRadius: CGFloat = 20
    static let compactCornerRadius: CGFloat = 16
    static let selectionCornerRadius: CGFloat = 12
    /// Action-control corner radius. Reconciles the prior button-style disagreement
    /// (panel defaulted to 10, standalone used 12) to one value — 12, matching
    /// `selectionCornerRadius` and the dominant explicit call-site usage.
    static let controlCornerRadius: CGFloat = 12
    /// Shared action-button height. The panel/standalone/secondary action button
    /// styles all render at this single height so sibling buttons line up without
    /// any per-call-site hand adjustments (UR-4: Clear/Disable backup no longer
    /// disagree with the sign-in/standalone buttons beside them).
    static let actionButtonHeight: CGFloat = 44
    /// Metric-pill corner radius (e.g. `LavaMetricPill`).
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
        switch role {
        case .card:
            content
                .background(LavaSurface.cardBackground, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        case .panel:
            content
                .background(LavaSurface.panelBackground, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .stroke(borderTint ?? LavaSurface.panelStroke, lineWidth: 1)
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
        case .card:
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
    static let screenHorizontal: CGFloat = 18
    static let screenTop: CGFloat = 16
    static let screenBottom: CGFloat = 96
}

// MARK: - Row metrics

/// Shared minimum height for settings / scaffold table rows. Standardizes the
/// touch target across toggle rows, system-link rows, and inline action rows so
/// sibling rows line up instead of each taking its content's intrinsic height
/// (UR-28: the Live Activities toggle row and the Language "open in Settings"
/// row no longer disagree). Anchored to a one-line info panel — a `LavaInfoCard`'s
/// 16pt top + bottom padding around a single ~22pt `.headline` line (e.g. the "Off"
/// status panel, ≈ 54pt) — so a single-line row sits level with a status panel
/// beside it. The earlier 40pt floor was below that natural panel height, so the
/// `LavaInfoPanel` floor never bound and panels read taller than the rows; 54
/// makes the floor bind and the two line up.
enum LavaRowHeight {
    static let standard: CGFloat = 54
    /// Horizontal inset shared by every row, so content lines up whether the row is a
    /// standalone control card or sits inside a condensed list.
    static let horizontalInset: CGFloat = 16
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
