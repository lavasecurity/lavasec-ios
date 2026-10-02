import SwiftUI
import LavaSecKit

enum LavaWebLinks {
    static let support = URL(string: "https://lavasecurity.app/support/")!
    static let privacy = URL(string: "https://lavasecurity.app/privacy/")!
    // No custom EULA is hosted; Apple's standard EULA is the compliant default
    // for the Guideline 3.1.2 "Terms of Use" link.
    static let terms = URL(string: "https://www.apple.com/legal/internet-services/itunes/dev/stdeula/")!
}

enum SettingsSubpageLayout {
    static let spacing: CGFloat = 18
    static let feedbackSpacing: CGFloat = 18
}

/// The shared layout for a Settings sub-screen — the single place the "Lava Settings Page"
/// anatomy is enforced, so a non-technical user (think a parent with no security background)
/// meets the same shape on every screen instead of a different layout each time:
///
///   1. Large navigation `title`, always run through `.lavaLocalized`.
///   2. Exactly one `intro` panel (`LavaInfoPanel`) above all sections — one plain sentence
///      saying what the screen does plus the single reassurance that matters. On a
///      `.technical` (Workshop) screen this panel is the plain-language on-ramp. Typed as a
///      concrete `LavaInfoPanel?` rather than a generic slot so the "one panel" rule is
///      structural, not a convention each screen has to remember.
///   3. The body is titled `LavaSectionGroup`s; per-option helper text lives in the group's
///      `footer:`, not scattered `lavaQuietNoteText`.
///   4. `tier` declares the screen's depth (`LavaTier`): `.calm` for everyday screens,
///      `.celebratory` for delight, `.technical` for power-user surfaces. The tier governs
///      the reading level — how much jargon is allowed — see `LavaTier` in LavaTokens.swift.
///
/// Sales surfaces (Upgrade) are intentionally exempt from the strict body anatomy but still
/// declare a `tier` and reuse the shared components/tokens.
struct SettingsSubpageContent<Content: View>: View {
    let title: String?
    let tier: LavaTier
    let intro: LavaInfoPanel?
    let introAction: LavaSectionFooterLink?
    let spacing: CGFloat
    let scrolls: Bool
    let refreshAction: (() async -> Void)?
    let content: Content

    init(
        title: String? = nil,
        tier: LavaTier = .calm,
        intro: LavaInfoPanel? = nil,
        introAction: LavaSectionFooterLink? = nil,
        spacing: CGFloat = SettingsSubpageLayout.spacing,
        scrolls: Bool = true,
        refreshAction: (() async -> Void)? = nil,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.tier = tier
        self.intro = intro
        self.introAction = introAction
        self.spacing = spacing
        self.scrolls = scrolls
        self.refreshAction = refreshAction
        self.content = content()
    }

    var body: some View {
        LavaScreenContent(
            spacing: spacing,
            scrolls: scrolls,
            refreshAction: refreshAction
        ) {
            if let intro {
                LavaSettingsIntroduction(summary: intro.description ?? intro.title, action: introAction)
            }
            content
        }
        .lavaTier(tier)
        .modifier(SettingsSubpageNavigationTitle(title: title))
    }
}

/// Applies the localized large navigation title when a subpage declares one, leaving the
/// chrome untouched otherwise. Keeps the `.lavaLocalized` call in one place so no screen can
/// ship an unlocalized title.
private struct SettingsSubpageNavigationTitle: ViewModifier {
    let title: String?

    @ViewBuilder
    func body(content: Content) -> some View {
        if let title {
            content.navigationTitle(title.lavaLocalized)
        } else {
            content
        }
    }
}

struct SettingsActionRow<Icon: View>: View {
    let title: String
    let iconTint: Color
    let titleTint: Color
    let icon: Icon

    init(
        title: String,
        iconTint: Color = LavaStyle.safeGreen,
        titleTint: Color = .primary,
        @ViewBuilder icon: () -> Icon
    ) {
        self.title = title
        self.iconTint = iconTint
        self.titleTint = titleTint
        self.icon = icon()
    }

    var body: some View {
        HStack(spacing: 12) {
            icon
                .foregroundStyle(iconTint)
                .frame(width: 28, height: 28)

            Text(title.lavaLocalized)
                .font(LavaTypography.rowTitle)
                .foregroundStyle(titleTint)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
    }
}


/// One body-only introduction shared by Settings details and diagnostic pages.
struct LavaSettingsIntroduction: View {
    let summary: String
    var action: LavaSectionFooterLink? = nil
    var conclusion: String? = nil
    var actionAccessory: LavaNavigationCardAccessory = .chevron
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(summary.lavaLocalized).lavaSupportingText(color: LavaStyle.primaryText)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(LavaSpacing.lg)
            if let conclusion {
                Text(conclusion.lavaLocalized).lavaSupportingText(color: LavaStyle.primaryText)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(LavaSpacing.lg)
            }
            if let action {
                Button(action: action.action) {
                    LavaNavigationCardLabel(badge: nil, badgeSize: LavaNavigationRowMetrics.glyphPointSize, rowSpacing: LavaSpacing.md,
                        title: action.title, summary: .none, accessory: actionAccessory)
                }.buttonStyle(LavaCondensedRowButtonStyle())
            }
        }.background(LavaStyle.softGreen, in: RoundedRectangle(cornerRadius: LavaSurface.cardCornerRadius))
    }
}

/// A standalone settings row keeps its explanation on the page surface. Both
/// native and React settings use the shared small gap and flush helper baseline.
struct LavaSettingsRow<Content: View>: View {
    var surface: LavaSurface.Role = .card
    var footer: String? = nil
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: LavaSpacing.sm) {
            LavaCondensedList(surface: surface) { content() }
            if let footer {
                Text(footer.lavaLocalized).lavaQuietNoteText()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
    }
}
